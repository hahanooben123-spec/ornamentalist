import SwiftUI

@MainActor
struct StudioLayersView: View {
    @ObservedObject var model: StudioModel
    var onMerge: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: DrawingLayer?
    @State private var deleting: DrawingLayer?
    @State private var layerName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let document = model.document {
                let grouped = Dictionary(grouping: document.strokes, by: \.layerID)
                HStack {
                    Text("\(document.layers.count) / \(LayerManager.maximumLayers)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add layer", systemImage: "plus") { model.addLayer() }
                        .font(.subheadline).frame(minHeight: 44)
                        .disabled(document.layers.count >= LayerManager.maximumLayers)
                        .accessibilityIdentifier("addLayer")
                }
                if let layer = document.activeLayer {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Layer opacity"); Spacer()
                            Text("\(Int((layer.opacity * 100).rounded()))%").monospacedDigit()
                                .accessibilityIdentifier("layerOpacityValue")
                        }.font(.subheadline)
                        Slider(value: Binding(get: { layer.opacity }, set: { model.setLayerOpacity(layer.id, value: $0) }),
                               in: 0...1, step: 0.01, onEditingChanged: { editing in
                            if editing { model.beginLayerOpacityEdit() } else { model.finishLayerOpacityEdit() }
                        }).accessibilityLabel("Layer opacity").accessibilityIdentifier("layerOpacity")
                    }.padding(8).background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
                ForEach(Array(document.layers.reversed())) { layer in
                    row(layer, in: document, strokes: grouped[layer.id] ?? [])
                }
            }
        }
        .onDisappear { model.finishLayerOpacityEdit() }
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

    private func row(_ layer: DrawingLayer, in document: DrawingDocument, strokes: [InkStroke]) -> some View {
        HStack(spacing: 2) {
            Button { model.selectLayer(layer.id) } label: {
                HStack(spacing: 6) {
                    LayerPreview(model: model, document: document, layer: layer, strokeIDs: strokes.map(\.id))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(layer.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(layer.isVisible ? "\(Int((layer.opacity * 100).rounded()))%" : "Hidden")
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
                Button("Transform image", systemImage: "arrow.up.left.and.arrow.down.right") {
                    model.selectLayer(layer.id)
                    if let onMerge { onMerge() } else { dismiss() }
                    model.beginImageTransform()
                }.disabled(layer.raster == nil || !layer.isVisible || layer.isLocked)
                Button("Duplicate layer", systemImage: "square.on.square") { model.duplicateLayer(layer.id) }
                    .disabled(document.layers.count >= LayerManager.maximumLayers)
                Button("Merge down", systemImage: "arrow.down.square") {
                    if let onMerge { onMerge() } else { dismiss() }
                    Task { await model.mergeLayerDown(layer.id) }
                }
                    .disabled(!LayerManager.canMergeDown(layer.id, in: document))
                Divider()
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
        .padding(.leading, 6).padding(.vertical, 2)
        .background(layer.id == document.activeLayerID ? StudioStyle.copper.opacity(0.12) : Color.secondary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 14))
    }
}
