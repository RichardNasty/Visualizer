import Foundation
import Metal
import QuartzCore
import simd

/// Mirrors `Uniforms` in Visualizer.metal: every field is a float4.
struct Uniforms {
    var res = SIMD4<Float>(repeating: 0)
    var time = SIMD4<Float>(repeating: 0)
    var audio = SIMD4<Float>(repeating: 0)
    var beat = SIMD4<Float>(repeating: 0)
    var scenes = SIMD4<Float>(repeating: 0)
    var motion = SIMD4<Float>(repeating: 0)
    var pal0 = SIMD4<Float>(repeating: 0)
    var pal1 = SIMD4<Float>(repeating: 0)
    var pal2 = SIMD4<Float>(repeating: 0)
}

/// Ties the analyzer and director together and produces each frame's shader inputs.
final class Engine {
    let analyzer = AudioAnalyzer()
    let director = Director()
    private(set) var time: Double = 0

    func step(dt: Double, width: Int, height: Int) -> Uniforms {
        let dt = min(max(dt, 1.0 / 240), 0.1)
        time += dt
        let beat = analyzer.update(dt: dt)
        let f = analyzer.features
        director.update(dt: Float(dt), features: f, beat: beat)

        var u = Uniforms()
        let w = Float(width), h = Float(height)
        u.res = SIMD4(w, h, 1 / w, 1 / h)
        u.time = SIMD4(Float(time.truncatingRemainder(dividingBy: 3600)), Float(dt), Float(dt * 60), w / h)
        u.audio = SIMD4(f.bass, f.mid, f.treble, f.volume)
        u.beat = SIMD4(f.pulse, f.phase, f.kick, min(f.beatAge, 10))
        u.scenes = SIMD4(Float(director.previousScene), Float(director.scene), director.blend, director.decay)
        u.motion = SIMD4(director.rotation, director.musicalTime, f.silent ? 0 : 1, 0)
        let colors = director.paletteColors()
        u.pal0 = SIMD4(colors[0], 1)
        u.pal1 = SIMD4(colors[1], 1)
        u.pal2 = SIMD4(colors[2], 1)
        return u
    }
}

enum RendererError: LocalizedError {
    case setup(String)
    var errorDescription: String? {
        switch self { case let .setup(message): return message }
    }
}

/// Two passes per frame: advance the trails in an HDR feedback image, then add glow and tone map it to the screen.
final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let updatePipeline: MTLRenderPipelineState
    private let presentPipeline: MTLRenderPipelineState
    private var feedback: [MTLTexture] = []
    private var current = 0
    /// Longest side of the feedback image; the screen image is scaled up from it.
    var maxDimension = 2560

    init(outputFormat: MTLPixelFormat) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RendererError.setup("This Mac has no Metal graphics support.")
        }
        self.device = device
        self.queue = queue

        let source = try String(contentsOf: Self.shaderURL(), encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        guard let vertex = library.makeFunction(name: "fullscreen_vertex"),
              let update = library.makeFunction(name: "update_fragment"),
              let present = library.makeFunction(name: "present_fragment")
        else { throw RendererError.setup("The shaders are missing a function.") }

        let u = MTLRenderPipelineDescriptor()
        u.vertexFunction = vertex
        u.fragmentFunction = update
        u.colorAttachments[0].pixelFormat = .rgba16Float
        updatePipeline = try device.makeRenderPipelineState(descriptor: u)

        let p = MTLRenderPipelineDescriptor()
        p.vertexFunction = vertex
        p.fragmentFunction = present
        p.colorAttachments[0].pixelFormat = outputFormat
        presentPipeline = try device.makeRenderPipelineState(descriptor: p)
    }

    private static func shaderURL() throws -> URL {
        if let url = Bundle.main.url(forResource: "Visualizer", withExtension: "metal") { return url }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [
            exe.deletingLastPathComponent().appendingPathComponent("../Resources/Visualizer.metal"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Shaders/Visualizer.metal"),
        ]
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) { return url }
        throw RendererError.setup("Couldn't find the shaders.")
    }

    /// The feedback size for an output of the given size.
    func feedbackSize(for width: Int, _ height: Int) -> (Int, Int) {
        let scale = min(1, Double(maxDimension) / Double(max(width, height, 1)))
        return (max(16, Int(Double(width) * scale)), max(16, Int(Double(height) * scale)))
    }

    private func ensureFeedback(width: Int, height: Int, commandBuffer: MTLCommandBuffer) {
        if let first = feedback.first, first.width == width, first.height == height { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: true)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        feedback = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
        for texture in feedback {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
    }

    func encode(_ commandBuffer: MTLCommandBuffer, uniforms: Uniforms, wave: [Float], spectrum: [Float], output: MTLTexture) {
        var u = uniforms
        let width = Int(u.res.x), height = Int(u.res.y)
        ensureFeedback(width: width, height: height, commandBuffer: commandBuffer)
        guard feedback.count == 2 else { return }
        let source = feedback[current], target = feedback[1 - current]

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            enc.setRenderPipelineState(updatePipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            wave.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            spectrum.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
            enc.setFragmentTexture(source, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: target)
            blit.endEncoding()
        }

        let out = MTLRenderPassDescriptor()
        out.colorAttachments[0].texture = output
        out.colorAttachments[0].loadAction = .dontCare
        out.colorAttachments[0].storeAction = .store
        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: out) {
            enc.setRenderPipelineState(presentPipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(target, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        current = 1 - current
    }
}
