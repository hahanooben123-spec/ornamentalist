import Foundation

enum DrawingLimits {
    static let encodedBytes = 64 * 1024 * 1024
    static let sampleCount = 100_000
    static let strokeSamples = 20_000
    // Storage units of 16 bytes, not expanded triangle vertices. A compact
    // stamped dab uses two units, versus six for its expanded triangles.
    static let vertexCount = 2_000_000 // 32 MB, excluding render targets.
    static let strokeVertices = 250_000
}

/// Uses a fixed deadline as well as an idle deadline. Continuous dotting cannot
/// postpone persistence indefinitely. Time is injected for deterministic tests.
struct SaveSchedule {
    private(set) var firstDirty: Double?
    private(set) var lastEdit: Double?
    mutating func edited(at time: Double) {
        if firstDirty == nil { firstDirty = time }
        lastEdit = time
    }
    func isDue(at time: Double) -> Bool {
        guard let firstDirty, let lastEdit else { return false }
        return time - lastEdit >= 0.5 || time - firstDirty >= 2
    }
    mutating func saved() { firstDirty = nil; lastEdit = nil }
}
