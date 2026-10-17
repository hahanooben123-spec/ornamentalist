import XCTest
@testable import OrnamentalistCore

final class DocumentRepositoryTests: XCTestCase {
    func testSaveReopenStaleWriteAndBackupRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentRepository(directory: directory)
        var document = DrawingDocument()
        document.title = "First version"
        try await store.save(document, generation: 1)
        document.title = "Second version"
        try await store.save(document, generation: 2)
        var stale = document; stale.title = "Stale"
        try await store.save(stale, generation: 1)
        let (opened, recovered) = try await store.open(document.id)
        XCTAssertEqual(opened.title, "Second version")
        XCTAssertFalse(recovered)
        // Simulate a damaged primary; the previous complete drawing must survive.
        let primary = directory.appendingPathComponent(document.id.uuidString + ".mandala")
        try Data("broken JSON".utf8).write(to: primary)
        let (backup, usedBackup) = try await store.open(document.id)
        XCTAssertTrue(usedBackup)
        XCTAssertEqual(backup.title, "First version")
        let list = try await store.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.id, document.id)
    }
    func testBadFileDoesNotHideOtherDrawings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentRepository(directory: directory)
        let good = DrawingDocument(), badID = UUID()
        try await store.save(good, generation: 1)
        let bad = directory.appendingPathComponent(badID.uuidString + ".mandala")
        try Data("invalid".utf8).write(to: bad)
        let summaries = try await store.list()
        XCTAssertEqual(Set(summaries.map(\.id)), Set([good.id, badID]))
    }
    func testUnfinishedStrokeRecoveredFromNewestJournalAndPrimaryWinsAfterSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentRepository(directory: directory)
        var d = DrawingDocument()
        try await store.save(d, generation: 1)
        let p = StrokeSample(point: Point(x: 25, y: 40), pressure: 0.5, altitude: 1, azimuth: 0, time: 1)
        d.strokes = [InkStroke(samples: [p])]
        try await store.checkpoint(d, generation: 2)
        let (recovered, usedJournal) = try await store.open(d.id)
        XCTAssertTrue(usedJournal)
        XCTAssertEqual(recovered.strokes, d.strokes)
        XCTAssertEqual(recovered.storageRevision, 2)
        d.title = "Saved newer version"
        try await store.save(d, generation: 3)
        // Reintroduce an older journal to simulate a crash around journal cleanup.
        var stale = recovered; stale.storageRevision = 2
        try JSONEncoder().encode(stale).write(to: directory.appendingPathComponent(d.id.uuidString + ".journal"))
        let (latest, fallback) = try await store.open(d.id)
        XCTAssertFalse(fallback)
        XCTAssertEqual(latest.title, "Saved newer version")
    }
    func testNativeExportImportKeepsEditableStrokesWithoutOverwritingOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentRepository(directory: directory)
        var d = DrawingDocument()
        d.title = "My ornament"
        d.strokes = [InkStroke(samples: [StrokeSample(point: Point(x: 40, y: 90), pressure: 1, altitude: 1, azimuth: 0, time: 1)])]
        try await store.save(d, generation: 1)
        let url = try await store.exportProject(d)
        let imported = try await store.importProject(at: url)
        XCTAssertNotEqual(imported.id, d.id)
        XCTAssertEqual(imported.strokes, d.strokes)
        XCTAssertEqual(imported.title, d.title)
        try await store.save(imported, generation: 2)
        let list = try await store.list()
        XCTAssertEqual(list.count, 2)
    }
}
