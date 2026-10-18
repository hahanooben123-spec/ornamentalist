import XCTest
import MetalKit
@testable import Ornamentalist

final class RendererCacheTests: XCTestCase {
    private func fixture(copies: Int = 8) -> DrawingDocument {
        var d = DrawingDocument(); d.size = Point(x: 128, y: 128)
        d.symmetry = SymmetryConfiguration(repetitions: copies, center: Point(x: 64, y: 64), mirror: true)
        _ = LayerManager.add(in: &d); _ = LayerManager.add(in: &d)
        d.activeLayerID = d.layers[1].id; d.layers[1].opacity = 0.65
        for layer in 0..<3 {
            for stroke in 0..<12 {
                var samples: [StrokeSample] = []
                for point in 0..<12 {
                    samples.append(StrokeSample(point: Point(x: 67 + Double(point), y: 30 + Double(stroke * 2 + layer)),
                        pressure: 1, altitude: 1, azimuth: 0, time: Double(point)))
                }
                let color = layer == 0 ? InkColor(blue: 1) : layer == 1 ? InkColor(red: 1) : InkColor(green: 0.6)
                d.strokes.append(InkStroke(brush: InkBrush(width: 2), symmetry: d.symmetry,
                    samples: samples, layerID: d.layers[layer].id, color: color))
            }
        }
        return d
    }

    private func assertPixels(_ cached: [UInt8], _ reference: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(cached.count, reference.count, file: file, line: line)
        let maximum = zip(cached, reference).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
        // Flattening adjacent static layers introduces at most a few 8-bit
        // premultiplied rounding steps, not a change in the artwork geometry.
        XCTAssertLessThanOrEqual(maximum, 3, file: file, line: line)
    }

    @MainActor
    func testWarmLiveInkAndEraserReuseTexturesWithoutReplayingCommittedStrokes() async throws {
        let d = fixture()
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
        try await renderer.synchronize(d.strokes, layers: d.layers)
        _ = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        for operation in [StrokeOperation.ink, .erase] {
            var brush = BrushPreset.softShader.makeBrush(); brush.width = 18; brush.opacity = 0.5
            var session = StrokeSession(brush: brush, symmetry: d.symmetry, existingSamples: 0, existingVertices: 0,
                layerID: d.activeLayerID, color: InkColor(red: 0.2, green: 0.7, blue: 0.4), operation: operation)
            renderer.begin()
            try renderer.append(session.append(StrokeSample(point: Point(x: 76, y: 47), pressure: 1, altitude: 1, azimuth: 0, time: 1)))
            let allocations = renderer.workingTextureAllocations, draws = renderer.committedStrokeDraws
            let groups = renderer.cachedGroupBuilds, layers = renderer.cachedLayerBuilds
            var image: [UInt8] = []
            for _ in 0..<4 {
                image = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256, active: session.stroke)
            }
            XCTAssertEqual(renderer.workingTextureAllocations, allocations)
            XCTAssertEqual(renderer.committedStrokeDraws, draws)
            XCTAssertEqual(renderer.cachedGroupBuilds, groups); XCTAssertEqual(renderer.cachedLayerBuilds, layers)
            let reference = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256,
                active: session.stroke, reference: true)
            assertPixels(image, reference)
            renderer.cancel()
        }
    }

    @MainActor
    func testCommitIsIncrementalAndUndoRedoRestoreTheSamePixels() async throws {
        var d = fixture()
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
        try await renderer.synchronize(d.strokes, layers: d.layers)
        let before = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        var session = StrokeSession(brush: InkBrush(width: 9), symmetry: d.symmetry, existingSamples: 0,
            existingVertices: 0, layerID: d.activeLayerID, operation: .erase)
        renderer.begin()
        try renderer.append(session.append(StrokeSample(point: Point(x: 73, y: 45), pressure: 1, altitude: 1, azimuth: 0, time: 1)))
        let live = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256,
            active: session.stroke, preview: session.preview(predictions: []))
        let draws = renderer.committedStrokeDraws
        try renderer.commit(session.stroke); d.strokes.append(session.stroke)
        let committed = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        XCTAssertEqual(renderer.incrementalLayerUpdates, 1)
        XCTAssertEqual(renderer.committedStrokeDraws - draws, 1)
        XCTAssertEqual(live, committed)
        d.strokes.removeLast(); renderer.prune(d.strokes, layers: d.layers)
        let undone = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        XCTAssertEqual(undone, before)
        d.strokes.append(session.stroke); try await renderer.synchronize(d.strokes, layers: d.layers)
        let redone = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        XCTAssertEqual(redone, committed)
    }

    @MainActor
    func testCacheInvalidatesForNavigationLayerEditsAndMemoryPressure() async throws {
        var d = fixture()
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
        try await renderer.synchronize(d.strokes, layers: d.layers)
        _ = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        let allocations = renderer.workingTextureAllocations
        var viewport = Viewport(); viewport.zoom = 1.4; viewport.rotation = 0.3; viewport.pan = Point(x: 12, y: -7)
        let moved = try await renderer.renderOffscreen(document: d, viewport: viewport, width: 256, height: 256)
        let movedReference = try await renderer.renderOffscreen(document: d, viewport: viewport, width: 256, height: 256, reference: true)
        assertPixels(moved, movedReference)
        XCTAssertEqual(renderer.workingTextureAllocations, allocations)
        d.layers[0].isVisible = false; d.layers[2].opacity = 0.4
        _ = LayerManager.move(d.activeLayerID, up: true, in: &d)
        let edited = try await renderer.renderOffscreen(document: d, viewport: viewport, width: 256, height: 256)
        let editedReference = try await renderer.renderOffscreen(document: d, viewport: viewport, width: 256, height: 256, reference: true)
        assertPixels(edited, editedReference)
        renderer.handleMemoryPressure()
        XCTAssertEqual(renderer.renderCacheBytes, 0)
        let fallback = try await renderer.renderOffscreen(document: d, viewport: viewport, width: 256, height: 256)
        assertPixels(fallback, editedReference)
        XCTAssertEqual(renderer.renderCacheBytes, 0)
        let working = renderer.workingTextureAllocations
        _ = try await renderer.renderOffscreen(document: d, viewport: viewport, width: 256, height: 256)
        XCTAssertEqual(renderer.workingTextureAllocations, working)
        let resized = try await renderer.renderOffscreen(document: d, viewport: viewport, width: 192, height: 256)
        XCTAssertEqual(resized.count, 192 * 256 * 4)
    }

    @MainActor
    func testCachedAndReferenceRenderingTimingSamples() async throws {
        var report: [String] = []
        for copies in [8, 64] {
            let d = fixture(copies: copies)
            let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
            try await renderer.synchronize(d.strokes, layers: d.layers)
            _ = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 512, height: 512)
            var cached: [Double] = [], reference: [Double] = []
            for _ in 0..<6 {
                for original in [false, true] {
                    let start = ProcessInfo.processInfo.systemUptime
                    _ = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 512, height: 512, reference: original)
                    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    if original { reference.append(elapsed) } else { cached.append(elapsed) }
                }
            }
            let a = cached.sorted()[cached.count / 2], b = reference.sorted()[reference.count / 2]
            report.append("\(copies) sectors + Mirror, 36 strokes, 512px: cached median \(a) ms; reference median \(b) ms; ratio \(b / max(0.001, a))x")
        }
        let attachment = XCTAttachment(string: report.joined(separator: "\n") + "\nSimulator measurements include GPU wait and pixel readback. Not physical iPad latency/FPS.")
        attachment.name = "cached-versus-reference-rendering"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
