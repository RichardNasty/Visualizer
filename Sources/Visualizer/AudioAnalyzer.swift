import Accelerate
import Foundation

struct AudioFeatures {
    static let bandCount = 48
    static let waveformCount = 512

    var bands = [Float](repeating: 0, count: AudioFeatures.bandCount)
    var waveform = [Float](repeating: 0, count: AudioFeatures.waveformCount)
    var level: Float = 0
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    /// 1 on a detected beat, decaying towards 0 afterwards.
    var beat: Float = 0
    var silent = true
}

/// Turns raw samples into smoothed, auto-levelled features the visuals can react to.
/// `push` is called from the audio thread, `analyze` from the render thread.
final class AudioAnalyzer {
    private let fftSize = 2048
    private let log2n: vDSP_Length = 11
    private let ringMask = 16384 - 1
    private var ring = [Float](repeating: 0, count: 16384)
    private var writeIndex = 0
    private var sampleRate: Double = 48_000
    private let lock = NSLock()

    private let fftSetup: FFTSetup
    private var window: [Float]
    private var frame: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var magnitudes: [Float]

    private var features = AudioFeatures()
    private var bandPeak: Float = 1e-3
    private var levelPeak: Float = 0.02
    private var previousBass: Float = 0
    private var previousMid: Float = 0
    private var fluxAverage: Float = 0
    private var lastBeat: Double = 0
    private var lastSound: Double = 0

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        frame = [Float](repeating: 0, count: fftSize)
        windowed = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        magnitudes = [Float](repeating: 0, count: fftSize / 2)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    func push(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        lock.lock()
        self.sampleRate = sampleRate
        for i in 0..<count {
            ring[writeIndex] = samples[i]
            writeIndex = (writeIndex + 1) & ringMask
        }
        lock.unlock()
    }

    func analyze(time: Double) -> AudioFeatures {
        let n = fftSize
        lock.lock()
        let start = (writeIndex - n + ring.count) & ringMask
        for i in 0..<n { frame[i] = ring[(start + i) & ringMask] }
        let rate = sampleRate
        lock.unlock()

        // Loudness with automatic gain so quiet and loud songs both fill the screen.
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(n))
        if rms > 1e-4 { lastSound = time }
        let silent = time - lastSound > 1.5
        levelPeak = max(levelPeak * 0.9995, rms, 0.02)
        let level = min(1, rms / levelPeak)

        // Waveform: the most recent samples, normalised.
        let waveStart = n - AudioFeatures.waveformCount
        let waveGain = 0.8 / levelPeak
        for i in 0..<AudioFeatures.waveformCount {
            let target = max(-1.5, min(1.5, frame[waveStart + i] * waveGain))
            features.waveform[i] += (target - features.waveform[i]) * 0.5
        }

        // Spectrum.
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(n))
        let half = n / 2
        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    let complex = raw.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(complex.baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        let binWidth = rate / Double(n)
        let lowest = 30.0, highest = 16_000.0
        var raw = [Float](repeating: 0, count: AudioFeatures.bandCount)
        var loudest: Float = 0
        for b in 0..<AudioFeatures.bandCount {
            let f0 = lowest * pow(highest / lowest, Double(b) / Double(AudioFeatures.bandCount))
            let f1 = lowest * pow(highest / lowest, Double(b + 1) / Double(AudioFeatures.bandCount))
            let i0 = max(1, Int(f0 / binWidth))
            let i1 = min(half - 1, max(i0 + 1, Int(f1 / binWidth)))
            var sum: Float = 0
            for i in i0..<i1 { sum += magnitudes[i] }
            let value = sqrt(sum / Float(i1 - i0))
            raw[b] = value
            loudest = max(loudest, value)
        }
        bandPeak = max(bandPeak * 0.998, loudest, 1e-3)

        var bass: Float = 0, mid: Float = 0, treble: Float = 0
        var bassCount: Float = 0, midCount: Float = 0, trebleCount: Float = 0
        for b in 0..<AudioFeatures.bandCount {
            let target = silent ? 0 : pow(min(1, raw[b] / bandPeak), 0.7)
            let current = features.bands[b]
            let speed: Float = target > current ? 0.6 : 0.12
            features.bands[b] = current + (target - current) * speed

            let freq = lowest * pow(highest / lowest, (Double(b) + 0.5) / Double(AudioFeatures.bandCount))
            if freq < 160 { bass += features.bands[b]; bassCount += 1 }
            else if freq < 2_000 { mid += features.bands[b]; midCount += 1 }
            else { treble += features.bands[b]; trebleCount += 1 }
        }
        bass /= max(1, bassCount)
        mid /= max(1, midCount)
        treble /= max(1, trebleCount)

        // Beat detection from spectral flux in the low end.
        let flux = max(0, bass - previousBass) + 0.5 * max(0, mid - previousMid)
        previousBass = bass
        previousMid = mid
        fluxAverage = fluxAverage * 0.95 + flux * 0.05
        if !silent, flux > fluxAverage * 1.8, flux > 0.04, time - lastBeat > 0.22 {
            features.beat = 1
            lastBeat = time
        } else {
            features.beat *= 0.86
        }

        features.level += ((silent ? 0 : level) - features.level) * 0.3
        features.bass = bass
        features.mid = mid
        features.treble = treble
        features.silent = silent
        return features
    }
}
