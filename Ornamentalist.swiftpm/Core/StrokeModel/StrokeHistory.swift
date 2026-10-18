import Foundation

/// Stroke operations retain their layer and symmetry. Structural layer edits
/// retain copy-on-write content snapshots, without changing brush/view settings.
struct StrokeHistory: Sendable {
    private struct Content: Codable, Sendable {
        var layers: [DrawingLayer]
        var activeLayerID: UUID
        var strokes: [InkStroke]
        init(_ document: DrawingDocument) {
            layers = document.layers; activeLayerID = document.activeLayerID; strokes = document.strokes
        }
        func apply(to document: inout DrawingDocument) {
            document.layers = layers; document.activeLayerID = activeLayerID; document.strokes = strokes
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
    var redoStrokes: [InkStroke] { redoEdits.compactMap {
        guard let edit = decoded($0), case .stroke(let stroke) = edit else { return nil }
        return stroke
    } }
    var canRedo: Bool { !redoEdits.isEmpty }
    func canUndo(in document: DrawingDocument) -> Bool { !undoEdits.isEmpty || !document.strokes.isEmpty }

    mutating func recordNewStroke(_ stroke: InkStroke, in document: inout DrawingDocument) {
        document.strokes.append(stroke)
        undoEdits.append(.stroke(stroke)); redoEdits.removeAll()
        revision += 1
    }
    mutating func recordLayerChange(from before: DrawingDocument, to after: DrawingDocument) {
        undoEdits.append(.layers(Content(before), Content(after)))
        redoEdits.removeAll()
        revision += 1
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
            return copy
        }.value
    }
    @discardableResult
    mutating func undo(in document: inout DrawingDocument) -> Bool {
        let recorded: Edit
        if let entry = undoEdits.popLast() { recorded = entry }
        else if let stroke = document.strokes.last { recorded = .stroke(stroke) }
        else { return false }
        guard let edit = decoded(recorded) else { undoEdits.append(recorded); return false }
        switch edit {
        case .stroke(let stroke):
            document.strokes.removeAll { $0.id == stroke.id }
        case .layers(let before, _): before.apply(to: &document)
        case .archived: undoEdits.append(recorded); return false
        }
        redoEdits.append(recorded); revision += 1
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
        case .layers(_, let after): after.apply(to: &document)
        case .archived: redoEdits.append(recorded); return false
        }
        undoEdits.append(recorded); revision += 1
        return true
    }
}
