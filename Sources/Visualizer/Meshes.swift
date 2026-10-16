import simd

struct ShapeVertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
}

/// Builds the glowing shapes as plain triangle lists.
enum MeshFactory {
    static func make(_ kind: ShapeKind) -> [ShapeVertex] {
        switch kind {
        case .sphere: return smooth(subdivide(icosahedron(), times: 3))
        case .icosahedron: return faceted(icosahedron())
        case .octahedron: return faceted(octahedron())
        case .tetrahedron: return faceted(tetrahedron())
        case .cube: return faceted(cube())
        case .torus: return torus(major: 0.75, minor: 0.28, segments: 64, sides: 24)
        case .heart, .teardrop: return surface(kind, segments: 72, rings: 48, faceted: false)
        case .star, .shards: return surface(kind, segments: 72, rings: 48, faceted: true)
        }
    }

    /// The shape's edges, for the neon wireframe look.
    static func edges(_ kind: ShapeKind) -> [(SIMD3<Float>, SIMD3<Float>)] {
        switch kind {
        case .sphere: return uniqueEdges(subdivide(icosahedron(), times: 1))
        case .icosahedron: return uniqueEdges(icosahedron())
        case .octahedron: return uniqueEdges(octahedron())
        case .tetrahedron: return uniqueEdges(tetrahedron())
        case .cube:
            let h: Float = 0.62
            let p = (0..<8).map { i in SIMD3<Float>(i & 1 == 0 ? -h : h, i & 2 == 0 ? -h : h, i & 4 == 0 ? -h : h) }
            let pairs = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
            return pairs.map { (p[$0.0], p[$0.1]) }
        case .torus:
            let major: Float = 0.75, minor: Float = 0.28, segments = 16, sides = 8
            func point(_ i: Int, _ j: Int) -> SIMD3<Float> {
                let u = Float(i) / Float(segments) * 2 * .pi
                let v = Float(j) / Float(sides) * 2 * .pi
                let center = SIMD3<Float>(cos(u) * major, 0, sin(u) * major)
                let normal = SIMD3<Float>(cos(u) * cos(v), sin(v), sin(u) * cos(v))
                return center + normal * minor
            }
            var result: [(SIMD3<Float>, SIMD3<Float>)] = []
            for i in 0..<segments {
                for j in 0..<sides {
                    result.append((point(i, j), point(i + 1, j)))
                    result.append((point(i, j), point(i, j + 1)))
                }
            }
            return result
        case .heart, .star, .teardrop:
            // A clean neon outline, extruded front to back like old vector graphics.
            let count = 80
            let depth: Float = kind == .teardrop ? 0 : 0.2
            let loop = (0..<count).map { outline(kind, Float($0) / Float(count)) }
            var result: [(SIMD3<Float>, SIMD3<Float>)] = []
            for i in 0..<count {
                let a = loop[i], b = loop[(i + 1) % count]
                result.append((a + SIMD3(0, 0, depth), b + SIMD3(0, 0, depth)))
                if depth > 0 {
                    result.append((a - SIMD3(0, 0, depth), b - SIMD3(0, 0, depth)))
                    if i % 8 == 0 { result.append((a + SIMD3(0, 0, depth), a - SIMD3(0, 0, depth))) }
                } else {
                    // The drop is round: add a crossing outline so it reads in 3D.
                    let c = SIMD3(0, a.y, a.x), d = SIMD3(0, b.y, b.x)
                    result.append((c, d))
                }
            }
            return result
        case .shards:
            // Each crystal spike as a sharp pyramid of light.
            var result: [(SIMD3<Float>, SIMD3<Float>)] = []
            for spike in shardDirections {
                let tip = spike.direction * (0.42 + spike.length)
                let side = normalize(cross(spike.direction, abs(spike.direction.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)))
                let other = cross(spike.direction, side)
                let base = (0..<3).map { k -> SIMD3<Float> in
                    let a = Float(k) / 3 * 2 * .pi
                    return spike.direction * 0.3 + (side * cos(a) + other * sin(a)) * 0.16
                }
                for k in 0..<3 {
                    result.append((base[k], tip))
                    result.append((base[k], base[(k + 1) % 3]))
                }
            }
            return result
        }
    }

    /// The flat silhouette of a mood shape, s from 0 to 1 around it.
    static func outline(_ kind: ShapeKind, _ s: Float) -> SIMD3<Float> {
        let t = s * 2 * .pi
        switch kind {
        case .heart:
            let x = 15 * sin(t) - 4 * sin(3 * t)
            let y = 15 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
            return SIMD3(x, y + 2, 0) / 15
        case .star:
            let r = 0.5 + 0.75 * pow(abs(cos(2.5 * (t - .pi / 2))), 4)
            return SIMD3(cos(t) * r, sin(t) * r, 0)
        case .teardrop:
            let radius = sin(t) * pow(abs(sin(t / 2)), 1.6) * 0.95
            return SIMD3(radius, cos(t) * 1.05 - 0.15, 0)
        default:
            return SIMD3(cos(t), sin(t), 0)
        }
    }

    // MARK: - Mood shapes, all built as surfaces over (u around, v top to bottom)

    /// A point on a mood shape. u goes around (0...1), v goes from top (0) to bottom (1).
    static func point(_ kind: ShapeKind, _ u: Float, _ v: Float) -> SIMD3<Float> {
        let theta = u * 2 * .pi
        let phi = v * .pi
        switch kind {
        case .heart:
            // The classic 3D heart surface, lobes on top, scaled to about the size of a ball.
            let a = phi, b = theta
            let x = sin(a) * (15 * sin(b) - 4 * sin(3 * b))
            let depth = 8 * cos(a)
            let y = sin(a) * (15 * cos(b) - 5 * cos(2 * b) - 2 * cos(3 * b) - cos(4 * b))
            return SIMD3(x, y + 2, depth) / 15
        case .star:
            // A puffy five-pointed star facing the camera.
            let dir = SIMD3<Float>(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
            let angle = atan2(dir.y, dir.x)
            let point = pow(abs(cos(2.5 * (angle - .pi / 2))), 4)
            let flat = sqrt(max(0, 1 - dir.z * dir.z))
            let r = 0.5 + 0.75 * point * flat
            return SIMD3(dir.x * r, dir.y * r, dir.z * 0.42)
        case .teardrop:
            // A falling drop: round at the bottom, pointed at the top.
            let t = phi
            let radius = sin(t) * pow(sin(t / 2), 1.6) * 0.95
            return SIMD3(cos(theta) * radius, cos(t) * 1.05 - 0.15, sin(theta) * radius)
        case .shards:
            // A cluster of crystal spikes bursting out of a core.
            let dir = SIMD3<Float>(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
            var spike: Float = 0
            for s in shardDirections { spike = max(spike, pow(max(0, dot(dir, s.direction)), 18) * s.length) }
            return dir * (0.42 + spike)
        default:
            return SIMD3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
        }
    }

    private static let shardDirections: [(direction: SIMD3<Float>, length: Float)] = {
        var generator = SplitMix(seed: 7)
        return (0..<11).map { i -> (direction: SIMD3<Float>, length: Float) in
            let z = generator.next() * 2 - 1
            let a = generator.next() * 2 * .pi
            let r = sqrt(max(0, 1 - z * z))
            return (SIMD3(r * cos(a), z, r * sin(a)), 0.55 + generator.next() * 0.7 + (i == 0 ? 0.2 : 0))
        }
    }()

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Float {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return Float(z >> 40) / Float(1 << 24)
        }
    }

    private static func surface(_ kind: ShapeKind, segments: Int, rings: Int, faceted flat: Bool) -> [ShapeVertex] {
        var grid: [[SIMD3<Float>]] = []
        for j in 0...rings {
            var row: [SIMD3<Float>] = []
            for i in 0...segments {
                row.append(point(kind, Float(i) / Float(segments), Float(j) / Float(rings)))
            }
            grid.append(row)
        }
        let center = grid.flatMap { $0 }.reduce(SIMD3<Float>(0, 0, 0), +) / Float((rings + 1) * (segments + 1))
        func smoothNormal(_ i: Int, _ j: Int) -> SIMD3<Float> {
            let du = grid[j][(i + 1) % segments] - grid[j][(i + segments - 1) % segments]
            let dv = grid[min(rings, j + 1)][i] - grid[max(0, j - 1)][i]
            var n = cross(du, dv)
            let p = grid[j][i]
            if simd_length_squared(n) < 1e-10 { n = p - center }
            n = normalize(n)
            return dot(n, p - center) < 0 ? -n : n
        }
        var vertices: [ShapeVertex] = []
        for j in 0..<rings {
            for i in 0..<segments {
                let corners = [(i, j), (i + 1, j), (i + 1, j + 1), (i, j + 1)]
                let p = corners.map { grid[$0.1][$0.0] }
                for tri in [(0, 1, 2), (0, 2, 3)] {
                    let a = p[tri.0], b = p[tri.1], c = p[tri.2]
                    let face = cross(b - a, c - a)
                    guard simd_length_squared(face) > 1e-12 else { continue }
                    if flat {
                        var n = normalize(face)
                        if dot(n, (a + b + c) / 3 - center) < 0 { n = -n }
                        vertices += [a, b, c].map { ShapeVertex(position: SIMD4($0, 1), normal: SIMD4(n, 0)) }
                    } else {
                        for k in [tri.0, tri.1, tri.2] {
                            let (ci, cj) = corners[k]
                            vertices.append(ShapeVertex(position: SIMD4(p[k], 1), normal: SIMD4(smoothNormal(ci % segments, cj), 0)))
                        }
                    }
                }
            }
        }
        return vertices
    }

    private static func uniqueEdges(_ triangles: Triangles) -> [(SIMD3<Float>, SIMD3<Float>)] {
        var seen = Set<String>()
        var result: [(SIMD3<Float>, SIMD3<Float>)] = []
        func key(_ p: SIMD3<Float>) -> String { String(format: "%.3f,%.3f,%.3f", p.x, p.y, p.z) }
        for (a, b, c) in triangles {
            for (p, q) in [(a, b), (b, c), (c, a)] {
                let k1 = key(p), k2 = key(q)
                let k = k1 < k2 ? k1 + "|" + k2 : k2 + "|" + k1
                if seen.insert(k).inserted { result.append((p, q)) }
            }
        }
        return result
    }

    private typealias Triangles = [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]

    private static func faceted(_ triangles: Triangles) -> [ShapeVertex] {
        triangles.flatMap { a, b, c -> [ShapeVertex] in
            var n = normalize(cross(b - a, c - a))
            if dot(n, a + b + c) < 0 { n = -n }
            return [a, b, c].map { ShapeVertex(position: SIMD4($0, 1), normal: SIMD4(n, 0)) }
        }
    }

    private static func smooth(_ triangles: Triangles) -> [ShapeVertex] {
        triangles.flatMap { a, b, c in
            [a, b, c].map { ShapeVertex(position: SIMD4($0, 1), normal: SIMD4(normalize($0), 0)) }
        }
    }

    private static func icosahedron() -> Triangles {
        let t: Float = (1 + Float(5).squareRoot()) / 2
        let raw: [SIMD3<Float>] = [
            [-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0],
            [0, -1, t], [0, 1, t], [0, -1, -t], [0, 1, -t],
            [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1],
        ]
        let v = raw.map { normalize($0) }
        let f: [(Int, Int, Int)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
            (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
            (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
            (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
        ]
        return f.map { (v[$0.0], v[$0.1], v[$0.2]) }
    }

    private static func subdivide(_ triangles: Triangles, times: Int) -> Triangles {
        var result = triangles
        for _ in 0..<times {
            result = result.flatMap { a, b, c -> Triangles in
                let ab = normalize((a + b) / 2), bc = normalize((b + c) / 2), ca = normalize((c + a) / 2)
                return [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
            }
        }
        return result
    }

    private static func octahedron() -> Triangles {
        let px = SIMD3<Float>(1, 0, 0), nx = SIMD3<Float>(-1, 0, 0)
        let py = SIMD3<Float>(0, 1, 0), ny = SIMD3<Float>(0, -1, 0)
        let pz = SIMD3<Float>(0, 0, 1), nz = SIMD3<Float>(0, 0, -1)
        return [(py, pz, px), (py, px, nz), (py, nz, nx), (py, nx, pz),
                (ny, px, pz), (ny, nz, px), (ny, nx, nz), (ny, pz, nx)]
    }

    private static func tetrahedron() -> Triangles {
        let s: Float = 1 / Float(3).squareRoot()
        let a = SIMD3<Float>(1, 1, 1) * s, b = SIMD3<Float>(1, -1, -1) * s
        let c = SIMD3<Float>(-1, 1, -1) * s, d = SIMD3<Float>(-1, -1, 1) * s
        return [(a, b, c), (a, d, b), (a, c, d), (b, d, c)]
    }

    private static func cube() -> Triangles {
        let h: Float = 0.62
        let p = (0..<8).map { i in SIMD3<Float>(i & 1 == 0 ? -h : h, i & 2 == 0 ? -h : h, i & 4 == 0 ? -h : h) }
        let quads = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
        return quads.flatMap { q -> Triangles in [(p[q.0], p[q.1], p[q.2]), (p[q.0], p[q.2], p[q.3])] }
    }

    private static func torus(major: Float, minor: Float, segments: Int, sides: Int) -> [ShapeVertex] {
        func point(_ i: Int, _ j: Int) -> ShapeVertex {
            let u = Float(i) / Float(segments) * 2 * .pi
            let v = Float(j) / Float(sides) * 2 * .pi
            let center = SIMD3<Float>(cos(u) * major, 0, sin(u) * major)
            let normal = SIMD3<Float>(cos(u) * cos(v), sin(v), sin(u) * cos(v))
            return ShapeVertex(position: SIMD4(center + normal * minor, 1), normal: SIMD4(normal, 0))
        }
        var vertices: [ShapeVertex] = []
        for i in 0..<segments {
            for j in 0..<sides {
                let a = point(i, j), b = point(i + 1, j), c = point(i + 1, j + 1), d = point(i, j + 1)
                vertices += [a, b, c, a, c, d]
            }
        }
        return vertices
    }
}
