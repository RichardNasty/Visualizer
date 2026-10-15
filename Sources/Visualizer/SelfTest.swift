import Foundation
import Metal

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

        // GPU: compile shaders and draw some frames offscreen.
        if let device = MTLCreateSystemDefaultDevice() {
            do {
                let renderer = try Renderer(device: device)
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
                let lit = stride(from: 0, to: pixels.count, by: 4).filter { Int(pixels[$0]) + Int(pixels[$0 + 1]) + Int(pixels[$0 + 2]) > 30 }.count
                check("render frames", last?.status == .completed && lit > 500, "\(device.name), \(lit) lit pixels")
            } catch {
                check("render frames", false, error.localizedDescription)
            }
        } else {
            print("SKIP  render frames — no GPU on this machine")
        }

        print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
        return failures == 0 ? 0 : 1
    }
}
