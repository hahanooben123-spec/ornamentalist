import Foundation

/// Shared input pipeline used by UIKit and input-replay tests. Only confirmed
/// samples mutate this state. Predictions run through a copy of the stabilizer.
struct StrokeSession {
    private(set) var stroke: InkStroke
    private var filtered: StrokeSample?
    private var rawPrevious: StrokeSample?
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

    init(brush: InkBrush, symmetry: SymmetryConfiguration, existingSamples: Int, existingVertices: Int,
         layerID: UUID = DrawingLayer.legacyID, color: InkColor = .black, operation: StrokeOperation = .ink) {
        stroke = InkStroke(brush: brush, symmetry: symmetry, layerID: layerID, color: color, operation: operation)
        stamps = BrushStampState(id: stroke.seedID)
        remainingSamples = min(DrawingLimits.strokeSamples, DrawingLimits.sampleCount - existingSamples)
        remainingVertices = min(DrawingLimits.strokeVertices, DrawingLimits.vertexCount - existingVertices)
    }
    private func stabilized(_ sample: StrokeSample, previous: StrokeSample?) -> StrokeSample {
        guard let previous, stroke.brush.stabilization > 0 else { return sample }
        let dt = max(0.001, min(0.1, sample.time - previous.time))
        var response = 1.0
        if stroke.brush.adaptiveStabilization {
            let delta = sample.point - (rawPrevious?.point ?? previous.point)
            let speed = delta.length / dt
            let prior = (rawPrevious?.point ?? previous.point) - previous.point
            let alignment = (delta.x * prior.x + delta.y * prior.y) / max(0.000001, delta.length * prior.length)
            response = 1 + min(6, speed / 180) + (alignment < 0.3 ? 3 : 0)
        }
        let alpha = 1 - exp(-dt * response / (stroke.brush.stabilization * 0.045))
        var result = sample
        result.point = previous.point + (sample.point - previous.point) * alpha
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
            guard stableVertices + cost <= remainingVertices else { throw vertexLimitError }
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
        for raw in predictions.prefix(12) {
            guard raw.time.isFinite, raw.time > (copy.filtered?.time ?? -.infinity),
                  raw.point.isFinite, raw.pressure.isFinite,
                  raw.altitude.isFinite, raw.azimuth.isFinite else { continue }
            // Copy only the bounded tail, never the entire accumulated stroke.
            let sample = copy.stabilized(raw, previous: copy.filtered)
            if stroke.brush.usesStamps {
                let cost = copy.stamps.stampCount(to: sample, brush: stroke.brush) * BrushStampState.dabsPerStamp(stroke.brush) * 6
                guard stableVertices + vertices.count + cost <= remainingVertices else { break }
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
