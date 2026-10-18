import Accelerate
import Foundation

/// What the visuals react to, refreshed once per frame.
struct AudioFeatures {
    /// Band levels relative to the song's own recent average (about 1), 0 when silent.
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    var volume: Float = 0
    /// 1 on each beat, fading out over the beat.
    var pulse: Float = 0
    var beatAge: Float = 10
    var phase: Float = 0
    var bpm: Float = 0
    /// Strength of the latest bass hit, fading quickly.
    var kick: Float = 0
    var silent = true
    /// Loudness over the last couple of seconds versus the last ten; drops and builds swing this.
    var sectionRatio: Float = 1
    var beatCount = 0
}

/// Turns raw samples into band levels, a tempo-locked beat, a waveform and a spectrum.
/// Samples arrive on the audio thread through `push`; `update` runs once per frame.
final class AudioAnalyzer {
    static let fftSize = 2048
    static let displayCount = 512

    private let lock = NSLock()
    private var ring = [Float](repeating: 0, count: 8192)
    private var writeIndex = 0
    private var sampleRate: Double = 48_000

    private let log2n = vDSP_Length(11)
    private let fftSetup: FFTSetup
    private var window = [Float](repeating: 0, count: fftSize)
    private var frame = [Float](repeating: 0, count: fftSize)
    private var windowed = [Float](repeating: 0, count: fftSize)
    private var real = [Float](repeating: 0, count: fftSize / 2)
    private var imag = [Float](repeating: 0, count: fftSize / 2)
    private var mags = [Float](repeating: 0, count: fftSize / 2)
    private var logMags = [Float](repeating: 0, count: fftSize / 2)
    private var prevLogMags = [Float](repeating: 0, count: fftSize / 2)

    /// Oscilloscope trace, -1...1, and spectrum, 0...1, for the shaders.
    private(set) var wave = [Float](repeating: 0, count: displayCount)
    private(set) var spectrum = [Float](repeating: 0, count: displayCount)

    private(set) var features = AudioFeatures()
    private(set) var time: Double = 0

    private var bandAverage: [Float] = [1e-4, 1e-4, 1e-4, 1e-4]
    private var bandSmoothed: [Float] = [0, 0, 0, 0]
    private var peak: Float = 0.05
    private var shortLevel: Float = 0
    private var longLevel: Float = 0

    private var fluxMean: Float = 0
    private var fluxVar: Float = 0
    private var bassFluxMean: Float = 0
    private var bassFluxVar: Float = 0
    private var lastOnset: Double = -10
    private struct Onset { let time: Double; let weight: Double }
    private var onsets: [Onset] = []
    private var lastTempoEstimate: Double = 0
    private(set) var period: Double = 0
    private var pendingPeriod: Double = 0
    private var nextBeat: Double = 0
    private var lastBeat: Double = -10

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    func push(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        lock.lock()
        self.sampleRate = sampleRate
        let mask = ring.count - 1
        for i in 0..<count {
            ring[writeIndex] = samples[i]
            writeIndex = (writeIndex + 1) & mask
        }
        lock.unlock()
    }

    /// Advances the analysis by `dt` seconds and returns whether a beat landed this frame.
    @discardableResult
    func update(dt: Double) -> Bool {
        time += dt
        let rate: Double
        lock.lock()
        rate = sampleRate
        let mask = ring.count - 1
        var index = (writeIndex - Self.fftSize) & mask
        for i in 0..<Self.fftSize {
            frame[i] = ring[index]
            index = (index + 1) & mask
        }
        lock.unlock()

        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(Self.fftSize))
        let silent = rms < 0.0004

        updateWave(silent: silent)
        computeSpectrum()
        let binHz = Float(rate) / Float(Self.fftSize)
        updateDisplaySpectrum(binHz: binHz, silent: silent)

        // Band energies.
        let edges: [(Float, Float)] = [(25, 150), (150, 2000), (2000, 12000), (25, 12000)]
        var raw: [Float] = []
        for (lo, hi) in edges {
            let a = max(1, Int(lo / binHz)), b = min(mags.count - 1, Int(hi / binHz))
            var sum: Float = 0
            for i in a...b { sum += mags[i] * mags[i] }
            raw.append(sum)
        }
        let f = Float(dt)
        for i in 0..<4 {
            if !silent { bandAverage[i] += (raw[i] - bandAverage[i]) * min(1, f / 5) }
            let relative = silent ? 0 : min(3, sqrt(raw[i] / max(bandAverage[i], 1e-9)))
            let tau: Float = relative > bandSmoothed[i] ? 0.03 : 0.18
            bandSmoothed[i] += (relative - bandSmoothed[i]) * min(1, f / tau)
        }

        shortLevel += (rms - shortLevel) * min(1, f / 1.5)
        longLevel += (rms - longLevel) * min(1, f / 10)

        let beat = detectBeats(silent: silent, binHz: binHz)

        var out = features
        out.bass = bandSmoothed[0]
        out.mid = bandSmoothed[1]
        out.treble = bandSmoothed[2]
        out.volume = bandSmoothed[3]
        out.silent = silent
        out.sectionRatio = longLevel > 1e-5 ? shortLevel / longLevel : 1
        out.bpm = period > 0 ? Float(60 / period) : 0
        out.beatAge = Float(time - lastBeat)
        out.pulse = silent ? out.pulse * 0.9 : exp(-out.beatAge * 5)
        out.phase = period > 0 ? Float(min(1, (time - lastBeat) / period)) : 0
        out.kick *= exp(-f * 9)
        if beat { out.beatCount += 1 }
        features = out
        return beat
    }

    // MARK: - Waveform and spectrum

    private func updateWave(silent: Bool) {
        // Trigger on a rising zero crossing so the trace holds still like an oscilloscope.
        let span = Self.displayCount * 2
        let start = Self.fftSize - span - 256
        var trigger = start
        for i in start..<(start + 256) where frame[i] <= 0 && frame[i + 1] > 0 {
            trigger = i
            break
        }
        var localPeak: Float = 0
        for i in 0..<span { localPeak = max(localPeak, abs(frame[trigger + i])) }
        peak = max(localPeak, peak * 0.995)
        let gain = 0.9 / max(peak, 0.02)
        for j in 0..<Self.displayCount {
            let s = (frame[trigger + j * 2] + frame[trigger + j * 2 + 1]) * 0.5 * gain
            wave[j] += ((silent ? 0 : s) - wave[j]) * 0.6
        }
    }

    private func computeSpectrum() {
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(Self.fftSize))
        let half = Self.fftSize / 2
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        let scale = 1 / Float(Self.fftSize)
        for i in 0..<half { mags[i] *= scale }
        mags[0] = 0
    }

    private func updateDisplaySpectrum(binHz: Float, silent: Bool) {
        let lo: Float = 30, hi: Float = 16000
        let count = Float(Self.displayCount - 1)
        for j in 0..<Self.displayCount {
            let t = Float(j) / count
            let hz = lo * pow(hi / lo, t)
            let fi = min(Float(mags.count - 2), hz / binHz)
            let i = Int(fi)
            let m = mags[i] + (mags[i + 1] - mags[i]) * (fi - Float(i))
            // dB with a gentle treble lift so cymbals show as clearly as bass.
            let db = 20 * log10(m + 1e-9) + 4 * log2(hz / 200)
            let target: Float = silent ? 0 : max(0, min(1.2, (db + 70) / 55))
            spectrum[j] = target > spectrum[j] ? target : spectrum[j] * 0.88 + target * 0.12
        }
    }

    // MARK: - Beats

    private func detectBeats(silent: Bool, binHz: Float) -> Bool {
        let upper = min(mags.count, Int(9000 / binHz))
        let bassUpper = max(2, Int(160 / binHz))
        var flux: Float = 0
        var bassFlux: Float = 0
        for i in 1..<upper {
            logMags[i] = log(1 + 1000 * mags[i])
            let rise = max(0, logMags[i] - prevLogMags[i])
            flux += rise
            if i < bassUpper { bassFlux += rise }
        }
        swap(&logMags, &prevLogMags)
        if silent {
            // After a real pause, forget the old tempo so the next song starts fresh.
            if time - lastOnset > 4 {
                onsets.removeAll()
                period = 0
                pendingPeriod = 0
            }
            return false
        }

        // Adaptive thresholds from the recent mean and spread.
        let isOnset = flux > fluxMean + 1.5 * sqrt(fluxVar) && flux > 0.5 && time - lastOnset > 0.1
        let d = flux - fluxMean
        let strength = d / max(sqrt(fluxVar), 1e-3)
        fluxMean += d * 0.03
        fluxVar = 0.97 * (fluxVar + 0.03 * d * d)
        let bd = bassFlux - bassFluxMean
        let bassRise = max(0, bd / max(sqrt(bassFluxVar), 1e-3))
        if bassRise > 1.5 && bassFlux > 0.2 {
            features.kick = max(features.kick, min(1, bassRise / 3))
        }
        bassFluxMean += bd * 0.03
        bassFluxVar = 0.97 * (bassFluxVar + 0.03 * bd * bd)

        if isOnset {
            lastOnset = time
            // Bass hits count most when deciding where the beat falls.
            onsets.append(Onset(time: time, weight: Double(0.2 * strength + bassRise * bassRise)))
            onsets.removeAll { time - $0.time > 10 }
        }
        if time - lastTempoEstimate > 1 {
            lastTempoEstimate = time
            estimateTempo()
        }

        guard period > 0 else {
            // No tempo yet: every clear onset is a beat.
            if isOnset && time - lastBeat > 0.25 {
                lastBeat = time
                return true
            }
            return false
        }

        // Pull the beat grid toward real onsets that land close to it.
        if isOnset {
            let sinceLast = time - lastBeat
            let untilNext = nextBeat - time
            let window = 0.18 * period
            if untilNext >= 0 && untilNext < window {
                nextBeat -= untilNext * 0.5
            } else if sinceLast < window {
                nextBeat += sinceLast * 0.3
            }
        }
        if nextBeat < time - period { nextBeat = time }
        if time >= nextBeat {
            lastBeat = time
            nextBeat += period
            return true
        }
        return false
    }

    /// Finds the beat period that best explains the gaps between recent onsets.
    private func estimateTempo() {
        guard onsets.count >= 8 else {
            if onsets.count < 3 { period = 0 }
            return
        }
        var best = 0.0, bestScore = 0.0
        var candidate = 60.0 / 180
        let sigma = 0.018
        while candidate <= 60.0 / 70 {
            var score = 0.0
            for i in 0..<onsets.count {
                for j in (i + 1)..<onsets.count {
                    let gap = onsets[j].time - onsets[i].time
                    if gap > 4 { break }
                    let k = (gap / candidate).rounded()
                    guard k >= 1, k <= 8 else { continue }
                    let err = gap - k * candidate
                    score += exp(-err * err / (2 * sigma * sigma)) / k
                }
            }
            // Gentle preference for tempos near 120 BPM.
            let octaves = log2(candidate / 0.5)
            score *= exp(-octaves * octaves / (2 * 0.8 * 0.8))
            if score > bestScore {
                bestScore = score
                best = candidate
            }
            candidate += 0.004
        }
        guard best > 0, bestScore > Double(onsets.count) * 0.15 else { return }
        if period == 0 {
            period = best
            nextBeat = time + best
        } else if abs(best - period) / period < 0.05 {
            period += (best - period) * 0.5
        } else if pendingPeriod > 0 && abs(best - pendingPeriod) / pendingPeriod < 0.05 {
            period = best
            pendingPeriod = 0
        } else {
            pendingPeriod = best
        }
        alignPhase()
    }

    /// Slides the beat grid so it sits on the strongest (mostly bass) onsets.
    private func alignPhase() {
        let p = period
        var bestPhase = 0.0, bestScore = -1.0
        var phase = 0.0
        while phase < p {
            var score = 0.0
            for onset in onsets {
                var offset = (onset.time - phase).truncatingRemainder(dividingBy: p)
                if offset < 0 { offset += p }
                if offset > p / 2 { offset -= p }
                score += onset.weight * exp(-offset * offset / (2 * 0.02 * 0.02))
            }
            if score > bestScore {
                bestScore = score
                bestPhase = phase
            }
            phase += 0.01
        }
        let candidate = bestPhase + ((time - bestPhase) / p).rounded(.up) * p
        var shift = (candidate - nextBeat).truncatingRemainder(dividingBy: p)
        if shift > p / 2 { shift -= p }
        if shift < -p / 2 { shift += p }
        nextBeat += abs(shift) > 0.1 * p ? shift : shift * 0.5
    }
}
