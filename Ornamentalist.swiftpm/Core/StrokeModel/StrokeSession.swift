import Foundation

/// Shared input pipeline used by UIKit and input-replay tests. Only confirmed
/// samples mutate this state. Predictions run through a copy of the stabilizer.
struct StrokeSession {
    private(set) var stroke: InkStroke
    private var filtered: StrokeSample?
    private var rawPrevious: StrokeSample?
    private var velocity = Point.zero
    private var smoothPosition: Point?
    private var smoothFollower: Point?
    private let inputScale: Double
    private var traveled = 0.0
    private var stableVertices = 0
    private var stamps: BrushStampState
    private let remainingSamples: Int
    private let remainingVertices: Int
    private var sampleLimitError: DocumentError {
        remainingSamples == DrawingLimits.strokeSamples ? .strokeLimit : .memoryLimit
    }
    private var vertexLimitError: DocumentError {
        remainingVertices == DrawingLimits.strokeVertices ? .strokeLimit : .memoryLimit
    }

    /// Same conservative price as a full replay, accumulated while ingesting
    /// confirmed input so lifting Pencil does not rescan the complete stroke.
    var estimatedVertexCount: Int {
        guard !stroke.samples.isEmpty else { return 0 }
        if stroke.brush.usesStamps { return stableVertices }
        return stableVertices + StrokeGeometry.estimatedTail(samples: stroke.samples, brush: stroke.brush)
    }
    var estimatedStorageCost: Int {
        BrushGeometry.storageCost(vertexCount: estimatedVertexCount, stamped: stroke.brush.usesStamps)
    }

    init(brush: InkBrush, symmetry: SymmetryConfiguration, existingSamples: Int, existingVertices: Int,
         layerID: UUID = DrawingLayer.legacyID, color: InkColor = .black, operation: StrokeOperation = .ink,
         inputScale: Double = 1) {
        stroke = InkStroke(brush: brush, symmetry: symmetry, layerID: layerID, color: color, operation: operation)
        stamps = BrushStampState(id: stroke.seedID)
        self.inputScale = inputScale.isFinite ? max(0.001, inputScale) : 1
        remainingSamples = min(DrawingLimits.strokeSamples, DrawingLimits.sampleCount - existingSamples)
        remainingVertices = min(DrawingLimits.strokeVertices, DrawingLimits.vertexCount - existingVertices)
    }
    private mutating func stabilized(_ sample: StrokeSample, previous: StrokeSample?) -> StrokeSample {
        guard let previous, stroke.brush.stabilizationEnabled, stroke.brush.stabilization > 0 else { return sample }
        let dt = max(0.001, min(0.1, sample.time - previous.time))
        var response = 1.0
        if stroke.brush.adaptiveStabilization {
            // Smooth the velocity vector before measuring its magnitude. Raw
            // zigzag noise must not masquerade as speed or trigger a turn boost.
            // Screen points keep the response consistent when the canvas zooms.
            let measured = (sample.point - (rawPrevious?.point ?? previous.point)) * (inputScale / dt)
            let velocityAlpha = 1 - exp(-dt / 0.025)
            velocity = velocity + (measured - velocity) * velocityAlpha
            // High Steady line settings must retain strong smoothing even
            // during a fast curve, rather than mostly bypassing the control.
            response = 1 + min(2, velocity.length / 400) * (1 - stroke.brush.stabilization * 0.65)
        }
        // A quadratic strength scale makes high settings meaningfully stronger
        // for ordinary hand wobble (a few Hz), not only sample-to-sample noise.
        let duration = 0.012 + stroke.brush.stabilization * stroke.brush.stabilization * 0.22
        let alpha = 1 - exp(-dt * response / duration)
        var result = sample
        // Partial delay compensation preserves deliberate arcs while retaining
        // low-frequency smoothing. Full triple compensation was too eager to
        // follow the very hand wobble Steady line should remove.
        let first = smoothPosition ?? previous.point
        let next = first + (sample.point - first) * alpha
        let follower = smoothFollower ?? previous.point
        let nextFollower = follower + (next - follower) * alpha
        smoothPosition = next; smoothFollower = nextFollower
        result.point = next * 1.5 - nextFollower * 0.5
        if stroke.brush.pressureEnabled {
            let pressureAlpha = 1 - exp(-dt / 0.01)
            result.pressure = previous.pressure + (sample.pressure - previous.pressure) * pressureAlpha
        }
        return result
    }
    mutating func append(_ raw: StrokeSample) throws -> [BrushVertex] {
        guard raw.point.isFinite, raw.time.isFinite, raw.pressure.isFinite,
              raw.altitude.isFinite, raw.azimuth.isFinite else { throw DocumentError.invalidData }
        if let last = filtered, raw.time <= last.time { return [] }
        var sample = stabilized(raw, previous: filtered)
        rawPrevious = raw
        if let last = filtered { traveled += (sample.point - last.point).length }
        if !stroke.brush.usesStamps, stroke.brush.taperStart > 0 {
            sample.radiusScale = min(1, traveled / max(0.01, stroke.brush.width * stroke.brush.taperStart))
        }
        // Retain the first repeated endpoint for midpoint interpolation, but
        // do not spend geometry/sample budgets on a stationary solid Pencil.
        // Keep the filter clock current, so resuming movement has the same dt.
        if !stroke.brush.usesStamps, stroke.samples.count >= 2 {
            let last = stroke.samples[stroke.samples.count - 1]
            let previous = stroke.samples[stroke.samples.count - 2]
            if sample.point == last.point, last.point == previous.point,
               !stroke.brush.pressureEnabled || (sample.pressure == last.pressure && last.pressure == previous.pressure) {
                filtered = sample
                return []
            }
        }
        guard stroke.samples.count < remainingSamples else { throw sampleLimitError }
        if stroke.brush.usesStamps {
            let cost = stamps.stampCount(to: sample, brush: stroke.brush) * BrushStampState.dabsPerStamp(stroke.brush) * 6
            guard (stableVertices + cost) / 3 <= remainingVertices else { throw vertexLimitError }
            let addition = stamps.advance(sample, brush: stroke.brush).flatMap(\.vertices)
            stroke.samples.append(sample); filtered = sample; stableVertices += cost
            return addition
        }
        // Only three samples are needed to price and tessellate the next stable section.
        let recent = Array(stroke.samples.suffix(2)) + [sample]
        let tailReserve = StrokeGeometry.estimatedTail(samples: recent, brush: stroke.brush)
        let cost = StrokeGeometry.estimatedAddition(samples: recent, brush: stroke.brush)
        guard stableVertices + cost + tailReserve <= remainingVertices else { throw vertexLimitError }
        let addition = StrokeGeometry.stableAddition(samples: recent, brush: stroke.brush)
        stroke.samples.append(sample); filtered = sample; stableVertices += cost
        return addition.map { BrushVertex($0) }
    }
    func finishedStroke() -> InkStroke {
        if !stroke.samples.isEmpty, traveled <= 0.0001 {
            var tap = stroke
            for i in tap.samples.indices { tap.samples[i].radiusScale = 1 }
            return tap
        }
        guard !stroke.brush.usesStamps, stroke.brush.taperEnd > 0, stroke.samples.count > 1 else { return stroke }
        var result = stroke, distance = 0.0
        if result.samples.count == 2 { result.samples[0].radiusScale = 1 }
        let length = max(0.01, stroke.brush.width * stroke.brush.taperEnd)
        for i in result.samples.indices.reversed() {
            if i < result.samples.count - 1 {
                distance += (result.samples[i + 1].point - result.samples[i].point).length
            }
            if distance >= length { break }
            result.samples[i].radiusScale = min(result.samples[i].radiusScale, distance / length)
        }
        return result
    }
    func preview(predictions: [StrokeSample]) -> [BrushVertex] {
        var copy = self, vertices: [BrushVertex] = []
        let horizon = (filtered?.time ?? 0) + 1.0 / 60
        for raw in predictions.prefix(12) {
            if stroke.brush.stabilizationEnabled, stroke.brush.stabilization > 0, raw.time > horizon { break }
            guard raw.time.isFinite, raw.time > (copy.filtered?.time ?? -.infinity),
                  raw.point.isFinite, raw.pressure.isFinite,
                  raw.altitude.isFinite, raw.azimuth.isFinite else { continue }
            // Copy only the bounded tail, never the entire accumulated stroke.
            let sample = copy.stabilized(raw, previous: copy.filtered)
            if stroke.brush.usesStamps {
                let cost = copy.stamps.stampCount(to: sample, brush: stroke.brush) * BrushStampState.dabsPerStamp(stroke.brush) * 6
                guard (stableVertices + vertices.count + cost) / 3 <= remainingVertices else { break }
                vertices += copy.stamps.advance(sample, brush: stroke.brush).flatMap(\.vertices)
            } else {
                var at = sample
                if let last = copy.filtered { copy.traveled += (at.point - last.point).length }
                if stroke.brush.taperStart > 0 {
                    at.radiusScale = min(1, copy.traveled / max(0.01, stroke.brush.width * stroke.brush.taperStart))
                }
                let recent = Array(copy.stroke.samples.suffix(2)) + [at]
                let cost = StrokeGeometry.estimatedAddition(samples: recent, brush: stroke.brush)
                let tail = StrokeGeometry.estimatedTail(samples: recent, brush: stroke.brush)
                guard stableVertices + vertices.count + cost + tail <= remainingVertices else { break }
                vertices += StrokeGeometry.stableAddition(samples: recent, brush: stroke.brush).map { BrushVertex($0) }
                copy.stroke.samples = recent
            }
            copy.filtered = sample; copy.rawPrevious = raw
        }
        return vertices + BrushGeometry.tail(copy.stroke)
    }
}
