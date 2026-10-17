import XCTest
import MetalKit
import UIKit
@testable import Ornamentalist

final class ExportAndMetalTests: XCTestCase {
    private func drawing() -> DrawingDocument {
        var d = DrawingDocument()
        d.size = Point(x: 128, y: 128)
        d.symmetry = SymmetryConfiguration(repetitions: 8, center: Point(x: 64, y: 64))
        let sample = StrokeSample(point: Point(x: 96, y: 64), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        d.strokes = [InkStroke(brush: InkBrush(width: 8), symmetry: d.symmetry, samples: [sample])]
        return d
    }
    func testPNGDimensionsTransparencyAndRadialCopies() throws {
        for transparent in [true, false] {
            let data = try PNGExporter.data(document: drawing(), transparent: transparent)
            let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
            XCTAssertEqual(image.width, 128); XCTAssertEqual(image.height, 128)
            var pixels = [UInt8](repeating: 0, count: 128*128*4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 128, height: 128,
                    bitsPerComponent: 8, bytesPerRow: 128*4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 128))
            }
            for (x,y) in [(96,64), (64,96), (32,64), (64,32), (87,87), (41,41)] {
                let i = (y*128+x)*4
                XCTAssertLessThan(pixels[i], 10, "Copy missing at \(x),\(y)")
                XCTAssertGreaterThan(pixels[i+3], 245)
            }
            let corner = (5*128+5)*4
            XCTAssertEqual(pixels[corner+3], transparent ? 0 : 255)
            if !transparent { XCTAssertEqual(pixels[corner], 255) }
        }
    }
    @MainActor
    func testRuntimeMetalShadersCompileAndLiveMeshCanCommit() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this simulator host") }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 512, height: 512))
        let renderer = try MetalCanvasRenderer(view: view)
        let document = drawing(), stroke = document.strokes[0]
        renderer.begin()
        try renderer.append(StrokeGeometry.stableAddition(samples: stroke.samples, brush: stroke.brush))
        try renderer.commit(stroke)
        try await renderer.synchronize(document.strokes)
        // Creation validates Swift/Metal uniform declarations and the pipeline.
        // Visible latency and drawable output still require the device checklist.
        XCTAssertNotNil(view.device)
    }
    @MainActor
    func testActualMetalPixelsTrackAsymmetricStrokeThroughZoomPanRotation() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        var d = DrawingDocument()
        d.size = Point(x: 128, y: 128)
        d.symmetry = SymmetryConfiguration(repetitions: 1, center: Point(x: 64, y: 64))
        let samples = [(20.0, 25.0), (20.0, 45.0), (45.0, 45.0)].enumerated().map {
            StrokeSample(point: Point(x: $0.element.0, y: $0.element.1), pressure: 1,
                         altitude: 1, azimuth: 0, time: Double($0.offset))
        }
        let stroke = InkStroke(brush: InkBrush(width: 6, stabilization: 0), symmetry: d.symmetry, samples: samples)
        d.strokes = [stroke]
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
        try await renderer.synchronize(d.strokes)
        for angle in [0.0, Double.pi/2, -0.4] {
            let viewport = Viewport(zoom: 1.1, rotation: angle, pan: Point(x: 5, y: -7))
            let pixels = try await renderer.renderOffscreen(document: d, viewport: viewport, width: 256, height: 256, guides: true)
            for p in [Point(x: 20, y: 29), Point(x: 39, y: 45)] {
                // Independent expected screen coordinates, not Matrix.apply/inverse.
                let x = (p.x-64)*1.84*1.1, y = (p.y-64)*1.84*1.1
                let sx = Int((133 + cos(angle)*x - sin(angle)*y).rounded())
                let sy = Int((121 + sin(angle)*x + cos(angle)*y).rounded())
                let i = (sy*256+sx)*4
                XCTAssertLessThan(pixels[i], 20)
                XCTAssertLessThan(pixels[i+1], 20)
                XCTAssertLessThan(pixels[i+2], 20)
            }
        }
        let png = try PNGExporter.data(document: d, transparent: false)
        let image = try XCTUnwrap(UIImage(data: png)?.cgImage)
        for p in [Point(x: 20, y: 29), Point(x: 39, y: 45)] {
            XCTAssertLessThan(try pixel(image, x: Int(p.x), y: Int(p.y))[0], 20)
        }
        // A vertical flip would put ink here; the asymmetric export must stay white.
        XCTAssertGreaterThan(try pixel(image, x: 20, y: 99)[0], 240)
    }
    @MainActor
    func testLivePredictedPixelsDisappearWithoutChangingCommittedInk() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        var d = DrawingDocument(); d.size = Point(x: 128, y: 128)
        d.symmetry = SymmetryConfiguration(repetitions: 1, center: Point(x: 64, y: 64))
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
        var session = StrokeSession(brush: InkBrush(width: 6, stabilization: 0), symmetry: d.symmetry, existingSamples: 0, existingVertices: 0)
        renderer.begin()
        for (i,y) in [25.0, 35.0].enumerated() {
            try renderer.append(session.append(StrokeSample(point: Point(x: 20, y: y), pressure: 1, altitude: 1, azimuth: 0, time: Double(i))))
        }
        let prediction = StrokeSample(point: Point(x: 60, y: 60), pressure: 1, altitude: 1, azimuth: 0, time: 2)
        let live = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256,
                              active: session.stroke, preview: session.preview(predictions: [prediction]))
        let position = Viewport().matrix(viewSize: Point(x: 256, y: 256), canvasSize: d.size).apply(prediction.point)
        let index = (Int(position.y.rounded())*256+Int(position.x.rounded()))*4
        XCTAssertLessThan(live[index], 20)
        try renderer.commit(session.stroke); d.strokes = [session.stroke]
        let committed = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        XCTAssertGreaterThan(committed[index], 240)
        XCTAssertEqual(d.strokes[0].samples.count, 2)
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}
