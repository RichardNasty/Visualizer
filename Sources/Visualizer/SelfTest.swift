import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// `Visualizer --selftest`: checks the parts that can be checked without a person, used by the build.
enum SelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        // Lyrics parsing.
        let lrc = "[ar:Someone]\n[00:12.50]I will hold you close\n[00:15.00][01:15.00]We fly so high\n[00:20.00]"
        let lines = LyricsService.parseLRC(lrc)
        check("parse synced lyrics", lines.count == 4 && lines[0].time == 12.5 && lines[1].text == "We fly so high" && lines.last?.time == 75)
        check("parse YouTube title", NowPlayingWatcher.youTubeSong(from: "(2) Artist - Song (Official Music Video) - YouTube") == "Artist - Song")

        // Free storyteller.
        let simple = SimpleStoryteller.story(title: "Test", lines: lines)
        check("simple story", simple != nil && simple!.beats.count == 4 && simple!.beats[0].action == .embrace,
              simple.map { $0.beats.map(\.action.rawValue).joined(separator: ",") } ?? "nil")

        // Claude reply parsing (including chatter around the JSON and unknown values).
        let reply = """
        Here you go:
        {"title":"Two lights","characters":[{"name":"her","shape":"torus","hue":0.9},{"name":"him","shape":"blob","hue":1.2}],
         "beats":[{"time":15,"action":"rise","actors":[0,1],"valence":0.8,"energy":0.7,"hue":0.1},
                  {"time":12.5,"action":"teleport","actors":[5],"valence":3,"energy":0.2,"hue":0.6}]}
        """
        do {
            let story = try StoryService.parse(reply)
            check("parse Claude story", story.characters[1].shape == .sphere && story.beats[0].time == 12.5
                  && story.beats[0].action == .drift && story.beats[0].actors.isEmpty && story.beats[0].valence == 1)
        } catch {
            check("parse Claude story", false, error.localizedDescription)
        }
        check("prompt mentions lyrics", StoryService.prompt(track: TrackInfo(title: "T", artist: "A", source: .music), lyrics: lines).contains("[12.50] I will hold you close"))

        // Story playback.
        let director = Director()
        director.story = simple
        var position = 0.0
        director.songPosition = { position }
        var audio = AudioFeatures()
        audio.silent = false
        audio.level = 0.5
        audio.bass = 0.6
        var scene = SceneState()
        for frame in 0..<600 {
            position = Double(frame) / 30
            scene = director.update(dt: 1 / 30, audio: audio)
        }
        check("director moves characters", scene.characters.count == 2 && scene.characters.allSatisfy { $0.position.x.isFinite && $0.scale > 0 })

        // Analyzer.
        let analyzer = AudioAnalyzer()
        var tone = (0..<4096).map { Float(sin(Double($0) * 2 * .pi * 80 / 48_000)) * 0.5 }
        tone.withUnsafeMutableBufferPointer { analyzer.push($0.baseAddress!, count: $0.count, sampleRate: 48_000) }
        var features = AudioFeatures()
        for i in 0..<10 { features = analyzer.analyze(time: Double(i) / 60) }
        check("analyzer hears bass", features.bass > features.treble && features.bass > 0.2, "bass \(features.bass) treble \(features.treble)")

        // Note lines: a note lights its own line and nothing else, whatever sample rate the Mac's audio runs at.
        func listen(_ midis: [Int], rate: Double, amplitude: Float) -> AudioFeatures {
            let analyzer = AudioAnalyzer()
            var samples = (0..<32_768).map { i -> Float in
                var sum: Float = 0
                for midi in midis {
                    let frequency = 440 * pow(2, Double(midi - 69) / 12)
                    sum += Float(sin(Double(i) * 2 * .pi * frequency / rate)) * amplitude
                }
                return sum
            }
            samples.withUnsafeMutableBufferPointer { analyzer.push($0.baseAddress!, count: $0.count, sampleRate: rate) }
            var heard = AudioFeatures()
            for i in 0..<20 { heard = analyzer.analyze(time: Double(i) / 60) }
            return heard
        }
        func brightestOther(_ heard: AudioFeatures, besides lit: [Int]) -> Float {
            heard.notes.indices.filter { !lit.contains($0) }.map { heard.notes[$0] }.max() ?? 0
        }
        var misses: [String] = []
        for rate in [44_100.0, 48_000, 96_000, 192_000] {
            for midi in [36, 38, 48, 59, 60, 69, 95, 107] {
                let heard = listen([midi], rate: rate, amplitude: 0.5)
                let line = midi - AudioFeatures.lowestNote
                let strongest = heard.notes.indices.max { heard.notes[$0] < heard.notes[$1] } ?? -1
                let name = heard.chroma.indices.max { heard.chroma[$0] < heard.chroma[$1] } ?? -1
                let other = brightestOther(heard, besides: [line])
                if strongest != line || heard.notes[line] < 0.5 || other > 0.2 || name != midi % 12 {
                    misses.append("MIDI \(midi) at \(Int(rate)) Hz: brightest line \(strongest), own line \(heard.notes[line]), other \(other)")
                }
            }
        }
        check("each note lights only its own line", misses.isEmpty, misses.joined(separator: "; "))

        let chord = listen([60, 64, 67], rate: 48_000, amplitude: 0.3)
        let chordLines = [60, 64, 67].map { $0 - AudioFeatures.lowestNote }
        let chordOther = brightestOther(chord, besides: chordLines)
        check("a C major chord lights C, E and G", chordLines.allSatisfy { chord.notes[$0] > 0.5 } && chordOther < 0.2,
              "C E G \(chordLines.map { chord.notes[$0] }), other \(chordOther)")

        // Noise (hiss, cymbals, the rush of a crowd) has no pitch, so it should light hardly any lines,
        // while a note played through it still shows.
        var seed: UInt64 = 12_345
        func nextNoise() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(seed >> 40) / Float(1 << 24)
        }
        let noiseAnalyzer = AudioAnalyzer()
        let toneAnalyzer = AudioAnalyzer()
        var crowd = 0
        var throughNoise = AudioFeatures()
        for frame in 0..<60 {
            var hiss = (0..<800).map { _ in (nextNoise() + nextNoise() + nextNoise() - 1.5) * 0.2 }
            hiss.withUnsafeMutableBufferPointer { noiseAnalyzer.push($0.baseAddress!, count: $0.count, sampleRate: 48_000) }
            let heard = noiseAnalyzer.analyze(time: Double(frame + 1) * 800 / 48_000)
            if frame >= 10 { crowd = max(crowd, heard.notes.filter { $0 > 0.2 }.count) }

            var mix = (0..<800).map { i -> Float in
                let t = Double(frame * 800 + i) / 48_000
                let hum = (nextNoise() + nextNoise() + nextNoise() - 1.5) * 0.1
                return Float(sin(t * 2 * .pi * 440)) * 0.2 + hum
            }
            mix.withUnsafeMutableBufferPointer { toneAnalyzer.push($0.baseAddress!, count: $0.count, sampleRate: 48_000) }
            throughNoise = toneAnalyzer.analyze(time: Double(frame + 1) * 800 / 48_000)
        }
        check("noise lights hardly any lines", crowd <= 3, "\(crowd) lines at most")
        let a4 = 69 - AudioFeatures.lowestNote
        let noiseOther = brightestOther(throughNoise, besides: [a4])
        check("a note still shows through noise", throughNoise.notes[a4] > 0.5 && noiseOther < 0.2,
              "A4 \(throughNoise.notes[a4]), other \(noiseOther)")

        // GPU: compile shaders and draw some frames offscreen.
        if let device = MTLCreateSystemDefaultDevice() {
            do {
                let renderer = try Renderer(device: device)
                renderer.fixedStep = 1 / 60
                let director = Director()
                renderer.frameSource = { dt in (director.update(dt: dt, audio: audio), audio) }
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 640, height: 360, mipmapped: false)
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.storageMode = .shared
                guard let target = device.makeTexture(descriptor: descriptor) else { throw RendererError.noGPU }
                var last: MTLCommandBuffer?
                for _ in 0..<30 {
                    renderer.renderFrame(to: target, size: CGSize(width: 640, height: 360)) { last = $0 }
                }
                last?.waitUntilCompleted()
                var pixels = [UInt8](repeating: 0, count: 640 * 360 * 4)
                target.getBytes(&pixels, bytesPerRow: 640 * 4, from: MTLRegionMake2D(0, 0, 640, 360), mipmapLevel: 0)
                var lit = 0
                for i in stride(from: 0, to: pixels.count, by: 4) {
                    let sum: Int = Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
                    if sum > 30 { lit += 1 }
                }
                check("render frames", last?.status == .completed && lit > 500, "\(device.name), \(lit) lit pixels")
            } catch {
                check("render frames", false, error.localizedDescription)
            }
        } else {
            print("SKIP  render frames — no GPU on this machine")
        }

        if let folder = ProcessInfo.processInfo.environment["VISUALIZER_PREVIEW"] {
            savePreviews(to: folder, story: simple)
        }

        print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
        return failures == 0 ? 0 : 1
    }

    /// Renders a few stills of a story playing to fake music, for the README and release page.
    private static func savePreviews(to folder: String, story: Story?) {
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = try? Renderer(device: device) else { return }
        renderer.fixedStep = 1 / 60
        let width = 1280, height = 720
        // Fake music for the note lines: a bass note and chord changing every two seconds, a melody on top.
        let chords: [[Int]] = [[0, 4, 7], [9, 0, 4], [5, 9, 0], [7, 11, 2]]
        let melody = [12, 14, 16, 19, 16, 14, 12, 11]
        let director = Director()
        director.story = story
        var clock = 0.0
        director.songPosition = { clock }
        var frame = 0
        renderer.frameSource = { dt in
            frame += 1
            let t = Float(frame) / 60
            var audio = AudioFeatures()
            audio.silent = false
            audio.bass = 0.5 + 0.5 * max(0, sin(t * 7.5))
            audio.mid = 0.4 + 0.2 * sin(t * 3)
            audio.treble = 0.3 + 0.2 * sin(t * 11)
            audio.level = 0.6 + 0.3 * sin(t * 1.3)
            audio.beat = fmod(t, 0.5) < 0.05 ? 1 : 0
            var notes = [Float](repeating: 0, count: AudioFeatures.noteCount)
            let chord = chords[Int(t / 2) % chords.count]
            let bar = 1 - Float(fmod(Double(t), 2)) / 2 * 0.5
            notes[12 + chord[0]] = 0.9 * bar
            for pitchClass in chord {
                notes[24 + pitchClass] = 0.7 * bar
                notes[36 + pitchClass] = 0.45 * bar
            }
            let step = Int(t * 4) % melody.count
            let melodyNote = 36 + chord[0] + melody[step]
            notes[melodyNote] = max(notes[melodyNote], 0.95 - Float(fmod(Double(t * 4), 1)) * 0.4)
            notes[60 + (step * 5) % 12] = 0.3
            audio.notes = notes
            audio.chroma = (0..<12).map { pitchClass -> Float in
                var sum: Float = 0
                for n in stride(from: pitchClass, to: AudioFeatures.noteCount, by: 12) { sum += notes[n] }
                return min(1, sum * 0.6)
            }
            audio.waveform = (0..<AudioFeatures.waveformCount).map { i -> Float in
                let x = Float(i)
                let a: Float = sin(x * 0.09 + t * 20) * 0.6
                let b: Float = sin(x * 0.31 - t * 9) * 0.3
                return a + b
            }
            return (director.update(dt: 1 / 60, audio: audio), audio)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor) else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        // One still per lyric moment, once its world has settled in: 12.5s embrace, 15s rise, 20s calm.
        for (index, moment) in [14.6, 19.5, 26.0].enumerated() {
            var last: MTLCommandBuffer?
            while clock < moment {
                clock += 1.0 / 60
                renderer.renderFrame(to: target, size: CGSize(width: width, height: height)) { last = $0 }
            }
            last?.waitUntilCompleted()
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            target.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                                      decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { continue }
            let url = URL(fileURLWithPath: folder).appendingPathComponent("preview-\(index + 1).png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            print("Saved \(url.path)")
        }
    }
}
