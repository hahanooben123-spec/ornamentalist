import SwiftUI

@MainActor
struct StudioEraserView: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Eraser", systemImage: "eraser").font(.headline)
            Text("Removes ink from the selected layer. Lower layers show through. Mirror follows your symmetry settings.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Eraser edge", selection: Binding(get: { model.eraserBrush.usesStamps }, set: { model.setSoftEraser($0) })) {
                Text("Hard").tag(false); Text("Soft").tag(true)
            }.pickerStyle(.segmented).accessibilityIdentifier("eraserEdge")
            HStack {
                Text("Size"); Spacer()
                Text("\(Int(model.eraserBrush.width)) px").monospacedDigit().foregroundStyle(.secondary)
            }.font(.subheadline)
            Slider(value: Binding(get: { model.eraserBrush.width }, set: { model.setEraserWidth($0) }), in: 0.5...160)
                .accessibilityLabel("Eraser size")
            Text("Hard removes completely. Soft builds removal with overlapping passes. Each eraser stroke can be undone.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Return to brush", systemImage: "pencil.tip") { model.selectTool(.brush) }
                .frame(minHeight: 44).accessibilityIdentifier("returnToBrush")
        }
    }
}
