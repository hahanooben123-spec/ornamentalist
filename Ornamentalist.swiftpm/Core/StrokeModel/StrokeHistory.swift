import Foundation

/// Stroke operations retain their layer and symmetry. Structural layer edits
/// retain copy-on-write content snapshots, without changing brush/view settings.
struct StrokeHistory {
    private struct Content {
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
    private enum Edit {
        case stroke(InkStroke)
        case layers(Content, Content)
    }
    private var undoEdits: [Edit] = []
    private var redoEdits: [Edit] = []
    var redoStrokes: [InkStroke] { redoEdits.compactMap { if case .stroke(let s) = $0 { return s }; return nil } }
    var canRedo: Bool { !redoEdits.isEmpty }
    func canUndo(in document: DrawingDocument) -> Bool { !undoEdits.isEmpty || !document.strokes.isEmpty }

    mutating func recordNewStroke(_ stroke: InkStroke, in document: inout DrawingDocument) {
        document.strokes.append(stroke)
        undoEdits.append(.stroke(stroke)); redoEdits.removeAll()
    }
    mutating func recordLayerChange(from before: DrawingDocument, to after: DrawingDocument) {
        undoEdits.append(.layers(Content(before), Content(after)))
        redoEdits.removeAll()
    }
    @discardableResult
    mutating func undo(in document: inout DrawingDocument) -> Bool {
        let edit: Edit
        if let recorded = undoEdits.popLast() { edit = recorded }
        else if let stroke = document.strokes.last { edit = .stroke(stroke) }
        else { return false }
        switch edit {
        case .stroke(let stroke):
            document.strokes.removeAll { $0.id == stroke.id }
        case .layers(let before, _): before.apply(to: &document)
        }
        redoEdits.append(edit)
        return true
    }
    @discardableResult
    mutating func redo(in document: inout DrawingDocument) -> Bool {
        guard let edit = redoEdits.popLast() else { return false }
        switch edit {
        case .stroke(let stroke):
            guard document.layers.contains(where: { $0.id == stroke.layerID }) else { return false }
            document.strokes.append(stroke)
        case .layers(_, let after): after.apply(to: &document)
        }
        undoEdits.append(edit)
        return true
    }
}
