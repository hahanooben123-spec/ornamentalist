import Foundation

struct SymmetryConfiguration: Codable, Hashable, Sendable {
    var repetitions = 8 // 1 is symmetry off.
    var center = Point(x: 1024, y: 1024)
    var matrices: [Matrix] {
        (0..<max(1, min(64, repetitions))).map { i in
            Matrix.translation(center * -1)
                .followed(by: .rotation(Double(i) * 2 * .pi / Double(max(1, repetitions))))
                .followed(by: .translation(center))
        }
    }
}
