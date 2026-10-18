import XCTest
import UIKit
import MetalKit
@testable import Ornamentalist

final class EditingToolsNativeTests: XCTestCase {
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
