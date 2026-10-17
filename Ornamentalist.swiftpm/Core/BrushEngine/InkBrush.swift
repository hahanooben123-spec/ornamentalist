import Foundation

struct InkBrush: Codable, Equatable, Sendable {
    var width = 5.0
    var pressureEnabled = false
    var stabilization = 0.25
    var geometryVersion = 2
    func radius(pressure: Double) -> Double {
        guard pressureEnabled else { return width * 0.5 }
        return width * (0.2 + 0.8 * sqrt(max(0, min(1, pressure)))) * 0.5
    }
    var diskSides: Int {
        guard geometryVersion >= 2 else { return 12 }
        // Sagitta <= 0.03 canvas units, capped to keep geometry bounded.
        let angle = acos(max(-1, min(1, 1 - 0.03 / max(0.25, width * 0.5))))
        return max(12, min(64, Int(ceil(.pi / angle))))
    }
}

extension InkBrush {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Double.self, forKey: .width)
        pressureEnabled = try c.decodeIfPresent(Bool.self, forKey: .pressureEnabled) ?? true
        stabilization = try c.decodeIfPresent(Double.self, forKey: .stabilization) ?? 0
        geometryVersion = try c.decodeIfPresent(Int.self, forKey: .geometryVersion) ?? 1
    }
}
