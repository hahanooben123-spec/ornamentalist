import SwiftUI
import UniformTypeIdentifiers

private struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
struct StudioView: View {
    @StateObject private var model: StudioModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("studioAppearance") private var appearance = "system"
    @State private var shareFile: ShareFile?
    @State private var exporting = false
    @State private var importing = false
    @State private var creating = false
    @State private var renameTarget: ProjectSummary?
    @State private var projectName = ""
    @State private var performanceText: String?
    @State private var panel: StudioPanel?
    @State private var zen = false
    @State private var prepared = false
    private let exportService = ExportService()

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-showcase") {
            // UI tests always use a new isolated repository, never the user's drawings.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            _model = StateObject(wrappedValue: StudioModel(repository: DocumentRepository(directory: directory)))
            return
        }
        #endif
        _model = StateObject(wrappedValue: StudioModel())
    }

    var body: some View {
        ZStack {
            if let document = model.document { editor(document) }
            else {
                StudioGallery(model: model, create: { creating = true }, importProject: { importing = true }) { project in
                    projectName = project.title; renameTarget = project
                }
            }
        }
        .tint(StudioStyle.copper)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .task {
            model.startMaintenance()
            guard !prepared else { return }
            prepared = true
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-showcase"),
               !ProcessInfo.processInfo.arguments.contains("--ui-empty") {
                do { try await StudioShowcase.seed(repository: model.repository) }
                catch { model.error = error.localizedDescription }
            }
            #endif
            await model.refresh()
        }
        .onDisappear { model.stopMaintenance() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await model.saveNow() } }
        }
        .alert("Ornamentalist", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("Drawing recovered", isPresented: $model.recoveryNotice) {
            Button("OK", role: .cancel) {}
        } message: { Text("Confirmed ink was recovered from the recovery journal or a previous backup. The last unsaved moments may be missing. Save to keep this version.") }
        .sheet(item: $shareFile) { file in ShareSheet(url: file.url) }
        .sheet(isPresented: $creating) {
            NewDrawingSheet { title in Task { await model.create(title: title) } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): Task { await model.importProject(url) }
            case .failure(let error): model.error = error.localizedDescription
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

    private func editor(_ document: DrawingDocument) -> some View {
        // Chrome overlays preserve the canvas bounds and document transform.
        PencilCanvas(model: model)
            .id(document.id)
            .ignoresSafeArea()
            .allowsHitTesting(!exporting && !model.busy && !model.isPreparing)
            .overlay(alignment: .top) {
                if !zen { editorHeader(document).padding(.horizontal, 20).padding(.top, 10) }
            }
            .overlay(alignment: .bottom) {
                if !zen {
                    VStack(spacing: 12) {
                        dock(document)
                        Text(model.fingerDrawing ? "Finger drawing on · Two fingers to navigate" : "Apple Pencil to draw · Two fingers to navigate")
                            .font(.caption).foregroundStyle(.white.opacity(0.65))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(StudioStyle.workspace.opacity(0.85), in: Capsule())
                            .allowsHitTesting(false)
                    }.padding(.horizontal, 16).padding(.bottom, 16)
                }
            }
            .overlay(alignment: .topTrailing) {
                if zen {
                    Button { zen = false } label: { StudioIcon(symbol: "arrow.down.right.and.arrow.up.left") }
                        .studioSurface().padding(20).accessibilityLabel("Show studio controls")
                        .accessibilityIdentifier("leaveZen")
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

    private func editorHeader(_ document: DrawingDocument) -> some View {
        HStack(spacing: 12) {
            Button {
                panel = nil; Task { await model.close() }
            } label: { StudioIcon(symbol: "square.grid.2x2") }
                .disabled(controlsDisabled).accessibilityLabel("Gallery").accessibilityIdentifier("gallery")
            Rectangle().fill(.secondary.opacity(0.2)).frame(width: 1, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(document.title).font(.system(.headline, design: .serif)).lineLimit(1)
                Text(model.saveStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("saveStatus")
            }.frame(maxWidth: 260, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Button { model.undo() } label: { StudioIcon(symbol: "arrow.uturn.backward") }
                    .disabled(document.strokes.isEmpty || controlsDisabled)
                    .accessibilityLabel("Undo").accessibilityIdentifier("undo")
                Button { model.redo() } label: { StudioIcon(symbol: "arrow.uturn.forward") }
                    .disabled(model.redoStack.isEmpty || controlsDisabled)
                    .accessibilityLabel("Redo").accessibilityIdentifier("redo")
            }
            Menu {
                Button("Save drawing", systemImage: "externaldrive") { Task { await model.saveNow() } }
                Divider()
                Button("PNG · White paper", systemImage: "photo") { exportPNG(transparent: false) }
                Button("PNG · Transparent", systemImage: "square.dashed") { exportPNG(transparent: true) }
                Button("Editable project", systemImage: "doc") { exportProject() }
            } label: { StudioIcon(symbol: "square.and.arrow.up") }
                .disabled(controlsDisabled).accessibilityLabel("Save and export")
            Button { panel = nil; zen = true } label: { StudioIcon(symbol: "arrow.up.left.and.arrow.down.right") }
                .disabled(controlsDisabled).accessibilityLabel("Hide studio controls").accessibilityIdentifier("enterZen")
        }
        .padding(.horizontal, 10).padding(.vertical, 8).studioSurface()
        .frame(maxWidth: 900)
    }

    private func dock(_ document: DrawingDocument) -> some View {
        HStack(spacing: 4) {
            dockButton(.brush, symbol: "pencil.tip", detail: "\(document.brush.width.formatted(.number.precision(.fractionLength(1)))) px")
            Divider().frame(height: 28).padding(.horizontal, 4)
            dockButton(.symmetry, symbol: "circle.hexagongrid", detail: document.symmetry.repetitions == 1 ? "Off" : "×\(document.symmetry.repetitions)")
            Divider().frame(height: 28).padding(.horizontal, 4)
            dockButton(.canvas, symbol: "hand.draw", detail: nil)
        }
        .padding(8).studioSurface().fixedSize(horizontal: false, vertical: true)
        .disabled(controlsDisabled)
    }

    private func dockButton(_ item: StudioPanel, symbol: String, detail: String?) -> some View {
        Button { panel = panel == item ? nil : item } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 22, weight: .light))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.rawValue).font(.subheadline.weight(.medium))
                    if let detail { Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
            }
            .padding(.horizontal, 16).frame(minHeight: 48)
            .background(panel == item ? StudioStyle.copper.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 15))
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioPressStyle()).accessibilityIdentifier("panel-\(item.id)")
        .popover(isPresented: Binding(get: { panel == item }, set: { if !$0 && panel == item { panel = nil } }), arrowEdge: .bottom) {
            StudioPanelView(panel: item, model: model, appearance: $appearance) {
                panel = nil; performanceText = model.rendererDiagnostics?()
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
