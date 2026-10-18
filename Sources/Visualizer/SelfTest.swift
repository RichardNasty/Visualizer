import CoreGraphics
import Foundation
import ImageIO
import Metal

/// A small synthetic track: kick on every beat, snare on 2 and 4, off-beat hats, bass and a soft chord pad.
struct SyntheticSong {
    let bpm: Double
    let sampleRate: Double = 48_000
    var drums = true
    private var n = 0
    private var noiseState: UInt32 = 12345

    init(bpm: Double) { self.bpm = bpm }

    var beatPeriod: Double { 60 / bpm }

    private mutating func noise() -> Float {
        noiseState = noiseState &* 1_664_525 &+ 1_013_904_223
        return Float(noiseState >> 8) / Float(1 << 24) * 2 - 1
    }

    mutating func next(_ count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let p = beatPeriod
        for i in 0..<count {
            let t = Double(n) / sampleRate
            n += 1
            let beat = t / p
            let tb = (beat - beat.rounded(.down)) * p                  // seconds since the beat
            let beatIndex = Int(beat.rounded(.down))
            let half = (beat * 2 - (beat * 2).rounded(.down)) * p / 2   // seconds since the half beat
            var s: Float = 0
            if drums {
                let kickPhase = 2 * Double.pi * (48 * tb + 95.0 / 28 * (1 - exp(-28 * tb)))
                s += Float(sin(kickPhase) * exp(-tb * 14)) * 0.8
                if beatIndex % 2 == 1 {
                    s += (noise() * 0.35 + Float(sin(2 * Double.pi * 190 * tb)) * 0.2) * Float(exp(-tb * 22))
                }
                if tb >= p / 2 {
                    s += noise() * 0.12 * Float(exp(-(tb - p / 2) * 70))
                }
            }
            let root = [55.0, 43.65, 49.0, 41.2][(beatIndex / 8) % 4]
            s += Float(sin(2 * Double.pi * root * t)) * 0.18 * Float(exp(-half * 4))
            for ratio in [4.0, 4.0 * 1.189, 4.0 * 1.498] {
                let ph = (root * ratio * t).truncatingRemainder(dividingBy: 1)
                s += Float(ph * 2 - 1) * 0.025
            }
            out[i] = s * 0.6
        }
        return out
    }
}

enum SelfTest {
    static func run() -> Int32 {
        var failures: [String] = []
        func check(_ ok: Bool, _ message: String) {
            print(ok ? "PASS  \(message)" : "FAIL  \(message)")
            if !ok { failures.append(message) }
        }

        let fps = 60.0
        let hop = 800

        // 1. Silence stays still.
        do {
            let a = AudioAnalyzer()
            var zeros = [Float](repeating: 0, count: hop)
            var beats = 0
            for _ in 0..<120 {
                a.push(&zeros, count: hop, sampleRate: 48_000)
                if a.update(dt: 1 / fps) { beats += 1 }
            }
            check(a.features.silent && a.features.volume < 0.05 && beats == 0,
                  "silence: no movement (volume \(a.features.volume), beats \(beats))")
        }

        // 2. Tempo lock on a 124 BPM track.
        for bpm in [124.0, 96.0, 140.0] {
            let a = AudioAnalyzer()
            var song = SyntheticSong(bpm: bpm)
            var beatTimes: [Double] = []
            for _ in 0..<Int(14 * fps) {
                var samples = song.next(hop)
                a.push(&samples, count: hop, sampleRate: song.sampleRate)
                if a.update(dt: 1 / fps) { beatTimes.append(a.time) }
            }
            let found = Double(a.features.bpm)
            check(abs(found - bpm) / bpm < 0.04, "tempo: \(Int(bpm)) BPM track read as \(String(format: "%.1f", found)) BPM")
            let late = beatTimes.filter { $0 > 8 }
            // The analysis window ends at the newest sample, so a beat is seen up to one window late.
            let offsets = late.map { t -> Double in
                let k = (t / song.beatPeriod).rounded()
                return abs(t - k * song.beatPeriod)
            }
            let meanOffset = offsets.isEmpty ? 1 : offsets.reduce(0, +) / Double(offsets.count)
            let expected = 6 / song.beatPeriod
            check(Double(late.count) > expected * 0.8 && Double(late.count) < expected * 1.2,
                  "beats at \(Int(bpm)) BPM: \(late.count) in 6 s (expected about \(Int(expected)))")
            check(meanOffset < 0.06, "beats at \(Int(bpm)) BPM land on the kick (average \(Int(meanOffset * 1000)) ms off)")
            check(a.features.bass > 0.3 && a.features.volume > 0.3, "levels: bass \(a.features.bass), volume \(a.features.volume)")
        }

        // 3. Every scene draws something, and three preview stills.
        do {
            let renderer = try Renderer(outputFormat: .bgra8Unorm)
            let dir = ProcessInfo.processInfo.environment["VISUALIZER_PREVIEW"].map { URL(fileURLWithPath: $0) }
            if let dir {
                try FileManager.default.createDirectory(at: dir.appendingPathComponent("scenes"), withIntermediateDirectories: true)
            }
            for (index, scene) in Director.scenes.enumerated() {
                let palette = index % Director.palettes.count
                let pixels = try render(renderer: renderer, scene: scene.name, sceneIndex: index, palette: palette,
                                        width: 800, height: 500, seconds: 5,
                                        save: dir?.appendingPathComponent("scenes/\(index + 1)-\(scene.name).png"))
                check(pixels.mean > 0.02 && pixels.mean < 0.7,
                      "\(scene.name) / \(Director.palettes[palette].name): brightness \(String(format: "%.3f", pixels.mean))")
            }
            let stills = [(0, 1), (1, 0), (3, 4)]
            for (i, still) in stills.enumerated() {
                let pixels = try render(renderer: renderer, scene: Director.scenes[still.0].name, sceneIndex: still.0,
                                        palette: still.1, width: 1600, height: 1000, seconds: 8,
                                        save: dir?.appendingPathComponent("preview-\(i + 1).png"))
                check(pixels.mean > 0.02, "preview \(i + 1): brightness \(String(format: "%.3f", pixels.mean))")
            }
        } catch {
            check(false, "rendering: \(error.localizedDescription)")
        }

        print(failures.isEmpty ? "All checks passed." : "\(failures.count) check(s) failed.")
        return failures.isEmpty ? 0 : 1
    }

    struct Pixels { let mean: Double }

    private static func render(renderer: Renderer, scene: String, sceneIndex: Int, palette: Int,
                               width: Int, height: Int, seconds: Double, save: URL?) throws -> Pixels {
        let engine = Engine()
        engine.director.force(scene: sceneIndex, palette: palette)
        engine.director.locked = true
        var song = SyntheticSong(bpm: 124)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .managed
        guard let output = renderer.device.makeTexture(descriptor: d) else { throw RendererError.setup("No output texture") }

        let frames = Int(seconds * 60)
        for frame in 0..<frames {
            var samples = song.next(800)
            engine.analyzer.push(&samples, count: samples.count, sampleRate: song.sampleRate)
            let (w, h) = renderer.feedbackSize(for: width, height)
            let u = engine.step(dt: 1.0 / 60, width: w, height: h)
            guard let cb = renderer.queue.makeCommandBuffer() else { throw RendererError.setup("No command buffer") }
            renderer.encode(cb, uniforms: u, wave: engine.analyzer.wave, spectrum: engine.analyzer.spectrum, output: output)
            if frame == frames - 1, let blit = cb.makeBlitCommandEncoder() {
                blit.synchronize(resource: output)
                blit.endEncoding()
            }
            cb.commit()
            if frame % 30 == 0 || frame == frames - 1 { cb.waitUntilCompleted() }
        }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        output.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        var sum = 0
        for i in stride(from: 0, to: bytes.count, by: 4) { sum += Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2]) }
        let mean = Double(sum) / Double(width * height * 3) / 255

        if let save {
            let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
            let data = Data(bytes) as CFData
            if let provider = CGDataProvider(data: data),
               let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                                   decode: nil, shouldInterpolate: false, intent: .defaultIntent),
               let dest = CGImageDestinationCreateWithURL(save as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
        }
        return Pixels(mean: mean)
    }
}
