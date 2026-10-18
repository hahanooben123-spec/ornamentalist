import UIKit
import ImageIO

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
        var failure: Error?
        let image = renderer.image { output in
            let context = output.cgContext
            if !transparent {
                context.setFillColor(UIColor.white.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
            }
            context.scaleBy(x: scale, y: scale)
            context.clip(to: CGRect(x: 0, y: 0, width: document.size.x, height: document.size.y))
            context.setFillColor(UIColor.black.cgColor)
            do { try paintDocument(document, in: context) } catch { failure = error }

        }
        if let failure { throw failure }
        guard let data = image.pngData() else { throw DocumentError.graphics }
        return data
    }
    static func rasterImage(_ raster: LayerRaster) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(raster.png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == raster.width, image.height == raster.height else { throw DocumentError.invalidData }
        return image
    }
    static func paintDocument(_ document: DrawingDocument, in context: CGContext) throws {
        let grouped = Dictionary(grouping: document.strokes, by: \.layerID)
        for layer in document.layers where layer.isVisible && layer.opacity > 0 {
            context.saveGState()
            context.setAlpha(CGFloat(layer.opacity))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            if let raster = layer.raster {
                do {
                    let image = try rasterImage(raster)
                    context.saveGState()
                    context.translateBy(x: 0, y: document.size.y); context.scaleBy(x: 1, y: -1)
                    context.draw(image, in: CGRect(x: 0, y: 0, width: document.size.x, height: document.size.y))
                    context.restoreGState()
                } catch {
                    context.endTransparencyLayer(); context.restoreGState(); throw error
                }
            }
            for stroke in grouped[layer.id] ?? [] { paint(stroke, in: context) }
            context.endTransparencyLayer(); context.restoreGState()
        }
    }
    static func sample(document: DrawingDocument, point: Point) throws -> InkColor {
        try document.validate()
        guard point.isFinite, (0..<document.size.x).contains(point.x), (0..<document.size.y).contains(point.y) else { throw DocumentError.invalidData }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        var failure: Error?
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { output in
            let context = output.cgContext
            context.setFillColor(UIColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            context.translateBy(x: -floor(point.x), y: -floor(point.y))
            do { try paintDocument(document, in: context) } catch { failure = error }
        }
        if let failure { throw failure }
        guard let cgImage = image.cgImage else { throw DocumentError.graphics }
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw DocumentError.graphics }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return InkColor(red: Double(bytes[0]) / 255, green: Double(bytes[1]) / 255, blue: Double(bytes[2]) / 255)
    }
    static func paint(_ stroke: InkStroke, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        if stroke.operation == .erase { context.setBlendMode(.destinationOut) }
        let ink = stroke.color
        if stroke.brush.usesStamps {
            let locations: [CGFloat] = (0...32).map { CGFloat($0) / 32 }
            let colors = locations.map { radius in
                UIColor(red: ink.red, green: ink.green, blue: ink.blue,
                        alpha: stroke.brush.opacity * BrushGeometry.coverage(radius: Double(radius), softness: 1)).cgColor
            }
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations)
            let dabs = BrushGeometry.dabs(stroke)
            for matrix in stroke.symmetry.matrices {
                context.saveGState()
                context.concatenate(CGAffineTransform(a: matrix.a, b: matrix.b, c: matrix.c, d: matrix.d,
                                                      tx: matrix.tx, ty: matrix.ty))
                for dab in dabs {
                    context.saveGState()
                    context.translateBy(x: dab.center.x, y: dab.center.y)
                    context.rotate(by: dab.angle)
                    context.scaleBy(x: dab.radius, y: dab.radius * dab.aspect)
                    if stroke.brush.preset.softness > 0 {
                        if let gradient {
                            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                                                       endCenter: .zero, endRadius: 1, options: [])
                        }
                    } else {
                        context.setFillColor(UIColor(red: ink.red, green: ink.green, blue: ink.blue, alpha: stroke.brush.opacity).cgColor)
                        context.fillEllipse(in: CGRect(x: -1, y: -1, width: 2, height: 2))
                    }
                    context.restoreGState()
                }
                context.restoreGState()
            }
            return
        }
        context.setFillColor(UIColor(red: ink.red, green: ink.green, blue: ink.blue, alpha: stroke.brush.opacity).cgColor)
        let vertices = StrokeGeometry.mesh(stroke)
        // A single union fill keeps the original opaque fineliner free of seams.
        for matrix in stroke.symmetry.matrices {
            let path = CGMutablePath()
            for i in stride(from: 0, to: vertices.count, by: 3) {
                let a = matrix.apply(vertices[i]), b = matrix.apply(vertices[i+1]), c = matrix.apply(vertices[i+2])
                path.move(to: CGPoint(x: a.x, y: a.y))
                path.addLine(to: CGPoint(x: b.x, y: b.y))
                path.addLine(to: CGPoint(x: c.x, y: c.y))
                path.closeSubpath()
            }
            if stroke.brush.opacity == 1 {
                context.addPath(path); context.fillPath()
            } else {
                // Antialias the union boundary, not each internal fan edge.
                // Internal triangle antialiasing otherwise dims even an interior
                // pixel shared by two adjacent triangles (unlike Metal MSAA).
                context.saveGState()
                context.addPath(path); context.clip()
                context.setShouldAntialias(false)
                for i in stride(from: 0, to: vertices.count, by: 3) {
                    let triangle = CGMutablePath()
                    for j in 0..<3 {
                        let p = matrix.apply(vertices[i+j])
                        if j == 0 { triangle.move(to: CGPoint(x: p.x, y: p.y)) }
                        else { triangle.addLine(to: CGPoint(x: p.x, y: p.y)) }
                    }
                    triangle.closeSubpath(); context.addPath(triangle); context.fillPath()
                }
                context.restoreGState()
            }
        }
    }

}

actor ExportService {
    private struct PreviewIdentity: Hashable {
        let document: UUID
        let layer: UUID
    }
    private struct Preview {
        let raster: UUID?
        let strokes: [UUID]
        let png: Data
    }
    private var layerPreviews: [PreviewIdentity: Preview] = [:]
    private var previewOrder: [PreviewIdentity] = []
    private(set) var layerPreviewRenders = 0
    func sampledColor(_ document: DrawingDocument, point: Point) throws -> InkColor {
        try Task.checkCancellation()
        return try PNGExporter.sample(document: document, point: point)
    }
    func layerThumbnail(_ document: DrawingDocument, id: UUID) throws -> Data {
        try Task.checkCancellation()
        guard var layer = document.layers.first(where: { $0.id == id }) else { throw DocumentError.invalidData }
        let identity = PreviewIdentity(document: document.id, layer: id)
        let strokes = document.strokes.filter { $0.layerID == id }
        let ids = strokes.map(\.id)
        if let preview = layerPreviews[identity], preview.raster == layer.raster?.id, preview.strokes == ids {
            return preview.png
        }
        layer.isVisible = true; layer.opacity = 1
        var d = document; d.layers = [layer]; d.activeLayerID = id; d.strokes = strokes
        let data = try PNGExporter.data(document: d, transparent: true, maximumSide: 80)
        try Task.checkCancellation()
        layerPreviewRenders += 1
        previewOrder.removeAll { $0 == identity }; previewOrder.append(identity)
        layerPreviews[identity] = Preview(raster: layer.raster?.id, strokes: ids, png: data)
        while previewOrder.count > 32 { layerPreviews.removeValue(forKey: previewOrder.removeFirst()) }
        return data
    }
    func mergedLayer(_ document: DrawingDocument, topID: UUID) throws -> LayerRaster {
        try Task.checkCancellation()
        guard LayerManager.canMergeDown(topID, in: document),
              let i = document.layers.firstIndex(where: { $0.id == topID }) else { throw DocumentError.invalidData }
        guard document.size.x.rounded() == document.size.x, document.size.y.rounded() == document.size.y,
              document.size.x <= 2048, document.size.y <= 2048 else { throw DocumentError.mergeSize }
        var d = document; d.layers = Array(d.layers[(i - 1)...i]); d.activeLayerID = topID
        let ids = Set(d.layers.map(\.id)); d.strokes = d.strokes.filter { ids.contains($0.layerID) }
        let data = try PNGExporter.data(document: d, transparent: true)
        try Task.checkCancellation()
        let raster = LayerRaster(png: data, width: Int(d.size.x), height: Int(d.size.y))
        try raster.validate(canvas: d.size)
        return raster
    }

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
