import XCTest
@testable import OrnamentalistCore

final class DocumentRepositoryTests: XCTestCase {
    func testAppendLineageSkipsPrefixScanAndStructuralChangeStillSavesExactly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentRepository(directory: directory)
        let lineage = UUID()
        let sample = StrokeSample(point: Point(x: 30, y: 40), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        var drawing = DrawingDocument(); drawing.strokes = [InkStroke(samples: [sample])]
        try await store.save(drawing, generation: 1, appendLineage: lineage)
        drawing.strokes.append(InkStroke(samples: [sample]))
        try await store.autosave(drawing, generation: 2, appendLineage: lineage)
        let comparisons = await store.prefixComparisons
        XCTAssertEqual(comparisons, 0)
        let restart = DocumentRepository(directory: directory)
        let appended = try await restart.open(drawing.id)
        XCTAssertEqual(appended.0.strokes, drawing.strokes)
        // A structural edit retains the ID but changes existing ink.
        drawing.strokes[0].samples[0].point.x = 100
        try await store.autosave(drawing, generation: 3, appendLineage: UUID())
        let scanned = await store.prefixComparisons
        XCTAssertGreaterThan(scanned, 0)
        let reopened = try await DocumentRepository(directory: directory).open(drawing.id)
        XCTAssertEqual(reopened.0.strokes, drawing.strokes)
        XCTAssertEqual(reopened.0.storageRevision, 3)
    }

    func testCorruptJournalWarnsAndKeepsRecoveryFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentRepository(directory: directory)
        let drawing = DrawingDocument()
        try await store.save(drawing, generation: 1)
        let journal = directory.appendingPathComponent(drawing.id.uuidString + ".journal")
        let damaged = Data("unreadable recovery".utf8)
        try damaged.write(to: journal)
        let opened = try await store.open(drawing.id)
        XCTAssertTrue(opened.1)
        XCTAssertEqual(opened.0.id, drawing.id)
        let warning = await store.recoveryWarning(for: drawing.id)
        XCTAssertNotNil(warning)
        XCTAssertEqual(try Data(contentsOf: journal), damaged)
    }

    func testCompressionChecksIntegrityBoundsAndLegacyJSON() throws {
        let original = Data(String(repeating: "editable drawing samples ", count: 4000).utf8)
        let packed = try DrawingStorageCodec.pack(original)
        XCTAssertTrue(packed.starts(with: DrawingStorageCodec.magic))
        XCTAssertLessThan(packed.count, original.count / 4)
        XCTAssertEqual(try DrawingStorageCodec.unpack(packed), original)
        let legacy = Data("{\"version\":1}".utf8)
        XCTAssertEqual(try DrawingStorageCodec.unpack(legacy), legacy)
        var corrupted = packed; corrupted[16] ^= 1
        XCTAssertThrowsError(try DrawingStorageCodec.unpack(corrupted))
        var oversized = packed
        oversized.replaceSubrange(8..<16, with: repeatElement(UInt8(255), count: 8))
        XCTAssertThrowsError(try DrawingStorageCodec.unpack(oversized))
        var truncatedSize = packed; truncatedSize[8] ^= 1
        XCTAssertThrowsError(try DrawingStorageCodec.unpack(truncatedSize))
        XCTAssertThrowsError(try DrawingStorageCodec.unpack(Data(packed.dropLast(8))))
    }

    func testIncrementalAutosaveReconstructsExactInkAfterPrimaryCorruption() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentRepository(directory: directory)
        var drawing = DrawingDocument()
        for line in 0..<20 {
            let samples = (0..<300).map { i in
                StrokeSample(point: Point(x: Double(i), y: Double(line * 4)), pressure: 0.5,
                             altitude: 1, azimuth: 0, time: Double(i))
            }
            drawing.strokes.append(InkStroke(samples: samples))
        }
        try await store.save(drawing, generation: 1)
        let primary = directory.appendingPathComponent(drawing.id.uuidString + ".mandala")
        let initial = try Data(contentsOf: primary)
        XCTAssertTrue(initial.starts(with: DrawingStorageCodec.magic))
        drawing.strokes.append(InkStroke(samples: [StrokeSample(point: Point(x: 10, y: 20), pressure: 1,
                                                               altitude: 1, azimuth: 0, time: 1)]))
        drawing.title = "Latest title"
        try await store.autosave(drawing, generation: 2)
        XCTAssertEqual(try Data(contentsOf: primary), initial, "Autosave must not rewrite the full primary")
        let journalBytes = await store.lastCheckpointBytes
        XCTAssertLessThan(journalBytes, initial.count)
        let restarted = DocumentRepository(directory: directory)
        let (opened, recovered) = try await restarted.open(drawing.id)
        XCTAssertTrue(recovered); XCTAssertEqual(opened.strokes, drawing.strokes)
        XCTAssertEqual(opened.title, drawing.title)
        try Data("corrupt primary".utf8).write(to: primary)
        let recovery = DocumentRepository(directory: directory)
        let (repaired, _) = try await recovery.open(drawing.id)
        XCTAssertEqual(repaired.strokes, drawing.strokes)
        XCTAssertEqual(repaired.storageRevision, 2)
        try await recovery.save(repaired, generation: 3)
        let (saved, usedRecovery) = try await recovery.open(drawing.id)
        XCTAssertFalse(usedRecovery); XCTAssertEqual(saved.strokes, drawing.strokes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(drawing.id.uuidString + ".journalbase").path))
    }

    func testLegacyUncompressedPrimaryStillOpens() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var drawing = DrawingDocument(); drawing.version = 14
        try JSONEncoder().encode(drawing).write(to: directory.appendingPathComponent(drawing.id.uuidString + ".mandala"))
        let (opened, _) = try await DocumentRepository(directory: directory).open(drawing.id)
        XCTAssertEqual(opened, drawing)
    }
    func testOpeningAnOlderProjectDoesNotChangeRecentProjectOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentRepository(directory: directory)
        var older = DrawingDocument(), newer = DrawingDocument()
        older.modified = Date(timeIntervalSince1970: 100)
        newer.modified = Date(timeIntervalSince1970: 200)
        try await store.save(older, generation: 1)
        try await store.save(newer, generation: 1)
        let (opened, _) = try await store.open(older.id)
        try await store.save(opened, generation: 2)
        let projects = try await store.list()
        XCTAssertEqual(projects.map(\.id), [newer.id, older.id])
        XCTAssertEqual(projects.last?.modified, older.modified)
    }

    func testDeletingProjectRemovesRecoveryCopiesAndRejectsLateWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentRepository(directory: directory)
        let drawing = DrawingDocument(), keep = DrawingDocument()
        try await store.save(drawing, generation: 1)
        try await store.save(drawing, generation: 2)
        try await store.checkpoint(drawing, generation: 3)
        try await store.storeThumbnail(Data([1, 2]), id: drawing.id, generation: 3)
        try await store.save(keep, generation: 1)
        try await store.delete(drawing.id)
        for suffix in ["mandala", "backup", "journal", "index", "png"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(drawing.id.uuidString + "." + suffix).path))
        }
        // The marker also protects against work completing after app restart.
        let reopened = DocumentRepository(directory: directory)
        try await reopened.save(drawing, generation: 4)
        try await reopened.checkpoint(drawing, generation: 5)
        try await reopened.storeThumbnail(Data([3]), id: drawing.id, generation: 5)
        let projects = try await reopened.list()
        XCTAssertEqual(projects.map(\.id), [keep.id])
        do { _ = try await reopened.open(drawing.id); XCTFail("Deleted project reopened") }
        catch DocumentError.invalidData { }
    }

    func testOversizedIndexFallsBackToSavedDrawing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentRepository(directory: directory)
        var drawing = DrawingDocument()
        drawing.title = "Saved drawing"
        try await store.save(drawing, generation: 1)
        let index = directory.appendingPathComponent(drawing.id.uuidString + ".index")
        var corrupted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        corrupted["title"] = String(repeating: "x", count: 32 * 1024)
        try JSONSerialization.data(withJSONObject: corrupted).write(to: index)
        let summaries = try await store.list()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.title, drawing.title)
        let (reopened, _) = try await store.open(drawing.id)
        XCTAssertEqual(reopened.title, drawing.title)
    }

    func testPreviewStampRejectsLegacyAndStaleImagesAndSurvivesRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentRepository(directory: directory)
        var drawing = DrawingDocument(); try await store.save(drawing, generation: 1)
        let image = Data([1, 2, 3])
        try image.write(to: directory.appendingPathComponent(drawing.id.uuidString + ".png"))
        let legacy = try await store.list(); XCTAssertNil(legacy.first?.thumbnail)
        try await store.storeThumbnail(image, id: drawing.id, generation: 1)
        let restarted = try await DocumentRepository(directory: directory).list()
        XCTAssertEqual(restarted.first?.thumbnail, image)
        drawing.modified = drawing.modified.addingTimeInterval(1)
        try await store.save(drawing, generation: 2)
        let stale = try await store.list(); XCTAssertNil(stale.first?.thumbnail)
        try await store.storeThumbnail(image, id: drawing.id, generation: 2)
        let fresh = try await store.list(); XCTAssertEqual(fresh.first?.thumbnail, image)
    }
    func testLateThumbnailCannotReplaceANewerSavedRevision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentRepository(directory: directory)
        var drawing = DrawingDocument()
        try await store.save(drawing, generation: 1)
        let oldPreview = Data([1, 2]), latestPreview = Data([3, 4])
        try await store.storeThumbnail(oldPreview, id: drawing.id, generation: 1)
        drawing.title = "Renamed while preview was rendering"
        try await store.save(drawing, generation: 2)
        try await store.storeThumbnail(Data([9]), id: drawing.id, generation: 1)
        let afterStale = try await store.list()
        XCTAssertEqual(afterStale.first?.thumbnail, oldPreview)
        XCTAssertEqual(afterStale.first?.title, drawing.title)
        try await store.storeThumbnail(latestPreview, id: drawing.id, generation: 2)
        let afterLatest = try await store.list()
        XCTAssertEqual(afterLatest.first?.thumbnail, latestPreview)
    }

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
