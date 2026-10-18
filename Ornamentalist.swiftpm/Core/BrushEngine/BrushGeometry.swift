import Foundation

/// Float4 on the GPU: document position and local stamp coordinates. Old ink
/// uses (0, 0) locally, so it retains the original triangle tessellation.
struct BrushVertex: Equatable, Sendable {
    var point: Point
    var local = Point.zero
    var opacity = 1.0
    init(_ point: Point, local: Point = .zero, opacity: Double = 1) {
        self.point = point; self.local = local; self.opacity = opacity
    }
}

struct BrushDab: Equatable, Sendable {
    var center: Point
    var radius: Double
    var aspect = 1.0
    var angle = 0.0
    var opacity = 1.0
    func point(_ local: Point) -> Point {
        center + Matrix.rotation(angle).apply(Point(x: local.x * radius, y: local.y * radius * aspect))
    }
    var vertices: [BrushVertex] {
        let a = Point(x: -1, y: -1), b = Point(x: 1, y: -1)
        let c = Point(x: 1, y: 1), d = Point(x: -1, y: 1)
        return [a, b, c, a, c, d].map { BrushVertex(point($0), local: $0, opacity: opacity) }
    }
}

/// Fixed arc-length spacing and indexed randomness: batching, predictions,
/// reopening, Mirror and export produce the same dots. No frame/time RNG.
struct BrushStampState: Sendable {
    private var previous: StrokeSample?
    private var distanceToNext = 0.0
    private var index: UInt64 = 0
    private var traveled = 0.0
    private let seed: UInt64
    init(id: UUID) {
        seed = id.uuidString.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
    private func random(_ ordinal: UInt64, _ channel: UInt64) -> Double {
        var x = seed &+ ordinal &* 0x9e3779b97f4a7c15 &+ channel &* 0xbf58476d1ce4e5b9
        x = (x ^ (x >> 30)) &* 0xbf58476d1ce4e5b9
        x = (x ^ (x >> 27)) &* 0x94d049bb133111eb
        return Double((x ^ (x >> 31)) >> 11) / 9007199254740992.0
    }
    static func dabsPerStamp(_ brush: InkBrush) -> Int {
        brush.preset.scattered ? max(1, Int((brush.density * 20).rounded())) : 1
    }
    private func dabs(_ sample: StrokeSample, brush: InkBrush, ordinal: UInt64, distance: Double) -> [BrushDab] {
        let radius = brush.radius(pressure: sample.pressure)
        let tilt = brush.tiltShading * max(0, min(1, 1 - sample.altitude / (.pi / 2)))
        let spreadScale = 1 + tilt * 0.8
        let tiltAngle = sample.azimuth
        if !brush.preset.scattered {
            return [BrushDab(center: sample.point, radius: radius * spreadScale,
                             aspect: (brush.preset == .flatMarker ? 0.28 : 1) / (spreadScale * spreadScale),
                             angle: tilt > 0 ? tiltAngle : (brush.preset == .flatMarker ? -.pi / 4 : 0),
                             opacity: brush.falloffOpacity(distance: distance))]
        }
        return (0..<Self.dabsPerStamp(brush)).map { dot in
            let key = ordinal &* 32 &+ UInt64(dot)
            let angle = random(key, 1) * 2 * Double.pi
            let u = random(key, 2)
            // Center-weighted dots for a feathered stipple shadow.
            let spread = brush.preset == .dotShader ? u * u : sqrt(u)
            let offset = Point(x: cos(angle) * spreadScale, y: sin(angle) / spreadScale) * (radius * spread)
            let center = sample.point + (tilt > 0 ? Matrix.rotation(tiltAngle).apply(offset) : offset)
            let base: Double
            switch brush.preset {
            case .graphite: base = 0.035
            case .charcoal: base = 0.13
            case .hatching: base = 0.25
            default: base = 0.045
            }
            return BrushDab(center: center, radius: max(0.28, radius * base * (0.65 + random(key, 3) * 0.7)),
                            aspect: brush.preset == .hatching ? 0.12 : 1,
                            angle: brush.preset == .hatching ? -.pi / 4 : 0,
                            opacity: brush.falloffOpacity(distance: distance))
        }
    }
    /// Price before allocating. A malformed long jump cannot allocate an
    /// unbounded mesh on the touch thread or during document validation.
    func stampCount(to sample: StrokeSample, brush: InkBrush) -> Int {
        guard let previous else { return 1 }
        guard traveled < brush.falloffLength else { return 0 }
        let length = min((sample.point - previous.point).length, brush.falloffLength - traveled)
        guard length > 0.000001, length + 0.000001 >= distanceToNext else { return 0 }
        let count = floor((length + 0.000001 - distanceToNext) / max(0.25, brush.width * brush.spacing)) + 1
        return Int(min(Double(DrawingLimits.strokeVertices), max(0, count)))
    }
    mutating func advance(_ sample: StrokeSample, brush: InkBrush, emit: Bool = true) -> [BrushDab] {
        let count = stampCount(to: sample, brush: brush)
        let step = max(0.25, brush.width * brush.spacing)
        var result: [BrushDab] = []
        if let previous {
            let delta = sample.point - previous.point, length = delta.length
            if length > 0.000001 {
                for i in 0..<count {
                    let t = min(1, (distanceToNext + Double(i) * step) / length)
                    var at = sample
                    at.point = previous.point + delta * t
                    at.pressure = previous.pressure + (sample.pressure - previous.pressure) * t
                    at.altitude = previous.altitude + (sample.altitude - previous.altitude) * t
                    let turn = atan2(sin(sample.azimuth - previous.azimuth), cos(sample.azimuth - previous.azimuth))
                    at.azimuth = previous.azimuth + turn * t
                    if emit { result += dabs(at, brush: brush, ordinal: index,
                                            distance: traveled + distanceToNext + Double(i) * step) }
                    index &+= 1
                }
                distanceToNext = max(0, distanceToNext + Double(count) * step - length)
                traveled += length
            }
        } else {
            if emit { result = dabs(sample, brush: brush, ordinal: index, distance: 0) }
            index &+= 1; distanceToNext = step
        }
        self.previous = sample
        return result
    }
}

enum BrushGeometry {
    static func dabs(_ stroke: InkStroke) -> [BrushDab] {
        var state = BrushStampState(id: stroke.seedID)
        return stroke.samples.flatMap { state.advance($0, brush: stroke.brush) }
    }
    static func mesh(_ stroke: InkStroke) -> [BrushVertex] {
        if stroke.brush.usesStamps { return dabs(stroke).flatMap(\.vertices) }
        return StrokeGeometry.mesh(stroke).map { BrushVertex($0) }
    }
    static func estimatedVertexCount(_ stroke: InkStroke) -> Int {
        var state = BrushStampState(id: stroke.seedID), count = 0
        for sample in stroke.samples {
            count += state.stampCount(to: sample, brush: stroke.brush) * BrushStampState.dabsPerStamp(stroke.brush) * 6
            if count / 3 > DrawingLimits.strokeVertices { return count }
            _ = state.advance(sample, brush: stroke.brush, emit: false)
        }
        return count
    }
    /// Budget units are 16 bytes. Six expanded stamp vertices (96 bytes)
    /// become four Float2 corners (32 bytes); shape coordinates are implicit.
    static func storageCost(vertexCount: Int, stamped: Bool) -> Int {
        stamped ? vertexCount / 3 : vertexCount
    }
    static func estimatedStorageCost(_ stroke: InkStroke) -> Int {
        storageCost(vertexCount: StrokeGeometry.estimatedVertexCount(stroke), stamped: stroke.brush.usesStamps)
    }
    static func tail(_ stroke: InkStroke) -> [BrushVertex] {
        stroke.brush.usesStamps ? [] : StrokeGeometry.tail(samples: stroke.samples, brush: stroke.brush).map { BrushVertex($0) }
    }
    static func coverage(radius: Double, softness: Double) -> Double {
        guard radius <= 1 else { return 0 }
        guard softness > 0 else { return 1 }
        let t = max(0, min(1, (radius - (1 - softness)) / softness))
        return 1 - t * t * (3 - 2 * t)
    }
}
