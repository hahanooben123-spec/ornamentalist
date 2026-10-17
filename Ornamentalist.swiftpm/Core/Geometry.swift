import Foundation

struct Point: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    static let zero = Point(x: 0, y: 0)
    static func + (a: Point, b: Point) -> Point { Point(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: Point, b: Point) -> Point { Point(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: Point, s: Double) -> Point { Point(x: a.x * s, y: a.y * s) }
    var length: Double { hypot(x, y) }
    var isFinite: Bool { x.isFinite && y.isFinite }
}

/// Column-vector affine matrix. `a.followed(by: b)` applies a, then b.
struct Matrix: Equatable, Sendable {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, tx = 0.0, ty = 0.0
    func apply(_ p: Point) -> Point {
        Point(x: a * p.x + c * p.y + tx, y: b * p.x + d * p.y + ty)
    }
    func followed(by m: Matrix) -> Matrix {
        Matrix(a: m.a*a + m.c*b, b: m.b*a + m.d*b,
               c: m.a*c + m.c*d, d: m.b*c + m.d*d,
               tx: m.a*tx + m.c*ty + m.tx, ty: m.b*tx + m.d*ty + m.ty)
    }
    var inverse: Matrix {
        let det = a*d - b*c
        precondition(abs(det) > 1e-12)
        return Matrix(a: d/det, b: -b/det, c: -c/det, d: a/det,
                      tx: (c*ty-d*tx)/det, ty: (b*tx-a*ty)/det)
    }
    static func translation(_ p: Point) -> Matrix { Matrix(tx: p.x, ty: p.y) }
    static func scale(_ s: Double) -> Matrix { Matrix(a: s, d: s) }
    static func rotation(_ angle: Double) -> Matrix {
        Matrix(a: cos(angle), b: sin(angle), c: -sin(angle), d: cos(angle))
    }
}

/// Viewport has no effect on stored geometry or symmetry.
struct Viewport: Sendable {
    var zoom = 1.0
    var rotation = 0.0
    var pan = Point.zero
    func matrix(viewSize: Point, canvasSize: Point) -> Matrix {
        let fit = max(0.001, min(viewSize.x / canvasSize.x, viewSize.y / canvasSize.y) * 0.92)
        return Matrix.translation(canvasSize * -0.5)
            .followed(by: .scale(fit * zoom))
            .followed(by: .rotation(rotation))
            .followed(by: .translation(viewSize * 0.5 + pan))
    }
}
