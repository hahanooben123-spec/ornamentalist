import SwiftUI
import UniformTypeIdentifiers

private struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
struct StudioView: View {
    @StateObject private var model = StudioModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var shareFile: ShareFile?
    @State private var exporting = false
    @State private var importing = false
    @State private var renameTarget: ProjectSummary?
    @State private var projectName = ""
    @State private var performanceText: String?
    private let exportService = ExportService()

    var body: some View {
        NavigationStack {
            Group {
                if let document = model.document { editor(document) }
                else { gallery }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(.teal)
        .task { model.startMaintenance(); await model.refresh() }
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

    private var gallery: some View {
        VStack(spacing: 0) {
            if model.projects.isEmpty {
                ContentUnavailableView {
                    Label("Your next mandala", systemImage: "circle.hexagongrid")
                } description: {
                    Text("Create a canvas and draw with Apple Pencil. Your drawings stay on this iPad.")
                } actions: {
                    Button("New canvas") { Task { await model.create() } }.buttonStyle(.borderedProminent)
                }
            } else {
                List(model.projects) { project in
                    Button {
                        Task { await model.open(project.id) }
                    } label: {
                        HStack(spacing: 16) {
                            Group {
                                if let data = project.thumbnail, let image = UIImage(data: data) {
                                    Image(uiImage: image).resizable().scaledToFit()
                                } else { Image(systemName: "circle.hexagongrid").font(.largeTitle).foregroundStyle(.teal) }
                            }
                            .frame(width: 72, height: 72).background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(project.title).font(.headline).foregroundStyle(.primary)
                                Text("\(project.strokeCount) strokes · \(project.modified.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                    }
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") { projectName = project.title; renameTarget = project }
                    }
                }
            }
            Text("Phase 1 · Apple Pencil canvas · Native Metal rendering")
                .font(.caption).foregroundStyle(.secondary).padding()
        }
        .navigationTitle("Ornamentalist")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack {
                    Button { importing = true } label: { Label("Import project", systemImage: "square.and.arrow.down") }
                    Button { Task { await model.create() } } label: { Label("New canvas", systemImage: "plus") }
                }
            }
        }
        .disabled(model.busy)
    }

    private func editor(_ document: DrawingDocument) -> some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                controls(document)
                ScrollView(.horizontal, showsIndicators: true) { controls(document) }
            }
            .padding(.horizontal).padding(.vertical, 10)
            .background(.bar)
            PencilCanvas(model: model)
                .id(document.id)
                .overlay {
                    if model.isPreparing { ProgressView("Preparing drawing…").padding().background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12)) }
                }
                .allowsHitTesting(!exporting && !model.busy && !model.isPreparing)
                .ignoresSafeArea(edges: .bottom)
            HStack {
                Text(model.saveStatus)
                Spacer()
                Text(model.fingerDrawing ? "Finger drawing enabled" : "Pencil draws · Two fingers navigate")
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.vertical, 6)
        }
        .navigationTitle(document.title)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task { await model.close() }
                } label: { Label("Gallery", systemImage: "square.grid.2x2") }
                .disabled(model.isDrawing || model.busy || exporting)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(document.strokes.isEmpty || model.isDrawing || exporting || !model.canEdit)
                Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(model.redoStack.isEmpty || model.isDrawing || exporting || !model.canEdit)
                Menu {
                    Button("Save drawing", systemImage: "externaldrive") { Task { await model.saveNow() } }
                    Button("Export PNG · White background") { exportPNG(transparent: false) }
                    Button("Export PNG · Transparent") { exportPNG(transparent: true) }
                    Button("Export editable project") { exportProject() }
                } label: {
                    if exporting { ProgressView() }
                    else { Label("Save and export", systemImage: "square.and.arrow.up") }
                }.disabled(model.isDrawing || !model.canEdit || exporting)
            }
        }
    }

    private func controls(_ document: DrawingDocument) -> some View {
        HStack(spacing: 18) {
            Stepper(value: Binding(get: { document.symmetry.repetitions }, set: { model.setRepetitions($0) }), in: 1...64) {
                Text(document.symmetry.repetitions == 1 ? "Symmetry off" : "Radial ×\(document.symmetry.repetitions)")
                    .monospacedDigit().frame(width: 112, alignment: .leading)
            }.fixedSize()
            Menu {
                ForEach([1, 2, 4, 6, 8, 12, 16, 24, 32, 64], id: \.self) { count in
                    Button(count == 1 ? "Off" : "×\(count)") { model.setRepetitions(count) }
                }
            } label: { Image(systemName: "circle.hexagongrid") }.accessibilityLabel("Symmetry presets")
            HStack(spacing: 8) {
                Text("Width")
                Slider(value: Binding(get: { document.brush.width }, set: { model.setWidth($0) }), in: 0.5...40)
                    .frame(width: 100).accessibilityLabel("Brush width")
                Text(document.brush.width.formatted(.number.precision(.fractionLength(1)))).monospacedDigit()
                    .frame(width: 34)
            }
            Toggle(isOn: $model.guides) { Label("Guides", systemImage: "scope") }.toggleStyle(.button)
            Menu {
                Toggle("Pressure changes width", isOn: Binding(get: { document.brush.pressureEnabled }, set: { model.setPressure($0) }))
                ForEach([0.0, 0.25, 0.5, 0.75], id: \.self) { amount in
                    Button("Stabilization \(Int(amount * 100))%") { model.setStabilization(amount) }
                }
            } label: { Label("Fineliner", systemImage: "pencil.tip") }
            Menu {
                Toggle("Draw with finger", isOn: $model.fingerDrawing)
                Button("Reset canvas view", systemImage: "arrow.counterclockwise") { model.resetViewToken = UUID() }
                Button("Performance report", systemImage: "speedometer") { performanceText = model.rendererDiagnostics?() }
            } label: { Label("Canvas", systemImage: "hand.draw") }
        }
        .font(.subheadline)
        .disabled(model.isDrawing || !model.canEdit || exporting)
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
