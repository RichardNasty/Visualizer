import Foundation
import simd

struct CharacterRender {
    var position: SIMD3<Float>
    var scale: Float
    var rotation: SIMD3<Float>
    var color: SIMD3<Float>
    var brightness: Float
    var shape: ShapeKind
    var displacement: Float
    var attraction: Float
}

struct SceneState {
    var characters: [CharacterRender] = []
    var turbulence: Float = 0.6
    var swirl: Float = 0.6
    var radial: Float = 0
    var gravity = SIMD3<Float>(0, 0, 0)
    var fade: Float = 0.92
    var warp: Float = 0.5
    var saturation: Float = 0.8
    var particleBrightness: Float = 1
    var backgroundHue: Float = 0.6
    var backgroundIntensity: Float = 0.3
    var zoom: Float = 1.004
    var rotate: Float = 0
    var cameraDistance: Float = 6.5
    var cameraHeight: Float = 1
    var cameraAngle: Float = 0
    var waveHue: Float = 0.6
    var waveTilt: Float = 0.2
    var waveAmplitude: Float = 0.5
}

/// Turns the hidden story (or, without one, an improvised ambient story) plus live audio
/// into where every shape and particle cloud should be this frame.
final class Director {
    private struct Staging {
        var radius: Float, height: Float, scale: Float, brightness: Float
        var swirl: Float, turbulence: Float, radial: Float, gravity: Float
        var fade: Float, warp: Float, saturation: Float, orbitSpeed: Float
    }

    private static func staging(_ action: StoryAction) -> Staging {
        switch action {
        case .drift:    return Staging(radius: 1.6, height: 0, scale: 0.9, brightness: 0.8, swirl: 0.6, turbulence: 0.6, radial: 0, gravity: 0, fade: 0.92, warp: 0.5, saturation: 0.8, orbitSpeed: 0.15)
        case .approach: return Staging(radius: 0.9, height: 0, scale: 1.0, brightness: 0.95, swirl: 0.8, turbulence: 0.4, radial: 0, gravity: 0, fade: 0.93, warp: 0.6, saturation: 0.9, orbitSpeed: 0.2)
        case .embrace:  return Staging(radius: 0.28, height: 0.1, scale: 1.1, brightness: 1.2, swirl: 1.6, turbulence: 0.3, radial: 0, gravity: 0, fade: 0.95, warp: 0.7, saturation: 1.0, orbitSpeed: 0.6)
        case .separate: return Staging(radius: 3.2, height: 0, scale: 0.7, brightness: 0.6, swirl: 0.2, turbulence: 0.5, radial: 0.3, gravity: 0, fade: 0.9, warp: 0.3, saturation: 0.5, orbitSpeed: 0.05)
        case .chase:    return Staging(radius: 1.8, height: 0, scale: 0.9, brightness: 1.0, swirl: 1.2, turbulence: 0.8, radial: 0, gravity: 0, fade: 0.9, warp: 0.8, saturation: 0.9, orbitSpeed: 0.9)
        case .orbit:    return Staging(radius: 1.8, height: 0, scale: 0.95, brightness: 1.0, swirl: 1.4, turbulence: 0.5, radial: 0, gravity: 0, fade: 0.93, warp: 0.6, saturation: 0.9, orbitSpeed: 0.7)
        case .rise:     return Staging(radius: 1.2, height: 1.6, scale: 1.0, brightness: 1.1, swirl: 0.7, turbulence: 0.5, radial: 0.2, gravity: 1.5, fade: 0.94, warp: 0.7, saturation: 1.0, orbitSpeed: 0.25)
        case .fall:     return Staging(radius: 1.4, height: -1.6, scale: 0.8, brightness: 0.6, swirl: 0.3, turbulence: 0.4, radial: 0, gravity: -1.5, fade: 0.93, warp: 0.4, saturation: 0.5, orbitSpeed: 0.1)
        case .shatter:  return Staging(radius: 2.2, height: 0, scale: 1.4, brightness: 1.3, swirl: 0.8, turbulence: 2.0, radial: 3.0, gravity: 0, fade: 0.88, warp: 1.4, saturation: 1.1, orbitSpeed: 0.4)
        case .bloom:    return Staging(radius: 1.5, height: 0.3, scale: 1.5, brightness: 1.3, swirl: 1.0, turbulence: 0.6, radial: 0.8, gravity: 0.3, fade: 0.94, warp: 0.9, saturation: 1.2, orbitSpeed: 0.3)
        case .hide:     return Staging(radius: 2.0, height: -0.4, scale: 0.25, brightness: 0.3, swirl: 0.4, turbulence: 1.0, radial: 0, gravity: 0, fade: 0.96, warp: 0.3, saturation: 0.4, orbitSpeed: 0.08)
        case .reveal:   return Staging(radius: 1.0, height: 0.4, scale: 1.25, brightness: 1.5, swirl: 0.6, turbulence: 0.4, radial: 0.5, gravity: 0.2, fade: 0.93, warp: 0.8, saturation: 1.0, orbitSpeed: 0.2)
        case .storm:    return Staging(radius: 2.0, height: 0, scale: 1.1, brightness: 1.1, swirl: 2.0, turbulence: 3.0, radial: 0.4, gravity: 0, fade: 0.9, warp: 1.5, saturation: 1.0, orbitSpeed: 1.2)
        case .calm:     return Staging(radius: 1.3, height: 0, scale: 0.85, brightness: 0.7, swirl: 0.3, turbulence: 0.2, radial: 0, gravity: 0, fade: 0.96, warp: 0.3, saturation: 0.7, orbitSpeed: 0.08)
        }
    }

    private struct Actor {
        var shape: ShapeKind
        var baseHue: Float
        var position = SIMD3<Float>(0, 0, 0)
        var scale: Float = 0.1
        var brightness: Float = 0
        var hue: Float
        var rotation = SIMD3<Float>(0, 0, 0)
        var phase: Float
    }

    /// Song position in seconds, if known.
    var songPosition: () -> Double? = { nil }

    var story: Story? {
        didSet { cast() }
    }

    private var actors: [Actor] = []
    private var scene = SceneState()
    private var time: Double = 0
    private var beatIndex = -1
    private var flash: Float = 0
    private var burst: Float = 0
    private var energySmooth: Float = 0.4

    private var ambientBeat = StoryBeat(time: 0, action: .drift, actors: [], valence: 0.2, energy: 0.4, hue: 0.6)
    private var ambientUntil: Double = 0

    init() { cast() }

    private func cast() {
        let characters = story?.characters ?? [
            StoryCharacter(name: "one", shape: .icosahedron, hue: 0.08),
            StoryCharacter(name: "two", shape: .torus, hue: 0.58),
        ]
        actors = characters.enumerated().map { index, character -> Actor in
            var actor = actors.indices.contains(index) ? actors[index] : Actor(shape: character.shape, baseHue: Float(character.hue), hue: Float(character.hue), phase: Float(index) * 2.1)
            actor.shape = character.shape
            actor.baseHue = Float(character.hue)
            return actor
        }
        beatIndex = -1
    }

    func update(dt: Float, audio: AudioFeatures) -> SceneState {
        time += Double(dt)
        let beat = currentBeat(audio: audio)
        let stage = Self.staging(beat.action)
        let energy = Float(beat.energy)
        let valence = Float(beat.valence)
        energySmooth = mix(energySmooth, energy, rate: 0.8, dt: dt)
        let drive = 0.6 + energySmooth * 0.8 + audio.level * 0.4

        flash *= exp(-dt * 2.5)
        burst *= exp(-dt * 3.0)
        let t = Float(time)

        // Characters.
        let cast = beat.actors.isEmpty ? Array(actors.indices) : beat.actors
        var rendered: [CharacterRender] = []
        for i in actors.indices {
            var actor = actors[i]
            let slot = cast.firstIndex(of: i)
            var target: SIMD3<Float>
            var scale: Float
            var brightness: Float

            if let slot {
                let count = Float(cast.count)
                let radius = cast.count == 1 ? stage.radius * 0.35 : stage.radius
                let angle = t * stage.orbitSpeed * drive + 2 * .pi * Float(slot) / count + actor.phase * 0.1
                if beat.action == .chase {
                    let lag = Float(slot) * 0.7
                    target = lissajous(t * 0.6 * drive - lag) * stage.radius
                } else {
                    target = SIMD3(cos(angle) * radius, stage.height, sin(angle) * radius * 0.7)
                }
                if beat.action == .separate, cast.count == 1 {
                    target = SIMD3(i == 0 ? -2.4 : 2.4, 0, 0)
                }
                scale = stage.scale
                brightness = stage.brightness
            } else {
                let angle = t * 0.05 + Float(i) * 2.4
                target = SIMD3(cos(angle) * 3.0, -0.6, sin(angle) * 2.0)
                scale = 0.45
                brightness = 0.25
            }
            // Gentle wander so nothing is ever perfectly still.
            target += SIMD3(sin(t * 0.31 + actor.phase), sin(t * 0.23 + actor.phase * 1.7), cos(t * 0.27 + actor.phase)) * 0.18

            actor.position = mix(actor.position, target, rate: 0.9 * drive, dt: dt)
            actor.scale = mix(actor.scale, scale, rate: 1.5, dt: dt)
            actor.brightness = mix(actor.brightness, brightness, rate: 1.5, dt: dt)
            let warmth: Float = valence >= 0 ? -0.05 * valence : 0.08 * -valence
            let wantedHue = mixHue(actor.baseHue, Float(beat.hue), 0.3) + warmth
            actor.hue = mixHue(actor.hue, wantedHue, 1 - exp(-dt * 0.8))
            let spin = (0.25 + energySmooth * 0.9 + audio.level * 0.8) * dt
            actor.rotation += SIMD3(spin * 0.7, spin, spin * 0.4)
            actors[i] = actor

            let pulse = 1 + audio.bass * 0.35 + flash * 0.4 + audio.beat * 0.12
            let saturation = min(1, 0.55 + stage.saturation * 0.4 + valence * 0.1)
            rendered.append(CharacterRender(
                position: actor.position,
                scale: max(0.05, actor.scale * pulse) * 0.75,
                rotation: actor.rotation,
                color: hsv(actor.hue, saturation, 1),
                brightness: actor.brightness * (0.7 + audio.level * 0.6 + flash),
                shape: actor.shape,
                displacement: 0.04 + audio.bass * 0.22 + (beat.action == .shatter ? 0.3 : 0) + burst * 0.3,
                attraction: slot == nil ? 0.4 : 1.0 + (beat.action == .embrace ? 0.6 : 0)
            ))
        }

        // World.
        scene.characters = rendered
        scene.turbulence = mix(scene.turbulence, stage.turbulence * drive + audio.treble * 0.6, rate: 1.2, dt: dt)
        scene.swirl = mix(scene.swirl, stage.swirl * drive, rate: 1.2, dt: dt)
        scene.radial = mix(scene.radial, stage.radial, rate: 2, dt: dt) + burst
        scene.gravity = mix(scene.gravity, SIMD3(0, stage.gravity, 0), rate: 1, dt: dt)
        scene.fade = mix(scene.fade, stage.fade - 0.04, rate: 0.8, dt: dt)
        scene.warp = mix(scene.warp, stage.warp + audio.bass * 0.4, rate: 1, dt: dt)
        scene.saturation = mix(scene.saturation, stage.saturation * (0.85 + valence * 0.15), rate: 0.8, dt: dt)
        scene.particleBrightness = mix(scene.particleBrightness, (0.5 + energySmooth * 0.6) * (beat.action == .hide ? 0.5 : 1), rate: 1, dt: dt)
        scene.backgroundHue = mixHue(scene.backgroundHue, Float(beat.hue), 1 - exp(-dt * 0.5))
        scene.backgroundIntensity = 0.18 + audio.level * 0.25 + flash * 0.3
        scene.zoom = 1.001 + audio.bass * 0.004 + scene.radial * 0.0015
        scene.rotate = 0.0015 * sin(t * 0.1) + scene.swirl * 0.0012
        scene.cameraAngle += dt * (0.04 + energySmooth * 0.08)
        scene.cameraDistance = mix(scene.cameraDistance, 6.8 - energySmooth * 1.2 + (beat.action == .hide ? 1.2 : 0) + (beat.action == .separate ? 1.0 : 0), rate: 0.5, dt: dt)
        scene.cameraHeight = 0.9 + sin(t * 0.07) * 0.8
        scene.waveHue = scene.backgroundHue + 0.5
        scene.waveTilt = mix(scene.waveTilt, 0.15 + valence * 0.35, rate: 0.6, dt: dt)
        scene.waveAmplitude = 0.35 + energySmooth * 0.5
        return scene
    }

    private func currentBeat(audio: AudioFeatures) -> StoryBeat {
        if let story, let position = songPosition() {
            var index = -1
            for (i, beat) in story.beats.enumerated() where beat.time <= position + 0.15 { index = i }
            if index != beatIndex {
                beatIndex = index
                if index >= 0 { trigger(story.beats[index].action) }
            }
            if index >= 0 { return story.beats[index] }
            // Before the first lyric: the characters wait in the dark.
            let first = story.beats.first!
            return StoryBeat(time: 0, action: .hide, actors: [], valence: first.valence, energy: 0.3, hue: first.hue)
        }
        return ambient(audio: audio)
    }

    /// Without lyrics, improvise: pick a new staging every few bars, guided by how loud the music is.
    private func ambient(audio: AudioFeatures) -> StoryBeat {
        if time >= ambientUntil {
            let loud = audio.level > 0.6
            let options: [StoryAction] = audio.silent ? [.calm, .hide, .drift]
                : loud ? [.storm, .bloom, .orbit, .shatter, .chase, .rise]
                : [.drift, .approach, .embrace, .orbit, .separate, .rise, .calm, .reveal]
            let action = options.filter { $0 != ambientBeat.action }.randomElement() ?? .drift
            let hue = Story.wrap(ambientBeat.hue + Double.random(in: 0.08...0.3))
            ambientBeat = StoryBeat(time: time, action: action, actors: [], valence: Double.random(in: -0.4...0.8),
                                    energy: Double(min(1, 0.3 + audio.level * 0.7)), hue: hue)
            ambientUntil = time + Double.random(in: 7...13)
            trigger(action)
        }
        return ambientBeat
    }

    private func trigger(_ action: StoryAction) {
        switch action {
        case .shatter: burst = 3
        case .bloom: burst = 1
        case .reveal: flash = 1
        case .embrace: flash = 0.5
        default: break
        }
    }

    private func lissajous(_ t: Float) -> SIMD3<Float> {
        SIMD3(sin(t * 1.3), sin(t * 2.1) * 0.5, cos(t * 0.9) * 0.8)
    }
}

// MARK: - Small math helpers

func mix(_ a: Float, _ b: Float, rate: Float, dt: Float) -> Float {
    a + (b - a) * (1 - exp(-dt * rate))
}

func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, rate: Float, dt: Float) -> SIMD3<Float> {
    a + (b - a) * (1 - exp(-dt * rate))
}

func mixHue(_ a: Float, _ b: Float, _ amount: Float) -> Float {
    var delta = (b - a).truncatingRemainder(dividingBy: 1)
    if delta > 0.5 { delta -= 1 }
    if delta < -0.5 { delta += 1 }
    let h = (a + delta * amount).truncatingRemainder(dividingBy: 1)
    return h < 0 ? h + 1 : h
}

func hsv(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
    let hue = (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
    let c = v * s
    let x = c * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
    let m = v - c
    let rgb: SIMD3<Float>
    switch Int(hue) {
    case 0: rgb = SIMD3(c, x, 0)
    case 1: rgb = SIMD3(x, c, 0)
    case 2: rgb = SIMD3(0, c, x)
    case 3: rgb = SIMD3(0, x, c)
    case 4: rgb = SIMD3(x, 0, c)
    default: rgb = SIMD3(c, 0, x)
    }
    return rgb + m
}
