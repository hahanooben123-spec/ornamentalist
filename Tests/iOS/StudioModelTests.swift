import XCTest
@testable import Ornamentalist

@MainActor
final class StudioModelTests: XCTestCase {
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
