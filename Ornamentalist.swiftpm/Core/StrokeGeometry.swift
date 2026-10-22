import Foundation

/// Triangles are renderer independent. Quadratic midpoint interpolation is causal:
/// only the uncommitted tail changes when another sample arrives.
enum StrokeGeometry {
    /// Recognize a line, circular arc or nearly closed circle. Other strokes
    /// stay unchanged; input timing and symmetry remain intact.
    static func correctedShape(_ stroke: InkStroke) -> InkStroke? {
        guard stroke.operation == .ink, stroke.samples.count >= 2,
              let first = stroke.samples.first, let last = stroke.samples.last else { return nil }
        let points = stroke.samples.map(\.point)
        let delta = last.point - first.point, span = delta.length
        guard points.allSatisfy(\.isFinite) else { return nil }
        var positions = circularArc(points) ?? []
        if positions.isEmpty, span > 6 {
            let error = points.map { abs(delta.x * ($0.y - first.point.y) - delta.y * ($0.x - first.point.x)) / span }.max() ?? 0
            let length = zip(points, points.dropFirst()).reduce(0.0) { $0 + ($1.1 - $1.0).length }
            if error <= max(3, span * 0.15), length <= span * 1.6 {
                positions = (0...16).map { first.point + delta * (Double($0) / 16) }
            }
        }
        if positions.isEmpty, points.count >= 16 {
            let lowX = points.map(\.x).min()!, highX = points.map(\.x).max()!
            let lowY = points.map(\.y).min()!, highY = points.map(\.y).max()!
            let width = highX - lowX, height = highY - lowY
            let radius = (width + height) * 0.25
            let center = Point(x: (lowX + highX) * 0.5, y: (lowY + highY) * 0.5)
            guard radius > 8, min(width, height) / max(width, height) > 0.8,
                  span < radius * 0.4 else { return nil }
            let radialError = points.reduce(0.0) { $0 + abs(($1 - center).length - radius) } / Double(points.count)
            guard radialError < radius * 0.1 else { return nil }
            let start = atan2(first.point.y - center.y, first.point.x - center.x)
            let winding = zip(points, points.dropFirst()).reduce(0.0) {
                let a = $1.0 - center, b = $1.1 - center
                return $0 + atan2(a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y)
            }
            guard abs(winding) > .pi * 1.7 else { return nil }
            positions = (0...128).map { index in
                let angle = start + (winding < 0 ? -1.0 : 1.0) * Double(index) * 2 * .pi / 128
                return center + Point(x: cos(angle), y: sin(angle)) * radius
            }
        }
        guard !positions.isEmpty else { return nil }
        var result = stroke
        let pressure = stroke.samples.reduce(0.0) { $0 + $1.pressure } / Double(stroke.samples.count)
        result.samples = positions.enumerated().map { index, point in
            var sample = first; sample.point = point; sample.pressure = pressure; sample.radiusScale = 1
            sample.time = first.time + max(0.01, last.time - first.time) * Double(index) / Double(positions.count - 1)
            return sample
        }
        return result
    }

    /// Fit a circle constrained through both endpoints. Equally spaced input
    /// prevents slow Pencil sections or duplicate samples from biasing the fit.
    /// The work is bounded to 65 positions and runs only when the hold fires.
    private static func circularArc(_ points: [Point]) -> [Point]? {
        guard points.count >= 6, let first = points.first, let last = points.last else { return nil }
        let chord = last - first, span = chord.length
        guard span > 6 else { return nil }
        let lengths = zip(points, points.dropFirst()).map { ($0.1 - $0.0).length }
        let length = lengths.reduce(0, +)
        guard length > 10 else { return nil }
        var sampled: [Point] = [], segment = 0, traveled = 0.0
        for index in 0...64 {
            let target = length * Double(index) / 64
            while segment < lengths.count - 1 && traveled + lengths[segment] < target {
                traveled += lengths[segment]; segment += 1
            }
            let t = lengths[segment] > 0.000001 ? max(0, min(1, (target - traveled) / lengths[segment])) : 0
            sampled.append(points[segment] + (points[segment + 1] - points[segment]) * t)
        }
        let midpoint = (first + last) * 0.5
        let normal = Point(x: -chord.y, y: chord.x) * (1 / span)
        var numerator = 0.0, denominator = 0.0, sides: [Double] = []
        for point in sampled {
            let p = point - midpoint, side = p.x * normal.x + p.y * normal.y
            sides.append(side)
            numerator += side * (p.x * p.x + p.y * p.y - span * span * 0.25)
            denominator += 2 * side * side
        }
        guard denominator > 0.000001,
              (sides.map({ abs($0) }).max() ?? 0) > max(3, span * 0.04) else { return nil }
        let direction = sides.reduce(0, +) >= 0 ? 1.0 : -1.0
        guard sides.filter({ $0 * direction < -max(1, span * 0.015) }).count <= 4 else { return nil }
        let offset = numerator / denominator
        let center = midpoint + normal * offset
        let radius = (first - center).length
        guard center.isFinite, radius.isFinite, radius > 6, radius < span * 8 else { return nil }
        let errors = sampled.map { abs(($0 - center).length - radius) }
        let rms = sqrt(errors.reduce(0) { $0 + $1 * $1 } / Double(errors.count))
        guard rms <= max(1, radius * 0.045), (errors.max() ?? 0) <= max(2.5, radius * 0.12) else { return nil }
        var sweep = 0.0, angularTravel = 0.0
        for (a, b) in zip(sampled, sampled.dropFirst()) {
            let u = a - center, v = b - center
            let angle = atan2(u.x * v.y - u.y * v.x, u.x * v.x + u.y * v.y)
            sweep += angle; angularTravel += abs(angle)
        }
        guard abs(sweep) >= 0.45, abs(sweep) < .pi * 1.85,
              angularTravel - abs(sweep) <= max(0.08, abs(sweep) * 0.08) else { return nil }
        let start = atan2(first.y - center.y, first.x - center.x)
        var result = (0...64).map { index in
            let angle = start + sweep * Double(index) / 64
            return center + Point(x: cos(angle), y: sin(angle)) * radius
        }
        result[0] = first; result[64] = last
        return result
    }

    /// Shape adjustment preserves the brush, clipping and symmetry. Only the
    /// confirmed centerline changes; Pencil predictions never enter the shape.
    static func adjustedHeldShape(_ shape: InkStroke, endpoint: Point, verticalDrag: Double) -> InkStroke {
        guard endpoint.isFinite, verticalDrag.isFinite, let first = shape.samples.first,
              let last = shape.samples.last, shape.samples.count > 1 else { return shape }
        var result = shape
        if shape.samples.count > 32 && (first.point - last.point).length < 0.001 {
            let points = shape.samples.dropLast()
            let center = points.reduce(Point.zero) { $0 + $1.point } * (1 / Double(points.count))
            let factor = exp(max(-3, min(3, -verticalDrag / 160)))
            for i in result.samples.indices { result.samples[i].point = center + (shape.samples[i].point - center) * factor }
        } else if shape.samples.count > 32 {
            // Keep an open arc circular when Pencil moves after the hold.
            // Anchor its start and rotate/scale its chord toward the new endpoint.
            let a = last.point - first.point, b = endpoint - first.point
            let square = a.x * a.x + a.y * a.y
            guard square > 0.000001, b.length > 1 else { return shape }
            let c = (a.x * b.x + a.y * b.y) / square
            let s = (a.x * b.y - a.y * b.x) / square
            for i in result.samples.indices {
                let p = shape.samples[i].point - first.point
                result.samples[i].point = first.point + Point(x: c * p.x - s * p.y, y: s * p.x + c * p.y)
            }
        } else {
            for i in result.samples.indices {
                result.samples[i].point = first.point + (endpoint - first.point) * (Double(i) / Double(result.samples.count - 1))
            }
        }
        return result
    }

    /// Constant-distance normal offset. Closed curves retain a shared endpoint.
    static func parallelCopy(_ stroke: InkStroke, distance: Double) -> InkStroke? {
        guard distance.isFinite, abs(distance) >= 1, abs(distance) <= 100,
              stroke.samples.count >= 2, stroke.operation == .ink else { return nil }
        var result = stroke; result.geometrySeed = stroke.seedID; result.id = UUID()
        let points = stroke.samples.map(\.point)
        let closed = points.count > 3 && (points[0] - points[points.count - 1]).length < 0.01
        for index in points.indices {
            let previous = index == 0 ? (closed ? points[points.count - 2] : points[0]) : points[index - 1]
            let next = index == points.count - 1 ? (closed ? points[1] : points[index]) : points[index + 1]
            let tangent = next - previous
            guard tangent.length > 0.00001 else { continue }
            result.samples[index].point = points[index] + Point(x: -tangent.y, y: tangent.x) * (distance / tangent.length)
        }
        return result
    }
    static func disk(_ p: StrokeSample, brush: InkBrush) -> [Point] {
        let r = p.radius(brush: brush)
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
        let ra = n * a.radius(brush: brush), rb = n * b.radius(brush: brush)
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
            next.radiusScale = a.radiusScale*u*u + control.radiusScale*2*u*t + b.radiusScale*t*t
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
            let scale = a.radiusScale*u*u + c.radiusScale*2*u*t + b.radiusScale*t*t
            let radius = brush.radius(pressure: pressure) * scale
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
            join.radiusScale = a.radiusScale*u*u + c.radiusScale*2*u*t + b.radiusScale*t*t
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
