#if DEBUG
import Foundation

/// Original procedural drawings for isolated simulator UI tests only.
enum StudioShowcase {
    static func seed(repository: DocumentRepository) async throws {
        let exporter = ExportService()
        for variant in 0..<3 {
            var document = DrawingDocument()
            document.title = ["Solstice", "Quiet orbit", "Petal study"][variant]
            document.modified = Date(timeIntervalSince1970: 1_792_281_600 - Double(variant * 86_400))
            let count = [12, 16, 8][variant]
            document.symmetry.repetitions = count
            let wedge = 2 * Double.pi / Double(count)
            func stroke(_ points: [Point], width: Double = 3) -> InkStroke {
                var ink = InkStroke()
                ink.brush.width = width
                ink.symmetry.repetitions = count
                ink.samples = points.enumerated().map {
                    StrokeSample(point: $0.element, pressure: 0.6, altitude: 1, azimuth: 0, time: Double($0.offset) / 120)
                }
                return ink
            }
            func polar(_ radius: Double, _ angle: Double) -> Point {
                Point(x: 1024 + cos(angle) * radius, y: 1024 + sin(angle) * radius)
            }
            // Nested pointed petals, with two fine contour lines per ring.
            for ring in 0..<5 {
                let inner = 65.0 + Double(ring) * 130
                let outer = inner + 215
                for inset in [0.0, 16.0] {
                    let points = (0...160).map { index -> Point in
                        let t = Double(index) / 160
                        let radius = inner + (outer - inner - inset) * pow(sin(.pi * t), 0.85)
                        return polar(radius, wedge * (t - 0.5) + (ring.isMultiple(of: 2) ? 0 : wedge / 2))
                    }
                    document.strokes.append(stroke(points, width: ring == 4 ? 4 : 3))
                }
            }
            for radius in [48.0, 61, 766, 782, 810] {
                let points = (0...32).map { polar(radius, wedge * Double($0) / 32) }
                document.strokes.append(stroke(points, width: 2.5))
            }
            for radius in [320.0, 580, 842] {
                let points = (0...28).map { index -> Point in
                    let t = Double(index) * 2 * .pi / 28
                    return Point(x: 1024 + radius + cos(t) * 10, y: 1024 + sin(t) * 10)
                }
                document.strokes.append(stroke(points, width: 3))
            }
            try document.validate()
            try await repository.save(document, generation: 1)
            let preview = try await exporter.thumbnail(document)
            try await repository.storeThumbnail(preview, id: document.id, generation: 1)
        }
    }
}
#endif
