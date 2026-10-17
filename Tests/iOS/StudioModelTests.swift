import XCTest
@testable import Ornamentalist

@MainActor
final class StudioModelTests: XCTestCase {
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
