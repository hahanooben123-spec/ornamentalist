import XCTest
import UIKit
@testable import Ornamentalist

final class PNGExportOptimizationTests: XCTestCase {
    func testLassoClipsMirroredInkAndEraserAfterTransform() throws {
        for operation in [StrokeOperation.ink, .erase] {
            var document = DrawingDocument(); document.size = Point(x: 128, y: 128)
            document.symmetry = SymmetryConfiguration(repetitions: 1, center: Point(x: 64, y: 64), mirror: true)
            if operation == .erase {
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let background = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128), format: format).image { output in
                    UIColor.black.setFill(); output.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
                }
                document.layers[0].raster = LayerRaster(png: try XCTUnwrap(background.pngData()), width: 128, height: 128)
            }
            let selection = StrokeSelection(points: [Point(x: 20, y: 20), Point(x: 50, y: 20), Point(x: 50, y: 44), Point(x: 20, y: 44)])
            document.strokes = [InkStroke(brush: InkBrush(width: 10, stabilization: 0), symmetry: document.symmetry, samples: [
                StrokeSample(point: Point(x: 20, y: 32), pressure: 1, altitude: 1, azimuth: 0, time: 0),
                StrokeSample(point: Point(x: 100, y: 32), pressure: 1, altitude: 1, azimuth: 0, time: 1)
            ], operation: operation, selection: selection, transform: Matrix.translation(Point(x: 10, y: 3)))]
            let expected = operation == .ink ? 0.0 : 1.0
            for point in [Point(x: 40, y: 35), Point(x: 40, y: 99)] {
                XCTAssertEqual(try PNGExporter.sample(document: document, point: point).red, expected, accuracy: 0.05)
            }
            XCTAssertEqual(try PNGExporter.sample(document: document, point: Point(x: 90, y: 35)).red, 1 - expected, accuracy: 0.05)
        }
    }
    @MainActor
    func testWholeLayerTransformMovesRasterAndEraserTogetherAndCanReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DocumentRepository(directory: directory)
        var document = DrawingDocument(); document.size = Point(x: 128, y: 128)
        document.symmetry = SymmetryConfiguration(repetitions: 1, center: Point(x: 64, y: 64))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { output in
            UIColor.black.setFill(); output.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        document.layers[0].raster = LayerRaster(png: try XCTUnwrap(image.pngData()), width: 64, height: 64,
            placement: RasterPlacement(center: Point(x: 64, y: 64)))
        document.strokes = [InkStroke(brush: InkBrush(width: 12), symmetry: document.symmetry,
            samples: [StrokeSample(point: Point(x: 64, y: 64), pressure: 1, altitude: 1, azimuth: 0, time: 0)], operation: .erase)]
        try await repository.save(document, generation: 1)
        let model = StudioModel(repository: repository); await model.open(document.id)
        let original = try XCTUnwrap(model.document)
        await model.beginLayerTransform()
        XCTAssertTrue(model.isTransforming)
        model.moveImage(by: Point(x: 20, y: 10)); model.finishImageTransform(apply: true)
        let moved = try XCTUnwrap(model.document)
        XCTAssertEqual(try PNGExporter.sample(document: moved, point: Point(x: 84, y: 74)).red, 1, accuracy: 0.05)
        XCTAssertEqual(try PNGExporter.sample(document: moved, point: Point(x: 64, y: 64)).red, 0, accuracy: 0.05)
        model.undo(); XCTAssertEqual(model.document?.strokes, original.strokes); XCTAssertEqual(model.document?.layers, original.layers)
        model.redo(); XCTAssertEqual(model.document?.strokes, moved.strokes)
        let saved = await model.saveNow(); XCTAssertTrue(saved)
        let reopened = try await DocumentRepository(directory: directory).open(document.id)
        XCTAssertEqual(reopened.0.strokes, moved.strokes); XCTAssertEqual(reopened.0.layers, moved.layers)
    }
    func testFillRespectsSelectionAndMirrorWithoutPaintingOutside() async throws {
        for mirrored in [false, true] {
            var document = DrawingDocument(); document.size = Point(x: 128, y: 128)
            document.symmetry = SymmetryConfiguration(repetitions: 1, center: Point(x: 64, y: 64), mirror: mirrored)
            let selection = StrokeSelection(points: [Point(x: 20, y: 20), Point(x: 50, y: 20), Point(x: 50, y: 44), Point(x: 20, y: 44)])
            let raster = try await ExportService().filledRegion(document, point: Point(x: 30, y: 30), selection: selection)
            document.layers[0].raster = raster
            XCTAssertEqual(try PNGExporter.sample(document: document, point: Point(x: 30, y: 30)).red, 0, accuracy: 0.05)
            XCTAssertEqual(try PNGExporter.sample(document: document, point: Point(x: 30, y: 98)).red, mirrored ? 0 : 1, accuracy: 0.05)
            XCTAssertEqual(try PNGExporter.sample(document: document, point: Point(x: 70, y: 30)).red, 1, accuracy: 0.05)
        }
    }
    func testFiveSmallFillsDoNotConsumeFiveCanvasSizedRasters() async throws {
        var document = DrawingDocument(); document.symmetry.repetitions = 1
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2048, height: 2048), format: format).image { output in
            UIColor.white.setFill(); output.fill(CGRect(x: 0, y: 0, width: 2048, height: 2048))
            output.cgContext.setStrokeColor(UIColor.black.cgColor); output.cgContext.setLineWidth(2)
            for i in 0..<5 { output.cgContext.stroke(CGRect(x: 40 + i * 40, y: 40, width: 20, height: 20)) }
        }
        document.layers[0].raster = LayerRaster(png: try XCTUnwrap(image.pngData()), width: 2048, height: 2048)
        let service = ExportService()
        for i in 0..<5 {
            let fill = try await service.filledRegion(document, point: Point(x: Double(50 + i * 40), y: 50))
            XCTAssertLessThan(fill.width * fill.height, 500)
            var layer = DrawingLayer(); layer.raster = fill
            document.layers.insert(layer, at: 0)
            try document.validate()
        }
        XCTAssertEqual(document.layers.count, 6)
    }
    func testCanceledExportDoesNotProduceAnImage() async {
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try PNGExporter.data(document: DrawingDocument(), transparent: true)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let canceled = await task.value
        XCTAssertTrue(canceled)
    }
    func testDirectFillPixelsMatchPNGDecodedPixels() throws {
        var document = DrawingDocument(); document.size = Point(x: 128, y: 128)
        document.symmetry = SymmetryConfiguration(repetitions: 2, center: Point(x: 64, y: 64), mirror: true)
        var brush = BrushPreset.softShader.makeBrush(); brush.width = 30; brush.opacity = 0.3
        document.strokes = [InkStroke(brush: brush, symmetry: document.symmetry,
            samples: [StrokeSample(point: Point(x: 80, y: 45), pressure: 0.6, altitude: 0.8, azimuth: 0, time: 0)])]
        let direct = try XCTUnwrap(PNGExporter.image(document: document, transparent: false).cgImage)
        let encoded = try XCTUnwrap(UIImage(data: PNGExporter.data(document: document, transparent: false))?.cgImage)
        XCTAssertEqual(try bytes(direct), try bytes(encoded))
    }
    func testOptimizedPainterPreservesMirroredBrushesAndErasers() throws {
        for preset in BrushPreset.allCases {
            for operation in [StrokeOperation.ink, .erase] {
                var brush = preset.makeBrush()
                brush.width = 24; brush.opacity = 0.37; brush.falloff = 0.2
                brush.tiltShading = 0.7; brush.pressureEnabled = true
                let samples = [Point(x: -15, y: 2), Point(x: 32, y: 30), Point(x: 85, y: 68)].enumerated().map {
                    StrokeSample(point: $0.element, pressure: 0.4 + Double($0.offset) * 0.25,
                                 altitude: 0.4, azimuth: 0.6, time: Double($0.offset))
                }
                let stroke = InkStroke(brush: brush,
                    symmetry: SymmetryConfiguration(repetitions: 4, center: Point(x: 32, y: 32)),
                    samples: samples, operation: operation)
                let expected = try pixels(stroke, reference: true)
                let actual = try pixels(stroke, reference: false)
                let largestDifference = zip(expected, actual).map { abs(Int($0) - Int($1)) }.max() ?? 0
                XCTAssertLessThanOrEqual(largestDifference, 4, "\(preset), \(operation)")
            }
        }
    }
    func testRegionExportMatchesFullResolutionCrop() throws {
        var document = DrawingDocument(); document.size = Point(x: 128, y: 128)
        document.symmetry = SymmetryConfiguration(repetitions: 4, center: Point(x: 64, y: 64))
        var brush = BrushPreset.airbrush.makeBrush(); brush.width = 32
        document.strokes = [InkStroke(brush: brush, symmetry: document.symmetry,
            samples: [StrokeSample(point: Point(x: 57, y: 40), pressure: 1, altitude: 1, azimuth: 0, time: 0)])]
        let full = try XCTUnwrap(UIImage(data: PNGExporter.data(document: document, transparent: true))?.cgImage)
        let region = CGRect(x: 0, y: 0, width: 64, height: 64)
        let cropped = try XCTUnwrap(full.cropping(to: region))
        let direct = try XCTUnwrap(UIImage(data: PNGExporter.data(document: document, transparent: true, region: region))?.cgImage)
        XCTAssertEqual(direct.width, 64); XCTAssertEqual(direct.height, 64)
        XCTAssertEqual(try bytes(cropped), try bytes(direct))
    }
    private func pixels(_ stroke: InkStroke, reference: Bool) throws -> [UInt8] {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { output in
            let context = output.cgContext
            context.setFillColor(UIColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            if reference { Self.referencePaint(stroke, in: context) }
            else { PNGExporter.paint(stroke, in: context) }
        }
        return try bytes(XCTUnwrap(image.cgImage))
    }
    private func bytes(_ image: CGImage) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try output.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return output
    }
    private static func referencePaint(_ stroke: InkStroke, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        if stroke.operation == .erase { context.setBlendMode(.destinationOut) }
        let ink = stroke.color
        if stroke.brush.usesStamps {
            let locations: [CGFloat] = (0...32).map { CGFloat($0) / 32 }
            let colors = locations.map { radius in
                UIColor(red: ink.red, green: ink.green, blue: ink.blue,
                        alpha: stroke.brush.dabOpacity * BrushGeometry.coverage(radius: Double(radius), softness: stroke.brush.effectiveSoftness)).cgColor
            }
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations)
            let dabs = BrushGeometry.dabs(stroke)
            for matrix in stroke.symmetry.matrices {
                context.saveGState()
                context.concatenate(CGAffineTransform(a: matrix.a, b: matrix.b, c: matrix.c, d: matrix.d,
                                                      tx: matrix.tx, ty: matrix.ty))
                for dab in dabs where dab.radius > 0 {
                    context.saveGState()
                    if dab.opacity < 1 { context.setAlpha(CGFloat(dab.opacity)) }
                    context.translateBy(x: dab.center.x, y: dab.center.y)
                    context.rotate(by: dab.angle)
                    context.scaleBy(x: dab.radius, y: dab.radius * dab.aspect)
                    if stroke.brush.effectiveSoftness > 0 {
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
        let isolated = stroke.brush.opacity < 1
        if isolated {
            // Apply solid-brush opacity once to the complete stroke, including
            // intersections between symmetry copies. The group's interior is
            // opaque, so its overlapping triangles cannot darken the stroke.
            context.setAlpha(CGFloat(stroke.brush.opacity))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        context.setFillColor(UIColor(red: ink.red, green: ink.green, blue: ink.blue, alpha: 1).cgColor)
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
            context.addPath(path); context.fillPath()
        }
        if isolated { context.endTransparencyLayer() }
    }

}
