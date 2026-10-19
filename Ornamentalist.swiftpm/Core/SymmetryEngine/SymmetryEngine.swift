import Foundation

struct SymmetryConfiguration: Codable, Hashable, Sendable {
    var repetitions = 8 // 1 is symmetry off.
    var center = Point(x: 1024, y: 1024)
    var mirror = false
    var tileCount = 0 // 0: radial, otherwise 2×2 or 4×4 rectangular repeats.
    var tileCanvas = Point(x: 2048, y: 2048)
    private var tileRadius: Int { max(2, min(4, tileCount)) + 1 }
    var tileSize: Point { tileCanvas * (1 / Double(max(1, tileCount))) }
    var instanceCount: Int {
        tileCount > 0 ? (tileRadius * 2 + 1) * (tileRadius * 2 + 1) : max(1, min(64, repetitions)) * (mirror ? 2 : 1)
    }
    var guideRayCount: Int { tileCount > 0 ? 0 : instanceCount }
    var matrices: [Matrix] {
        if tileCount > 0 {
            let size = tileSize
            return (-tileRadius...tileRadius).flatMap { y in
                (-tileRadius...tileRadius).map { x in Matrix.translation(Point(x: Double(x) * size.x, y: Double(y) * size.y)) }
            }
        }
        let count = max(1, min(64, repetitions))
        return (0..<count).flatMap { i -> [Matrix] in
            let rotation = Matrix.rotation(Double(i) * 2 * Double.pi / Double(count))
            let origin = Matrix.translation(center * -1)
            let end = Matrix.translation(center)
            let normal = origin.followed(by: rotation).followed(by: end)
            guard mirror else { return [normal] }
            // Reflect around the horizontal guide through center, then rotate.
            let reflected = origin.followed(by: Matrix(a: 1, d: -1))
                .followed(by: rotation).followed(by: end)
            return [normal, reflected]
        }
    }
}

extension SymmetryConfiguration {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repetitions = try c.decode(Int.self, forKey: .repetitions)
        center = try c.decode(Point.self, forKey: .center)
        mirror = try c.decodeIfPresent(Bool.self, forKey: .mirror) ?? false
        tileCount = try c.decodeIfPresent(Int.self, forKey: .tileCount) ?? 0
        tileCanvas = try c.decodeIfPresent(Point.self, forKey: .tileCanvas) ?? Point(x: 2048, y: 2048)
    }
}
