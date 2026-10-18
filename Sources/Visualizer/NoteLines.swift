import simd

/// How the note lines are grouped by color.
enum NoteColors: String, CaseIterable, Identifiable {
    case byOctave, byNote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .byOctave: return "By octave: bass notes red, rising through orange, yellow, green and blue to violet"
        case .byNote: return "By note name: every C one color, every D another, and so on"
        }
    }
}

/// One glowing line for every musical note from C2 to B7. Each line remembers the last few seconds
/// of how strongly its note sounded, so melodies and chords travel along the lines as they play.
/// The visual world decides how the lines are laid out; the story gathers, splits, bends and breaks them.
struct NoteField {
    static let points = 96
    static let tick: Float = 1.0 / 30

    struct View {
        var eye: SIMD3<Float>
        var forward: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
    }

    private var history = [Float](repeating: 0, count: AudioFeatures.noteCount * NoteField.points)
    private var head = 0
    private var clock: Float = 0
    private var positions = [SIMD3<Float>](repeating: .zero, count: NoteField.points)
    private var alphas = [Float](repeating: 0, count: NoteField.points)
    private var widths = [Float](repeating: 0, count: NoteField.points)

    mutating func update(dt: Float, audio: AudioFeatures) {
        clock += dt
        var ticks = 0
        while clock >= Self.tick, ticks < 4 {
            clock -= Self.tick
            ticks += 1
            for n in 0..<AudioFeatures.noteCount {
                history[n * Self.points + head] = audio.notes[n]
            }
            head = (head + 1) % Self.points
        }
        if clock >= Self.tick { clock = 0 }
    }

    /// k = 0 is the oldest sample, k = points - 1 the newest.
    private func value(_ n: Int, _ k: Int) -> Float {
        history[n * Self.points + (head + k) % Self.points]
    }

    static func color(_ n: Int, _ grouping: NoteColors) -> SIMD3<Float> {
        let pitchClass = Float(n % 12)
        let octave = n / 12
        switch grouping {
        case .byOctave:
            // Each octave is one color family; within it every note is its own shade, C deepest, B palest.
            let hues: [Float] = [0.0, 0.07, 0.14, 0.33, 0.56, 0.76]
            let shade = pitchClass / 11
            return hsv(hues[min(octave, hues.count - 1)], 0.95 - shade * 0.3, 0.72 + shade * 0.28)
        case .byNote:
            // Every C shares a color, every C# the next one round the color wheel, and so on.
            // Higher octaves are paler versions of the same color.
            return hsv(pitchClass / 12, 0.92 - Float(octave) * 0.09, 0.8 + Float(octave) * 0.04)
        }
    }

    /// Colors for the particle clouds: the note names sounding most strongly right now.
    static func particleColors(_ audio: AudioFeatures, _ grouping: NoteColors) -> [(color: SIMD3<Float>, brightness: Float)]? {
        guard !audio.silent else { return nil }
        let ranked = audio.chroma.indices.sorted { audio.chroma[$0] > audio.chroma[$1] }
        guard let first = ranked.first, audio.chroma[first] > 0.05 else { return nil }
        return ranked.prefix(3).map { pitchClass -> (color: SIMD3<Float>, brightness: Float) in
            var best = pitchClass
            var bestValue: Float = -1
            for octave in 0..<(AudioFeatures.noteCount / 12) {
                let n = octave * 12 + pitchClass
                if audio.notes[n] > bestValue {
                    bestValue = audio.notes[n]
                    best = n
                }
            }
            return (color(best, grouping), 0.4 + audio.chroma[pitchClass])
        }
    }

    /// Adds every note line to the frame. Crisp lines are drawn fresh; a soft copy feeds the liquid trails.
    mutating func build(crisp: inout LineBatch, trails: inout LineBatch, scene: SceneState, audio: AudioFeatures,
                        time t: Float, view: View, colors grouping: NoteColors) {
        let count = AudioFeatures.noteCount
        let last = Self.points - 1
        let frac = min(1, clock / Self.tick)
        // When the story changes world the lines fold quickly from one layout into the next,
        // instead of spending seconds tangled halfway between the two.
        let cw = scene.classic * scene.classic * scene.classic
        let mw = scene.magnetosphere * scene.magnetosphere * scene.magnetosphere
        let xw = scene.xbox * scene.xbox * scene.xbox
        let total = max(0.001, cw + mw + xw)
        let wClassic = cw / total
        let wMagneto = mw / total
        let wXbox = xw / total

        let spread = scene.lineSpread
        let split = scene.lineSplit
        let bend = scene.lineBend
        let lift = scene.lineLift
        let jitter = scene.lineJitter
        let shatter = scene.lineShatter
        let chase = scene.lineChase
        let dim = scene.lineDim
        // Each lyric line sends a bright pulse sweeping along every line, from now back into the past.
        let pulseStrength = 1.8 * exp(-scene.linePulse * 1.4)
        let pulseCenter = 1 - scene.linePulse / 1.2
        let trailGain = 0.05 * (0.3 + scene.classic)
        // Quiet notes still show as faint lines, so every note always has its line.
        let idle = 0.28 * (1 - dim * 0.7)
        let gap = 1 - shatter * 0.55
        let tilt: Float = 0.45
        let discUp = view.up * cos(tilt) - view.forward * sin(tilt)

        for n in 0..<count {
            let v = Float(n) / Float(count - 1)
            let side: Float = v < 0.5 ? -1 : 1
            let noteSeed = Float(n)
            let rippleFrequency = 2.5 + noteSeed * 0.12
            let rippleSpeed = 2 + noteSeed * 0.06
            let spinDirection: Float = n % 2 == 0 ? 1 : -1
            var lineEnergy: Float = 0

            for k in 0...last {
                let h = k == last ? audio.notes[n] : value(n, k)
                lineEnergy = max(lineEnergy, h)
                let u = k == last ? 1 : max(0, (Float(k) - frac) / Float(last))

                // How far the line is pushed out from where it rests: a bump while its note sounds,
                // rippling faster for higher notes, plus whatever the story is doing to it.
                var push = h * 0.3 + h * 0.08 * sin(u * rippleFrequency * 2 * .pi - t * rippleSpeed)
                push += jitter * 0.12 * sin(u * 41 + t * 17 + noteSeed * 1.7)
                let dash = u * 14 + noteSeed * 0.37
                let piece = dash.rounded(.down)
                push += shatter * 0.4 * (noise1(noteSeed * 31 + piece) - 0.5)
                let curve = bend * u * u

                // Classic: a stack of lines facing you, low notes at the bottom.
                let flatY = (v - 0.5) * 5.2 * spread + side * split * 0.8 + lift + curve * 1.1
                let flat = view.right * ((u - 0.5) * 9.2) + view.up * (flatY + push)

                // Magnetosphere: glowing rings one inside the other like a record, low notes in the middle.
                let discRadius = 0.45 + v * 2.9 * spread + (v < 0.5 ? -0.25 : 0.7) * split + push * 0.8
                let angle = u * 1.92 * .pi + t * 0.1 * spinDirection + v * 3
                let disc = view.right * (cos(angle) * discRadius) + discUp * (sin(angle) * discRadius)
                    + view.up * (lift + curve * 0.6)

                // Xbox: every note a neon ring in a tunnel stretching away from you, low notes nearest.
                let depth = 2.2 + v * 8.5 * spread + (v < 0.5 ? 0 : split * 2.5)
                let spin = u * 1.9 * .pi + noteSeed * 0.13 + t * 0.35 * spinDirection
                let ringRadius = 1.6 + push * 0.9 + curve * 0.3
                let around = view.right * cos(spin) + view.up * sin(spin)
                let tunnel = view.eye + view.forward * depth + around * ringRadius + view.up * (lift * 0.4)

                positions[k] = flat * wClassic + disc * wMagneto + tunnel * wXbox

                var glow = idle + h * 1.3
                let chaseCenter = (t * 0.45 + v * 0.3).truncatingRemainder(dividingBy: 1)
                let chaseOffset = (u - chaseCenter) * 9
                glow += chase * exp(-chaseOffset * chaseOffset) * (0.3 + h)
                let pulseOffset = (u - pulseCenter) * 10
                glow += pulseStrength * exp(-pulseOffset * pulseOffset) * (0.25 + h)
                glow *= min(1, u / 0.15)
                let visible = dash - piece < gap
                alphas[k] = visible ? glow : 0
                widths[k] = 0.02 + h * 0.05
            }

            let whiten = min(0.15, lineEnergy * 0.15)
            let color = Self.color(n, grouping) * (1 - whiten) + SIMD3<Float>(repeating: whiten)
            let soft = trailGain > 0.02 && lineEnergy > 0.05
            for k in 0..<last {
                let a = alphas[k]
                let b = alphas[k + 1]
                guard a > 0.004 || b > 0.004 else { continue }
                crisp.segment(positions[k], positions[k + 1], width: widths[k], color: color, alpha: a,
                              widthB: widths[k + 1], alphaB: b)
                if soft {
                    trails.segment(positions[k], positions[k + 1], width: widths[k] * 3, color: color, alpha: a * trailGain,
                                   widthB: widths[k + 1] * 3, alphaB: b * trailGain)
                }
            }
        }
    }
}

/// A repeatable pseudo-random number from 0 to 1.
private func noise1(_ x: Float) -> Float {
    let s = sin(x * 12.9898) * 43758.5453
    return s - s.rounded(.down)
}
