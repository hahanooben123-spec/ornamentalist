import UIKit

/// Exports document-space triangles through Core Graphics. No viewport, guides,
/// prediction, UI chrome, or screenshot is involved. 2048 square in Phase 1.
enum PNGExporter {
    static func data(document: DrawingDocument, transparent: Bool, maximumSide: Double? = nil) throws -> Data {
        try document.validate()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // Exact pixel dimensions, independent of the iPad screen scale.
        format.opaque = !transparent
        let scale = maximumSide.map { min(1, $0 / max(document.size.x, document.size.y)) } ?? 1
        let size = CGSize(width: document.size.x * scale, height: document.size.y * scale)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { output in
            let context = output.cgContext
            if !transparent {
                context.setFillColor(UIColor.white.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
            }
            context.scaleBy(x: scale, y: scale)
            context.clip(to: CGRect(x: 0, y: 0, width: document.size.x, height: document.size.y))
            context.setFillColor(UIColor.black.cgColor)
            for stroke in document.strokes {
                let vertices = StrokeGeometry.mesh(stroke)
                // One union-style nonzero fill per transformed stroke avoids seams
                // between adjacent tessellation triangles in Core Graphics.
                for matrix in stroke.symmetry.matrices {
                    let path = CGMutablePath()
                    for i in stride(from: 0, to: vertices.count, by: 3) {
                        let a = matrix.apply(vertices[i]), b = matrix.apply(vertices[i+1]), c = matrix.apply(vertices[i+2])
                        path.move(to: CGPoint(x: a.x, y: a.y))
                        path.addLine(to: CGPoint(x: b.x, y: b.y))
                        path.addLine(to: CGPoint(x: c.x, y: c.y))
                        path.closeSubpath()
                    }
                    context.addPath(path); context.fillPath()
                }
            }
        }
        guard let data = image.pngData() else { throw DocumentError.graphics }
        return data
    }
}

actor ExportService {
    func thumbnail(_ document: DrawingDocument) throws -> Data {
        try Task.checkCancellation()
        let data = try PNGExporter.data(document: document, transparent: false, maximumSide: 512)
        try Task.checkCancellation()
        return data
    }
    func png(_ document: DrawingDocument, transparent: Bool) throws -> URL {
        let data = try PNGExporter.data(document: document, transparent: transparent)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OrnamentalistExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Fixed name per project avoids accumulating temporary files every export.
        let url = directory.appendingPathComponent("Ornamentalist-\(document.id.uuidString).png")
        try data.write(to: url, options: .atomic)
        return url
    }
}
