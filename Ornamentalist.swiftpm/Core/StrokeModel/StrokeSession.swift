import Foundation

/// Shared input pipeline used by UIKit and input-replay tests. Only confirmed
/// samples mutate this state. Predictions run through a copy of the stabilizer.
struct StrokeSession {
    private(set) var stroke: InkStroke
    private var filtered: StrokeSample?
    private var stableVertices = 0
    private let remainingSamples: Int
    private let remainingVertices: Int

    init(brush: InkBrush, symmetry: SymmetryConfiguration, existingSamples: Int, existingVertices: Int,
         layerID: UUID = DrawingLayer.legacyID) {
        stroke = InkStroke(brush: brush, symmetry: symmetry, layerID: layerID)
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
    mutating func append(_ raw: StrokeSample) throws -> [Point] {
        guard raw.point.isFinite, raw.time.isFinite, raw.pressure.isFinite else { throw DocumentError.invalidData }
        if let last = stroke.samples.last, raw.time <= last.time { return [] }
        guard stroke.samples.count < remainingSamples else { throw DocumentError.memoryLimit }
        let sample = stabilized(raw, previous: filtered)
        // Only three samples are needed to price and tessellate the next stable section.
        let recent = Array(stroke.samples.suffix(2)) + [sample]
        let addition = StrokeGeometry.stableAddition(samples: recent, brush: stroke.brush)
        let tailReserve = stroke.brush.diskSides * 3 + 6
        let cost = StrokeGeometry.estimatedAddition(samples: recent, brush: stroke.brush)
        guard stableVertices + cost + tailReserve <= remainingVertices else { throw DocumentError.memoryLimit }
        stroke.samples.append(sample); filtered = sample; stableVertices += cost
        return addition
    }
    func preview(predictions: [StrokeSample]) -> [Point] {
        var recent = Array(stroke.samples.suffix(2)), last = filtered, vertices: [Point] = []
        for raw in predictions.prefix(12) {
            guard raw.time > (last?.time ?? -.infinity), raw.point.isFinite else { continue }
            let sample = stabilized(raw, previous: last)
            recent.append(sample)
            vertices += StrokeGeometry.stableAddition(samples: recent, brush: stroke.brush)
            last = sample
        }
        return vertices + StrokeGeometry.tail(samples: recent, brush: stroke.brush)
    }
}
