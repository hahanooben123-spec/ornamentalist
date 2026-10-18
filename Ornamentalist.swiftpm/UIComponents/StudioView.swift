import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

private struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
struct StudioView: View {
    @StateObject private var model: StudioModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("studioAppearance") private var appearance = "system"
    @State private var shareFile: ShareFile?
    @State private var exporting = false
    @State private var importing = false
    @State private var importingImage = false
    @State private var photoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var creating = false
    @State private var renameTarget: ProjectSummary?
    @State private var projectName = ""
    @State private var performanceText: String?
    @State private var panel: StudioPanel?
    @State private var zen = false
    @AppStorage("layersSidebarVisible") private var layersVisible = true
    private let exportService = ExportService()

    init() {
        #if DEBUG
        if StudioShowcase.enabled {
            // UI tests always use a new isolated repository, never the user's drawings.
            _model = StateObject(wrappedValue: StudioShowcase.makeModel())
            return
        }
        #endif
        _model = StateObject(wrappedValue: StudioModel(preferences: .standard))
    }

    var body: some View {
        ZStack {
            if let document = model.document { editor(document) }
            else {
                StudioGallery(model: model, create: { creating = true }, importProject: { importingImage = false; importing = true }) { project in
                    projectName = project.title; renameTarget = project
                }
            }
        }
        .tint(StudioStyle.copper)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(rootIdentifier)
        .accessibilityValue(rootDiagnostic)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .task {
            print("Ornamentalist 0.9.6: studio visible; loading gallery")
            model.startMaintenance()
            await model.refresh()
            print("Ornamentalist 0.9.6: gallery loading finished")
        }
        .onDisappear { model.stopMaintenance() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await model.saveNow() } }
        }
        .alert("Ornamentalist", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("Copy errors") { UIPasteboard.general.string = model.errorReport }
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("Drawing recovered", isPresented: $model.recoveryNotice) {
            Button("OK", role: .cancel) {}
        } message: { Text("Confirmed ink was recovered from the recovery journal or a previous backup. The last unsaved moments may be missing. Save to keep this version.") }
        .sheet(item: $shareFile) { file in ShareSheet(url: file.url) }
        .sheet(isPresented: $creating) {
            NewDrawingSheet { title in Task { await model.create(title: title) } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: importingImage ? [.png, .jpeg] : [.json]) { result in
            switch result {
            case .success(let url):
                let image = importingImage
                Task { if image { await model.insertImageFile(url) } else { await model.importProject(url) } }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .photosPicker(isPresented: $photoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            let targetID = model.document?.id
            Task {
                defer { photoItem = nil }
                do {
                    if let data = try await item.loadTransferable(type: Data.self), model.document?.id == targetID {
                        await model.insertImage(data)
                    }
                } catch { model.error = error.localizedDescription }
            }
        }
        .alert("Drawing performance", isPresented: Binding(get: { performanceText != nil }, set: { if !$0 { performanceText = nil } })) {
            Button("Copy report") { UIPasteboard.general.string = performanceText; performanceText = nil }
            Button("OK", role: .cancel) { performanceText = nil }
        } message: { Text(performanceText ?? "") }
        .alert("Name drawing", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Drawing name", text: $projectName)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let target = renameTarget { Task { await model.renameProject(target.id, title: projectName) } }
                renameTarget = nil
            }
        }
    }

    private var controlsDisabled: Bool { model.isDrawing || !model.canEdit || exporting }

    private var rootIdentifier: String {
        #if DEBUG
        return StudioShowcase.enabled ? "studio-test" : "studio"
        #else
        return "studio"
        #endif
    }

    private var rootDiagnostic: String {
        #if DEBUG
        if StudioShowcase.enabled { return model.error ?? "\(model.projects.count) test drawings" }
        #endif
        return ""
    }

    private func editor(_ document: DrawingDocument) -> some View {
        // Chrome overlays preserve the canvas bounds and document transform.
        PencilCanvas(model: model)
            .id(document.id)
            // Reserve room for the top toolbar, including in focus mode.
            // Toggling chrome must not change the Pencil coordinate frame.
            .padding(.top, 60)
            .ignoresSafeArea()
            .allowsHitTesting(!exporting && !model.busy && !model.isPreparing)
            .overlay { editorRails }
            .overlay(alignment: .top) {
                if !zen { editorHeader(document) }
            }
            .overlay(alignment: .topTrailing) {
                if zen {
                    Button { zen = false } label: { StudioIcon(symbol: "arrow.down.right.and.arrow.up.left") }
                        .studioSurface().padding(20).accessibilityLabel("Show studio controls")
                        .accessibilityIdentifier("leaveZen")
                }
            }
            .overlay(alignment: .bottom) {
                if model.isTransforming {
                    HStack(spacing: 8) {
                        Button("Cancel") { model.finishImageTransform(apply: false) }
                            .accessibilityIdentifier("cancelImageTransform")
                        Spacer(minLength: 4)
                        Button { model.flipImage(horizontal: true) } label: { StudioIcon(symbol: "arrow.left.and.right") }
                            .accessibilityLabel("Flip image horizontally")
                        Button { model.flipImage(horizontal: false) } label: { StudioIcon(symbol: "arrow.up.and.down") }
                            .accessibilityLabel("Flip image vertically")
                        Button { model.rotateImage(by: .pi / 2) } label: { StudioIcon(symbol: "rotate.right") }
                            .accessibilityLabel("Rotate image 90 degrees")
                        Spacer(minLength: 4)
                        Button("Apply") { model.finishImageTransform(apply: true) }.fontWeight(.semibold)
                            .accessibilityIdentifier("applyImageTransform")
                    }.padding(12).studioSurface().padding(16)
                        .disabled(model.busy || model.isPreparing)
                }
            }
            .overlay {
                if model.tool == .eyedropper {
                    Label("Tap artwork to pick a color", systemImage: "eyedropper")
                        .font(.subheadline).padding(16).studioSurface().allowsHitTesting(false)
                        .accessibilityIdentifier("eyedropperHint")
                } else if !document.canDrawOnActiveLayer {
                    Label(document.activeLayer?.isVisible == false ? "Layer hidden · Choose a visible layer" : "Layer locked · Unlock in Layers",
                          systemImage: document.activeLayer?.isVisible == false ? "eye.slash" : "lock")
                        .font(.subheadline).padding(16).studioSurface().allowsHitTesting(false)
                        .accessibilityIdentifier("layerDrawingBlocked")
                }
            }
            .overlay {
                if model.isPreparing || model.busy || exporting {
                    ProgressView(exporting ? "Preparing export…" : model.isPreparing ? "Preparing drawing…" : "Saving drawing…")
                        .padding(24).studioSurface()
                }
            }
            .background(StudioStyle.workspace)
    }

    private var editorRails: some View {
        GeometryReader { geometry in
            if !zen && !model.isTransforming {
                HStack(spacing: 0) {
                    VStack(spacing: 6) {
                        StudioBrushRail(model: model, sliderHeight: min(180, max(60, (geometry.size.height - 350) / 2)))
                        VStack(spacing: 0) {
                            Button { model.undo() } label: { StudioIcon(symbol: "arrow.uturn.backward") }
                                .disabled(!model.canUndo || controlsDisabled)
                                .accessibilityLabel("Undo").accessibilityIdentifier("undo")
                            Button { model.redo() } label: { StudioIcon(symbol: "arrow.uturn.forward") }
                                .disabled(!model.canRedo || controlsDisabled)
                                .accessibilityLabel("Redo").accessibilityIdentifier("redo")
                        }.studioSurface()
                    }
                    Spacer(minLength: 12)
                    if layersVisible && panel == nil {
                        VStack(spacing: 0) {
                            HStack {
                                Text("Layers").font(.system(.title3, design: .serif))
                                Spacer()
                                Button { layersVisible = false } label: { StudioIcon(symbol: "chevron.right") }
                                    .accessibilityLabel("Collapse layers").accessibilityIdentifier("closePanel")
                            }.padding(.horizontal, 14).padding(.top, 4)
                            ScrollView {
                                StudioLayersView(model: model, onMerge: { layersVisible = false })
                                    .padding(8)
                            }
                        }
                        .frame(width: min(300, geometry.size.width * 0.36),
                               height: min(190 + CGFloat(model.document?.layers.count ?? 1) * 60,
                                           max(200, geometry.size.height - 96)))
                        .studioSurface()
                        .frame(maxHeight: .infinity, alignment: .top)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("layersSidebar")
                        .disabled(controlsDisabled)
                    }
                }
                .padding(.leading, 8).padding(.top, 64).padding(.bottom, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .disabled(exporting)
            }
        }
    }

    private func editorHeader(_ document: DrawingDocument) -> some View {
        HStack(spacing: horizontalSizeClass == .compact ? 0 : 6) {
            Button {
                panel = nil; Task { await model.close() }
            } label: {
                if horizontalSizeClass == .compact { StudioIcon(symbol: "square.grid.2x2") }
                else { Text("Gallery").font(.subheadline).padding(.horizontal, 12).frame(minHeight: 44) }
            }
                .disabled(controlsDisabled).accessibilityLabel("Gallery").accessibilityIdentifier("gallery")
            dockButton(.canvas, symbol: "wrench", detail: nil)
            dockButton(.symmetry, symbol: "circle.hexagongrid", detail: nil)
            Spacer(minLength: 0)
            dockButton(.brush, symbol: "paintbrush.pointed", detail: nil)
            if horizontalSizeClass == .compact {
                Menu {
                    Button("Brush", systemImage: "pencil.tip") { model.selectTool(.brush) }
                    Button("Eraser", systemImage: "eraser") { model.selectTool(.eraser) }
                    Button("Eyedropper", systemImage: "eyedropper") { model.selectTool(.eyedropper) }
                } label: { StudioIcon(symbol: model.tool == .brush ? "pencil.tip" : model.tool == .eraser ? "eraser" : "eyedropper") }
                    .disabled(controlsDisabled).accessibilityLabel("Drawing tools")
            } else {
                toolButton(.eraser, symbol: "eraser", label: "Eraser")
                toolButton(.eyedropper, symbol: "eyedropper", label: "Eyedropper")
            }
            dockButton(.layers, symbol: "square.3.layers.fill", detail: nil)
            Button { panel = panel == .colors ? nil : .colors } label: {
                Circle().fill(document.color.swiftUIColor)
                    .overlay(Circle().stroke(.secondary.opacity(0.4), lineWidth: 1))
                    .frame(width: 26, height: 26).padding(9)
            }.disabled(controlsDisabled).accessibilityLabel("Drawing color")
                .accessibilityValue(document.color.hex).accessibilityIdentifier("panel-Colors")
                .popover(isPresented: Binding(get: { panel == .colors }, set: { if !$0 && panel == .colors { panel = nil } })) {
                    StudioPanelView(panel: .colors, model: model, appearance: $appearance) {}.tint(StudioStyle.copper)
                }
            Menu {
                Button("Insert photo", systemImage: "photo.on.rectangle") { panel = nil; photoPicker = true }
                Button("Insert image file", systemImage: "doc.badge.plus") { panel = nil; importingImage = true; importing = true }
                Button("Transform image", systemImage: "arrow.up.left.and.arrow.down.right") { panel = nil; model.beginImageTransform() }
                    .disabled(document.activeLayer?.raster == nil || !document.canDrawOnActiveLayer)
                Divider()
                Button("Save drawing", systemImage: "externaldrive") { Task { await model.saveNow() } }
                Divider()
                Button("PNG · White paper", systemImage: "photo") { exportPNG(transparent: false) }
                Button("PNG · Transparent", systemImage: "square.dashed") { exportPNG(transparent: true) }
                Button("Editable project", systemImage: "doc") { exportProject() }
                Divider()
                Button("Hide studio controls", systemImage: "arrow.up.left.and.arrow.down.right") { panel = nil; zen = true }
                    .accessibilityIdentifier("enterZen")
            } label: { StudioIcon(symbol: "square.and.arrow.up") }
                .disabled(controlsDisabled).accessibilityLabel("Save and export")
            if horizontalSizeClass != .compact {
                Button { panel = nil; zen = true } label: { StudioIcon(symbol: "arrow.up.left.and.arrow.down.right") }
                    .disabled(controlsDisabled).accessibilityLabel("Hide studio controls").accessibilityIdentifier("enterZen")
            }
        }
        .padding(.horizontal, horizontalSizeClass == .compact ? 4 : 10).padding(.vertical, 6)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .disabled(controlsDisabled)
    }

    private func toolButton(_ tool: StudioTool, symbol: String, label: String) -> some View {
        Button {
            panel = nil; model.selectTool(model.tool == tool ? .brush : tool)
        } label: {
            StudioIcon(symbol: symbol)
                .background(model.tool == tool ? StudioStyle.copper.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }.disabled(controlsDisabled).accessibilityLabel(label).accessibilityIdentifier("tool-\(tool.rawValue)")
            .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
    }

    private func dock(_ document: DrawingDocument) -> some View {
        HStack(spacing: 4) {
            dockButton(.brush, symbol: model.tool == .eraser ? "eraser" : "pencil.tip",
                       detail: model.tool == .eraser ? "Eraser · \(Int(model.eraserBrush.width)) px" : document.brush.preset.name)
            Divider().frame(height: 28).padding(.horizontal, 4)
            dockButton(.symmetry, symbol: "circle.hexagongrid", detail: document.symmetry.mirror ? "×\(document.symmetry.instanceCount) · Mirror" : document.symmetry.repetitions == 1 ? "Off" : "×\(document.symmetry.repetitions)")
            Divider().frame(height: 28).padding(.horizontal, 4)
            dockButton(.layers, symbol: "square.3.layers.3d", detail: document.activeLayer?.name)
            Divider().frame(height: 28).padding(.horizontal, 4)
            dockButton(.canvas, symbol: "hand.draw", detail: nil)
        }
        .padding(8).studioSurface().fixedSize(horizontal: false, vertical: true)
        .disabled(controlsDisabled)
    }

    private func dockButton(_ item: StudioPanel, symbol: String, detail: String?) -> some View {
        Button {
            if item == .layers { panel = nil; layersVisible.toggle() }
            else {
                if item == .brush, model.tool != .brush { model.selectTool(.brush) }
                panel = panel == item ? nil : item
            }
        } label: {
            Group {
                if item == .layers { StudioLayersIcon() }
                else { StudioIcon(symbol: symbol) }
            }
            .background((panel == item || item == .layers && layersVisible && panel == nil) ? StudioStyle.copper.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 15))
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioPressStyle()).accessibilityLabel(item.rawValue).accessibilityValue(detail ?? "")
        .accessibilityIdentifier("panel-\(item.id)")
        .accessibilityAddTraits(item == .layers && layersVisible && panel == nil ? .isSelected : [])
        .popover(isPresented: Binding(get: { panel == item }, set: { if !$0 && panel == item { panel = nil } }), arrowEdge: .top) {
            StudioPanelView(panel: item, model: model, appearance: $appearance) {
                panel = nil
                let rendering = model.rendererDiagnostics?() ?? "Renderer unavailable"
                performanceText = model.errorReport.isEmpty ? rendering : rendering + "\n\nRecent errors:\n" + model.errorReport
            }.tint(StudioStyle.copper)
        }
    }

    private func exportProject() {
        guard let document = model.document else { return }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                guard await model.saveNow() else { return }
                let url = try await model.repository.exportProject(model.document ?? document)
                shareFile = ShareFile(url: url)
            } catch { model.error = error.localizedDescription }
        }
    }

    private func exportPNG(transparent: Bool) {
        guard let document = model.document else { return }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                let url = try await exportService.png(document, transparent: transparent)
                shareFile = ShareFile(url: url)
            } catch { model.error = error.localizedDescription }
        }
    }
}

@MainActor
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
