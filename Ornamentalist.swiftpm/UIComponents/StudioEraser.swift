import SwiftUI

@MainActor
struct StudioEraserView: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Eraser", systemImage: "eraser").font(.headline)
            Text("Removes ink from the selected layer. Lower layers show through. Mirror follows your symmetry settings.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Hard") { model.setSoftEraser(false) }.accessibilityIdentifier("hardEraser")
                Button("Soft") { model.setSoftEraser(true) }.accessibilityIdentifier("softEraser")
            }.buttonStyle(.bordered)
            Button("Return to brush", systemImage: "pencil.tip") { model.selectTool(.brush) }
                .frame(minHeight: 44).accessibilityIdentifier("returnToBrush")
            Text("Choose any brush shape or texture below. Eraser settings are remembered separately from drawing brushes.")
                .font(.caption).foregroundStyle(.secondary)
            StudioBrushesView(model: model, brush: model.eraserBrush)
        }
        .onDisappear { model.brushPreviewRequested?(false) }
    }
}
