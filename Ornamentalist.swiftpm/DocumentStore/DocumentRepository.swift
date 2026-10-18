import Foundation

struct ProjectSummary: Identifiable, Sendable {
    let id: UUID
    let title: String
    let modified: Date
    let strokeCount: Int
    var thumbnail: Data? = nil
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

    init(directory: URL? = nil, saveDelayNanoseconds: UInt64 = 0) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MandalaDrawings", isDirectory: true)
        self.saveDelayNanoseconds = saveDelayNanoseconds
    }
    private func file(_ id: UUID, suffix: String = "mandala") -> URL {
        directory.appendingPathComponent(id.uuidString + "." + suffix)
    }
    private func decode(_ url: URL) throws -> DrawingDocument {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= DrawingLimits.encodedBytes else {
            throw DocumentError.oversized
        }
        let d = try JSONDecoder().decode(DrawingDocument.self, from: Data(contentsOf: url))
        try d.validate()
        return d
    }
    private func encoded(_ document: DrawingDocument, generation: Int) throws -> Data {
        var d = document; d.version = 7; d.storageRevision = generation
        try d.validate()
        let data = try JSONEncoder().encode(d)
        guard data.count <= DrawingLimits.encodedBytes else { throw DocumentError.oversized }
        return data
    }
    func save(_ document: DrawingDocument, generation: Int) async throws {
        if saveDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: saveDelayNanoseconds) }
        if let saved = savedGenerations[document.id], generation < saved { return }
        let data = try encoded(document, generation: generation)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = file(document.id)
        if FileManager.default.fileExists(atPath: target.path), (try? decode(target)) != nil {
            try Data(contentsOf: target).write(to: file(document.id, suffix: "backup"), options: .atomic)
        }
        try data.write(to: target, options: .atomic)
        savedGenerations[document.id] = generation
        // Revisions make a crash between primary write and journal deletion safe.
        try? FileManager.default.removeItem(at: file(document.id, suffix: "journal"))
        try? writeIndex(document, bytes: data.count)
    }
    /// Atomic rolling journal, including confirmed input from an unfinished stroke.
    func checkpoint(_ document: DrawingDocument, generation: Int) throws {
        if let saved = savedGenerations[document.id], generation < saved { return }
        let data = try encoded(document, generation: generation)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(document.id, suffix: "journal"), options: .atomic)
        savedGenerations[document.id] = generation
    }
    func open(_ id: UUID) throws -> (DrawingDocument, Bool) {
        let primary = try? decode(file(id))
        let journal = try? decode(file(id, suffix: "journal"))
        let validPrimary = primary.flatMap { $0.id == id ? $0 : nil }
        let validJournal = journal.flatMap { $0.id == id ? $0 : nil }
        if let journal = validJournal, journal.storageRevision > (validPrimary?.storageRevision ?? -1) {
            savedGenerations[id] = max(savedGenerations[id] ?? 0, journal.storageRevision)
            return (journal, true)
        }
        if let primary = validPrimary {
            savedGenerations[id] = max(savedGenerations[id] ?? 0, primary.storageRevision)
            return (primary, false)
        }
        let backup = try decode(file(id, suffix: "backup"))
        guard backup.id == id else { throw DocumentError.invalidData }
        savedGenerations[id] = max(savedGenerations[id] ?? 0, backup.storageRevision)
        return (backup, true)
    }
    private func writeIndex(_ d: DrawingDocument, bytes: Int) throws {
        let a = try FileManager.default.attributesOfItem(atPath: file(d.id).path)
        let index = ProjectIndex(id: d.id, title: d.title, modified: d.modified, strokeCount: d.strokes.count,
                                 primaryBytes: bytes, primaryModified: a[.modificationDate] as? Date ?? .distantPast)
        try JSONEncoder().encode(index).write(to: file(d.id, suffix: "index"), options: .atomic)
    }
    func storeThumbnail(_ data: Data, id: UUID, generation: Int) throws {
        guard savedGenerations[id] == generation, data.count <= 1024*1024 else { return }
        try data.write(to: file(id, suffix: "png"), options: .atomic)
    }
    private func thumbnail(_ id: UUID) -> Data? {
        let url = file(id, suffix: "png")
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              ((a[.size] as? NSNumber)?.intValue ?? Int.max) <= 1024*1024 else { return nil }
        return try? Data(contentsOf: url)
    }
    func list() throws -> [ProjectSummary] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let ids = Set(urls.filter { ["mandala", "backup", "journal"].contains($0.pathExtension) }
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
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
                                      strokeCount: index.strokeCount, thumbnail: thumbnail(id))
            }
            if let (d, _) = try? open(id) {
                return ProjectSummary(id: id, title: d.title, modified: d.modified,
                                      strokeCount: d.strokes.count, thumbnail: thumbnail(id))
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
        d.version = 7; d.storageRevision = 0; d.modified = Date()
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
