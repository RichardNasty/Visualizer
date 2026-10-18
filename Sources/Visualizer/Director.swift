import Foundation
import simd

struct Scene {
    let name: String
    /// How much of the previous frame survives each 1/60 s; higher means longer trails.
    let decay: Float
}

struct Palette {
    let name: String
    /// Dark, mid and highlight colours. Each palette stays within two or three related hues.
    let colors: [SIMD3<Float>]
}

/// Chooses what is on screen: which scene and palette, and when to move on.
/// Changes follow the music: a drop after a quiet stretch, or every 16 beats once a scene has had its time.
final class Director {
    static let scenes: [Scene] = [
        Scene(name: "Nebula", decay: 0.965),
        Scene(name: "Tunnel", decay: 0.93),
        Scene(name: "Liquid", decay: 0.955),
        Scene(name: "Vortex", decay: 0.962),
        Scene(name: "Kaleidoscope", decay: 0.94),
        Scene(name: "Shockwave", decay: 0.925),
    ]

    static let palettes: [Palette] = [
        Palette(name: "Ember", colors: [SIMD3(0.55, 0.04, 0.02), SIMD3(1.0, 0.38, 0.06), SIMD3(1.0, 0.85, 0.5)]),
        Palette(name: "Deep Sea", colors: [SIMD3(0.02, 0.07, 0.32), SIMD3(0.0, 0.55, 0.62), SIMD3(0.65, 1.0, 0.95)]),
        Palette(name: "Glacier", colors: [SIMD3(0.04, 0.12, 0.42), SIMD3(0.3, 0.6, 1.0), SIMD3(0.92, 0.96, 1.0)]),
        Palette(name: "Aurora", colors: [SIMD3(0.0, 0.2, 0.18), SIMD3(0.1, 0.85, 0.5), SIMD3(0.75, 1.0, 0.85)]),
        Palette(name: "Gilded Night", colors: [SIMD3(0.1, 0.06, 0.28), SIMD3(0.85, 0.55, 0.18), SIMD3(1.0, 0.92, 0.72)]),
        Palette(name: "Rose Gold", colors: [SIMD3(0.35, 0.05, 0.1), SIMD3(0.95, 0.45, 0.38), SIMD3(1.0, 0.86, 0.72)]),
        Palette(name: "Moonlight", colors: [SIMD3(0.08, 0.09, 0.14), SIMD3(0.5, 0.56, 0.72), SIMD3(1.0, 1.0, 1.0)]),
    ]

    private(set) var scene = 0
    private(set) var previousScene = 0
    private(set) var palette = 1
    private var previousPalette = 1
    /// 0 at the start of a change, 1 once the new scene has fully taken over.
    private(set) var blend: Float = 1
    private var sceneTime: Double = 0
    private var beatsInScene = 0
    private var armedForDrop = false
    var locked = false

    private(set) var rotation: Float = 0
    private(set) var musicalTime: Float = 0

    /// Called with a short label whenever the scene or palette changes.
    var onChange: ((String) -> Void)?

    private let transitionSeconds: Float = 2.5
    private var rng = SystemRandomNumberGenerator()

    var sceneName: String { Self.scenes[scene].name }
    var paletteName: String { Self.palettes[palette].name }

    func update(dt: Float, features f: AudioFeatures, beat: Bool) {
        sceneTime += Double(dt)
        blend = min(1, blend + dt / transitionSeconds)

        let spin: Float = sin(musicalTime * 0.05) >= 0 ? 1 : -1
        rotation += dt * (0.08 + 0.25 * f.mid) * spin
        musicalTime += dt * (0.35 + 0.7 * f.volume + 0.8 * f.pulse)

        if beat { beatsInScene += 1 }
        guard !locked, blend >= 1 else { return }

        if f.sectionRatio < 0.55 { armedForDrop = true }
        let drop = armedForDrop && f.sectionRatio > 1.15 && sceneTime > 8
        let timeUp = sceneTime > 40 && beatsInScene % 16 == 0 && beat
        let quietTimeUp = f.silent && sceneTime > 60
        if (drop && beat) || timeUp || quietTimeUp {
            armedForDrop = false
            advance(scene: randomOther(than: scene, count: Self.scenes.count),
                    palette: randomOther(than: palette, count: Self.palettes.count))
        }
    }

    func nextScene(_ step: Int = 1) {
        let count = Self.scenes.count
        advance(scene: ((scene + step) % count + count) % count, palette: palette)
    }

    func nextPalette() {
        advance(scene: scene, palette: (palette + 1) % Self.palettes.count)
    }

    /// Jumps straight to a scene and palette with no transition (used for preview stills).
    func force(scene: Int, palette: Int) {
        self.scene = scene
        previousScene = scene
        self.palette = palette
        previousPalette = palette
        blend = 1
        sceneTime = 0
        beatsInScene = 0
    }

    private func advance(scene newScene: Int, palette newPalette: Int) {
        // Finish any running transition first so nothing snaps.
        previousScene = blend >= 0.5 ? scene : previousScene
        previousPalette = blend >= 0.5 ? palette : previousPalette
        scene = newScene
        palette = newPalette
        blend = 0
        sceneTime = 0
        beatsInScene = 0
        onChange?("\(sceneName) · \(paletteName)")
    }

    private func randomOther(than value: Int, count: Int) -> Int {
        let pick = Int.random(in: 0..<(count - 1), using: &rng)
        return pick >= value ? pick + 1 : pick
    }

    /// Colours for the shader, crossfaded during a change.
    func paletteColors() -> [SIMD3<Float>] {
        let t = smooth(blend)
        let a = Self.palettes[previousPalette].colors, b = Self.palettes[palette].colors
        return (0..<3).map { simd_mix(a[$0], b[$0], SIMD3(repeating: t)) }
    }

    var decay: Float {
        let t = smooth(blend)
        return Self.scenes[previousScene].decay * (1 - t) + Self.scenes[scene].decay * t
    }

    private func smooth(_ x: Float) -> Float { x * x * (3 - 2 * x) }
}
