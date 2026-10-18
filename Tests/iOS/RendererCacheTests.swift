import XCTest
import MetalKit
@testable import Ornamentalist

final class RendererCacheTests: XCTestCase {
    @MainActor
    func testCompactShadingMatchesExpandedLiveCommitAndReopenAcrossChunks() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        var document = DrawingDocument(); document.size = Point(x: 128, y: 128)
        document.symmetry = SymmetryConfiguration(repetitions: 2, center: Point(x: 64, y: 64), mirror: true)
        var brush = BrushPreset.dotShader.makeBrush()
        brush.width = 20; brush.density = 1; brush.spacing = 0.06; brush.stabilization = 0
        let compact = try MetalCanvasRenderer(view: MTKView(frame: .zero))
        let expanded = try MetalCanvasRenderer(view: MTKView(frame: .zero), compactStamps: false)
        var session = StrokeSession(brush: brush, symmetry: document.symmetry, existingSamples: 0, existingVertices: 0)
        compact.begin(); expanded.begin()
        for i in 0..<3 {
            let addition = try session.append(StrokeSample(point: Point(x: 10 + Double(i) * 50, y: 55), pressure: 0.7,
                altitude: 0.4, azimuth: 0.8, time: Double(i)))
            try compact.append(addition); try expanded.append(addition)
            let a = try await compact.renderOffscreen(document: document, viewport: Viewport(), width: 256, height: 256, active: session.stroke)
            let b = try await expanded.renderOffscreen(document: document, viewport: Viewport(), width: 256, height: 256, active: session.stroke)
            assertPixels(a, b)
        }
        XCTAssertGreaterThan(session.estimatedVertexCount, 8190)
        try compact.commit(session.stroke); try expanded.commit(session.stroke)
        document.strokes.append(session.stroke)
        XCTAssertEqual(compact.allocatedGeometryBytes * 3, expanded.allocatedGeometryBytes)
        let a = try await compact.renderOffscreen(document: document, viewport: Viewport(), width: 256, height: 256)
        let b = try await expanded.renderOffscreen(document: document, viewport: Viewport(), width: 256, height: 256)
        assertPixels(a, b)
        let reopened = try MetalCanvasRenderer(view: MTKView(frame: .zero))
        try await reopened.synchronize(document.strokes)
        let c = try await reopened.renderOffscreen(document: document, viewport: Viewport(), width: 256, height: 256)
        assertPixels(a, c)
        XCTAssertEqual(reopened.allocatedGeometryBytes, compact.allocatedGeometryBytes)
        compact.prune([]); XCTAssertEqual(compact.allocatedGeometryBytes, 0)
    }
    func testLayerPreviewCacheTracksContentRatherThanVisibilityOrOpacity() async throws {
        var d = fixture(); let id = d.activeLayerID
        let service = ExportService()
        let first = try await service.layerThumbnail(d, id: id)
        d.layers[1].isVisible = false; d.layers[1].opacity = 0.2
        let hidden = try await service.layerThumbnail(d, id: id)
        XCTAssertEqual(first, hidden)
        let warmCount = await service.layerPreviewRenders
        XCTAssertEqual(warmCount, 1)
        let p = StrokeSample(point: Point(x: 64, y: 64), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        d.strokes.append(InkStroke(brush: InkBrush(width: 12), symmetry: d.symmetry,
            samples: [p], layerID: id, color: InkColor(green: 1)))
        let changed = try await service.layerThumbnail(d, id: id)
        XCTAssertNotEqual(changed, first)
        let changedCount = await service.layerPreviewRenders
        XCTAssertEqual(changedCount, 2)
    }

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
            _ = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
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
            for operation in [StrokeOperation.ink, .erase] {
                var brush = BrushPreset.softShader.makeBrush(); brush.width = 12
                var session = StrokeSession(brush: brush, symmetry: d.symmetry, existingSamples: 0, existingVertices: 0,
                    layerID: d.activeLayerID, operation: operation)
                renderer.begin(); cached = []; reference = []
                for frame in 0..<7 {
                    let point = Point(x: 74 + Double(frame), y: 43 + Double(frame) * 0.3)
                    try renderer.append(session.append(StrokeSample(point: point, pressure: 1, altitude: 1, azimuth: 0, time: Double(frame))))
                    for original in [false, true] {
                        let start = ProcessInfo.processInfo.systemUptime
                        _ = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 512, height: 512,
                            active: session.stroke, reference: original)
                        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                        if frame > 0 {
                            if original { reference.append(elapsed) } else { cached.append(elapsed) }
                        }
                    }
                }
                let liveA = cached.sorted()[cached.count / 2], liveB = reference.sorted()[reference.count / 2]
                report.append("\(copies) sectors + Mirror, live \(operation), 512px: cached median \(liveA) ms; reference median \(liveB) ms; ratio \(liveB / max(0.001, liveA))x")
                renderer.cancel()
            }
        }
        let attachment = XCTAttachment(string: report.joined(separator: "\n") + "\nSimulator measurements include GPU wait and pixel readback. Not physical iPad latency/FPS.")
        attachment.name = "cached-versus-reference-rendering"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    func testMultipleStaticLayersCompositeInOrderAroundTheActiveLayer() async throws {
        var d = DrawingDocument(); d.size = Point(x: 128, y: 128)
        d.symmetry = SymmetryConfiguration(repetitions: 8, center: Point(x: 64, y: 64), mirror: true)
        for _ in 0..<6 { _ = LayerManager.add(in: &d) }
        d.activeLayerID = d.layers[3].id
        for i in d.layers.indices {
            d.layers[i].opacity = 0.4
            let point = Point(x: 65 + Double(i), y: 35 + Double(i))
            let sample = StrokeSample(point: point, pressure: 1, altitude: 1, azimuth: 0, time: 1)
            let color = InkColor(red: Double(i % 3) * 0.4, green: 0.3, blue: Double(i % 2) * 0.8)
            d.strokes.append(InkStroke(brush: InkBrush(width: 18), symmetry: d.symmetry, samples: [sample], layerID: d.layers[i].id, color: color))
        }
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero)); try await renderer.synchronize(d.strokes, layers: d.layers)
        let cached = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        let reference = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256, reference: true)
        assertPixels(cached, reference)
    }

    @MainActor
    func testConcurrentReadbacksKeepTheirOwnViewportAndPredictionState() async throws {
        let d = fixture()
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
        try await renderer.synchronize(d.strokes, layers: d.layers)
        let moved = Viewport(zoom: 1.6, rotation: -0.2)
        async let first = renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        async let second = renderer.renderOffscreen(document: d, viewport: moved, width: 256, height: 256)
        let images = try await (first, second)
        let referenceA = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256, reference: true)
        let referenceB = try await renderer.renderOffscreen(document: d, viewport: moved, width: 256, height: 256, reference: true)
        assertPixels(images.0, referenceA); assertPixels(images.1, referenceB)
    }

    @MainActor
    func testLongSoftStrokesPaintConfirmedVerticesOnceAndCancelRestoresTheBase() async throws {
        var d = fixture()
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
        try await renderer.synchronize(d.strokes, layers: d.layers)
        let base = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
        for operation in [StrokeOperation.ink, .erase] {
            var brush = BrushPreset.softShader.makeBrush(); brush.width = 12; brush.opacity = 0.35
            var session = StrokeSession(brush: brush, symmetry: d.symmetry, existingSamples: 0,
                existingVertices: 0, layerID: d.activeLayerID, operation: operation)
            renderer.begin()
            var expected = renderer.liveConfirmedVertexDraws
            var current: [UInt8] = []
            for i in 0..<20 {
                let p = Point(x: 69 + Double(i) * 0.7, y: 39 + sin(Double(i) * 0.4) * 5)
                let addition = try session.append(StrokeSample(point: p, pressure: 1, altitude: 1, azimuth: 0, time: Double(i)))
                try renderer.append(addition); expected += addition.count
                current = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256, active: session.stroke)
                XCTAssertEqual(renderer.liveConfirmedVertexDraws, expected)
                _ = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256, active: session.stroke)
                XCTAssertEqual(renderer.liveConfirmedVertexDraws, expected)
            }
            let reference = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256,
                active: session.stroke, reference: true)
            assertPixels(current, reference)
            if operation == .ink {
                renderer.cancel()
                let canceled = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
                XCTAssertEqual(canceled, base)
            } else {
                try renderer.commit(session.stroke); d.strokes.append(session.stroke)
                let committed = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256)
                assertPixels(committed, current)
                let replay = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256, reference: true)
                assertPixels(committed, replay)
            }
        }
    }

    @MainActor
    func testIncrementalStippleCrossesSealedGPUChunksWithoutRepaintingThePrefix() async throws {
        let d = fixture()
        var brush = BrushPreset.stippleDense.makeBrush(); brush.width = 12; brush.spacing = 0.06; brush.density = 1
        var session = StrokeSession(brush: brush, symmetry: d.symmetry, existingSamples: 0,
            existingVertices: 0, layerID: d.activeLayerID)
        let renderer = try MetalCanvasRenderer(view: MTKView(frame: .zero))
        try await renderer.synchronize(d.strokes, layers: d.layers); renderer.begin()
        var expected = 0
        var image: [UInt8] = []
        for batch in 0..<2 {
            for i in (batch * 30)..<((batch + 1) * 30) {
                let angle = Double(i) * 0.2
                let p = Point(x: 78 + cos(angle) * 12, y: 48 + sin(angle) * 12)
                let added = try session.append(StrokeSample(point: p, pressure: 1, altitude: 1, azimuth: 0, time: Double(i)))
                try renderer.append(added); expected += added.count
            }
            image = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256, active: session.stroke)
            XCTAssertEqual(renderer.liveConfirmedVertexDraws, expected)
        }
        XCTAssertGreaterThan(expected, 8190 * 2)
        let reference = try await renderer.renderOffscreen(document: d, viewport: Viewport(), width: 256, height: 256,
            active: session.stroke, reference: true)
        assertPixels(image, reference)
        try renderer.commit(session.stroke)
        var committedDocument = d; committedDocument.strokes.append(session.stroke)
        let committed = try await renderer.renderOffscreen(document: committedDocument, viewport: Viewport(), width: 256, height: 256)
        assertPixels(committed, reference)
    }
}
