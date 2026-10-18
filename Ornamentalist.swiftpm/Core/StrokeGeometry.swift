import Foundation

/// Triangles are renderer independent. Quadratic midpoint interpolation is causal:
/// only the uncommitted tail changes when another sample arrives.
enum StrokeGeometry {
    static func disk(_ p: StrokeSample, brush: InkBrush) -> [Point] {
        let r = brush.radius(pressure: p.pressure)
        let sides = brush.diskSides
        var result: [Point] = []
        result.reserveCapacity(sides * 3)
        for i in 0..<sides {
            let a = Double(i) * 2 * .pi / Double(sides)
            let b = Double(i + 1) * 2 * .pi / Double(sides)
            result += [p.point, p.point + Point(x: cos(a), y: sin(a)) * r,
                       p.point + Point(x: cos(b), y: sin(b)) * r]
        }
        return result
    }
    static func segment(_ a: StrokeSample, _ b: StrokeSample, brush: InkBrush) -> [Point] {
        let delta = b.point - a.point
        guard delta.length > 0.0001 else { return disk(b, brush: brush) }
        let n = Point(x: -delta.y, y: delta.x) * (1 / delta.length)
        let ra = n * brush.radius(pressure: a.pressure), rb = n * brush.radius(pressure: b.pressure)
        return [a.point+ra, a.point-ra, b.point+rb, b.point+rb, a.point-ra, b.point-rb] + disk(b, brush: brush)
    }
    static func quadratic(_ a: StrokeSample, _ control: StrokeSample, _ b: StrokeSample,
                          brush: InkBrush) -> [Point] {
        if brush.geometryVersion >= 2 { return ribbon(a, control, b, brush: brush) }
        let steps = subdivisions(a, control, b, brush: brush)
        var previous = a, result: [Point] = []
        for i in 1...steps {
            let t = Double(i)/Double(steps), u = 1-t
            var next = b
            next.point = a.point*(u*u) + control.point*(2*u*t) + b.point*(t*t)
            next.pressure = a.pressure*u*u + control.pressure*2*u*t + b.pressure*t*t
            result += segment(previous, next, brush: brush)
            previous = next
        }
        return result
    }

    // A continuous ribbon shares the position, pressure and tangent at midpoint
    // boundaries. Six vertices per section replace a quad plus an overlapping
    // full disk at every subdivision. Caps are emitted only at stroke ends;
    // a reversal gets one disk to cover the cusp. Version-one ink stays legacy.
    private static func reverses(_ a: StrokeSample, _ c: StrokeSample, _ b: StrokeSample) -> Bool {
        let incoming = c.point - a.point, outgoing = b.point - c.point
        return incoming.x * outgoing.x + incoming.y * outgoing.y < 0
    }
    private static func stationary(_ a: StrokeSample, _ c: StrokeSample, _ b: StrokeSample) -> Bool {
        (c.point - a.point).length + (b.point - c.point).length <= 0.0001
    }
    private static func ribbon(_ a: StrokeSample, _ c: StrokeSample, _ b: StrokeSample,
                               brush: InkBrush) -> [Point] {
        if stationary(a, c, b) { return disk(b, brush: brush) }
        let steps = subdivisions(a, c, b, brush: brush)
        let chord = b.point - a.point
        func edge(_ t: Double) -> (Point, Point) {
            let u = 1 - t
            let center = a.point * (u*u) + c.point * (2*u*t) + b.point * (t*t)
            var tangent = (c.point - a.point) * u + (b.point - c.point) * t
            if tangent.length <= 0.000001 { tangent = chord }
            if tangent.length <= 0.000001 { tangent = c.point - a.point }
            let normal = Point(x: -tangent.y, y: tangent.x) * (1 / max(0.000001, tangent.length))
            let pressure = a.pressure*u*u + c.pressure*2*u*t + b.pressure*t*t
            let radius = brush.radius(pressure: pressure)
            return (center + normal * radius, center - normal * radius)
        }
        var previous = edge(0), result: [Point] = []
        result.reserveCapacity(steps * 6 + (reverses(a, c, b) ? brush.diskSides * 3 : 0))
        for i in 1...steps {
            let next = edge(Double(i) / Double(steps))
            result += [previous.0, previous.1, next.0, next.0, previous.1, next.1]
            previous = next
        }
        if reverses(a, c, b) {
            // At a hairpin the derivative can vanish inside the curve. Put
            // the round join at that actual curve position, not the control.
            let incoming = c.point - a.point
            let change = b.point - c.point - incoming
            let squared = change.x * change.x + change.y * change.y
            let t = max(0, min(1, -(incoming.x * change.x + incoming.y * change.y) / max(0.000001, squared)))
            let u = 1 - t
            var join = b
            join.point = a.point*(u*u) + c.point*(2*u*t) + b.point*(t*t)
            join.pressure = a.pressure*u*u + c.pressure*2*u*t + b.pressure*t*t
            result += disk(join, brush: brush)
        }
        return result
    }
    static func stableAddition(samples: [StrokeSample], brush: InkBrush) -> [Point] {
        guard let last = samples.last else { return [] }
        if samples.count == 1 { return disk(last, brush: brush) }
        let previous = samples[samples.count-2]
        let start = samples.count == 2 ? previous : StrokeSample.midpoint(samples[samples.count-3], previous)
        return quadratic(start, previous, .midpoint(previous, last), brush: brush)
    }
    static func tail(samples: [StrokeSample], brush: InkBrush) -> [Point] {
        guard samples.count >= 2 else { return [] }
        let last = samples[samples.count-1]
        let mid = StrokeSample.midpoint(samples[samples.count-2], last)
        if brush.geometryVersion >= 2 {
            return ribbon(mid, .midpoint(mid, last), last, brush: brush) + disk(last, brush: brush)
        }
        return segment(mid, last, brush: brush)
    }
    static func mesh(_ stroke: InkStroke) -> [Point] {
        var prefix: [StrokeSample] = [], vertices: [Point] = []
        for sample in stroke.samples {
            prefix.append(sample)
            vertices += stableAddition(samples: prefix, brush: stroke.brush)
        }
        return vertices + tail(samples: prefix, brush: stroke.brush)
    }
    private static func subdivisions(_ a: StrokeSample, _ control: StrokeSample, _ b: StrokeSample,
                                     brush: InkBrush) -> Int {
        let length = (control.point-a.point).length + (b.point-control.point).length
        let distanceSteps = Int(ceil(length / max(0.7, brush.width * 0.25)))
        guard brush.geometryVersion >= 2 else { return max(1, min(256, distanceSteps)) }
        // Bound centerline chord error to 0.03 canvas units even with a wide
        // brush. Straight sections retain the existing sampling resolution.
        let bend = (a.point - control.point * 2 + b.point).length
        let curveSteps = Int(ceil(sqrt(bend / 0.12)))
        return max(1, min(256, max(distanceSteps, curveSteps)))
    }
    /// Conservative upper bound computed without allocating triangles.
    static func estimatedAddition(samples: [StrokeSample], brush: InkBrush) -> Int {
        guard let last = samples.last else { return 0 }
        let disk = brush.diskSides * 3
        guard samples.count > 1 else { return disk }
        let previous = samples[samples.count-2]
        let start = samples.count == 2 ? previous : StrokeSample.midpoint(samples[samples.count-3], previous)
        let end = StrokeSample.midpoint(previous, last)
        if brush.geometryVersion >= 2 {
            if stationary(start, previous, end) { return disk }
            return subdivisions(start, previous, end, brush: brush) * 6 + (reverses(start, previous, end) ? disk : 0)
        }
        return subdivisions(start, previous, end, brush: brush) * (6 + disk)
    }
    static func estimatedVertexCount(_ stroke: InkStroke) -> Int {
        if stroke.brush.usesStamps { return BrushGeometry.estimatedVertexCount(stroke) }
        guard !stroke.samples.isEmpty else { return 0 }
        let disk = stroke.brush.diskSides * 3
        var count = disk
        for i in 1..<stroke.samples.count {
            count += estimatedAddition(samples: Array(stroke.samples[max(0, i-2)...i]), brush: stroke.brush)
        }
        return count + (stroke.samples.count > 1 ? estimatedTail(samples: stroke.samples, brush: stroke.brush) : 0)
    }

    static func estimatedTail(samples: [StrokeSample], brush: InkBrush) -> Int {
        guard samples.count >= 2 else { return 0 }
        if brush.geometryVersion < 2 { return 6 + brush.diskSides * 3 }
        let last = samples[samples.count - 1]
        let mid = StrokeSample.midpoint(samples[samples.count - 2], last)
        if (last.point - mid.point).length <= 0.0001 { return brush.diskSides * 6 }
        return subdivisions(mid, .midpoint(mid, last), last, brush: brush) * 6 + brush.diskSides * 3
    }
}
