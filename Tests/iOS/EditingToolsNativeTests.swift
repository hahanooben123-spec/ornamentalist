import XCTest
import UIKit
import MetalKit
@testable import Ornamentalist

final class EditingToolsNativeTests: XCTestCase {
    @MainActor
    func testTileMirrorRotationsAndTransformedInkMatchMetalAndPNG() async throws {
        for copies in [1, 2] {
            var document = DrawingDocument(); document.size = Point(x: 128, y: 128)
            document.symmetry = SymmetryConfiguration(repetitions: 8, center: Point(x: 64, y: 64), mirror: true,
                tileCount: 2, tileSymmetry: true, tileRepetitions: copies, tileCanvas: document.size)
            document.strokes = [InkStroke(brush: InkBrush(width: 8, stabilization: 0), symmetry: document.symmetry,
                samples: [StrokeSample(point: Point(x: 20, y: 24), pressure: 1, altitude: 1, azimuth: 0, time: 0)],
                transform: Matrix.translation(Point(x: 3, y: 5)))]
            let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
            try await renderer.synchronize(document.strokes, layers: document.layers)
            let pixels = try await renderer.renderOffscreen(document: document, viewport: Viewport(), width: 128, height: 128)
            let matrix = Viewport().matrix(viewSize: document.size, canvasSize: document.size)
            var checks: [(Point, Double)] = [(Point(x: 23, y: 29), 0), (Point(x: 23, y: 45), 0),
                (Point(x: 87, y: 109), 0), (Point(x: 35, y: 37), 255)]
            checks.append((Point(x: 47, y: 45), copies == 2 ? 0 : 255))
            for (point, expected) in checks {
                let screen = matrix.apply(point), offset = (Int(screen.y) * 128 + Int(screen.x)) * 4
                XCTAssertEqual(Double(pixels[offset]), expected, accuracy: 5)
                XCTAssertEqual(try PNGExporter.sample(document: document, point: point).red * 255, expected, accuracy: 5)
            }
        }
    }
    @MainActor
    func testSelectionAndWholeStrokeTransformMatchMetalAndPNG() async throws {
        var drawing = DrawingDocument(); drawing.size = Point(x: 128, y: 128)
        drawing.symmetry = SymmetryConfiguration(repetitions: 1, center: Point(x: 64, y: 64), mirror: true)
        let selection = StrokeSelection(points: [Point(x: 20, y: 20), Point(x: 50, y: 20), Point(x: 50, y: 44), Point(x: 20, y: 44)])
        let points = [Point(x: 20, y: 32), Point(x: 100, y: 32)].enumerated().map {
            StrokeSample(point: $0.element, pressure: 1, altitude: 1, azimuth: 0, time: Double($0.offset))
        }
        drawing.strokes = [InkStroke(brush: InkBrush(width: 10, stabilization: 0), symmetry: drawing.symmetry,
            samples: points, selection: selection, transform: Matrix.translation(Point(x: 10, y: 3)))]
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
        try await renderer.synchronize(drawing.strokes, layers: drawing.layers)
        let pixels = try await renderer.renderOffscreen(document: drawing, viewport: Viewport(), width: 128, height: 128)
        let matrix = Viewport().matrix(viewSize: drawing.size, canvasSize: drawing.size)
        for (point, expected) in [(Point(x: 40, y: 35), 0), (Point(x: 40, y: 99), 0), (Point(x: 90, y: 35), 255)] {
            let screen = matrix.apply(point)
            let offset = (Int(screen.y) * 128 + Int(screen.x)) * 4
            XCTAssertEqual(Double(pixels[offset]), Double(expected), accuracy: 5)
            let png = try PNGExporter.sample(document: drawing, point: point)
            XCTAssertEqual(png.red * 255, Double(expected), accuracy: 5)
        }
    }
    @MainActor
    func testImagePlacementMatchesMetalAndPNGAndInvalidatesRasterCache() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 32), format: format).image { output in
            UIColor.red.setFill(); output.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            UIColor.blue.setFill(); output.fill(CGRect(x: 32, y: 0, width: 32, height: 32))
        }
        var d = DrawingDocument(); d.size = Point(x: 128, y: 128)
        d.symmetry = SymmetryConfiguration(repetitions: 1, center: Point(x: 64, y: 64))
        d.layers[0].raster = LayerRaster(png: try XCTUnwrap(image.pngData()), width: 64, height: 32,
            placement: RasterPlacement(center: Point(x: 64, y: 64), rotation: .pi / 2))
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
        try await renderer.synchronize(d.strokes, layers: d.layers)
        for flipped in [false, true] {
            d.layers[0].raster?.placement?.flipHorizontal = flipped
            let pixels = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
            let i = screenIndex(64, 44)
            let png = try pixel(d, x: 64, y: 44)
            XCTAssertEqual(Double(pixels[i + 2]), flipped ? 0 : 255, accuracy: 3)
            XCTAssertEqual(Double(pixels[i]), flipped ? 255 : 0, accuracy: 3)
            XCTAssertEqual(Double(png[0]), flipped ? 0 : 255, accuracy: 3)
            XCTAssertEqual(Double(png[2]), flipped ? 255 : 0, accuracy: 3)
        }
    }

    @MainActor
    func testTranslucentFinelinerMatchesPNGAndLiveCommit() async throws {
        var d = fixture()
        d.strokes[1].brush.opacity = 0.35
        try d.validate()
        let stroke = d.strokes.removeLast()
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
        try await renderer.synchronize(d.strokes, layers: d.layers)
        renderer.begin(); try renderer.append(BrushGeometry.mesh(stroke))
        let live = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256, active: stroke)
        try renderer.commit(stroke); d.strokes.append(stroke)
        let committed = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        XCTAssertEqual(live, committed)
        // Include the original narrow fan seam: solid opacity is uniform there.
        for (x, y) in [(85, 68), (95, 66), (83, 80)] {
            let i = screenIndex(Double(x), Double(y)), png = try pixel(d, x: x, y: y)
            XCTAssertEqual(Double(png[0]), 89, accuracy: 3)
            XCTAssertEqual(Double(png[2]), 166, accuracy: 3)
            XCTAssertEqual(Double(committed[i + 2]), Double(png[0]), accuracy: 3)
            XCTAssertEqual(Double(committed[i]), Double(png[2]), accuracy: 3)
        }
    }

    @MainActor
    func testSolidOpacityDoesNotAccumulateWithinLiveMirroredStroke() async throws {
        for preset in [BrushPreset.fineliner, .brushPen] {
            for operation in [StrokeOperation.ink, .erase] {
                var d = fixture()
                if operation == .ink { d.strokes.removeLast() }
                var brush = preset.makeBrush(); brush.width = 40; brush.opacity = 0.35; brush.pressureEnabled = false
                let symmetry = SymmetryConfiguration(repetitions: 4, center: Point(x: 64, y: 64), mirror: true)
                var session = StrokeSession(brush: brush, symmetry: symmetry, existingSamples: 0,
                    existingVertices: 0, layerID: d.activeLayerID, color: InkColor(red: 1), operation: operation)
                let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
                try await renderer.synchronize(d.strokes, layers: d.layers)
                renderer.begin()
                var live: [UInt8] = []
                for step in 0..<8 {
                    let sample = StrokeSample(point: Point(x: 80 + Double(step % 2) * 4, y: 64),
                        pressure: 1, altitude: 1, azimuth: 0, time: Double(step))
                    try renderer.append(session.append(sample))
                    live = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256,
                        active: session.stroke, preview: session.preview(predictions: []))
                    let i = screenIndex(85, 68)
                    XCTAssertEqual(Double(live[i + 2]), operation == .ink ? 89 : 166, accuracy: 3)
                    XCTAssertEqual(Double(live[i]), operation == .ink ? 166 : 89, accuracy: 3)
                }
                try renderer.commit(session.stroke); d.strokes.append(session.stroke)
                let committed = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
                XCTAssertEqual(live, committed)
                let png = try pixel(d, x: 85, y: 68)
                XCTAssertEqual(Double(png[0]), operation == .ink ? 89 : 166, accuracy: 3)
                XCTAssertEqual(Double(png[2]), operation == .ink ? 166 : 89, accuracy: 3)
            }
        }
    }
    private func fixture() -> DrawingDocument {
        var d = DrawingDocument(); d.size = Point(x: 128, y: 128)
        d.symmetry = SymmetryConfiguration(repetitions: 1, center: Point(x: 64, y: 64))
        let p = StrokeSample(point: Point(x: 64, y: 64), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        d.strokes = [InkStroke(brush: InkBrush(width: 120), symmetry: d.symmetry, samples: [p], color: InkColor(blue: 1))]
        _ = LayerManager.add(in: &d)
        var red = p; red.point = Point(x: 80, y: 64)
        d.strokes.append(InkStroke(brush: InkBrush(width: 40), symmetry: d.symmetry, samples: [red], layerID: d.activeLayerID, color: InkColor(red: 1)))
        return d
    }
    private func pixel(_ document: DrawingDocument, x: Int, y: Int, transparent: Bool = false) throws -> [UInt8] {
        let image = try XCTUnwrap(UIImage(data: PNGExporter.data(document: document, transparent: transparent))?.cgImage)
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { data in
            let context = try XCTUnwrap(CGContext(data: data.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
    private func screenIndex(_ x: Double, _ y: Double) -> Int {
        let sx = Int((128 + (x - 64) * 1.84).rounded()), sy = Int((128 + (y - 64) * 1.84).rounded())
        return (sy * 256 + sx) * 4
    }
    @MainActor
    func testLiveMirroredEraserRevealsLowerLayerAndSurvivesUndoAndReopen() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        var d = fixture(), history = StrokeHistory()
        var session = StrokeSession(brush: InkBrush(width: 8), symmetry: SymmetryConfiguration(repetitions: 1,
            center: Point(x: 64, y: 64), mirror: true), existingSamples: 0, existingVertices: 0,
            layerID: d.activeLayerID, operation: .erase)
        let p = StrokeSample(point: Point(x: 80, y: 74), pressure: 1, altitude: 1, azimuth: 0, time: 2)
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero)); try await renderer.synchronize(d.strokes, layers: d.layers)
        renderer.begin(); try renderer.append(session.append(p))
        let live = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256, active: session.stroke)
        try renderer.commit(session.stroke); history.recordNewStroke(session.stroke, in: &d)
        let committed = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        XCTAssertEqual(live, committed)
        for y in [54.0, 74] {
            let i = screenIndex(80, y)
            XCTAssertGreaterThan(committed[i], 250); XCTAssertLessThan(committed[i + 2], 5)
            let png = try pixel(d, x: 80, y: Int(y)); XCTAssertGreaterThan(png[2], 250); XCTAssertLessThan(png[0], 5)
        }
        XCTAssertGreaterThan(try pixel(d, x: 80, y: 64)[0], 250)
        XCTAssertTrue(history.undo(in: &d)); XCTAssertGreaterThan(try pixel(d, x: 80, y: 74)[0], 250)
        XCTAssertTrue(history.redo(in: &d))
        let reopened = try JSONDecoder().decode(DrawingDocument.self, from: JSONEncoder().encode(d))
        let other = try MetalCanvasRenderer(view: MTKView(frame: .zero)); try await other.synchronize(reopened.strokes, layers: reopened.layers)
        let restored = try await other.renderOffscreen(document: reopened, viewport: Viewport(), width: 256, height: 256)
        XCTAssertEqual(restored, committed)
        d.layers[0].isVisible = false
        XCTAssertEqual(try pixel(d, x: 80, y: 74, transparent: true)[3], 0)
    }
    @MainActor
    func testMergedRasterKeepsOpacityOrientationAndCanBeErasedInMetalAndPNG() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        var d = fixture(); d.layers[0].opacity = 0.4; d.layers[1].opacity = 0.6
        let p = StrokeSample(point: Point(x: 30, y: 25), pressure: 1, altitude: 1, azimuth: 0, time: 2)
        d.strokes.append(InkStroke(brush: InkBrush(width: 8), symmetry: d.symmetry, samples: [p], layerID: d.activeLayerID, color: InkColor(green: 1)))
        let before = d, service = ExportService()
        let raster = try await service.mergedLayer(d, topID: d.activeLayerID)
        XCTAssertTrue(try LayerManager.mergeDown(d.activeLayerID, raster: raster, in: &d))
        XCTAssertEqual(d.layers.count, 1); XCTAssertTrue(d.strokes.isEmpty)
        for (x, y) in [(80, 64), (30, 25), (30, 103), (5, 5)] {
            let a = try pixel(before, x: x, y: y, transparent: true), b = try pixel(d, x: x, y: y, transparent: true)
            for c in 0..<4 { XCTAssertEqual(Double(a[c]), Double(b[c]), accuracy: 2) }
        }
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero)); try await renderer.synchronize(d.strokes, layers: d.layers)
        let pixels = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        for (x, y) in [(80, 64), (30, 25), (30, 103)] {
            let expected = try pixel(before, x: x, y: y)
            let index = screenIndex(Double(x), Double(y))
            XCTAssertEqual(Double(pixels[index]), Double(expected[2]), accuracy: 4)
            XCTAssertEqual(Double(pixels[index + 1]), Double(expected[1]), accuracy: 4)
            XCTAssertEqual(Double(pixels[index + 2]), Double(expected[0]), accuracy: 4)
        }
        let green = screenIndex(30, 25), flipped = screenIndex(30, 103)
        XCTAssertGreaterThan(Int(pixels[green + 1]) - Int(pixels[green + 2]), 80)
        XCTAssertGreaterThan(pixels[flipped], 240); XCTAssertLessThan(pixels[flipped + 1], 200)
        let erased = InkStroke(brush: InkBrush(width: 12), symmetry: d.symmetry, samples: [p], layerID: d.activeLayerID, operation: .erase)
        d.strokes = [erased]; try await renderer.synchronize(d.strokes, layers: d.layers)
        let cleared = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        XCTAssertGreaterThan(cleared[green], 250); XCTAssertGreaterThan(cleared[green + 1], 250); XCTAssertGreaterThan(cleared[green + 2], 250)
        XCTAssertEqual(try pixel(d, x: 30, y: 25, transparent: true)[3], 0)
        let thumb = try await service.layerThumbnail(d, id: d.activeLayerID)
        XCTAssertNotNil(UIImage(data: thumb))
    }
    func testEyedropperSamplesVisibleCompositeWhitePaperAndErasedAreas() throws {
        var d = fixture(); d.layers[1].opacity = 0.5
        let purple = try PNGExporter.sample(document: d, point: Point(x: 80, y: 64))
        XCTAssertEqual(purple.red, 0.5, accuracy: 0.02); XCTAssertEqual(purple.blue, 0.5, accuracy: 0.02)
        d.layers[1].isVisible = false
        XCTAssertEqual(try PNGExporter.sample(document: d, point: Point(x: 80, y: 64)).hex, "#0000FF")
        XCTAssertEqual(try PNGExporter.sample(document: d, point: Point(x: 1, y: 1)).hex, "#FFFFFF")
        XCTAssertThrowsError(try PNGExporter.sample(document: d, point: Point(x: -1, y: 10)))
        d.layers[1].isVisible = true; d.layers[1].opacity = 1
        let p = StrokeSample(point: Point(x: 80, y: 64), pressure: 1, altitude: 1, azimuth: 0, time: 2)
        d.strokes.append(InkStroke(brush: InkBrush(width: 10), symmetry: d.symmetry, samples: [p], layerID: d.activeLayerID, operation: .erase))
        XCTAssertEqual(try PNGExporter.sample(document: d, point: p.point).hex, "#0000FF")
    }
    func testSoftEraserRemovesPartialAlphaAndDuplicateRetainsItsAppearance() throws {
        var d = fixture(); d.layers[0].isVisible = false
        var brush = BrushPreset.softShader.makeBrush(); brush.width = 20; brush.opacity = 0.5
        let p = StrokeSample(point: Point(x: 80, y: 64), pressure: 1, altitude: 1, azimuth: 0, time: 2)
        d.strokes.append(InkStroke(brush: brush, symmetry: d.symmetry, samples: [p], layerID: d.activeLayerID, operation: .erase))
        let alpha = try pixel(d, x: 80, y: 64, transparent: true)[3]
        XCTAssertGreaterThan(alpha, 115); XCTAssertLessThan(alpha, 145)
        let source = d.activeLayerID; _ = try LayerManager.duplicate(source, in: &d)
        if let i = d.layers.firstIndex(where: { $0.id == source }) { d.layers[i].isVisible = false }
        XCTAssertEqual(try pixel(d, x: 80, y: 64, transparent: true)[3], alpha)
    }
}
