import Foundation
import Metal
import MetalKit
import QuartzCore
import simd

// Must match FrameUniforms in Visualizer.metal.
struct FrameUniforms {
    var viewProj = matrix_identity_float4x4
    var camPos = SIMD4<Float>(0, 0, 0, 1)
    var time: Float = 0, dt: Float = 0, aspect: Float = 1, fade: Float = 0.9
    var bass: Float = 0, mid: Float = 0, treble: Float = 0, level: Float = 0
    var beat: Float = 0, turbulence: Float = 0, radial: Float = 0, swirl: Float = 0
    var gravity = SIMD4<Float>(0, 0, 0, 0)
    var bgHue: Float = 0, bgIntensity: Float = 0, warp: Float = 0, zoom: Float = 1
    var rotate: Float = 0, saturation: Float = 1, particleBright: Float = 1, charCount: Float = 1
    var charPos: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero)
    var charColor: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero)
}

struct ShapeUniforms {
    var model: simd_float4x4
    var color: SIMD4<Float>
    var params: SIMD4<Float>
}

struct LineVertex {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
}

struct Particle {
    var pos: SIMD4<Float>
    var vel: SIMD4<Float>
}

enum RendererError: LocalizedError {
    case noGPU, noShaders, setup(String)

    var errorDescription: String? {
        switch self {
        case .noGPU: return "This Mac has no Metal graphics support."
        case .noShaders: return "The visual effects file is missing from the app."
        case let .setup(message): return message
        }
    }
}

/// Draws one frame: particles, glowing shapes and the waveform ribbon over a trailing dream-like background.
final class Renderer: NSObject, MTKViewDelegate {
    static let particleCount = 60_000
    static let waveformPoints = AudioFeatures.waveformCount + 1

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let updatePipeline: MTLComputePipelineState
    private let particlePipeline: MTLRenderPipelineState
    private let shapePipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let composePipeline: MTLRenderPipelineState
    private var presentPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private let library: MTLLibrary
    private let particleBuffer: MTLBuffer
    private var meshes: [ShapeKind: (buffer: MTLBuffer, count: Int)] = [:]
    private var lineBuffers: [MTLBuffer] = []
    private let inFlight = DispatchSemaphore(value: 3)
    private var frameIndex = 0
    private var current: MTLTexture?
    private var previous: MTLTexture?
    private var startTime = CACurrentMediaTime()
    private var lastTime = CACurrentMediaTime()

    /// Supplies the scene and audio for each frame.
    var frameSource: ((_ dt: Float) -> (SceneState, AudioFeatures))?

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw RendererError.noGPU }
        self.device = device
        self.queue = queue
        let library = try Self.makeLibrary(device)
        self.library = library

        func function(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw RendererError.setup("Missing shader \(name)") }
            return f
        }
        func pipeline(_ vertex: String, _ fragment: String, additive: Bool, format: MTLPixelFormat = .rgba16Float) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = try function(vertex)
            d.fragmentFunction = try function(fragment)
            d.colorAttachments[0].pixelFormat = format
            if additive {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.rgbBlendOperation = .add
                a.alphaBlendOperation = .add
                a.sourceRGBBlendFactor = .one
                a.destinationRGBBlendFactor = .one
                a.sourceAlphaBlendFactor = .one
                a.destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }

        updatePipeline = try device.makeComputePipelineState(function: try function("updateParticles"))
        particlePipeline = try pipeline("particleVertex", "particleFragment", additive: true)
        shapePipeline = try pipeline("shapeVertex", "shapeFragment", additive: true)
        linePipeline = try pipeline("lineVertex", "lineFragment", additive: true)
        composePipeline = try pipeline("screenVertex", "composeFragment", additive: false)

        var particles = (0..<Renderer.particleCount).map { i -> Particle in
            let seed = Float(i) * 0.6180339 + 0.5
            let r = SIMD3<Float>(Float.random(in: -1...1), Float.random(in: -1...1), Float.random(in: -1...1)) * 3
            return Particle(pos: SIMD4(r, Float.random(in: 0...1)), vel: SIMD4(0, 0, 0, seed))
        }
        guard let buffer = device.makeBuffer(bytes: &particles, length: MemoryLayout<Particle>.stride * particles.count) else {
            throw RendererError.setup("Could not allocate particles")
        }
        particleBuffer = buffer

        var meshes: [ShapeKind: (buffer: MTLBuffer, count: Int)] = [:]
        for kind in ShapeKind.allCases {
            var vertices = MeshFactory.make(kind)
            guard let b = device.makeBuffer(bytes: &vertices, length: MemoryLayout<ShapeVertex>.stride * vertices.count) else {
                throw RendererError.setup("Could not allocate shapes")
            }
            meshes[kind] = (b, vertices.count)
        }
        var lineBuffers: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let b = device.makeBuffer(length: MemoryLayout<LineVertex>.stride * Renderer.waveformPoints * 2) else {
                throw RendererError.setup("Could not allocate waveform")
            }
            lineBuffers.append(b)
        }
        self.meshes = meshes
        self.lineBuffers = lineBuffers
        super.init()
    }

    private static func makeLibrary(_ device: MTLDevice) throws -> MTLLibrary {
        var candidates: [URL] = []
        if let url = Bundle.main.url(forResource: "Visualizer", withExtension: "metal") { candidates.append(url) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        candidates.append(exe.deletingLastPathComponent().appendingPathComponent("../Resources/Visualizer.metal"))
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Shaders/Visualizer.metal"))
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let source = try? String(contentsOf: url, encoding: .utf8) else { throw RendererError.noShaders }
        return try device.makeLibrary(source: source, options: nil)
    }

    private func presentPipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let p = presentPipelines[format] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "screenVertex")
        d.fragmentFunction = library.makeFunction(name: "presentFragment")
        d.colorAttachments[0].pixelFormat = format
        let p = try device.makeRenderPipelineState(descriptor: d)
        presentPipelines[format] = p
        return p
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }
        let size = view.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        renderFrame(to: drawable.texture, size: size) { $0.present(drawable) }
    }

    /// Renders one frame into `target`. Used by the window and by the self-test.
    func renderFrame(to target: MTLTexture, size: CGSize, beforeCommit: ((MTLCommandBuffer) -> Void)? = nil) {
        inFlight.wait()
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, max(0.001, now - lastTime)))
        lastTime = now
        let (scene, audio) = frameSource?(dt) ?? (SceneState(), AudioFeatures())

        ensureTextures(width: Int(size.width), height: Int(size.height))
        guard let current, let previous, let commands = queue.makeCommandBuffer() else { inFlight.signal(); return }
        let semaphore = inFlight
        commands.addCompletedHandler { _ in semaphore.signal() }

        var u = uniforms(scene: scene, audio: audio, dt: dt, time: Float(now - startTime), aspect: Float(size.width / size.height))

        if let compute = commands.makeComputeCommandEncoder() {
            compute.setComputePipelineState(updatePipeline)
            compute.setBuffer(particleBuffer, offset: 0, index: 0)
            compute.setBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            let width = min(updatePipeline.maxTotalThreadsPerThreadgroup, 256)
            compute.dispatchThreads(MTLSize(width: Self.particleCount, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
            compute.endEncoding()
        }

        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = current
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        scenePass.colorAttachments[0].storeAction = .store
        if let encoder = commands.makeRenderCommandEncoder(descriptor: scenePass) {
            encoder.setRenderPipelineState(composePipeline)
            encoder.setFragmentTexture(previous, index: 0)
            encoder.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            encoder.setRenderPipelineState(particlePipeline)
            encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Self.particleCount)

            encoder.setRenderPipelineState(shapePipeline)
            encoder.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            for character in scene.characters {
                guard let mesh = meshes[character.shape] else { continue }
                var s = ShapeUniforms(
                    model: Self.model(position: character.position, rotation: character.rotation, scale: character.scale),
                    color: SIMD4(character.color, character.brightness),
                    params: SIMD4(character.displacement, u.time, 0, 0)
                )
                encoder.setVertexBuffer(mesh.buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&s, length: MemoryLayout<ShapeUniforms>.stride, index: 2)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.count)
            }

            let lines = lineBuffers[frameIndex % lineBuffers.count]
            fillWaveform(lines, scene: scene, audio: audio)
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(lines, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: Self.waveformPoints * 2)
            encoder.endEncoding()
        }

        let presentPass = MTLRenderPassDescriptor()
        presentPass.colorAttachments[0].texture = target
        presentPass.colorAttachments[0].loadAction = .dontCare
        presentPass.colorAttachments[0].storeAction = .store
        if let pipeline = try? presentPipeline(for: target.pixelFormat),
           let encoder = commands.makeRenderCommandEncoder(descriptor: presentPass) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(current, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        beforeCommit?(commands)
        commands.commit()
        swap(&self.current, &self.previous)
        frameIndex += 1
    }

    private func ensureTextures(width: Int, height: Int) {
        if let current, current.width == width, current.height == height { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        current = device.makeTexture(descriptor: d)
        previous = device.makeTexture(descriptor: d)
        // Start the trail texture black.
        if let previous, let commands = queue.makeCommandBuffer() {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = previous
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            commands.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            commands.commit()
        }
    }

    private func uniforms(scene: SceneState, audio: AudioFeatures, dt: Float, time: Float, aspect: Float) -> FrameUniforms {
        let eye = SIMD3<Float>(sin(scene.cameraAngle) * scene.cameraDistance, scene.cameraHeight, cos(scene.cameraAngle) * scene.cameraDistance)
        let view = Self.lookAt(eye: eye, center: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0))
        let projection = Self.perspective(fovy: 0.9, aspect: aspect, near: 0.1, far: 100)

        var u = FrameUniforms()
        u.viewProj = projection * view
        u.camPos = SIMD4(eye, 1)
        u.time = time; u.dt = dt; u.aspect = aspect; u.fade = scene.fade
        u.bass = audio.bass; u.mid = audio.mid; u.treble = audio.treble; u.level = audio.level
        u.beat = audio.beat; u.turbulence = scene.turbulence; u.radial = scene.radial; u.swirl = scene.swirl
        u.gravity = SIMD4(scene.gravity, 0)
        u.bgHue = scene.backgroundHue; u.bgIntensity = scene.backgroundIntensity; u.warp = scene.warp; u.zoom = scene.zoom
        u.rotate = scene.rotate; u.saturation = scene.saturation; u.particleBright = scene.particleBrightness

        let chars = scene.characters
        u.charCount = Float(max(1, chars.count))
        func pos(_ i: Int) -> SIMD4<Float> {
            guard chars.indices.contains(i) else { return SIMD4(0, 0, 0, 0.5) }
            return SIMD4(chars[i].position, chars[i].attraction)
        }
        func color(_ i: Int) -> SIMD4<Float> {
            guard chars.indices.contains(i) else { return SIMD4(0.6, 0.7, 1, 1) }
            return SIMD4(chars[i].color, chars[i].brightness)
        }
        u.charPos = (pos(0), pos(1), pos(2))
        u.charColor = (color(0), color(1), color(2))
        return u
    }

    /// A glowing ring around the scene whose edge is the live waveform.
    private func fillWaveform(_ buffer: MTLBuffer, scene: SceneState, audio: AudioFeatures) {
        let vertices = buffer.contents().bindMemory(to: LineVertex.self, capacity: Self.waveformPoints * 2)
        let count = AudioFeatures.waveformCount
        let radius: Float = 3.4
        let thickness: Float = 0.018 + audio.level * 0.02
        let tilt = scene.waveTilt
        let brightness = 0.35 + audio.level * 0.9
        for i in 0..<Self.waveformPoints {
            let index = i % count
            let edge = sin(Float.pi * Float(index) / Float(count))
            let sample = audio.waveform[index] * scene.waveAmplitude * sqrt(max(0, edge))
            let angle = Float(i) / Float(count) * 2 * .pi
            var center = SIMD3<Float>(cos(angle) * (radius + sample * 0.4), sample * 0.6, sin(angle) * (radius + sample * 0.4))
            // Tilt the ring around the x axis.
            center = SIMD3(center.x, center.y * cos(tilt) - center.z * sin(tilt), center.y * sin(tilt) + center.z * cos(tilt))
            let rgb = hsv(scene.waveHue + Float(i) / Float(count) * 0.25, 0.7, 1) * brightness
            let color = SIMD4<Float>(rgb, 1)
            vertices[i * 2] = LineVertex(position: SIMD4(center + SIMD3(0, thickness, 0), 1), color: color)
            vertices[i * 2 + 1] = LineVertex(position: SIMD4(center - SIMD3(0, thickness, 0), 1), color: color)
        }
    }

    // MARK: - Matrices

    static func perspective(fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovy * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, -1),
            SIMD4(0, 0, z * near, 0)
        ))
    }

    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = normalize(eye - center)
        let x = normalize(cross(up, z))
        let y = cross(z, x)
        return simd_float4x4(columns: (
            SIMD4(x.x, y.x, z.x, 0),
            SIMD4(x.y, y.y, z.y, 0),
            SIMD4(x.z, y.z, z.z, 0),
            SIMD4(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
        ))
    }

    static func model(position: SIMD3<Float>, rotation: SIMD3<Float>, scale: Float) -> simd_float4x4 {
        let rx = simd_quatf(angle: rotation.x, axis: SIMD3(1, 0, 0))
        let ry = simd_quatf(angle: rotation.y, axis: SIMD3(0, 1, 0))
        let rz = simd_quatf(angle: rotation.z, axis: SIMD3(0, 0, 1))
        var m = simd_float4x4(rz * ry * rx)
        m.columns.0 *= scale
        m.columns.1 *= scale
        m.columns.2 *= scale
        m.columns.3 = SIMD4(position, 1)
        return m
    }
}
