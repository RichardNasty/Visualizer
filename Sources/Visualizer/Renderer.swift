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
    /// classic, magnetosphere, xbox, twirl
    var worlds = SIMD4<Float>(0.33, 0.33, 0.33, 0)
    /// hue drift, flash, unused, unused
    var effects = SIMD4<Float>(0, 0, 0, 0)
}

struct ShapeUniforms {
    var model: simd_float4x4
    var color: SIMD4<Float>
    var params: SIMD4<Float>
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

/// Draws one frame by mixing three looks:
/// classic iTunes (liquid trails and waveform ribbons), Magnetosphere (particle nebula)
/// and the original Xbox visualizer (neon wireframes, tunnel, bursts),
/// with the story's characters, their trails, bonds and rings of light on top.
final class Renderer: NSObject, MTKViewDelegate {
    static let particleCount = 80_000
    static let lineCapacity = 120_000

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
    private var edges: [ShapeKind: [(SIMD3<Float>, SIMD3<Float>)]] = [:]
    private var trailBuffers: [MTLBuffer] = []
    private var crispBuffers: [MTLBuffer] = []
    private var trailLines = LineBatch(capacity: Renderer.lineCapacity)
    private var crispLines = LineBatch(capacity: Renderer.lineCapacity)
    private let inFlight = DispatchSemaphore(value: 3)
    private var frameIndex = 0
    private var current: MTLTexture?
    private var previous: MTLTexture?
    private var crisp: MTLTexture?
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
        func pipeline(_ vertex: String, _ fragment: String, additive: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = try function(vertex)
            d.fragmentFunction = try function(fragment)
            d.colorAttachments[0].pixelFormat = .rgba16Float
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
        var edges: [ShapeKind: [(SIMD3<Float>, SIMD3<Float>)]] = [:]
        for kind in ShapeKind.allCases {
            var vertices = MeshFactory.make(kind)
            guard let b = device.makeBuffer(bytes: &vertices, length: MemoryLayout<ShapeVertex>.stride * vertices.count) else {
                throw RendererError.setup("Could not allocate shapes")
            }
            meshes[kind] = (b, vertices.count)
            edges[kind] = MeshFactory.edges(kind)
        }
        var trailBuffers: [MTLBuffer] = []
        var crispBuffers: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let a = device.makeBuffer(length: MemoryLayout<LineVertex>.stride * Renderer.lineCapacity),
                  let b = device.makeBuffer(length: MemoryLayout<LineVertex>.stride * Renderer.lineCapacity) else {
                throw RendererError.setup("Could not allocate lines")
            }
            trailBuffers.append(a)
            crispBuffers.append(b)
        }
        self.meshes = meshes
        self.edges = edges
        self.trailBuffers = trailBuffers
        self.crispBuffers = crispBuffers
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
        guard let current, let previous, let crisp, let commands = queue.makeCommandBuffer() else { inFlight.signal(); return }
        let semaphore = inFlight
        commands.addCompletedHandler { _ in semaphore.signal() }

        let aspect = Float(size.width / size.height)
        let time = Float(now - startTime)
        let camera = Self.camera(scene)
        var u = uniforms(scene: scene, audio: audio, dt: dt, time: time, aspect: aspect, camera: camera)

        // Build this frame's glowing lines.
        trailLines.reset(camera: camera.eye, aspect: aspect)
        crispLines.reset(camera: camera.eye, aspect: aspect)
        addClassicRibbons(scene: scene, audio: audio, time: time)
        addXbox(scene: scene, audio: audio, time: time, camera: camera)
        addStory(scene: scene, audio: audio, time: time, camera: camera)
        addWaveRing(scene: scene, audio: audio)
        let slot = frameIndex % 3
        let trailCount = upload(trailLines, to: trailBuffers[slot])
        let crispCount = upload(crispLines, to: crispBuffers[slot])

        if let compute = commands.makeComputeCommandEncoder() {
            compute.setComputePipelineState(updatePipeline)
            compute.setBuffer(particleBuffer, offset: 0, index: 0)
            compute.setBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            let width = min(updatePipeline.maxTotalThreadsPerThreadgroup, 256)
            compute.dispatchThreads(MTLSize(width: Self.particleCount, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
            compute.endEncoding()
        }

        // Pass 1: everything that leaves liquid trails (previous frame, particles, ribbons).
        if let encoder = commands.makeRenderCommandEncoder(descriptor: Self.pass(current)) {
            encoder.setRenderPipelineState(composePipeline)
            encoder.setFragmentTexture(previous, index: 0)
            encoder.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            encoder.setRenderPipelineState(particlePipeline)
            encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Self.particleCount)

            if trailCount > 0 {
                encoder.setRenderPipelineState(linePipeline)
                encoder.setVertexBuffer(trailBuffers[slot], offset: 0, index: 0)
                encoder.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: trailCount)
            }
            encoder.endEncoding()
        }

        // Pass 2: sharp things drawn fresh every frame (shapes, wireframes, bonds, rings).
        if let encoder = commands.makeRenderCommandEncoder(descriptor: Self.pass(crisp)) {
            encoder.setRenderPipelineState(shapePipeline)
            encoder.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            let solid = 1 - scene.xbox * 0.75
            for character in scene.characters {
                guard let mesh = meshes[character.shape] else { continue }
                var s = ShapeUniforms(
                    model: Self.model(position: character.position, rotation: character.rotation, scale: character.scale),
                    color: SIMD4(character.color, character.brightness * solid),
                    params: SIMD4(character.displacement, time, 0, 0)
                )
                encoder.setVertexBuffer(mesh.buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&s, length: MemoryLayout<ShapeUniforms>.stride, index: 2)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.count)
            }
            if crispCount > 0 {
                encoder.setRenderPipelineState(linePipeline)
                encoder.setVertexBuffer(crispBuffers[slot], offset: 0, index: 0)
                encoder.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: crispCount)
            }
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
            encoder.setFragmentTexture(crisp, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        beforeCommit?(commands)
        commands.commit()
        swap(&self.current, &self.previous)
        frameIndex += 1
    }

    private static func pass(_ texture: MTLTexture) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    private func upload(_ batch: LineBatch, to buffer: MTLBuffer) -> Int {
        let count = min(batch.vertices.count, Self.lineCapacity) / 3 * 3
        guard count > 0 else { return 0 }
        batch.vertices.withUnsafeBytes { raw in
            buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: count * MemoryLayout<LineVertex>.stride)
        }
        return count
    }

    private func ensureTextures(width: Int, height: Int) {
        if let current, current.width == width, current.height == height { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        current = device.makeTexture(descriptor: d)
        previous = device.makeTexture(descriptor: d)
        crisp = device.makeTexture(descriptor: d)
        if let previous, let commands = queue.makeCommandBuffer() {
            commands.makeRenderCommandEncoder(descriptor: Self.pass(previous))?.endEncoding()
            commands.commit()
        }
    }

    // MARK: - Camera and uniforms

    private struct Camera {
        var eye: SIMD3<Float>
        var forward: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
    }

    private static func camera(_ scene: SceneState) -> Camera {
        let eye = SIMD3<Float>(sin(scene.cameraAngle) * scene.cameraDistance, scene.cameraHeight, cos(scene.cameraAngle) * scene.cameraDistance)
        let forward = normalize(-eye)
        let right = normalize(cross(forward, SIMD3(0, 1, 0)))
        let up = cross(right, forward)
        return Camera(eye: eye, forward: forward, right: right, up: up)
    }

    private func uniforms(scene: SceneState, audio: AudioFeatures, dt: Float, time: Float, aspect: Float, camera: Camera) -> FrameUniforms {
        let view = Self.lookAt(eye: camera.eye, center: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0))
        let projection = Self.perspective(fovy: 0.9, aspect: aspect, near: 0.1, far: 100)

        var u = FrameUniforms()
        u.viewProj = projection * view
        u.camPos = SIMD4(camera.eye, 1)
        u.time = time; u.dt = dt; u.aspect = aspect; u.fade = scene.fade
        u.bass = audio.bass; u.mid = audio.mid; u.treble = audio.treble; u.level = audio.level
        u.beat = audio.beat; u.turbulence = scene.turbulence; u.radial = scene.radial; u.swirl = scene.swirl
        u.gravity = SIMD4(scene.gravity, 0)
        u.bgHue = scene.backgroundHue; u.bgIntensity = scene.backgroundIntensity; u.warp = scene.warp; u.zoom = scene.zoom
        u.rotate = scene.rotate; u.saturation = scene.saturation; u.particleBright = scene.particleBrightness
        u.worlds = SIMD4(scene.classic, scene.magnetosphere, scene.xbox, scene.twirl)
        u.effects = SIMD4(scene.hueDrift, scene.flash, 0, 0)

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

    // MARK: - Classic iTunes: oscilloscope ribbons that smear into liquid colour

    private func addClassicRibbons(scene: SceneState, audio: AudioFeatures, time: Float) {
        let weight = scene.classic
        guard weight > 0.02 else { return }
        let samples = audio.waveform
        let count = 160
        for ribbon in 0..<3 {
            let r = Float(ribbon)
            let angle = time * (0.13 + r * 0.05) + r * 2.1
            let cosA = cos(angle), sinA = sin(angle)
            let offset = sin(time * 0.37 + r * 1.7) * 0.25
            let amplitude: Float = 0.28 + audio.level * 0.35
            var points: [SIMD2<Float>] = []
            points.reserveCapacity(count)
            for i in 0..<count {
                let x = Float(i) / Float(count - 1) * 2.4 - 1.2
                let sample = samples[(i * 3 + ribbon * 40) % samples.count]
                let y = offset + sample * amplitude * (1 - abs(x) * 0.35)
                points.append(SIMD2(x * cosA - y * sinA, x * sinA + y * cosA))
            }
            let baseHue = time * 0.05 + r * 0.33
            trailLines.screenPolyline(points, width: 0.012 + audio.bass * 0.012,
                                      color: { hsv(baseHue + Float($0) / Float(count) * 0.35, 0.85, 1) },
                                      alpha: { _ in weight * 0.55 })
        }
    }

    // MARK: - Original Xbox: hexagon tunnel, beat spokes, neon wireframes

    private func addXbox(scene: SceneState, audio: AudioFeatures, time: Float, camera: Camera) {
        let weight = scene.xbox
        guard weight > 0.02 else { return }
        let neon = SIMD3<Float>(0.35, 1.0, 0.25)
        let rings = 16
        let depth: Float = 16
        for i in 0..<rings {
            let d = 0.8 + (Float(i) / Float(rings) - scene.tunnelPhase * 0.12).truncatingRemainder(dividingBy: 1).magnitudeWrapped * depth
            let fadeNear = min(1, (d - 0.8) / 1.5)
            let fadeFar = 1 - d / (depth + 0.8)
            let alpha = weight * fadeNear * fadeFar * (0.35 + audio.bass * 0.5)
            guard alpha > 0.01 else { continue }
            let center = camera.eye + camera.forward * d
            let radius: Float = 3.0 + audio.bass * 0.5
            let twist = Float(i) * 0.18 + time * 0.25
            let sides = 6
            var points: [SIMD3<Float>] = []
            for k in 0..<sides {
                let a = twist + Float(k) / Float(sides) * 2 * .pi
                points.append(center + camera.right * cos(a) * radius + camera.up * sin(a) * radius)
            }
            let color = mixColor(neon, hsv(scene.backgroundHue, 0.7, 1), 0.25)
            crispLines.polyline(points, closed: true, width: { _ in 0.035 }, color: { _ in color }, alpha: { _ in alpha })
        }

        // Spokes of light on every beat.
        let spokeAlpha = weight * audio.beat * 0.7
        if spokeAlpha > 0.02 {
            let spokes = 24
            for k in 0..<spokes {
                let a = Float(k) / Float(spokes) * 2 * .pi + time * 0.2
                let dir = SIMD2(cos(a) / scene.aspectCorrection(crispLines.aspect), sin(a))
                crispLines.screenSegment(dir * 0.18, dir * 1.6, width: 0.004,
                                         colorA: neon, alphaA: spokeAlpha, colorB: neon, alphaB: 0)
            }
        }

        // The characters as glowing wireframes.
        for character in scene.characters {
            guard let lines = edges[character.shape] else { continue }
            let model = Self.model(position: character.position, rotation: character.rotation, scale: character.scale * 1.08)
            let color = mixColor(character.color, neon, 0.45)
            let alpha = character.brightness * (0.15 + weight * 1.1)
            for (a, b) in lines {
                let wa = model * SIMD4(a, 1), wb = model * SIMD4(b, 1)
                crispLines.segment(SIMD3(wa.x, wa.y, wa.z), SIMD3(wb.x, wb.y, wb.z), width: 0.03, color: color, alpha: alpha)
            }
        }
    }

    // MARK: - The story: trails, bonds and rings of light

    private func addStory(scene: SceneState, audio: AudioFeatures, time: Float, camera: Camera) {
        for character in scene.characters where character.trail.count > 2 {
            let trail = [character.position] + character.trail
            let n = Float(trail.count)
            let head = 0.16 * max(0.4, character.scale)
            let brightness = character.brightness
            crispLines.polyline(trail, width: { head * (1 - Float($0) / n) },
                                color: { _ in character.color },
                                alpha: { brightness * 0.9 * pow(1 - Float($0) / n, 1.5) })
            // A softer copy feeds the liquid trails.
            trailLines.polyline(trail, width: { head * 1.6 * (1 - Float($0) / n) },
                                color: { _ in character.color },
                                alpha: { brightness * 0.06 * (1 - Float($0) / n) })
        }

        for tether in scene.tethers {
            let segments = 40
            let mid = (tether.a + tether.b) * 0.5 + SIMD3(0, 0.5 * (1 - tether.strength), 0)
            var points: [SIMD3<Float>] = []
            for i in 0...segments {
                let s = Float(i) / Float(segments)
                let a = tether.a + (mid - tether.a) * s
                let b = mid + (tether.b - mid) * s
                var p = a + (b - a) * s
                let wobble = sin(s * .pi) * (0.06 + audio.treble * 0.2) * sin(time * 4 + s * 14)
                p += camera.up * wobble
                points.append(p)
            }
            let strength = tether.strength
            crispLines.polyline(points, width: { _ in 0.02 + 0.05 * strength + audio.bass * 0.02 },
                                color: { mixColor(tether.colorA, tether.colorB, Float($0) / Float(segments)) },
                                alpha: { _ in min(1.2, strength * 1.1) })
        }

        for wave in scene.shockwaves {
            let segments = 56
            var points: [SIMD3<Float>] = []
            for k in 0..<segments {
                let a = Float(k) / Float(segments) * 2 * .pi
                points.append(wave.center + camera.right * cos(a) * wave.radius + camera.up * sin(a) * wave.radius)
            }
            crispLines.polyline(points, closed: true, width: { _ in 0.05 * wave.alpha + 0.01 },
                                color: { _ in wave.color }, alpha: { _ in wave.alpha })
            trailLines.polyline(points, closed: true, width: { _ in 0.08 },
                                color: { _ in wave.color }, alpha: { _ in wave.alpha * 0.08 })
        }
    }

    /// A glowing ring around the scene whose edge is the live waveform.
    private func addWaveRing(scene: SceneState, audio: AudioFeatures) {
        let weight = scene.magnetosphere * 0.8 + scene.xbox * 0.5 + 0.15
        let count = AudioFeatures.waveformCount / 2
        let radius: Float = 3.6
        let tilt = scene.waveTilt
        var points: [SIMD3<Float>] = []
        for i in 0..<count {
            let edge = sin(Float.pi * Float(i) / Float(count))
            let sample = audio.waveform[i * 2] * scene.waveAmplitude * sqrt(max(0, edge))
            let angle = Float(i) / Float(count) * 2 * .pi
            let p = SIMD3<Float>(cos(angle) * (radius + sample * 0.4), sample * 0.6, sin(angle) * (radius + sample * 0.4))
            points.append(SIMD3(p.x, p.y * cos(tilt) - p.z * sin(tilt), p.y * sin(tilt) + p.z * cos(tilt)))
        }
        let hue = scene.waveHue
        let brightness = (0.3 + audio.level * 0.8) * weight
        crispLines.polyline(points, closed: true, width: { _ in 0.03 + audio.level * 0.03 },
                            color: { hsv(hue + 0.12 * sin(Float($0) / Float(count) * 2 * .pi), 0.7, 1) },
                            alpha: { _ in brightness })
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

func mixColor(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
    a + (b - a) * t
}

private extension Float {
    /// Wraps a remainder into 0..<1.
    var magnitudeWrapped: Float { self < 0 ? self + 1 : self }
}

private extension SceneState {
    func aspectCorrection(_ aspect: Float) -> Float { max(aspect, 0.01) }
}
