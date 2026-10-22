import Foundation

/// Stroke operations retain their layer and symmetry. Structural layer edits
/// retain bounded content differences, without changing brush/view settings.
struct StrokeHistory: Sendable {
    private struct PositionedStroke: Codable, Sendable {
        let index: Int
        let stroke: InkStroke
    }
    /// Retain changed strokes only, rather than both complete documents.
    private struct Content: Codable, Sendable {
        var layers: [DrawingLayer]
        var activeLayerID: UUID
        var strokes: [PositionedStroke]
        init(_ document: DrawingDocument, comparedTo other: DrawingDocument) {
            layers = document.layers; activeLayerID = document.activeLayerID
            let existing = Dictionary(uniqueKeysWithValues: other.strokes.map { ($0.id, $0) })
            strokes = document.strokes.enumerated().compactMap { index, stroke in
                existing[stroke.id] == stroke ? nil : PositionedStroke(index: index, stroke: stroke)
            }
        }
        func apply(replacing other: Content, to document: inout DrawingDocument) {
            let replaced = Set((other.strokes + strokes).map { $0.stroke.id })
            document.strokes.removeAll { replaced.contains($0.id) }
            for item in strokes.sorted(by: { $0.index < $1.index }) {
                document.strokes.insert(item.stroke, at: min(item.index, document.strokes.count))
            }
            document.layers = layers; document.activeLayerID = activeLayerID
        }
    }
    private enum Edit: Codable, Sendable {
        case stroke(InkStroke)
        case layers(Content, Content)
        case archived(Data)
    }
    private var undoEdits: [Edit] = []
    private var redoEdits: [Edit] = []
    private(set) var revision = 0
    private var compactedRevision = -1
    private var implicitUndoAllowed = true
    private var memoryBudget: Int
    private var maximumEdits: Int
    init(memoryBudget: Int = 24 * 1024 * 1024, maximumEdits: Int = 100) {
        self.memoryBudget = max(0, memoryBudget); self.maximumEdits = max(0, maximumEdits)
    }
    private func bytes(_ stroke: InkStroke) -> Int {
        512 + stroke.samples.count * MemoryLayout<StrokeSample>.stride + (stroke.selection?.points.count ?? 0) * 16
    }
    private func bytes(_ edit: Edit) -> Int {
        switch edit {
        case .stroke(let stroke): return bytes(stroke)
        case .archived(let data): return data.count
        case .layers(let a, let b):
            return (a.layers + b.layers).reduce(0) { $0 + 256 + ($1.raster?.png.count ?? 0) } +
                (a.strokes + b.strokes).reduce(0) { $0 + bytes($1.stroke) }
        }
    }
    /// Conservative retained-data estimate; shared arrays may cost less in practice.
    var retainedBytes: Int { (undoEdits + redoEdits).reduce(0) { $0 + bytes($1) } }
    mutating func trimForMemoryPressure() {
        memoryBudget = min(memoryBudget, 8 * 1024 * 1024)
        enforceBudget(); revision += 1
    }
    private mutating func enforceBudget() {
        var total = retainedBytes
        while undoEdits.count + redoEdits.count > maximumEdits || total > memoryBudget {
            if !undoEdits.isEmpty {
                total -= bytes(undoEdits.removeFirst()); implicitUndoAllowed = false
            } else if !redoEdits.isEmpty { total -= bytes(redoEdits.removeFirst()) }
            else { break }
        }
    }
    var redoStrokes: [InkStroke] { redoEdits.compactMap {
        guard let edit = decoded($0), case .stroke(let stroke) = edit else { return nil }
        return stroke
    } }
    var canRedo: Bool { !redoEdits.isEmpty }
    func canUndo(in document: DrawingDocument) -> Bool { !undoEdits.isEmpty || (implicitUndoAllowed && !document.strokes.isEmpty) }

    mutating func recordNewStroke(_ stroke: InkStroke, in document: inout DrawingDocument) {
        document.strokes.append(stroke)
        undoEdits.append(.stroke(stroke)); redoEdits.removeAll()
        revision += 1; enforceBudget()
    }
    mutating func recordLayerChange(from before: DrawingDocument, to after: DrawingDocument) {
        undoEdits.append(.layers(Content(before, comparedTo: after), Content(after, comparedTo: before)))
        redoEdits.removeAll()
        revision += 1; enforceBudget()
    }
    private func decoded(_ edit: Edit) -> Edit? {
        if case .archived(let data) = edit {
            return try? JSONDecoder().decode(Edit.self, from: DrawingStorageCodec.unpack(data))
        }
        return edit
    }
    var needsCompaction: Bool {
        revision != compactedRevision && (undoEdits.dropLast(8).contains { if case .layers = $0 { return true }; return false } ||
        redoEdits.dropLast(8).contains { if case .archived = $0 { return false }; return true })
    }
    /// Compress old structural snapshots off the input actor. Ordinary undo
    /// stroke entries share the document's sample arrays and are kept as-is.
    func compacted() async -> StrokeHistory {
        await Task.detached(priority: .utility) {
            var copy = self
            copy.compactedRevision = copy.revision
            func packed(_ edit: Edit) -> Edit {
                guard let data = try? DrawingStorageCodec.pack(JSONEncoder().encode(edit)) else { return edit }
                return .archived(data)
            }
            for i in 0..<max(0, copy.undoEdits.count - 8) {
                if case .layers = copy.undoEdits[i] { copy.undoEdits[i] = packed(copy.undoEdits[i]) }
            }
            for i in 0..<max(0, copy.redoEdits.count - 8) {
                if case .archived = copy.redoEdits[i] { continue }
                copy.redoEdits[i] = packed(copy.redoEdits[i])
            }
            copy.enforceBudget()
            return copy
        }.value
    }
    @discardableResult
    mutating func undo(in document: inout DrawingDocument) -> Bool {
        let recorded: Edit
        if let entry = undoEdits.popLast() { recorded = entry }
        else if implicitUndoAllowed, let stroke = document.strokes.last { recorded = .stroke(stroke) }
        else { return false }
        guard let edit = decoded(recorded) else { undoEdits.append(recorded); return false }
        switch edit {
        case .stroke(let stroke):
            document.strokes.removeAll { $0.id == stroke.id }
        case .layers(let before, let after): before.apply(replacing: after, to: &document)
        case .archived: undoEdits.append(recorded); return false
        }
        redoEdits.append(recorded); revision += 1; enforceBudget()
        return true
    }
    @discardableResult
    mutating func redo(in document: inout DrawingDocument) -> Bool {
        guard let recorded = redoEdits.popLast() else { return false }
        guard let edit = decoded(recorded) else { redoEdits.append(recorded); return false }
        switch edit {
        case .stroke(let stroke):
            guard document.layers.contains(where: { $0.id == stroke.layerID }) else {
                redoEdits.append(recorded); return false
            }
            document.strokes.append(stroke)
        case .layers(let before, let after): after.apply(replacing: before, to: &document)
        case .archived: redoEdits.append(recorded); return false
        }
        undoEdits.append(recorded); revision += 1; enforceBudget()
        return true
    }
}
