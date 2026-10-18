import Foundation

struct RasterPlacement: Codable, Equatable, Hashable, Sendable {
    var center: Point
    var scale = 1.0
    var rotation = 0.0
    var flipHorizontal = false
    var flipVertical = false
    var isValid: Bool {
        center.isFinite && abs(center.x) <= 100_000 && abs(center.y) <= 100_000 &&
        scale.isFinite && (0.01...64).contains(scale) && rotation.isFinite && abs(rotation) <= .pi * 2
    }
    func matrix(size: Point) -> Matrix {
        Matrix.translation(size * -0.5)
            .followed(by: Matrix(a: flipHorizontal ? -scale : scale, d: flipVertical ? -scale : scale))
            .followed(by: .rotation(rotation)).followed(by: .translation(center))
    }
}

/// A merge bakes the two isolated layers into one transparent, document-sized
/// base. Later source strokes and erasers remain editable above that base.
struct LayerRaster: Codable, Equatable, Sendable {
    var id = UUID()
    var png: Data
    var width: Int
    var height: Int
    var placement: RasterPlacement?
    func matrix(canvas: Point) -> Matrix {
        placement?.matrix(size: Point(x: Double(width), y: Double(height))) ?? .init(a: canvas.x / Double(width), d: canvas.y / Double(height))
    }
    func corners(canvas: Point) -> [Point] {
        let transform = matrix(canvas: canvas)
        return [Point.zero, Point(x: Double(width), y: 0), Point(x: Double(width), y: Double(height)), Point(x: 0, y: Double(height))].map { transform.apply($0) }
    }
    static let maximumPixels = 2048 * 2048
    static let documentPixels = maximumPixels * 4
    static let documentBytes = 24 * 1024 * 1024
    func validate(canvas: Point) throws {
        let header: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard png.count >= 33, png.count <= 16 * 1024 * 1024,
              Array(png.prefix(8)) == header,
              Array(png[12..<16]) == [73, 72, 68, 82],
              width >= (placement == nil ? 64 : 1), height >= (placement == nil ? 64 : 1), width <= 2048, height <= 2048,
              width * height <= Self.maximumPixels,
              placement?.isValid ?? (Double(width) == canvas.x && Double(height) == canvas.y) else { throw DocumentError.invalidData }
        func integer(_ start: Int) -> Int {
            png[start..<(start + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        guard integer(16) == width, integer(20) == height else { throw DocumentError.invalidData }
    }
}
