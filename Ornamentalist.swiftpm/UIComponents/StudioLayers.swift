import SwiftUI

@MainActor
struct StudioLayersView: View {
    @ObservedObject var model: StudioModel
    @State private var renaming: DrawingLayer?
    @State private var deleting: DrawingLayer?
    @State private var layerName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let document = model.document {
                HStack {
                    Text("\(document.layers.count) / \(LayerManager.maximumLayers)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add layer", systemImage: "plus") { model.addLayer() }
                        .font(.subheadline).frame(minHeight: 44)
                        .disabled(document.layers.count >= LayerManager.maximumLayers)
                        .accessibilityIdentifier("addLayer")
                }
                ForEach(Array(document.layers.reversed())) { layer in
                    row(layer, in: document)
                }
                Text("Top layers sit above the ones below. Hidden or locked layers cannot be drawn on. Layer changes can be undone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .alert("Name layer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Layer name", text: $layerName).accessibilityIdentifier("layerName")
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let layer = renaming { model.renameLayer(layer.id, name: layerName) }
                renaming = nil
            }
        }
        .alert("Delete layer?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete layer", role: .destructive) {
                if let layer = deleting { model.deleteLayer(layer.id) }
                deleting = nil
            }
        } message: { Text("The layer and its strokes will be removed. You can restore them with Undo before closing the drawing.") }
    }

    private func row(_ layer: DrawingLayer, in document: DrawingDocument) -> some View {
        HStack(spacing: 2) {
            Button { model.selectLayer(layer.id) } label: {
                HStack(spacing: 9) {
                    Image(systemName: layer.id == document.activeLayerID ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(layer.id == document.activeLayerID ? StudioStyle.copper : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(layer.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text("\(document.strokes.filter { $0.layerID == layer.id }.count) strokes")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.frame(minHeight: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Select \(layer.name)")
            .accessibilityIdentifier("select-layer-\(layer.name)")
            .accessibilityAddTraits(layer.id == document.activeLayerID ? .isSelected : [])
            Button { model.toggleLayerVisibility(layer.id) } label: {
                StudioIcon(symbol: layer.isVisible ? "eye" : "eye.slash")
            }.accessibilityLabel("Visibility of \(layer.name)")
                .accessibilityValue(layer.isVisible ? "Visible" : "Hidden")
                .accessibilityIdentifier("visibility-\(layer.name)")
            Button { model.toggleLayerLock(layer.id) } label: {
                StudioIcon(symbol: layer.isLocked ? "lock.fill" : "lock.open")
            }.accessibilityLabel("Lock \(layer.name)")
                .accessibilityValue(layer.isLocked ? "Locked" : "Unlocked")
                .accessibilityIdentifier("lock-\(layer.name)")
            Menu {
                Button("Rename", systemImage: "pencil") { layerName = layer.name; renaming = layer }
                Button("Move up", systemImage: "arrow.up") { model.moveLayer(layer.id, up: true) }
                    .disabled(document.layers.last?.id == layer.id)
                Button("Move down", systemImage: "arrow.down") { model.moveLayer(layer.id, up: false) }
                    .disabled(document.layers.first?.id == layer.id)
                Button("Delete layer", systemImage: "trash", role: .destructive) { deleting = layer }
                    .disabled(document.layers.count == 1)
            } label: { StudioIcon(symbol: "ellipsis") }
                .accessibilityLabel("Options for \(layer.name)").accessibilityIdentifier("layer-options-\(layer.name)")
        }
        .padding(.leading, 10).padding(.vertical, 4)
        .background(layer.id == document.activeLayerID ? StudioStyle.copper.opacity(0.12) : Color.secondary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 14))
    }
}
