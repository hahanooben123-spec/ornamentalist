import Foundation

/// Shared input pipeline used by UIKit and input-replay tests. Only confirmed
/// samples mutate this state. Predictions run through a copy of the stabilizer.
struct StrokeSession {
    private(set) var stroke: InkStroke
    private var filtered: StrokeSample?
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
        let alpha = 1 - exp(-dt / (stroke.brush.stabilization * 0.045))
        var result = sample
        result.point = previous.point + (sample.point - previous.point) * alpha
        return result
    }
    mutating func append(_ raw: StrokeSample) throws -> [BrushVertex] {
        guard raw.point.isFinite, raw.time.isFinite, raw.pressure.isFinite else { throw DocumentError.invalidData }
        if let last = filtered, raw.time <= last.time { return [] }
        let sample = stabilized(raw, previous: filtered)
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
    func preview(predictions: [StrokeSample]) -> [BrushVertex] {
        if stroke.brush.usesStamps {
            var state = stamps, last = filtered, vertices: [BrushVertex] = []
            for raw in predictions.prefix(12) {
                guard raw.time.isFinite, raw.time > (last?.time ?? -.infinity), raw.point.isFinite, raw.pressure.isFinite else { continue }
                let sample = stabilized(raw, previous: last)
                let cost = state.stampCount(to: sample, brush: stroke.brush) * BrushStampState.dabsPerStamp(stroke.brush) * 6
                guard stableVertices + vertices.count + cost <= remainingVertices else { break }
                vertices += state.advance(sample, brush: stroke.brush).flatMap(\.vertices)
                last = sample
            }
            return vertices
        }
        var recent = Array(stroke.samples.suffix(2)), last = filtered, vertices: [Point] = []
        for raw in predictions.prefix(12) {
            guard raw.time > (last?.time ?? -.infinity), raw.point.isFinite else { continue }
            let sample = stabilized(raw, previous: last)
            recent.append(sample)
            vertices += StrokeGeometry.stableAddition(samples: recent, brush: stroke.brush)
            last = sample
        }
        return (vertices + StrokeGeometry.tail(samples: recent, brush: stroke.brush)).map { BrushVertex($0) }
    }
}
