import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct StudioLayersView: View {
    @ObservedObject var model: StudioModel
    var onMerge: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: DrawingLayer?
    @State private var deleting: DrawingLayer?
    @State private var layerName = ""
    @State private var draggedLayer: UUID?
    private static let layerDragType = UTType(exportedAs: "com.ornamentalist.layer-reorder")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let document = model.document {
                let grouped = Dictionary(grouping: document.strokes, by: \.layerID)
                HStack {
                    Text("\(document.layers.count) of \(LayerManager.maximumLayers) layers")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add layer", systemImage: "plus") { model.addLayer() }
                        .font(.caption.weight(.semibold)).frame(minHeight: 44)
                        .disabled(document.layers.count >= LayerManager.maximumLayers)
                        .accessibilityIdentifier("addLayer")
                }
                if let layer = document.activeLayer {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Opacity"); Spacer()
                            Text("\(Int((layer.opacity * 100).rounded()))%").monospacedDigit()
                                .accessibilityIdentifier("layerOpacityValue")
                        }.font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { layer.opacity }, set: { model.setLayerOpacity(layer.id, value: $0) }),
                               in: 0...1, step: 0.01, onEditingChanged: { editing in
                            if editing { model.beginLayerOpacityEdit() } else { model.finishLayerOpacityEdit() }
                        }).accessibilityLabel("Layer opacity").accessibilityIdentifier("layerOpacity")
                    }.padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                }
                ForEach(Array(document.layers.reversed())) { layer in
                    row(layer, in: document, strokes: grouped[layer.id] ?? [])
                        .onDrag {
                            draggedLayer = layer.id
                            let provider = NSItemProvider()
                            provider.registerDataRepresentation(forTypeIdentifier: Self.layerDragType.identifier, visibility: .ownProcess) { completion in
                                completion(Data(layer.id.uuidString.utf8), nil); return nil
                            }
                            return provider
                        }
                        .onDrop(of: [Self.layerDragType], delegate: LayerReorderDrop(
                            target: layer.id, dragged: $draggedLayer, model: model))
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
                HStack(spacing: 8) {
                    LayerPreview(model: model, document: document, layer: layer, strokeIDs: strokes.map(\.id))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(layer.name).font(.system(size: 13, weight: layer.id == document.activeLayerID ? .semibold : .medium)).lineLimit(1)
                        Text(!layer.isVisible ? "Hidden" : layer.isLocked ? "Locked" : "\(Int((layer.opacity * 100).rounded()))%")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.frame(minHeight: 54).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Select \(layer.name)")
            .accessibilityIdentifier("select-layer-\(layer.name)")
            .accessibilityAddTraits(layer.id == document.activeLayerID ? .isSelected : [])
            Button { model.toggleLayerVisibility(layer.id) } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 14, weight: .regular)).frame(width: 44, height: 44)
                    .foregroundStyle(layer.isVisible ? Color.secondary : StudioStyle.copper)
            }.accessibilityLabel("Visibility of \(layer.name)")
                .accessibilityValue(layer.isVisible ? "Visible" : "Hidden")
                .accessibilityIdentifier("visibility-\(layer.name)")
            Button { model.toggleLayerLock(layer.id) } label: {
                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 12, weight: .regular)).frame(width: 44, height: 44)
                    .foregroundStyle(layer.isLocked ? StudioStyle.copper : Color.secondary.opacity(0.45))
            }.accessibilityLabel("Lock \(layer.name)")
                .accessibilityValue(layer.isLocked ? "Locked" : "Unlocked")
                .accessibilityIdentifier("lock-\(layer.name)")
            Menu {
                Button("Transform layer", systemImage: "arrow.up.left.and.arrow.down.right") {
                    model.selectLayer(layer.id)
                    if let onMerge { onMerge() } else { dismiss() }
                    Task { await model.beginLayerTransform() }
                }.disabled(!layer.isVisible || layer.isLocked || (layer.raster == nil && strokes.isEmpty))
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
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium))
                    .frame(width: 44, height: 44).foregroundStyle(.secondary)
            }
                .accessibilityLabel("Options for \(layer.name)").accessibilityIdentifier("layer-options-\(layer.name)")
        }
        .padding(.leading, 10).padding(.vertical, 5)
        .background(layer.id == document.activeLayerID ? StudioStyle.copper.opacity(0.09) : Color.secondary.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            if layer.id == document.activeLayerID {
                Capsule().fill(StudioStyle.copper).frame(width: 3, height: 28).padding(.leading, 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

@MainActor
private struct LayerReorderDrop: DropDelegate {
    let target: UUID
    @Binding var dragged: UUID?
    let model: StudioModel
    func validateDrop(info: DropInfo) -> Bool {
        dragged != nil && dragged != target && model.canEdit && !model.isDrawing
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let source = dragged else { return false }
        model.moveLayer(source, relativeTo: target, above: info.location.y < 32)
        dragged = nil
        return true
    }
}
