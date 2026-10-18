import Foundation

struct SymmetryConfiguration: Codable, Hashable, Sendable {
    var repetitions = 8 // 1 is symmetry off.
    var center = Point(x: 1024, y: 1024)
    var mirror = false
    var instanceCount: Int { max(1, min(64, repetitions)) * (mirror ? 2 : 1) }
    var guideRayCount: Int { instanceCount }
    var matrices: [Matrix] {
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
    }
}
