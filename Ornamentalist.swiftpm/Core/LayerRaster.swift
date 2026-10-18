import Foundation

/// A merge bakes the two isolated layers into one transparent, document-sized
/// base. Later source strokes and erasers remain editable above that base.
struct LayerRaster: Codable, Equatable, Sendable {
    var id = UUID()
    var png: Data
    var width: Int
    var height: Int
    static let maximumPixels = 2048 * 2048
    static let documentPixels = maximumPixels * 4
    static let documentBytes = 24 * 1024 * 1024
    func validate(canvas: Point) throws {
        let header: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard png.count >= 33, png.count <= 16 * 1024 * 1024,
              Array(png.prefix(8)) == header,
              Array(png[12..<16]) == [73, 72, 68, 82],
              width >= 64, height >= 64, width <= 2048, height <= 2048,
              width * height <= Self.maximumPixels,
              Double(width) == canvas.x, Double(height) == canvas.y else { throw DocumentError.invalidData }
        func integer(_ start: Int) -> Int {
            png[start..<(start + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        guard integer(16) == width, integer(20) == height else { throw DocumentError.invalidData }
    }
}
