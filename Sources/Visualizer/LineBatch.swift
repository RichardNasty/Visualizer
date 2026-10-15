import simd

struct LineVertex {
    /// xyz + mode: w = 1 means world space, w = 0 means xy is already on screen (-1...1).
    var position: SIMD4<Float>
    /// rgb + brightness
    var color: SIMD4<Float>
    /// x: position across the line (-1...1), used for the soft glowing edge.
    var extra: SIMD4<Float>
}

/// Collects glowing lines (as thin quads) for one frame, so they can all be drawn in one call.
struct LineBatch {
    var vertices: [LineVertex] = []
    var camera = SIMD3<Float>(0, 0, 5)
    var aspect: Float = 1

    init(capacity: Int) { vertices.reserveCapacity(capacity) }

    mutating func reset(camera: SIMD3<Float>, aspect: Float) {
        vertices.removeAll(keepingCapacity: true)
        self.camera = camera
        self.aspect = aspect
    }

    /// A 3D line segment that always faces the camera.
    mutating func segment(_ a: SIMD3<Float>, _ b: SIMD3<Float>, width: Float, color: SIMD3<Float>, alpha: Float,
                          widthB: Float? = nil, colorB: SIMD3<Float>? = nil, alphaB: Float? = nil) {
        let along = b - a
        guard simd_length_squared(along) > 1e-10 else { return }
        let toCamera = camera - (a + b) * 0.5
        var side = cross(along, toCamera)
        let length = simd_length(side)
        guard length > 1e-6 else { return }
        side /= length
        let sa = side * width * 0.5
        let sb = side * (widthB ?? width) * 0.5
        let ca = SIMD4(color, alpha)
        let cb = SIMD4(colorB ?? color, alphaB ?? alpha)
        quad(SIMD4(a - sa, 1), SIMD4(a + sa, 1), SIMD4(b - sb, 1), SIMD4(b + sb, 1), ca, cb)
    }

    /// A connected 3D line through `points`.
    mutating func polyline(_ points: [SIMD3<Float>], closed: Bool = false, width: (Int) -> Float,
                           color: (Int) -> SIMD3<Float>, alpha: (Int) -> Float) {
        guard points.count > 1 else { return }
        let count = closed ? points.count : points.count - 1
        for i in 0..<count {
            let j = (i + 1) % points.count
            segment(points[i], points[j], width: width(i), color: color(i), alpha: alpha(i),
                    widthB: width(j), colorB: color(j), alphaB: alpha(j))
        }
    }

    /// A line drawn flat on the screen; points are in -1...1 screen space.
    mutating func screenPolyline(_ points: [SIMD2<Float>], width: Float, color: (Int) -> SIMD3<Float>, alpha: (Int) -> Float) {
        guard points.count > 1 else { return }
        for i in 0..<(points.count - 1) {
            screenSegment(points[i], points[i + 1], width: width, colorA: color(i), alphaA: alpha(i), colorB: color(i + 1), alphaB: alpha(i + 1))
        }
    }

    mutating func screenSegment(_ a: SIMD2<Float>, _ b: SIMD2<Float>, width: Float,
                                colorA: SIMD3<Float>, alphaA: Float, colorB: SIMD3<Float>, alphaB: Float) {
        // Work in square pixels so lines are equally thick in every direction.
        let along = SIMD2((b.x - a.x) * aspect, b.y - a.y)
        let length = simd_length(along)
        guard length > 1e-6 else { return }
        let normal = SIMD2(-along.y / length / aspect, along.x / length) * width * 0.5
        quad(SIMD4(a.x - normal.x, a.y - normal.y, 0, 0), SIMD4(a.x + normal.x, a.y + normal.y, 0, 0),
             SIMD4(b.x - normal.x, b.y - normal.y, 0, 0), SIMD4(b.x + normal.x, b.y + normal.y, 0, 0),
             SIMD4(colorA, alphaA), SIMD4(colorB, alphaB))
    }

    private mutating func quad(_ a0: SIMD4<Float>, _ a1: SIMD4<Float>, _ b0: SIMD4<Float>, _ b1: SIMD4<Float>,
                               _ ca: SIMD4<Float>, _ cb: SIMD4<Float>) {
        let left = SIMD4<Float>(-1, 0, 0, 0)
        let right = SIMD4<Float>(1, 0, 0, 0)
        vertices.append(LineVertex(position: a0, color: ca, extra: left))
        vertices.append(LineVertex(position: a1, color: ca, extra: right))
        vertices.append(LineVertex(position: b0, color: cb, extra: left))
        vertices.append(LineVertex(position: a1, color: ca, extra: right))
        vertices.append(LineVertex(position: b1, color: cb, extra: right))
        vertices.append(LineVertex(position: b0, color: cb, extra: left))
    }
}
