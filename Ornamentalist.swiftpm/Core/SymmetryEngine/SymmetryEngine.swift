#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

struct SymmetryConfiguration: Codable, Hashable, Sendable {
    var repetitions = 8 // 1 is symmetry off.
    var center = Point(x: 1024, y: 1024)
    var mirror = false
    var tileCount = 0 // 0: radial, otherwise 2×2 or 4×4 rectangular repeats.
    var tileSymmetry = false // Version 19 opts in; old tile strokes retain translation-only rendering.
    var tileRepetitions = 1
    var tileCanvas = Point(x: 2048, y: 2048)
    private var tileRadius: Int { max(2, min(4, tileCount)) + 1 }
    var tileSize: Point { tileCanvas * (1 / Double(max(1, tileCount))) }
    var instanceCount: Int {
        if tileCount > 0 {
            return tileSymmetry ? tileCount * tileCount * max(1, min(8, tileRepetitions)) * (mirror ? 2 : 1)
                : (tileRadius * 2 + 1) * (tileRadius * 2 + 1)
        }
        return max(1, min(64, repetitions)) * (mirror ? 2 : 1)
    }
    var guideRayCount: Int { tileCount > 0 ? 0 : instanceCount }
    var matrices: [Matrix] {
        if tileCount > 0 {
            if tileSymmetry { return matrices(for: CGRect(x: 0, y: 0, width: tileCanvas.x, height: tileCanvas.y)) }
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
    /// Only translations whose transformed source bounds can reach the target.
    /// A small stroke in a 4x4 pattern normally needs 16 copies per orientation,
    /// instead of submitting the complete 121-copy legacy grid to the GPU.
    func matrices(for source: CGRect, clip: CGRect? = nil) -> [Matrix] {
        guard tileCount > 0, tileSymmetry else { return matrices }
        guard !source.isNull, source.minX.isFinite, source.minY.isFinite,
              source.maxX.isFinite, source.maxY.isFinite else { return [] }
        let target = clip ?? CGRect(x: 0, y: 0, width: tileCanvas.x, height: tileCanvas.y)
        guard !target.isNull, !target.isEmpty else { return [] }
        let size = tileSize
        let copies = max(1, min(8, tileRepetitions))
        var result: [Matrix] = []
        for index in 0..<copies {
            let rotation = Matrix.rotation(Double(index) * 2 * .pi / Double(copies))
            for reflected in mirror ? [false, true] : [false] {
                let orientation = Matrix.translation(center * -1)
                    .followed(by: Matrix(a: 1, d: reflected ? -1 : 1))
                    .followed(by: rotation).followed(by: .translation(center))
                let bounds = Self.bounds(source, transformedBy: orientation)
                var lowX = Int(ceil((Double(target.minX) - Double(bounds.maxX)) / size.x))
                var highX = Int(floor((Double(target.maxX) - Double(bounds.minX)) / size.x))
                var lowY = Int(ceil((Double(target.minY) - Double(bounds.maxY)) / size.y))
                var highY = Int(floor((Double(target.maxY) - Double(bounds.minY)) / size.y))
                guard lowX <= highX, lowY <= highY else { continue }
                // Keep pathological off-paper input bounded like the legacy grid.
                if highX - lowX > tileCount * 2 + 4 { lowX = -tileRadius; highX = tileRadius }
                if highY - lowY > tileCount * 2 + 4 { lowY = -tileRadius; highY = tileRadius }
                for y in lowY...highY {
                    for x in lowX...highX {
                        result.append(orientation.followed(by: .translation(Point(x: Double(x) * size.x, y: Double(y) * size.y))))
                    }
                }
            }
        }
        return result
    }
    /// Conservative bounds retain every copy which could touch the view.
    /// Filtering keeps original copy order, including translucent overlaps.
    func visibleMatrices(for source: CGRect, clip: CGRect) -> [Matrix] {
        guard !source.isNull, !clip.isNull, !clip.isEmpty else { return [] }
        return matrices(for: source, clip: clip).filter {
            Self.bounds(source, transformedBy: $0).intersects(clip)
        }
    }
    static func bounds(of points: [Point], padding: Double = 0) -> CGRect {
        guard let first = points.first else { return .null }
        var lowX = first.x, highX = first.x, lowY = first.y, highY = first.y
        for point in points.dropFirst() {
            lowX = min(lowX, point.x); highX = max(highX, point.x)
            lowY = min(lowY, point.y); highY = max(highY, point.y)
        }
        return CGRect(x: lowX - padding, y: lowY - padding, width: highX - lowX + padding * 2, height: highY - lowY + padding * 2)
    }
    static func bounds(_ rect: CGRect, transformedBy matrix: Matrix) -> CGRect {
        guard !rect.isNull else { return .null }
        let points = [Point(x: Double(rect.minX), y: Double(rect.minY)), Point(x: Double(rect.maxX), y: Double(rect.minY)),
                      Point(x: Double(rect.maxX), y: Double(rect.maxY)), Point(x: Double(rect.minX), y: Double(rect.maxY))].map { matrix.apply($0) }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

}

extension SymmetryConfiguration {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repetitions = try c.decode(Int.self, forKey: .repetitions)
        center = try c.decode(Point.self, forKey: .center)
        mirror = try c.decodeIfPresent(Bool.self, forKey: .mirror) ?? false
        tileCount = try c.decodeIfPresent(Int.self, forKey: .tileCount) ?? 0
        tileSymmetry = try c.decodeIfPresent(Bool.self, forKey: .tileSymmetry) ?? false
        tileRepetitions = try c.decodeIfPresent(Int.self, forKey: .tileRepetitions) ?? 1
        tileCanvas = try c.decodeIfPresent(Point.self, forKey: .tileCanvas) ?? Point(x: 2048, y: 2048)
    }
}
