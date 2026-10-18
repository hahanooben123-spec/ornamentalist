import XCTest
import MetalKit
import UIKit
@testable import Ornamentalist

final class ExportAndMetalTests: XCTestCase {
    @MainActor
    func testDotFalloffAndSoftEdgesMatchPNGForInkAndEraser() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        for operation in [StrokeOperation.ink, .erase] {
            var document = DrawingDocument(); document.size = Point(x: 128, y: 128)
            document.symmetry = SymmetryConfiguration(repetitions: 1, center: Point(x: 64, y: 64))
            var brush = BrushPreset.dots.makeBrush()
            brush.width = 16; brush.spacing = 2; brush.falloff = 0.5; brush.edgeSoftness = 0.5; brush.tiltShading = 0
            let samples = [20.0, 116].enumerated().map { i, x in
                StrokeSample(point: Point(x: x, y: 64), pressure: 1, altitude: .pi / 2, azimuth: 0, time: Double(i))
            }
            let stroke = InkStroke(brush: brush, symmetry: document.symmetry, samples: samples, operation: operation)
            if operation == .erase {
                var p = samples[0]; p.point = Point(x: 64, y: 64)
                document.strokes.append(InkStroke(brush: InkBrush(width: 160), symmetry: document.symmetry, samples: [p]))
            }
            document.strokes.append(stroke)
            let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
            try await renderer.synchronize(document.strokes)
            let pixels = try await renderer.renderOffscreen(document: document, viewport: Viewport(), width: 256, height: 256)
            let image = try XCTUnwrap(UIImage(data: PNGExporter.data(document: document, transparent: false))?.cgImage)
            for dab in BrushGeometry.dabs(stroke) {
                let png = try pixel(image, x: Int(dab.center.x), y: 64)
                let expected = 255 * (operation == .ink ? 1 - dab.opacity : dab.opacity)
                XCTAssertEqual(Double(png[0]), expected, accuracy: 3)
                let x = Int((dab.center.x - 64) * 1.84 + 128)
                XCTAssertEqual(Double(pixels[(128 * 256 + x) * 4 + 2]), Double(png[0]), accuracy: 4)
            }
        }
    }
    @MainActor
    func testSoftOpacityHasGradualToneInMetalAndPNG() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        for preset in [BrushPreset.softShader, .airbrush] {
            let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
            var previousTone = -1
            for opacity in [0.0, 0.05, 0.1, 0.2, 0.4] {
                var document = DrawingDocument(); document.size = Point(x: 128, y: 128)
                document.symmetry = SymmetryConfiguration(repetitions: 1, center: Point(x: 64, y: 64))
                var brush = preset.makeBrush(); brush.width = 40; brush.opacity = opacity; brush.tiltShading = 0
                let samples = [20.0, 100].enumerated().map { i, x in
                    StrokeSample(point: Point(x: x, y: 64), pressure: 1, altitude: .pi / 2, azimuth: 0, time: Double(i))
                }
                document.strokes = [InkStroke(brush: brush, symmetry: document.symmetry, samples: samples)]
                try await renderer.synchronize(document.strokes)
                let pixels = try await renderer.renderOffscreen(document: document, viewport: Viewport(), width: 256, height: 256)
                let image = try XCTUnwrap(UIImage(data: PNGExporter.data(document: document, transparent: false))?.cgImage)
                let png = try pixel(image, x: 64, y: 64)
                let tone = 255 - Int(png[0])
                XCTAssertGreaterThan(tone, previousTone); previousTone = tone
                XCTAssertEqual(Double(pixels[(128 * 256 + 128) * 4 + 2]), Double(png[0]), accuracy: 6)
                if opacity == 0 { XCTAssertEqual(tone, 0) }
                if opacity == 0.1 { XCTAssertLessThan(tone, 50) }
            }
        }
    }
    @MainActor
    func testColoredLayersApplyGroupOpacityOnceWithLiveInkAndVisibility() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        var d = DrawingDocument(); d.size = Point(x: 128, y: 128)
        d.symmetry = SymmetryConfiguration(repetitions: 1, center: Point(x: 64, y: 64))
        let p = StrokeSample(point: Point(x: 64, y: 64), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        let brush = InkBrush(width: 30)
        let bottom = InkStroke(brush: brush, symmetry: d.symmetry, samples: [p], color: InkColor(blue: 1))
        d.strokes = [bottom]; _ = LayerManager.add(in: &d)
        let top = d.activeLayerID
        d.layers[1].opacity = 0.5
        let a = InkStroke(brush: brush, symmetry: d.symmetry, samples: [p], layerID: top, color: InkColor(red: 1))
        let b = InkStroke(brush: brush, symmetry: d.symmetry, samples: [p], layerID: top, color: InkColor(red: 1))
        d.strokes.append(a)
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero)); try await renderer.synchronize(d.strokes)
        renderer.begin(); try renderer.append(BrushGeometry.mesh(b))
        let live = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256, active: b)
        try renderer.commit(b); d.strokes.append(b)
        let committed = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        let center = (128 * 256 + 128) * 4
        for pixels in [live, committed] {
            XCTAssertEqual(Double(pixels[center]), 127, accuracy: 3) // Blue
            XCTAssertLessThan(pixels[center + 1], 3)
            XCTAssertEqual(Double(pixels[center + 2]), 128, accuracy: 3) // Red, not 191 from per-stroke alpha.
        }
        let png = try XCTUnwrap(UIImage(data: PNGExporter.data(document: d, transparent: true))?.cgImage)
        let rgba = try pixel(png, x: 64, y: 64)
        XCTAssertEqual(Double(rgba[0]), 128, accuracy: 3); XCTAssertEqual(Double(rgba[2]), 127, accuracy: 3)
        d.layers[0].isVisible = false
        let transparent = try XCTUnwrap(UIImage(data: PNGExporter.data(document: d, transparent: true))?.cgImage)
        XCTAssertEqual(Double(try pixel(transparent, x: 64, y: 64)[3]), 128, accuracy: 3)
        d.layers[1].isVisible = false
        let hidden = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        XCTAssertGreaterThan(hidden[center], 250); XCTAssertGreaterThan(hidden[center + 2], 250)
        d.layers[1].isVisible = true; d.layers[1].opacity = 0
        let zero = try XCTUnwrap(UIImage(data: PNGExporter.data(document: d, transparent: true))?.cgImage)
        XCTAssertEqual(try pixel(zero, x: 64, y: 64)[3], 0)
        // Restoring visibility keeps opacity; moving an opaque blue layer above
        // the translucent red layer must cover it, including its live stroke.
        d.layers[0].isVisible = true; d.layers[1].opacity = 0.5
        _ = LayerManager.move(top, up: false, in: &d)
        let moved = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256, active: b)
        XCTAssertGreaterThan(moved[center], 250); XCTAssertLessThan(moved[center + 2], 3)
    }

    @MainActor
    func testEveryPresetUsesItsStoredColorInMetalAndPNG() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
        for preset in BrushPreset.allCases {
            var d = DrawingDocument(); d.size = Point(x: 128, y: 128)
            d.symmetry = SymmetryConfiguration(repetitions: 1, center: Point(x: 64, y: 64))
            let p = StrokeSample(point: Point(x: 64, y: 64), pressure: 1, altitude: 1, azimuth: 0, time: 1)
            var brush = preset.makeBrush(); brush.opacity = 0.4
            let ink = InkStroke(brush: brush, symmetry: d.symmetry, samples: [p], color: InkColor(red: 0.9, green: 0.3, blue: 0.1))
            d.strokes = [ink]; try await renderer.synchronize(d.strokes)
            let pixels = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 128, height: 128)
            var chosen = 0, lowest: UInt8 = 255
            for y in 12..<116 { for x in 12..<116 {
                let i = (y * 128 + x) * 4
                if pixels[i] < lowest { lowest = pixels[i]; chosen = i }
            } }
            XCTAssertGreaterThan(Int(pixels[chosen + 2]) - Int(pixels[chosen]), 2, preset.name)
            let point: Point
            if ink.brush.usesStamps { point = try XCTUnwrap(BrushGeometry.dabs(ink).first).center }
            else { point = p.point }
            let image = try XCTUnwrap(UIImage(data: PNGExporter.data(document: d, transparent: false))?.cgImage)
            var difference = 0
            for y in (Int(point.y) - 1)...(Int(point.y) + 1) {
                for x in (Int(point.x) - 1)...(Int(point.x) + 1) {
                    let rgba = try pixel(image, x: x, y: y)
                    difference = max(difference, Int(rgba[0]) - Int(rgba[2]))
                }
            }
            XCTAssertGreaterThan(difference, 1, preset.name)
        }
    }

    @MainActor
    func testDotBrushHasGapsInLiveMetalReopenedMetalAndMirroredPNG() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        var d = DrawingDocument(); d.size = Point(x: 128, y: 128)
        d.symmetry = SymmetryConfiguration(repetitions: 1, center: Point(x: 64, y: 64), mirror: true)
        var b = BrushPreset.dots.makeBrush(); b.stabilization = 0
        var session = StrokeSession(brush: b, symmetry: d.symmetry, existingSamples: 0, existingVertices: 0)
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero)); renderer.begin()
        for (i, x) in [20.0, 80].enumerated() {
            try renderer.append(session.append(StrokeSample(point: Point(x: x, y: 80), pressure: 1,
                                                            altitude: 1, azimuth: 0, time: Double(i))))
        }
        let live = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256, active: session.stroke)
        try renderer.commit(session.stroke); d.strokes = [session.stroke]
        let committed = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        let reopened = try MetalCanvasRenderer(view: MTKView(frame: .zero)); try await reopened.synchronize(d.strokes)
        let restored = try await reopened.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        XCTAssertEqual(live, committed); XCTAssertEqual(committed, restored)
        let png = try XCTUnwrap(UIImage(data: PNGExporter.data(document: d, transparent: true))?.cgImage)
        for y in [48, 80] {
            for x in [20, 32, 44, 56, 68, 80] {
                let sx = Int((128 + (Double(x) - 64) * 1.84).rounded()), sy = Int((128 + (Double(y) - 64) * 1.84).rounded())
                XCTAssertLessThan(committed[(sy * 256 + sx) * 4], 15)
                XCTAssertGreaterThan(try pixel(png, x: x, y: y)[3], 245)
            }
            XCTAssertEqual(try pixel(png, x: 26, y: y)[3], 0)
        }
    }

    @MainActor
    func testSoftBrushMetalAndPNGHaveMatchingFeatheredOpacity() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        var d = DrawingDocument(); d.size = Point(x: 128, y: 128)
        d.symmetry = SymmetryConfiguration(repetitions: 1, center: Point(x: 64, y: 64))
        var b = BrushPreset.softShader.makeBrush(); b.width = 48; b.opacity = 0.5
        let sample = StrokeSample(point: Point(x: 64, y: 64), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        d.strokes = [InkStroke(brush: b, symmetry: d.symmetry, samples: [sample])]
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero)); try await renderer.synchronize(d.strokes)
        let pixels = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        let png = try XCTUnwrap(UIImage(data: PNGExporter.data(document: d, transparent: true))?.cgImage)
        let center = try pixel(png, x: 64, y: 64)[3], middle = try pixel(png, x: 76, y: 64)[3]
        XCTAssertGreaterThan(center, 115); XCTAssertLessThan(center, 140)
        XCTAssertGreaterThan(middle, 45); XCTAssertLessThan(middle, 80)
        XCTAssertEqual(try pixel(png, x: 90, y: 64)[3], 0)
        for x in [64, 70, 76, 82, 90] {
            let sx = Int((128 + (Double(x) - 64) * 1.84).rounded())
            let alpha = try pixel(png, x: x, y: 64)[3]
            XCTAssertEqual(Double(pixels[(128 * 256 + sx) * 4]), 255 - Double(alpha), accuracy: 10)
        }
        d.layers[0].isVisible = false
        let hidden = try XCTUnwrap(UIImage(data: PNGExporter.data(document: d, transparent: true))?.cgImage)
        XCTAssertEqual(try pixel(hidden, x: 64, y: 64)[3], 0)
    }

    @MainActor
    func testEveryBrushProducesMetalAndPNGInk() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
        for preset in BrushPreset.allCases {
            var d = DrawingDocument(); d.size = Point(x: 128, y: 128)
            d.symmetry = SymmetryConfiguration(repetitions: 1, center: Point(x: 64, y: 64))
            let sample = StrokeSample(point: Point(x: 64, y: 64), pressure: 1, altitude: 1, azimuth: 0, time: 1)
            d.strokes = [InkStroke(brush: preset.makeBrush(), symmetry: d.symmetry, samples: [sample])]
            try await renderer.synchronize(d.strokes)
            let pixels = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 128, height: 128)
            // Inspect the paper interior, excluding the dark workspace border.
            var minimum: UInt8 = 255
            for y in 12..<116 {
                for x in 12..<116 { minimum = min(minimum, pixels[(y * 128 + x) * 4]) }
            }
            XCTAssertLessThan(minimum, 253, preset.name)
            let image = try XCTUnwrap(UIImage(data: PNGExporter.data(document: d, transparent: false))?.cgImage)
            XCTAssertEqual(image.width, 128)
        }
    }

    @MainActor
    func testMirrorLiveAndCommittedPixelsAndHiddenLayerPNG() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        var d = DrawingDocument(); d.size = Point(x: 128, y: 128)
        let plain = SymmetryConfiguration(repetitions: 1, center: Point(x: 64, y: 64))
        d.symmetry = SymmetryConfiguration(repetitions: 1, center: plain.center, mirror: true)
        let old = StrokeSample(point: Point(x: 20, y: 25), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        d.strokes = [InkStroke(brush: InkBrush(width: 6), symmetry: plain, samples: [old])]
        d.layers[0].isVisible = false
        _ = LayerManager.add(in: &d)
        let sample = StrokeSample(point: Point(x: 96, y: 80), pressure: 1, altitude: 1, azimuth: 0, time: 2)
        let ink = InkStroke(brush: InkBrush(width: 6), symmetry: d.symmetry, samples: [sample], layerID: d.activeLayerID)
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
        try await renderer.synchronize(d.strokes)
        renderer.begin(); try renderer.append(StrokeGeometry.stableAddition(samples: ink.samples, brush: ink.brush))
        let live = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256, active: ink)
        try renderer.commit(ink); d.strokes.append(ink)
        let committed = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        for pixels in [live, committed] {
            for (x, y) in [(96.0, 80.0), (96, 48)] {
                let sx = Int((128 + (x - 64) * 1.84).rounded())
                let sy = Int((128 + (y - 64) * 1.84).rounded())
                XCTAssertLessThan(pixels[(sy * 256 + sx) * 4], 20)
            }
            let hx = Int((128 + (20.0 - 64) * 1.84).rounded())
            let hy = Int((128 + (25.0 - 64) * 1.84).rounded())
            XCTAssertGreaterThan(pixels[(hy * 256 + hx) * 4], 240)
        }
        let image = try XCTUnwrap(UIImage(data: PNGExporter.data(document: d, transparent: true))?.cgImage)
        XCTAssertGreaterThan(try pixel(image, x: 96, y: 80)[3], 245)
        XCTAssertGreaterThan(try pixel(image, x: 96, y: 48)[3], 245)
        XCTAssertEqual(try pixel(image, x: 20, y: 25)[3], 0)
        // Unhide invalidates scene ordering even when all stroke IDs are unchanged.
        d.layers[0].isVisible = true
        let unhidden = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        let hx = Int((128 + (20.0 - 64) * 1.84).rounded()), hy = Int((128 + (25.0 - 64) * 1.84).rounded())
        XCTAssertLessThan(unhidden[(hy * 256 + hx) * 4], 20)
    }

    @MainActor
    func test64SectorMirrorRenders128Transforms() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        var d = DrawingDocument(); d.size = Point(x: 128, y: 128)
        d.symmetry = SymmetryConfiguration(repetitions: 64, center: Point(x: 64, y: 64), mirror: true)
        let s = StrokeSample(point: Point(x: 100, y: 67), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        d.strokes = [InkStroke(brush: InkBrush(width: 2), symmetry: d.symmetry, samples: [s])]
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
        try await renderer.synchronize(d.strokes)
        let pixels = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        XCTAssertEqual(d.symmetry.instanceCount, 128)
        for y in [67.0, 61] {
            let sx = Int((128 + 36.0 * 1.84).rounded()), sy = Int((128 + (y - 64) * 1.84).rounded())
            XCTAssertLessThan(pixels[(sy * 256 + sx) * 4], 30)
        }
    }

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
        let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
    @MainActor
    func testRendererTimingSampleAtEightAnd64Copies() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        var report: [String] = []
        for repetitions in [8, 64] {
            var d = DrawingDocument(); d.size = Point(x: 128, y: 128)
            d.symmetry = SymmetryConfiguration(repetitions: repetitions, center: Point(x: 64, y: 64))
            for i in 0..<48 {
                var samples: [StrokeSample] = []
                for j in 0..<12 {
                    let x = 70.0 + Double(j)
                    let phase = Double(j) * 0.2
                    let baseline = 32.0 + Double(i % 8)
                    let y = baseline + sin(phase) * 8.0
                    let point = Point(x: x, y: y)
                    let sample = StrokeSample(point: point, pressure: 1, altitude: 1, azimuth: 0, time: Double(j))
                    samples.append(sample)
                }
                d.strokes.append(InkStroke(brush: InkBrush(width: 2, stabilization: 0), symmetry: d.symmetry, samples: samples))
            }
            let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
            try await renderer.synchronize(d.strokes)
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<3 {
                _ = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
            }
            let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000 / 3
            report.append("\(repetitions) copies · 48 source strokes · mean render+readback \(milliseconds) ms · \(renderer.allocatedVertexCount) source vertices")
            XCTAssertLessThanOrEqual(renderer.allocatedVertexCount, DrawingLimits.vertexCount)
        }
        let attachment = XCTAttachment(string: report.joined(separator: "\n") + "\nSimulator timings include readback; they are not physical iPad latency or FPS.")
        attachment.name = "8-and-64-copy-rendering-samples"; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
