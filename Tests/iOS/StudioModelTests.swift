import XCTest
import UIKit
import MetalKit
@testable import Ornamentalist

@MainActor
final class StudioModelTests: XCTestCase {
    func testQuickBrushSettingsRememberPresetsAndFreezeDuringStroke() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Ornamentalist-brush-test-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let model = StudioModel(repository: DocumentRepository(directory: folder), preferences: preferences)
        await model.create()
        model.setInputWidth(42); model.setInputOpacity(0.35)
        let fineliner = try XCTUnwrap(model.document?.brush)
        model.setBrush(.airbrush); model.setInputWidth(95); model.setInputOpacity(0.12)
        let airbrush = try XCTUnwrap(model.document?.brush)
        model.setBrush(.fineliner); XCTAssertEqual(model.document?.brush, fineliner)
        model.selectTool(.eraser); model.setInputWidth(66); model.setInputOpacity(0.45)
        XCTAssertEqual(model.inputBrush.width, 66); XCTAssertEqual(model.document?.brush, fineliner)
        model.setDrawing(true); model.setInputWidth(20); model.setInputOpacity(1)
        XCTAssertEqual(model.inputBrush.width, 66); XCTAssertEqual(model.inputBrush.opacity, 0.45)
        model.setDrawing(false); model.selectTool(.brush); model.setBrush(.airbrush)
        XCTAssertEqual(model.document?.brush, airbrush)
        let saved = await model.saveNow(); XCTAssertTrue(saved)
        let reopened = StudioModel(repository: DocumentRepository(directory: folder), preferences: preferences)
        await reopened.open(try XCTUnwrap(model.document?.id))
        XCTAssertEqual(reopened.document?.brush, airbrush)
        reopened.setBrush(.fineliner); XCTAssertEqual(reopened.document?.brush, fineliner)
    }

    func testSizePreviewUsesCanvasScaleWithoutModelRevisions() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudioModel(repository: DocumentRepository(directory: folder)); await model.create()
        model.setWidth(100)
        let view = PencilCanvasView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600); view.layoutIfNeeded()
        let before = model.generation
        model.brushPreviewRequested?(true)
        let cursors = (view.layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        let cursor = try XCTUnwrap(cursors.last)
        XCTAssertFalse(cursor.isHidden)
        XCTAssertEqual(try XCTUnwrap(cursor.path).boundingBoxOfPath.width, 100 * 600 / 2048 * 0.92, accuracy: 0.001)
        view.frame.size = CGSize(width: 400, height: 300); view.setNeedsLayout(); view.layoutIfNeeded()
        XCTAssertEqual(try XCTUnwrap(cursor.path).boundingBoxOfPath.width, 100 * 300 / 2048 * 0.92, accuracy: 0.001)
        XCTAssertEqual(model.generation, before)
        model.selectTool(.eyedropper); view.synchronize(); XCTAssertTrue(cursor.isHidden)
        let taps = (view.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
        XCTAssertEqual(Set(taps.map(\.numberOfTouchesRequired)), Set([2, 3]))
        XCTAssertTrue(taps.allSatisfy { $0.numberOfTapsRequired == 1 && !$0.cancelsTouchesInView })
    }
    func testDuplicateMergeUndoAndEyedropperTools() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DocumentRepository(directory: folder)
        var d = DrawingDocument(); d.size = Point(x: 128, y: 128)
        d.symmetry = SymmetryConfiguration(repetitions: 1, center: Point(x: 64, y: 64))
        let p = StrokeSample(point: Point(x: 30, y: 25), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        d.strokes = [InkStroke(brush: InkBrush(width: 20), symmetry: d.symmetry, samples: [p], color: InkColor(green: 1))]
        try await repository.save(d, generation: 1)
        let model = StudioModel(repository: repository); await model.open(d.id)
        model.selectTool(.eraser); model.setEraserWidth(45); model.setSoftEraser(true)
        XCTAssertEqual(model.eraserBrush.width, 45); XCTAssertTrue(model.eraserBrush.usesStamps)
        model.setDrawing(true); model.selectTool(.eyedropper); model.duplicateLayer(d.activeLayerID)
        XCTAssertEqual(model.tool, .eraser); XCTAssertEqual(model.document?.layers.count, 1)
        model.setDrawing(false); model.duplicateLayer(d.activeLayerID)
        let copyID = try XCTUnwrap(model.document?.activeLayerID)
        XCTAssertEqual(model.document?.layers.count, 2)
        await model.mergeLayerDown(copyID)
        XCTAssertEqual(model.document?.layers.count, 1); XCTAssertNotNil(model.document?.layers[0].raster)
        XCTAssertEqual(model.usedSamples, 0)
        model.undo(); XCTAssertEqual(model.document?.layers.count, 2); XCTAssertEqual(model.usedSamples, 2)
        model.redo(); XCTAssertEqual(model.document?.layers.count, 1)
        model.selectTool(.eyedropper); await model.pickColor(at: p.point)
        XCTAssertEqual(model.document?.color.hex, "#00FF00"); XCTAssertEqual(model.tool, .brush)
        let saved = await model.saveNow(); XCTAssertTrue(saved)
        let (opened, _) = try await repository.open(d.id)
        XCTAssertNotNil(opened.layers[0].raster)
    }

    func testLayerOpacityDragIsOneUndoAndColorChangesRespectActiveStroke() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudioModel(repository: DocumentRepository(directory: folder)); await model.create()
        let id = try XCTUnwrap(model.document?.activeLayerID)
        model.beginLayerOpacityEdit()
        model.setLayerOpacity(id, value: 0.8); model.setLayerOpacity(id, value: 0.6); model.setLayerOpacity(id, value: 0.4)
        model.finishLayerOpacityEdit()
        XCTAssertEqual(model.document?.activeLayer?.opacity, 0.4)
        model.undo(); XCTAssertEqual(model.document?.activeLayer?.opacity, 1); XCTAssertFalse(model.canUndo)
        model.redo(); XCTAssertEqual(model.document?.activeLayer?.opacity, 0.4)
        let red = InkColor(red: 1)
        model.setColor(red); model.setBrush(.softShader)
        XCTAssertEqual(model.document?.color, red)
        model.setDrawing(true); model.setColor(InkColor(blue: 1)); model.setLayerOpacity(id, value: 0.9)
        XCTAssertEqual(model.document?.color, red); XCTAssertEqual(model.document?.activeLayer?.opacity, 0.4)
        model.setDrawing(false)
        for i in 0..<20 { model.setColor(InkColor(red: Double(i) / 20)) }
        XCTAssertEqual(model.document?.recentColors.count, 12)
        let saved = await model.saveNow(); XCTAssertTrue(saved)
    }

    func testBrushChangesFreezeDuringInputAndSaveWithoutChangingOldInk() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DocumentRepository(directory: folder), model = StudioModel(repository: DocumentRepository(directory: folder))
        await model.create()
        let id = try XCTUnwrap(model.document?.id)
        model.setBrush(.dotShader); model.setOpacity(0.4); model.setSpacing(0.6); model.setDensity(0.8)
        let brush = try XCTUnwrap(model.document?.brush)
        model.setDrawing(true)
        model.setBrush(.airbrush); model.setWidth(100); model.setOpacity(1); model.setSpacing(2); model.setDensity(0.2)
        XCTAssertEqual(model.document?.brush, brush)
        model.setDrawing(false)
        let p = StrokeSample(point: Point(x: 100, y: 100), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        let ink = InkStroke(brush: brush, samples: [p])
        model.append(ink); model.setBrush(.softShader)
        XCTAssertEqual(model.document?.strokes, [ink])
        let saved = await model.saveNow(); XCTAssertTrue(saved)
        let (reopened, _) = try await repository.open(id)
        XCTAssertEqual(reopened.brush.preset, .softShader); XCTAssertEqual(reopened.strokes, [ink])
        model.setBrush(.fineliner); model.setOpacity(0.2)
        XCTAssertEqual(model.document?.brush.opacity, 0.2)
        XCTAssertEqual(model.document?.strokes, [ink])
    }

    func testImmediateUndoCancelsPendingCanvasPreparationWithoutBlockingInput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudioModel(repository: DocumentRepository(directory: folder))
        await model.create(); model.addLayer()
        let layerID = try XCTUnwrap(model.document?.activeLayerID)
        let s = StrokeSample(point: Point(x: 50, y: 70), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        model.append(InkStroke(samples: [s], layerID: layerID))
        let view = PencilCanvasView(model: model)
        view.synchronize()
        model.undo()
        view.synchronize()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(model.document?.strokes.isEmpty == true)
        XCTAssertFalse(model.isPreparing)
        XCTAssertTrue(model.canDraw)
        withExtendedLifetime(view) {}
    }

    func testLayerEditsAreFrozenDuringStrokeAndLockBlocksDrawing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudioModel(repository: DocumentRepository(directory: folder))
        await model.create(); model.addLayer()
        let id = try XCTUnwrap(model.document?.activeLayerID)
        model.setDrawing(true)
        model.deleteLayer(id); model.toggleLayerVisibility(id); model.toggleLayerLock(id); model.setMirror(true)
        XCTAssertEqual(model.document?.layers.count, 2)
        XCTAssertFalse(model.document?.symmetry.mirror ?? true)
        XCTAssertTrue(model.document?.canDrawOnActiveLayer == true)
        model.setDrawing(false); model.toggleLayerLock(id)
        XCTAssertFalse(model.canDraw)
        model.undo(); XCTAssertTrue(model.canDraw)
        model.setMirror(true)
        let s = StrokeSample(point: Point(x: 100, y: 120), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        let ink = InkStroke(symmetry: try XCTUnwrap(model.document?.symmetry), samples: [s], layerID: id)
        model.append(ink); model.deleteLayer(id)
        XCTAssertEqual(model.usedSamples, 0)
        model.undo()
        XCTAssertEqual(model.usedSamples, 1)
        XCTAssertEqual(model.document?.strokes, [ink])
        XCTAssertEqual(model.document?.activeLayerID, id)
        let saved = await model.saveNow()
        XCTAssertTrue(saved)
    }

    func testShowcaseUsesValidReopenableDrawings() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DocumentRepository(directory: folder)
        try await StudioShowcase.seed(repository: repository)
        let projects = try await repository.list()
        XCTAssertEqual(Set(projects.map(\.title)), Set(["Solstice", "Quiet orbit", "Petal study"]))
        for project in projects {
            XCTAssertNotNil(project.thumbnail)
            let (drawing, recovered) = try await repository.open(project.id)
            XCTAssertFalse(recovered)
            XCTAssertFalse(drawing.strokes.isEmpty)
        }
    }

    func testCloseLocksUndoRedoAndSettingsUntilExactSnapshotIsSaved() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DocumentRepository(directory: folder, saveDelayNanoseconds: 100_000_000)
        let model = StudioModel(repository: repository)
        await model.create()
        let id = try XCTUnwrap(model.document?.id)
        let sample = StrokeSample(point: Point(x: 30, y: 40), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        let stroke = InkStroke(samples: [sample])
        model.append(stroke)
        let generation = model.generation
        let closing = Task { await model.close() }
        for _ in 0..<100 where !model.busy { await Task.yield() }
        XCTAssertTrue(model.busy)
        model.undo(); model.redo(); model.setWidth(20); model.setRepetitions(64)
        XCTAssertEqual(model.generation, generation)
        await closing.value
        XCTAssertNil(model.document)
        let (saved, _) = try await repository.open(id)
        XCTAssertEqual(saved.strokes, [stroke])
        XCTAssertEqual(saved.brush.width, 5)
        XCTAssertEqual(saved.symmetry.repetitions, 8)
    }
    func testCanvasCheckpointContainsConfirmedActiveInk() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DocumentRepository(directory: folder)
        let model = StudioModel(repository: repository)
        await model.create()
        let id = try XCTUnwrap(model.document?.id)
        let p = StrokeSample(point: Point(x: 15, y: 40), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        let active = InkStroke(samples: [p])
        model.captureActiveStroke = { active }
        model.setDrawing(true)
        await model.checkpointActiveInk()
        XCTAssertTrue(model.document?.strokes.isEmpty == true)
        let (recovered, usedJournal) = try await repository.open(id)
        XCTAssertTrue(usedJournal)
        XCTAssertEqual(recovered.strokes, [active])
        model.setDrawing(false)
    }
    func testCanceledFingerCheckpointDoesNotReappearAfterSuccessfulSave() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DocumentRepository(directory: folder)
        let model = StudioModel(repository: repository)
        await model.create()
        let id = try XCTUnwrap(model.document?.id)
        let p = StrokeSample(point: Point(x: 15, y: 40), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        let tentative = InkStroke(samples: [p])
        model.captureActiveStroke = { tentative }; model.setDrawing(true)
        await model.checkpointActiveInk()
        model.captureActiveStroke = { nil }
        model.discardActiveCheckpoint()
        _ = await model.saveNow()
        let (reopened, _) = try await repository.open(id)
        XCTAssertTrue(reopened.strokes.isEmpty)
    }
}
