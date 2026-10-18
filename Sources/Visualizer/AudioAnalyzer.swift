import Accelerate
import Foundation

struct AudioFeatures {
    static let bandCount = 48
    static let waveformCount = 512
    /// One line per musical note, six octaves from C2 (about 65 Hz) to B7 (about 3950 Hz).
    static let noteCount = 72
    /// MIDI number of the lowest note (C2).
    static let lowestNote = 36

    var bands = [Float](repeating: 0, count: AudioFeatures.bandCount)
    var waveform = [Float](repeating: 0, count: AudioFeatures.waveformCount)
    var level: Float = 0
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    /// 1 on a detected beat, decaying towards 0 afterwards.
    var beat: Float = 0
    var silent = true
    /// How strongly each musical note is sounding right now, 0...1, lowest note first.
    var notes = [Float](repeating: 0, count: AudioFeatures.noteCount)
    /// The same folded into the 12 note names, C first.
    var chroma = [Float](repeating: 0, count: 12)
}

/// Turns raw samples into smoothed, auto-levelled features the visuals can react to.
/// `push` is called from the audio thread, `analyze` from the render thread.
final class AudioAnalyzer {
    private let fftSize = 2048
    private let log2n: vDSP_Length = 11
    // Long enough for the note window even when the Mac's audio runs at 192 kHz.
    private let ringMask = 65_536 - 1
    private var ring = [Float](repeating: 0, count: 65_536)
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

    // A longer window for telling neighbouring musical notes apart.
    private let noteSize = 8192
    private let noteLog2n: vDSP_Length = 13
    private let noteSetup: FFTSetup
    private var noteWindow: [Float]
    private var noteFrame: [Float]
    private var noteWindowed: [Float]
    private var noteReal: [Float]
    private var noteImag: [Float]
    private var notePower: [Float]
    private var notePeak: Float = 1e-4
    private var octavePeaks = [Float](repeating: 1e-4, count: AudioFeatures.noteCount / 12)

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

        noteSetup = vDSP_create_fftsetup(noteLog2n, FFTRadix(kFFTRadix2))!
        noteWindow = [Float](repeating: 0, count: noteSize)
        vDSP_hann_window(&noteWindow, vDSP_Length(noteSize), Int32(vDSP_HANN_NORM))
        noteFrame = [Float](repeating: 0, count: noteSize)
        noteWindowed = [Float](repeating: 0, count: noteSize)
        noteReal = [Float](repeating: 0, count: noteSize / 2)
        noteImag = [Float](repeating: 0, count: noteSize / 2)
        notePower = [Float](repeating: 0, count: noteSize / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        vDSP_destroy_fftsetup(noteSetup)
    }

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
        let rate = sampleRate
        let start = (writeIndex - n + ring.count) & ringMask
        for i in 0..<n { frame[i] = ring[(start + i) & ringMask] }
        // The note window always covers the same stretch of time: at high sample rates, neighbouring samples are
        // averaged down to about 48 kHz first, so a note lands on the same line whatever the Mac's audio is set to.
        let step = min(ring.count / noteSize, max(1, Int((rate / 48_000).rounded())))
        let noteStart = (writeIndex - noteSize * step + ring.count) & ringMask
        for i in 0..<noteSize {
            var sum: Float = 0
            for j in 0..<step { sum += ring[(noteStart + i * step + j) & ringMask] }
            noteFrame[i] = sum / Float(step)
        }
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

        analyzeNotes(rate: rate / Double(step), silent: silent)

        features.level += ((silent ? 0 : level) - features.level) * 0.3
        features.bass = bass
        features.mid = mid
        features.treble = treble
        features.silent = silent
        return features
    }

    /// Measures how strongly each of the 72 notes is sounding.
    private func analyzeNotes(rate: Double, silent: Bool) {
        let n = noteSize
        let half = n / 2
        vDSP_vmul(noteFrame, 1, noteWindow, 1, &noteWindowed, 1, vDSP_Length(n))
        noteReal.withUnsafeMutableBufferPointer { realPointer in
            noteImag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                noteWindowed.withUnsafeBytes { raw in
                    let complex = raw.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(complex.baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(noteSetup, &split, 1, noteLog2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &notePower, 1, vDSP_Length(half))
            }
        }

        // Every peak in the spectrum is one tone. Its exact pitch, read from between the bins, picks the single line
        // it lights, so a note never spills onto its neighbours or across into the next octave.
        let count = AudioFeatures.noteCount
        let binWidth = Float(rate) / Float(n)
        let lowHz: Float = 440 * pow(2, (Float(AudioFeatures.lowestNote) - 69.5) / 12)
        let highHz: Float = 440 * pow(2, (Float(AudioFeatures.lowestNote + count) - 69.5) / 12)
        let firstBin = max(2, Int(lowHz / binWidth) - 1)
        let lastBin = min(half - 3, Int(highHz / binWidth) + 2)
        // However quiet the song gets, a tone has to reach a share of its recent loudness to count,
        // so faint hiss between songs doesn't turn into lines.
        let minimumPeak = levelPeak * Float(n) * 0.25
        let gate = 0.04 * max(notePeak * 0.998, minimumPeak)
        var tonal = [Float](repeating: 0, count: count)
        if firstBin <= lastBin {
            for k in firstBin...lastBin {
                let p = notePower[k]
                guard p > notePower[k - 1], p >= notePower[k + 1] else { continue }
                let a = log(notePower[k - 1] + 1e-20), b = log(p + 1e-20), c = log(notePower[k + 1] + 1e-20)
                let curve = a - 2 * b + c
                let offset: Float = curve < 0 ? 0.5 * (a - c) / curve : 0
                let height = exp(0.5 * (b - 0.25 * (a - c) * offset))
                guard height >= gate else { continue }
                // A tone stands well clear of the spectrum around it; noise and drums don't.
                let local = notePower[max(1, k - 16)...min(half - 1, k + 16)].sorted()
                guard p >= 20 * local[local.count / 2] else { continue }
                let pitch = 12 * log2((Float(k) + offset) * binWidth / 440) + 69
                let note = Int(pitch.rounded()) - AudioFeatures.lowestNote
                guard note >= 0, note < count else { continue }
                tonal[note] = max(tonal[note], height)
            }
        }
        var loudest: Float = 0
        for value in tonal { loudest = max(loudest, value) }
        notePeak = max(notePeak * 0.998, loudest, minimumPeak)

        // Each octave keeps its own level so high notes show as clearly as bass notes,
        // but never with so much gain that an empty octave turns its noise into lines.
        for octave in octavePeaks.indices {
            var octaveLoudest: Float = 0
            for i in (octave * 12)..<(octave * 12 + 12) { octaveLoudest = max(octaveLoudest, tonal[i]) }
            octavePeaks[octave] = max(octavePeaks[octave] * 0.997, octaveLoudest, notePeak * 0.15)
        }

        var chroma = [Float](repeating: 0, count: 12)
        for i in 0..<count {
            let relative = min(1, tonal[i] / octavePeaks[i / 12])
            let target: Float = silent || tonal[i] < notePeak * 0.04 ? 0 : pow(relative, 1.4)
            let current = features.notes[i]
            let speed: Float = target > current ? 0.55 : 0.1
            features.notes[i] = current + (target - current) * speed
            chroma[i % 12] += features.notes[i]
        }
        for c in 0..<12 { features.chroma[c] = min(1, chroma[c] * 0.6) }
    }
}
