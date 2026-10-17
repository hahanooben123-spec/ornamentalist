import Foundation

/// One history operation is one original stroke plus every symmetric instance.
struct StrokeHistory {
    private(set) var redoStrokes: [InkStroke] = []
    mutating func recordNewStroke(_ stroke: InkStroke, in document: inout DrawingDocument) {
        document.strokes.append(stroke)
        redoStrokes.removeAll()
    }
    @discardableResult
    mutating func undo(in document: inout DrawingDocument) -> Bool {
        guard let stroke = document.strokes.popLast() else { return false }
        redoStrokes.append(stroke)
        return true
    }
    @discardableResult
    mutating func redo(in document: inout DrawingDocument) -> Bool {
        guard let stroke = redoStrokes.popLast() else { return false }
        document.strokes.append(stroke)
        return true
    }
}
