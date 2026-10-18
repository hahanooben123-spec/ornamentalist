import Foundation

enum DrawingLimits {
    static let encodedBytes = 128 * 1024 * 1024
    static let sampleCount = 400_000
    static let strokeSamples = 80_000
    // Storage units of 16 bytes, not expanded triangle vertices. A compact
    // stamped dab uses two units, versus six for its expanded triangles.
    static let vertexCount = 4_000_000 // Historical diagnostic baseline; not a document limit.
    static let strokeVertices = 500_000
}

/// Uses a fixed deadline as well as an idle deadline. Continuous dotting cannot
/// postpone persistence indefinitely. Time is injected for deterministic tests.
struct SaveSchedule {
    private(set) var firstDirty: Double?
    private(set) var lastEdit: Double?
    var deadline: Double? {
        guard let firstDirty, let lastEdit else { return nil }
        return min(firstDirty + 2, lastEdit + 0.5)
    }
    mutating func edited(at time: Double) {
        if firstDirty == nil { firstDirty = time }
        lastEdit = time
    }
    func isDue(at time: Double) -> Bool {
        guard let deadline else { return false }
        return time >= deadline
    }
    mutating func saved() { firstDirty = nil; lastEdit = nil }
}
