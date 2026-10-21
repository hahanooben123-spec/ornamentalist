import Foundation
import Compression
import CryptoKit

/// Lossless local storage envelope. JSON project export remains portable.
/// The declared decoded size is bounded before allocating; one extra byte
/// detects truncated output from compression_decode_buffer's buffer-size limit.
enum DrawingStorageCodec {
    static let magic = Data("ORNZ0001".utf8)
    static func pack(_ data: Data) throws -> Data {
        guard data.count <= DrawingLimits.encodedBytes else { throw DocumentError.oversized }
        guard data.count >= 1024 else { return data }
        var destination = Data(count: data.count)
        let capacity = destination.count
        let count = destination.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                compression_encode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard count > 0, count + 48 < data.count else { return data }
        var result = magic
        let length = UInt64(data.count)
        for shift in stride(from: 0, to: 64, by: 8) { result.append(UInt8(truncatingIfNeeded: length >> shift)) }
        result.append(contentsOf: SHA256.hash(data: data))
        result.append(destination.prefix(count))
        return result
    }
    static func unpack(_ data: Data) throws -> Data {
        guard data.count <= DrawingLimits.encodedBytes else { throw DocumentError.oversized }
        guard data.starts(with: magic) else { return data }
        guard data.count > 48 else { throw DocumentError.invalidData }
        let length = data[8..<16].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        guard length > 0, length <= UInt64(DrawingLimits.encodedBytes) else { throw DocumentError.oversized }
        var output = Data(count: Int(length) + 1)
        let capacity = output.count
        let decoded = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!.advanced(by: 48), source.count - 48, nil, COMPRESSION_LZFSE)
            }
        }
        guard decoded == Int(length) else { throw DocumentError.invalidData }
        output.count = decoded
        guard Data(SHA256.hash(data: output)) == data[16..<48] else { throw DocumentError.invalidData }
        return output
    }
}

private struct DrawingJournal: Codable {
    let baseRevision: Int
    let baseStrokeCount: Int
    var document: DrawingDocument
}

struct ProjectSummary: Identifiable, Sendable {
    let id: UUID
    let title: String
    let modified: Date
    let strokeCount: Int
    var thumbnail: Data? = nil
}

private struct ThumbnailStamp: Codable {
    let modified: Date
    let strokeCount: Int
}

private struct ProjectIndex: Codable {
    let id: UUID
    let title: String
    let modified: Date
    let strokeCount: Int
    let primaryBytes: Int
    let primaryModified: Date
}

actor DocumentRepository {
    private let directory: URL
    private var savedGenerations: [UUID: Int] = [:]
    private let saveDelayNanoseconds: UInt64
    private var primarySnapshot: DrawingDocument?
    private var primaryAppendLineage: UUID?
    private var recoveryWarnings: [UUID: String] = [:]
    func recoveryWarning(for id: UUID) -> String? { recoveryWarnings[id] }
    private(set) var prefixComparisons = 0
    private var journalBaseRevisions: [UUID: Int] = [:]
    private(set) var lastCheckpointBytes = 0

    init(directory: URL? = nil, saveDelayNanoseconds: UInt64 = 0) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MandalaDrawings", isDirectory: true)
        self.saveDelayNanoseconds = saveDelayNanoseconds
    }
    private func file(_ id: UUID, suffix: String = "mandala") -> URL {
        directory.appendingPathComponent(id.uuidString + "." + suffix)
    }
    private func isDeleted(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: file(id, suffix: "deleted").path)
    }
    func delete(_ id: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Persist deletion first: a delayed save or leftover recovery copy must
        // never bring a deleted project back into the gallery after restart.
        try Data().write(to: file(id, suffix: "deleted"), options: .atomic)
        savedGenerations.removeValue(forKey: id)
        if primarySnapshot?.id == id { primarySnapshot = nil }
        journalBaseRevisions.removeValue(forKey: id)
        for suffix in ["mandala", "backup", "journal", "journalbase", "index", "png", "preview"] {
            let target = file(id, suffix: suffix)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
        }
    }
    private func decode(_ url: URL) throws -> DrawingDocument {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= DrawingLimits.encodedBytes else {
            throw DocumentError.oversized
        }
        let d = try JSONDecoder().decode(DrawingDocument.self, from: DrawingStorageCodec.unpack(Data(contentsOf: url)))
        try d.validate()
        return d
    }
    private func encoded(_ document: DrawingDocument, generation: Int) throws -> Data {
        var d = document; d.version = 19; d.storageRevision = generation
        try d.validate()
        let data = try JSONEncoder().encode(d)
        guard data.count <= DrawingLimits.encodedBytes else { throw DocumentError.oversized }
        return data
    }
    func save(_ document: DrawingDocument, generation: Int, appendLineage: UUID? = nil) async throws {
        if saveDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: saveDelayNanoseconds) }
        guard !isDeleted(document.id) else { return }
        if let saved = savedGenerations[document.id], generation < saved { return }
        let data = try DrawingStorageCodec.pack(encoded(document, generation: generation))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = file(document.id)
        if FileManager.default.fileExists(atPath: target.path), (try? decode(target)) != nil {
            try Data(contentsOf: target).write(to: file(document.id, suffix: "backup"), options: .atomic)
        }
        try data.write(to: target, options: .atomic)
        savedGenerations[document.id] = generation
        var saved = document; saved.storageRevision = generation; primarySnapshot = saved; primaryAppendLineage = appendLineage
        // Revisions make a crash between primary write and journal deletion safe.
        try? FileManager.default.removeItem(at: file(document.id, suffix: "journal"))
        try? FileManager.default.removeItem(at: file(document.id, suffix: "journalbase"))
        journalBaseRevisions.removeValue(forKey: document.id)
        try? writeIndex(document, bytes: data.count)
    }
    /// A model-owned lineage survives only appending immutable strokes. Other callers
    /// retain the defensive deep comparison; the token is never loaded from a file.
    private func matchesPrefix(_ base: DrawingDocument, _ document: DrawingDocument, appendLineage: UUID?) -> Bool {
        guard base.id == document.id, document.strokes.count >= base.strokes.count else { return false }
        if let appendLineage, appendLineage == primaryAppendLineage,
           primarySnapshot?.id == base.id, primarySnapshot?.storageRevision == base.storageRevision { return true }
        prefixComparisons += 1
        let matches = zip(base.strokes, document.strokes).allSatisfy { $0 == $1 }
        if matches, let appendLineage {
            primarySnapshot = base; primaryAppendLineage = appendLineage
        }
        return matches
    }
    /// Atomic rolling journal, including confirmed input from an unfinished stroke.
    func autosave(_ document: DrawingDocument, generation: Int, appendLineage: UUID? = nil) async throws {
        let base = primarySnapshot?.id == document.id ? primarySnapshot : (try? decode(file(document.id)))
        if let base, document.strokes.count >= base.strokes.count,
           document.strokes.count - base.strokes.count < 64,
           matchesPrefix(base, document, appendLineage: appendLineage),
           document.strokes.dropFirst(base.strokes.count).reduce(0, { $0 + $1.samples.count }) < 20_000 {
            primarySnapshot = base
            try checkpoint(document, generation: generation, appendLineage: appendLineage)
        } else { try await save(document, generation: generation, appendLineage: appendLineage) }
    }
    func checkpoint(_ document: DrawingDocument, generation: Int, appendLineage: UUID? = nil) throws {
        guard !isDeleted(document.id) else { return }
        if let saved = savedGenerations[document.id], generation < saved { return }
        let base: DrawingDocument?
        if primarySnapshot?.id == document.id { base = primarySnapshot }
        else { base = try? decode(file(document.id)); primarySnapshot = base; primaryAppendLineage = nil }
        let data: Data
        if let base, document.strokes.count >= base.strokes.count,
           matchesPrefix(base, document, appendLineage: appendLineage) {
            if journalBaseRevisions[document.id] != base.storageRevision {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(contentsOf: file(document.id)).write(to: file(document.id, suffix: "journalbase"), options: .atomic)
                journalBaseRevisions[document.id] = base.storageRevision
            }
            var delta = document; delta.storageRevision = generation
            delta.strokes = Array(document.strokes.dropFirst(base.strokes.count))
            try delta.validate()
            let count = base.strokes.reduce(0) { $0 + $1.samples.count } + delta.strokes.reduce(0) { $0 + $1.samples.count }
            guard count <= DrawingLimits.sampleCount else { throw DocumentError.sampleLimit }
            data = try DrawingStorageCodec.pack(JSONEncoder().encode(DrawingJournal(baseRevision: base.storageRevision,
                baseStrokeCount: base.strokes.count, document: delta)))
        } else {
            data = try DrawingStorageCodec.pack(encoded(document, generation: generation))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(document.id, suffix: "journal"), options: .atomic)
        lastCheckpointBytes = data.count
        savedGenerations[document.id] = generation
    }
    func open(_ id: UUID) throws -> (DrawingDocument, Bool) {
        recoveryWarnings[id] = nil
        guard !isDeleted(id) else { throw DocumentError.invalidData }
        let primary = try? decode(file(id))
        let journalExists = FileManager.default.fileExists(atPath: file(id, suffix: "journal").path)
        let journal = try? readJournal(id, primary: primary)
        let validPrimary = primary.flatMap { $0.id == id ? $0 : nil }
        let validJournal = journal.flatMap { $0.id == id ? $0 : nil }
        if let journal = validJournal, journal.storageRevision > (validPrimary?.storageRevision ?? -1) {
            savedGenerations[id] = max(savedGenerations[id] ?? 0, journal.storageRevision)
            return (journal, true)
        }
        if let primary = validPrimary {
            if journalExists && journal == nil {
                recoveryWarnings[id] = "The latest recovery journal could not be read. The last valid saved drawing was opened. Newer changes may be missing. The recovery files have been kept."
            }
            primarySnapshot = primary; primaryAppendLineage = nil
            savedGenerations[id] = max(savedGenerations[id] ?? 0, primary.storageRevision)
            return (primary, journalExists && journal == nil)
        }
        let backup = try decode(file(id, suffix: "backup"))
        guard backup.id == id else { throw DocumentError.invalidData }
        savedGenerations[id] = max(savedGenerations[id] ?? 0, backup.storageRevision)
        return (backup, true)
    }
    private func readJournal(_ id: UUID, primary: DrawingDocument?) throws -> DrawingDocument {
        let url = file(id, suffix: "journal")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= DrawingLimits.encodedBytes else { throw DocumentError.oversized }
        let bytes = try DrawingStorageCodec.unpack(Data(contentsOf: url))
        if let journal = try? JSONDecoder().decode(DrawingJournal.self, from: bytes) {
            let base = primary?.storageRevision == journal.baseRevision ? primary : (try? decode(file(id, suffix: "journalbase")))
            guard let base, base.id == id, journal.document.id == id,
                  base.storageRevision == journal.baseRevision, base.strokes.count == journal.baseStrokeCount else {
                throw DocumentError.invalidData
            }
            var result = journal.document
            result.strokes = base.strokes + result.strokes
            try result.validate()
            return result
        }
        let document = try JSONDecoder().decode(DrawingDocument.self, from: bytes)
        try document.validate()
        return document
    }
    private func writeIndex(_ d: DrawingDocument, bytes: Int) throws {
        let a = try FileManager.default.attributesOfItem(atPath: file(d.id).path)
        let index = ProjectIndex(id: d.id, title: d.title, modified: d.modified, strokeCount: d.strokes.count,
                                 primaryBytes: bytes, primaryModified: a[.modificationDate] as? Date ?? .distantPast)
        try JSONEncoder().encode(index).write(to: file(d.id, suffix: "index"), options: .atomic)
    }
    func storeThumbnail(_ data: Data, id: UUID, generation: Int, modified: Date? = nil, strokeCount: Int? = nil) throws {
        guard !isDeleted(id), savedGenerations[id] == generation, data.count <= 1024*1024 else { return }
        let stamp: ThumbnailStamp
        if let modified, let strokeCount { stamp = ThumbnailStamp(modified: modified, strokeCount: strokeCount) }
        else {
            let (document, _) = try open(id)
            guard savedGenerations[id] == generation else { return }
            stamp = ThumbnailStamp(modified: document.modified, strokeCount: document.strokes.count)
        }
        try data.write(to: file(id, suffix: "png"), options: .atomic)
        try JSONEncoder().encode(stamp).write(to: file(id, suffix: "preview"), options: .atomic)
    }
    private func thumbnail(_ id: UUID, modified: Date, strokeCount: Int) -> Data? {
        // Legacy/unmatched thumbnails are regenerated. A white PNG from an old
        // save must not be treated as a permanently valid project preview.
        let metadata = file(id, suffix: "preview")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: metadata.path),
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 4096,
              let bytes = try? Data(contentsOf: metadata), let stamp = try? JSONDecoder().decode(ThumbnailStamp.self, from: bytes),
              stamp.modified == modified, stamp.strokeCount == strokeCount else { return nil }
        let url = file(id, suffix: "png")
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              ((a[.size] as? NSNumber)?.intValue ?? Int.max) <= 1024*1024 else { return nil }
        return try? Data(contentsOf: url)
    }
    func list() throws -> [ProjectSummary] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let ids = Set(urls.filter { ["mandala", "backup", "journal"].contains($0.pathExtension) }
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }).filter { !isDeleted($0) }
        return ids.map { id in
            if !FileManager.default.fileExists(atPath: file(id, suffix: "journal").path),
               let bytes = indexData(id),
               let index = try? JSONDecoder().decode(ProjectIndex.self, from: bytes), index.id == id,
               index.title.count <= 200, (0...20_000).contains(index.strokeCount),
               index.modified.timeIntervalSince1970.isFinite,
               let a = try? FileManager.default.attributesOfItem(atPath: file(id).path),
               (a[.size] as? NSNumber)?.intValue == index.primaryBytes,
               (a[.modificationDate] as? Date) == index.primaryModified {
                return ProjectSummary(id: id, title: index.title, modified: index.modified,
                                      strokeCount: index.strokeCount, thumbnail: thumbnail(id, modified: index.modified, strokeCount: index.strokeCount))
            }
            if let (d, _) = try? open(id) {
                return ProjectSummary(id: id, title: d.title, modified: d.modified,
                                      strokeCount: d.strokes.count, thumbnail: thumbnail(id, modified: d.modified, strokeCount: d.strokes.count))
            }
            return ProjectSummary(id: id, title: "Unreadable drawing · \(id.uuidString.prefix(8))",
                                  modified: .distantPast, strokeCount: 0)
        }.sorted { $0.modified > $1.modified }
    }
    private func indexData(_ id: UUID) -> Data? {
        // Indexes are replaceable metadata. Never allocate an unbounded file at launch.
        let url = file(id, suffix: "index")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size <= 16 * 1024 else { return nil }
        return try? Data(contentsOf: url)
    }
    func importProject(at url: URL) throws -> DrawingDocument {
        #if os(iOS) || os(macOS)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #endif
        var d = try decode(url)
        d.id = UUID() // Import is a new project, never an overwrite.
        d.version = 19; d.storageRevision = 0; d.modified = Date()
        return d
    }
    func exportProject(_ document: DrawingDocument) throws -> URL {
        let data = try encoded(document, generation: document.storageRevision)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OrnamentalistProjects", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Ornamentalist-\(document.id.uuidString).ornamentalist.json")
        try data.write(to: url, options: .atomic)
        return url
    }
}
