import Foundation

/// Four-connected region selection in an RGBA8 reference image. Marks each
/// pixel when queued so a large open region cannot grow an unbounded queue.
enum FillRegion {
    static func mask(rgba: [UInt8], width: Int, height: Int, seeds: [(Int, Int)], tolerance: Int = 24) -> [UInt8] {
        guard width > 0, height > 0, width <= 2048, height <= 2048,
              rgba.count == width * height * 4 else { return [] }
        var selected = [UInt8](repeating: 0, count: width * height)
        for (x, y) in seeds where x >= 0 && y >= 0 && x < width && y < height {
            let start = y * width + x
            guard selected[start] == 0 else { continue }
            let target = Array(rgba[(start * 4)..<(start * 4 + 4)])
            func matches(_ index: Int) -> Bool {
                let offset = index * 4
                return (0..<4).allSatisfy { abs(Int(rgba[offset + $0]) - Int(target[$0])) <= tolerance }
            }
            var queue = [start], head = 0
            selected[start] = 255
            while head < queue.count {
                let pixel = queue[head]; head += 1
                let column = pixel % width
                for next in [column > 0 ? pixel - 1 : -1, column + 1 < width ? pixel + 1 : -1,
                             pixel >= width ? pixel - width : -1, pixel + width < width * height ? pixel + width : -1]
                    where next >= 0 && selected[next] == 0 {
                    if matches(next) { selected[next] = 255; queue.append(next) }
                }
            }
        }
        return selected
    }
}

/// A bounded source-space lasso. Each stroke's symmetry mirrors its clipping
/// region with the ink; old strokes retain their own immutable region.
struct StrokeSelection: Codable, Equatable, Sendable {
    var points: [Point]
    var isValid: Bool { (3...64).contains(points.count) && points.allSatisfy { $0.isFinite && abs($0.x) <= 100_000 && abs($0.y) <= 100_000 } }
    func contains(_ point: Point) -> Bool {
        guard isValid else { return false }
        var inside = false, j = points.count - 1
        for i in points.indices {
            let a = points[i], b = points[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x-a.x) * (point.y-a.y) / (b.y-a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}

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
    static func decomposed(_ matrix: Matrix, size: Point) throws -> RasterPlacement {
        let scale = hypot(matrix.a, matrix.b)
        let value = RasterPlacement(center: matrix.apply(size * 0.5), scale: scale,
            rotation: atan2(matrix.b, matrix.a), flipVertical: matrix.a * matrix.d - matrix.b * matrix.c < 0)
        guard value.isValid else { throw DocumentError.invalidData }
        return value
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
