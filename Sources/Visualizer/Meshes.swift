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
        }
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
