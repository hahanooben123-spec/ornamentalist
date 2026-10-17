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
        return max(1, min(256, Int(ceil(length / max(0.7, brush.width * 0.25)))))
    }
    /// Conservative upper bound computed without allocating triangles.
    static func estimatedAddition(samples: [StrokeSample], brush: InkBrush) -> Int {
        guard let last = samples.last else { return 0 }
        let disk = brush.diskSides * 3
        guard samples.count > 1 else { return disk }
        let previous = samples[samples.count-2]
        let start = samples.count == 2 ? previous : StrokeSample.midpoint(samples[samples.count-3], previous)
        return subdivisions(start, previous, .midpoint(previous, last), brush: brush) * (6 + disk)
    }
    static func estimatedVertexCount(_ stroke: InkStroke) -> Int {
        guard !stroke.samples.isEmpty else { return 0 }
        let disk = stroke.brush.diskSides * 3
        var count = disk
        for i in 1..<stroke.samples.count {
            count += estimatedAddition(samples: Array(stroke.samples[max(0, i-2)...i]), brush: stroke.brush)
        }
        return count + (stroke.samples.count > 1 ? 6 + disk : 0)
    }
}
