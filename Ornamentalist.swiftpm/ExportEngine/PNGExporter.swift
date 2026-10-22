import UIKit
import ImageIO
import MetalKit

/// Exports document-space triangles through Core Graphics. No viewport, guides,
/// prediction, UI chrome, or screenshot is involved. 2048 square in Phase 1.
enum PNGExportResolution: String, CaseIterable, Sendable {
    case original = "Original size", high = "4096 px", a4 = "A4 · 300 PPI"
    func pixels(canvas: Point) -> Point {
        switch self {
        case .original: return canvas
        case .high: return canvas * (4096 / max(canvas.x, canvas.y))
        case .a4: return canvas.x > canvas.y ? Point(x: 3508, y: 2480) : Point(x: 2480, y: 3508)
        }
    }
}

enum PNGExporter {
    static func data(document: DrawingDocument, transparent: Bool, maximumSide: Double? = nil, region: CGRect? = nil, outputSize: Point? = nil) throws -> Data {
        let rendered = try image(document: document, transparent: transparent, maximumSide: maximumSide, region: region, outputSize: outputSize)
        try Task.checkCancellation()
        guard let data = rendered.pngData() else { throw DocumentError.graphics }
        try Task.checkCancellation()
        return data
    }
    static func image(document: DrawingDocument, transparent: Bool, maximumSide: Double? = nil, region: CGRect? = nil, outputSize: Point? = nil) throws -> UIImage {
        try Task.checkCancellation()
        try document.validate()
        let bounds = CGRect(x: 0, y: 0, width: document.size.x, height: document.size.y)
        let region = region ?? bounds
        guard !region.isEmpty, bounds.contains(region) else { throw DocumentError.invalidData }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // Exact pixel dimensions, independent of the iPad screen scale.
        format.opaque = !transparent
        var scale: Double = maximumSide.map { min(1.0, $0 / max(Double(region.width), Double(region.height))) } ?? 1.0
        var size = CGSize(width: Double(region.width) * scale, height: Double(region.height) * scale)
        if let outputSize {
            guard outputSize.isFinite, outputSize.x >= 1, outputSize.y >= 1,
                  outputSize.x <= 8192, outputSize.y <= 8192 else { throw DocumentError.invalidData }
            size = CGSize(width: outputSize.x.rounded(), height: outputSize.y.rounded())
            scale = min(Double(size.width) / region.width, Double(size.height) / region.height)
        }
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        var failure: Error?
        let image = renderer.image { output in
            let context = output.cgContext
            if !transparent {
                context.setFillColor(UIColor.white.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
            }
            context.translateBy(x: (Double(size.width) - region.width * scale) / 2,
                                y: (Double(size.height) - region.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -region.minX, y: -region.minY)
            context.clip(to: CGRect(x: 0, y: 0, width: document.size.x, height: document.size.y))
            context.setFillColor(UIColor.black.cgColor)
            do { try paintDocument(document, in: context) } catch { failure = error }

        }
        if let failure { throw failure }
        try Task.checkCancellation()
        return image
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
            try Task.checkCancellation()
            context.saveGState()
            context.setAlpha(CGFloat(layer.opacity))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            if let raster = layer.raster {
                do {
                    let image = try rasterImage(raster)
                    context.saveGState()
                    let m = raster.matrix(canvas: document.size)
                    context.concatenate(CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty))
                    context.translateBy(x: 0, y: Double(raster.height)); context.scaleBy(x: 1, y: -1)
                    context.interpolationQuality = .high
                    context.draw(image, in: CGRect(x: 0, y: 0, width: Double(raster.width), height: Double(raster.height)))
                    context.restoreGState()
                } catch {
                    context.endTransparencyLayer(); context.restoreGState(); throw error
                }
            }
            do {
                for stroke in grouped[layer.id] ?? [] { try paintCancellable(stroke, in: context) }
            } catch {
                context.endTransparencyLayer(); context.restoreGState(); throw error
            }
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
        try? paintCancellable(stroke, in: context)
    }
    private static func clip(_ selection: StrokeSelection?, context: CGContext) {
        guard let points = selection?.points, let first = points.first else { return }
        context.beginPath(); context.move(to: CGPoint(x: first.x, y: first.y))
        for point in points.dropFirst() { context.addLine(to: CGPoint(x: point.x, y: point.y)) }
        context.closePath(); context.clip(using: .evenOdd)
    }
    static func paintCancellable(_ stroke: InkStroke, in context: CGContext) throws {
        try Task.checkCancellation()
        context.saveGState()
        defer { context.restoreGState() }
        if let m = stroke.transform {
            context.concatenate(CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty))
        }
        if stroke.operation == .erase { context.setBlendMode(.destinationOut) }
        let ink = stroke.color
        if stroke.brush.usesStamps {
            let soft = stroke.brush.effectiveSoftness > 0
            let fill = UIColor(red: ink.red, green: ink.green, blue: ink.blue, alpha: stroke.brush.opacity).cgColor
            let locations: [CGFloat] = (0...32).map { CGFloat($0) / 32 }
            let colors = locations.map { radius in
                UIColor(red: ink.red, green: ink.green, blue: ink.blue,
                        alpha: stroke.brush.dabOpacity * BrushGeometry.coverage(radius: Double(radius), softness: stroke.brush.effectiveSoftness)).cgColor
            }
            let gradient = soft ? CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations) : nil
            var state = BrushStampState(id: stroke.seedID), dabs: [BrushDab] = []
            for (index, sample) in stroke.samples.enumerated() {
                if index % 64 == 0 { try Task.checkCancellation() }
                dabs += state.advance(sample, brush: stroke.brush)
            }
            var sourceBounds = CGRect.null
            if stroke.symmetry.tileCount > 0 && stroke.symmetry.tileSymmetry {
                for dab in dabs {
                    let extent = dab.radius * max(1, dab.aspect) * 1.5
                    sourceBounds = sourceBounds.union(CGRect(x: dab.center.x - extent, y: dab.center.y - extent, width: extent * 2, height: extent * 2))
                }
            }
            for matrix in stroke.symmetry.matrices(for: sourceBounds, clip: context.boundingBoxOfClipPath.insetBy(dx: -2, dy: -2)) {
                try Task.checkCancellation()
                context.saveGState()
                defer { context.restoreGState() }
                context.concatenate(CGAffineTransform(a: matrix.a, b: matrix.b, c: matrix.c, d: matrix.d,
                                                      tx: matrix.tx, ty: matrix.ty))
                clip(stroke.selection, context: context)
                // The clip is expressed in this symmetry copy's local coordinates.
                // Keep a device-pixel margin for antialiasing at the canvas edge.
                let pixel = context.convertToUserSpace(CGSize(width: 1, height: 1))
                let margin = max(abs(pixel.width), abs(pixel.height)) * 2
                let clip = context.boundingBoxOfClipPath.insetBy(dx: -margin, dy: -margin)
                context.setFillColor(fill)
                for (index, dab) in dabs.enumerated() {
                    if index % 128 == 0 { try Task.checkCancellation() }
                    guard dab.radius > 0, dab.opacity > 0 else { continue }
                    let extent = dab.radius * max(1, dab.aspect)
                    guard clip.intersects(CGRect(x: dab.center.x - extent, y: dab.center.y - extent,
                                                  width: extent * 2, height: extent * 2)) else { continue }
                    if !soft && dab.aspect == 1 {
                        // Circular dots need no individual coordinate-system stack.
                        // Preserve separate fills: translucent dots must accumulate.
                        context.setAlpha(CGFloat(dab.opacity))
                        context.fillEllipse(in: CGRect(x: dab.center.x - dab.radius, y: dab.center.y - dab.radius,
                                                       width: dab.radius * 2, height: dab.radius * 2))
                        continue
                    }
                    context.saveGState()
                    context.setAlpha(CGFloat(dab.opacity))
                    context.translateBy(x: dab.center.x, y: dab.center.y)
                    context.rotate(by: dab.angle)
                    context.scaleBy(x: dab.radius, y: dab.radius * dab.aspect)
                    if soft {
                        // A radial gradient has no coverage outside this square.
                        // Bound the shading operation rather than shade the whole canvas per dab.
                        context.clip(to: CGRect(x: -1, y: -1, width: 2, height: 2))
                        if let gradient {
                            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                                                       endCenter: .zero, endRadius: 1, options: [])
                        }
                    } else {
                        context.fillEllipse(in: CGRect(x: -1, y: -1, width: 2, height: 2))
                    }
                    context.restoreGState()
                }
            }
            return
        }
        let isolated = stroke.brush.opacity < 1
        if isolated {
            // Apply solid-brush opacity once to the complete stroke, including
            // intersections between symmetry copies. The group's interior is
            // opaque, so its overlapping triangles cannot darken the stroke.
            context.setAlpha(CGFloat(stroke.brush.opacity))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        context.setFillColor(UIColor(red: ink.red, green: ink.green, blue: ink.blue, alpha: 1).cgColor)
        defer { if isolated { context.endTransparencyLayer() } }
        let vertices = StrokeGeometry.mesh(stroke)
        try Task.checkCancellation()
        // Build the source path once; Core Graphics applies each symmetry transform.
        // Separate copy fills preserve the original translucent/eraser compositing.
        let path = CGMutablePath()
        for i in stride(from: 0, to: vertices.count, by: 3) {
            if i % 1023 == 0 { try Task.checkCancellation() }
            let a = vertices[i], b = vertices[i + 1], c = vertices[i + 2]
            path.move(to: CGPoint(x: a.x, y: a.y))
            path.addLine(to: CGPoint(x: b.x, y: b.y))
            path.addLine(to: CGPoint(x: c.x, y: c.y))
            path.closeSubpath()
        }
        let sourceBounds = stroke.symmetry.tileCount > 0 && stroke.symmetry.tileSymmetry
            ? SymmetryConfiguration.bounds(of: vertices, padding: 2) : CGRect.null
        for matrix in stroke.symmetry.matrices(for: sourceBounds, clip: context.boundingBoxOfClipPath.insetBy(dx: -2, dy: -2)) {
            try Task.checkCancellation()
            context.saveGState()
            context.concatenate(CGAffineTransform(a: matrix.a, b: matrix.b, c: matrix.c, d: matrix.d,
                                                  tx: matrix.tx, ty: matrix.ty))
            clip(stroke.selection, context: context)
            context.addPath(path); context.fillPath()
            context.restoreGState()
        }
        try Task.checkCancellation()
    }

}

actor ExportService {
    func filledRegion(_ document: DrawingDocument, point: Point, selection: StrokeSelection? = nil) throws -> LayerRaster {
        try Task.checkCancellation()
        let width = Int(document.size.x), height = Int(document.size.y)
        guard width >= 64, height >= 64, width <= 2048, height <= 2048 else { throw DocumentError.mergeSize }
        guard let image = try PNGExporter.image(document: document, transparent: false).cgImage else { throw DocumentError.graphics }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Copy CGImage rows directly: flipping here mirrors the tapped seed
            // vertically and can flood the outside of a small closed shape.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw DocumentError.graphics }
        let seeds = document.symmetry.matrices(for: CGRect(x: point.x - 0.01, y: point.y - 0.01, width: 0.02, height: 0.02)).map { matrix -> (Int, Int) in
            let p = matrix.apply(point)
            return (Int(p.x.rounded(.down)), Int(p.y.rounded(.down)))
        }
        var mask = FillRegion.mask(rgba: pixels, width: width, height: height, seeds: seeds)
        try Task.checkCancellation()
        if let selection {
            // Rasterize the lasso once instead of testing every filled pixel
            // against every polygon edge and every Mirror copy.
            var selectionPixels = [UInt8](repeating: 0, count: width * height)
            try selectionPixels.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw DocumentError.graphics }
                context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
                context.setShouldAntialias(false); context.setFillColor(gray: 1, alpha: 1)
                for matrix in document.symmetry.matrices(for: SymmetryConfiguration.bounds(of: selection.points, padding: 1)) {
                    try Task.checkCancellation()
                    context.beginPath()
                    for (i, point) in selection.points.enumerated() {
                        let p = matrix.apply(point)
                        if i == 0 { context.move(to: CGPoint(x: p.x, y: p.y)) }
                        else { context.addLine(to: CGPoint(x: p.x, y: p.y)) }
                    }
                    context.closePath(); context.drawPath(using: .eoFill)
                }
            }
            for i in mask.indices where selectionPixels[i] == 0 { mask[i] = 0 }
        }
        guard let first = mask.firstIndex(where: { $0 != 0 }) else { throw DocumentError.invalidData }
        var minX = first % width, maxX = minX, minY = first / width, maxY = minY
        for i in mask.indices where mask[i] != 0 {
            minX = min(minX, i % width); maxX = max(maxX, i % width)
            minY = min(minY, i / width); maxY = max(maxY, i / width)
        }
        let croppedWidth = maxX - minX + 1, croppedHeight = maxY - minY + 1
        let color = document.color, alpha = document.brush.opacity
        let red = UInt8((color.red * alpha * 255).rounded()), green = UInt8((color.green * alpha * 255).rounded())
        let blue = UInt8((color.blue * alpha * 255).rounded()), opacity = UInt8((alpha * 255).rounded())
        var cropped = [UInt8](repeating: 0, count: croppedWidth * croppedHeight * 4)
        for y in 0..<croppedHeight {
            if y % 64 == 0 { try Task.checkCancellation() }
            for x in 0..<croppedWidth where mask[(y + minY) * width + x + minX] != 0 {
                let offset = (y * croppedWidth + x) * 4
                cropped[offset] = red; cropped[offset + 1] = green
                cropped[offset + 2] = blue; cropped[offset + 3] = opacity
            }
        }
        guard let provider = CGDataProvider(data: Data(cropped) as CFData),
              let output = CGImage(width: croppedWidth, height: croppedHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: croppedWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let png = UIImage(cgImage: output).pngData() else { throw DocumentError.graphics }
        let raster = LayerRaster(png: png, width: croppedWidth, height: croppedHeight,
            placement: RasterPlacement(center: Point(x: Double(minX) + Double(croppedWidth) * 0.5,
                                                     y: Double(minY) + Double(croppedHeight) * 0.5)))
        try raster.validate(canvas: document.size)
        return raster
    }
    private struct TransformPreviewKey: Equatable {
        let document: UUID
        let layer: UUID
        let raster: UUID?
        let placement: RasterPlacement?
        let size: Point
        let strokes: [UUID]
    }
    private var cachedTransformPreview: (TransformPreviewKey, LayerRaster)?
    func transformPreview(_ document: DrawingDocument, layerID: UUID) throws -> LayerRaster {
        try Task.checkCancellation()
        guard var layer = document.layers.first(where: { $0.id == layerID }) else { throw DocumentError.invalidData }
        let strokes = document.strokes.filter { $0.layerID == layerID }
        let key = TransformPreviewKey(document: document.id, layer: layerID, raster: layer.raster?.id,
            placement: layer.raster?.placement, size: document.size, strokes: strokes.map(\.id))
        if let cached = cachedTransformPreview, cached.0 == key { return cached.1 }
        layer.opacity = 1; layer.isVisible = true
        var isolated = document; isolated.layers = [layer]; isolated.activeLayerID = layerID; isolated.strokes = strokes
        // Only the interactive preview is reduced. Apply composes matrices onto original ink/images.
        let image = try PNGExporter.image(document: isolated, transparent: true, maximumSide: 1024)
        guard let cg = image.cgImage else { throw DocumentError.graphics }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let cropped: CGImage = try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw DocumentError.graphics }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let normalized = context.makeImage() else { throw DocumentError.graphics }
            return normalized
        }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            if y % 64 == 0 { try Task.checkCancellation() }
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { throw DocumentError.invalidData }
        // A small transparent margin retains antialiasing at the handle bounds.
        minX = max(0, minX - 2); minY = max(0, minY - 2)
        maxX = min(width - 1, maxX + 2); maxY = min(height - 1, maxY + 2)
        let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let result = cropped.cropping(to: rect), let png = UIImage(cgImage: result).pngData() else { throw DocumentError.graphics }
        let scale = document.size.x / Double(width)
        let raster = LayerRaster(png: png, width: result.width, height: result.height,
            placement: RasterPlacement(center: Point(x: Double(rect.midX) * scale, y: Double(rect.midY) * scale), scale: scale))
        try Task.checkCancellation()
        cachedTransformPreview = (key, raster)
        return raster
    }
    private struct PreviewIdentity: Hashable {
        let document: UUID
        let layer: UUID
    }
    private struct Preview {
        let raster: UUID?
        let placement: RasterPlacement?
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
        if let preview = layerPreviews[identity], preview.raster == layer.raster?.id,
           preview.placement == layer.raster?.placement, preview.strokes == ids {
            return preview.png
        }
        layer.isVisible = true; layer.opacity = 1
        var d = document; d.layers = [layer]; d.activeLayerID = id; d.strokes = strokes
        let data = try PNGExporter.data(document: d, transparent: true, maximumSide: 80)
        try Task.checkCancellation()
        layerPreviewRenders += 1
        previewOrder.removeAll { $0 == identity }; previewOrder.append(identity)
        layerPreviews[identity] = Preview(raster: layer.raster?.id, placement: layer.raster?.placement, strokes: ids, png: data)
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
    func importedImage(_ data: Data, canvas: Point) throws -> LayerRaster {
        guard data.count <= DrawingLimits.encodedBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw DocumentError.invalidData }
        try Task.checkCancellation()
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw DocumentError.graphics }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DocumentError.graphics }
        let scale = min(canvas.x / Double(image.width), canvas.y / Double(image.height)) * 0.8
        let raster = LayerRaster(png: output as Data, width: image.width, height: image.height,
                                 placement: RasterPlacement(center: canvas * 0.5, scale: min(64, max(0.01, scale))))
        try raster.validate(canvas: canvas)
        return raster
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
    func tilePNG(_ document: DrawingDocument) throws -> URL {
        guard document.symmetry.tileCount > 0 else { throw DocumentError.invalidData }
        let size = document.symmetry.tileSize
        // Render only the requested tile, at its original pixel resolution.
        // Avoid rendering/compressing the full repeated canvas, decoding and compressing it again.
        let output = try PNGExporter.data(document: document, transparent: true,
                                         region: CGRect(x: 0, y: 0, width: size.x, height: size.y))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OrnamentalistExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Ornamentalist-Tile-\(document.id.uuidString).png")
        try output.write(to: url, options: .atomic)
        return url
    }
}


/// One separate renderer serializes readbacks without disturbing canvas caches.
/// Finished PNGs are cached by visible content, with a 4 MiB/40-image bound.
@MainActor
final class ArtworkRenderer {
    weak var source: MetalCanvasRenderer?
    private var renderer: MetalCanvasRenderer?
    private var rendering = false
    private var gpuFailure: Error?
    private let encoder = ExportService()
    private struct Key: Equatable {
        let display: CanvasDisplayState
        let side: Int
        let transparent: Bool
        let region: CGRect
    }
    private var previews: [(Key, Data)] = []
    private(set) var renderCount = 0
    init(source: MetalCanvasRenderer? = nil) { self.source = source }
    func releaseCaches() { renderer = nil; previews.removeAll() }
    func export(_ document: DrawingDocument, resolution: PNGExportResolution, transparent: Bool,
                progress: @escaping @MainActor (Double) -> Void) async throws -> Data {
        let target = resolution.pixels(canvas: document.size)
        let width = Int(target.x.rounded()), height = Int(target.y.rounded())
        while rendering { try await Task.sleep(nanoseconds: 10_000_000) }
        try Task.checkCancellation()
        rendering = true; defer { rendering = false }
        if let gpuFailure { throw gpuFailure }
        do {
            if let source {
                if renderer?.usesArtworkDevice(of: source) != true { renderer = try source.makeArtworkRenderer() }
            } else if renderer == nil { renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero)) }
            guard let renderer else { throw DocumentError.noMetal }
            if let source { renderer.borrowArtworkGeometry(from: source) }
            try await renderer.synchronize(document.strokes, layers: document.layers)
            var pixels = Data(count: width * height * 4)
            let scale = min(Double(width) / document.size.x, Double(height) / document.size.y)
            let count = ((width + 1023) / 1024) * ((height + 1023) / 1024)
            var completed = 0
            for y in stride(from: 0, to: height, by: 1024) {
                for x in stride(from: 0, to: width, by: 1024) {
                    try Task.checkCancellation()
                    let w = min(1024, width - x), h = min(1024, height - y)
                    // Two pixels of overlap keep antialiasing identical at tile boundaries.
                    let tw = w + 4, th = h + 4
                    let fit = min(Double(tw) / document.size.x, Double(th) / document.size.y) * 0.92
                    let viewport = Viewport(zoom: scale / fit,
                        pan: Point(x: Double(width - tw) / 2 - Double(x) + 2,
                                   y: Double(height - th) / 2 - Double(y) + 2))
                    let tile = try await renderer.renderOffscreen(document: document, viewport: viewport,
                        width: tw, height: th, transparent: transparent, paper: true)
                    pixels.withUnsafeMutableBytes { destination in
                        tile.withUnsafeBytes { source in
                            for row in 0..<h {
                                destination.baseAddress!.advanced(by: ((y + row) * width + x) * 4)
                                    .copyMemory(from: source.baseAddress!.advanced(by: ((row + 2) * tw + 2) * 4), byteCount: w * 4)
                            }
                        }
                    }
                    completed += 1; progress(Double(completed) / Double(count) * 0.9)
                }
            }
            let data = try await encoder.encodeArtwork(pixels, width: width, height: height, dpi: resolution == .a4 ? 300 : nil)
            progress(1); return data
        } catch is CancellationError { renderer = nil; throw CancellationError() }
        catch { renderer = nil; gpuFailure = error; throw error }
    }
    func png(_ document: DrawingDocument, maximumSide: Int, transparent: Bool, region: CGRect? = nil) async throws -> Data {
        let canvas = CGRect(x: 0, y: 0, width: document.size.x, height: document.size.y)
        let region = region ?? canvas
        guard !region.isEmpty, canvas.contains(region) else { throw DocumentError.invalidData }
        var drawing = document
        if let first = drawing.layers.first { drawing.activeLayerID = first.id }
        let key = Key(display: CanvasDisplayState(drawing, guides: false), side: maximumSide, transparent: transparent, region: region)
        if let cached = previews.first(where: { $0.0 == key }) { return cached.1 }
        while rendering { try await Task.sleep(nanoseconds: 10_000_000) }
        try Task.checkCancellation()
        if let cached = previews.first(where: { $0.0 == key }) { return cached.1 }
        rendering = true; defer { rendering = false }
        if let gpuFailure { throw gpuFailure }
        try document.validate()
        let scale = min(1, Double(maximumSide) / max(Double(region.width), Double(region.height)))
        let width = max(1, Int((Double(region.width) * scale).rounded())), height = max(1, Int((Double(region.height) * scale).rounded()))
        guard width <= 2048, height <= 2048 else { return try await encoder.pngData(drawing, transparent: transparent, region: region) }
        do {
        if let source {
            if renderer?.usesArtworkDevice(of: source) != true { renderer = try source.makeArtworkRenderer() }
        } else if renderer == nil { renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero)) }
        guard let renderer else { throw DocumentError.noMetal }
        if let source { renderer.borrowArtworkGeometry(from: source) }
        try await renderer.synchronize(drawing.strokes, layers: drawing.layers)
        let fit = min(Double(width) / drawing.size.x, Double(height) / drawing.size.y) * 0.92
        let center = Point(x: Double(region.midX), y: Double(region.midY))
        let viewport = Viewport(zoom: scale / fit, pan: (drawing.size * 0.5 - center) * scale)
        let pixels = try await renderer.renderOffscreen(document: drawing, viewport: viewport,
            width: width, height: height, transparent: transparent)
        try Task.checkCancellation()
        let png = try await encoder.encodeArtwork(Data(pixels), width: width, height: height)
        try Task.checkCancellation()
        renderCount += 1; previews.append((key, png))
        while previews.count > 40 || previews.reduce(0, { $0 + $1.1.count }) > 4 * 1024 * 1024 { previews.removeFirst() }
        return png
        } catch is CancellationError {
            renderer = nil; throw CancellationError()
        } catch {
            renderer = nil; gpuFailure = error; throw error
        }
    }
}

extension ExportService {
    func pngData(_ document: DrawingDocument, transparent: Bool, region: CGRect? = nil) throws -> Data {
        try PNGExporter.data(document: document, transparent: transparent, region: region)
    }
    func encodeArtwork(_ pixels: Data, width: Int, height: Int, dpi: Double? = nil) throws -> Data {
        try Task.checkCancellation()
        guard pixels.count == width * height * 4, let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw DocumentError.graphics }
        return try encodeImage(image, dpi: dpi)
    }
    private func encodeImage(_ image: CGImage, dpi: Double?) throws -> Data {
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw DocumentError.graphics }
        var properties: [CFString: Any] = [:]
        if let dpi { properties[kCGImagePropertyDPIWidth] = dpi; properties[kCGImagePropertyDPIHeight] = dpi }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw DocumentError.graphics }
        try Task.checkCancellation(); return data as Data
    }
    func scaledPNG(_ document: DrawingDocument, resolution: PNGExportResolution, transparent: Bool) throws -> Data {
        let image = try PNGExporter.image(document: document, transparent: transparent, outputSize: resolution.pixels(canvas: document.size))
        guard let cg = image.cgImage else { throw DocumentError.graphics }
        return try encodeImage(cg, dpi: resolution == .a4 ? 300 : nil)
    }
    func writeArtwork(_ data: Data, id: UUID, transparent: Bool, tile: Bool = false, suffix: String = "") throws -> URL {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OrnamentalistExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeSuffix = suffix.isEmpty ? "" : "-" + suffix.replacingOccurrences(of: " · ", with: "-").replacingOccurrences(of: " ", with: "-")
        let url = directory.appendingPathComponent("Ornamentalist-\(id.uuidString)\(safeSuffix)\(tile ? "-tile" : "")\(transparent ? "-transparent" : "").png")
        try data.write(to: url, options: .atomic); return url
    }
}
