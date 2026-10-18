import SwiftUI

@MainActor
final class StudioModel: ObservableObject {
    @Published private(set) var document: DrawingDocument?
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private var history = StrokeHistory()
    var redoStack: [InkStroke] { history.redoStrokes }
    var canUndo: Bool { document.map { history.canUndo(in: $0) } ?? false }
    var canRedo: Bool { history.canRedo }
    var canDraw: Bool { canEdit && (document?.canDrawOnActiveLayer ?? false) }
    @Published private(set) var saveStatus = "Saved on iPad"
    @Published private(set) var isDrawing = false
    @Published private(set) var busy = false
    @Published private(set) var isPreparing = false
    @Published var error: String?
    @Published var recoveryNotice = false
    @Published var guides = true
    @Published var fingerDrawing = false
    @Published var resetViewToken = UUID()
    var canEdit: Bool { !busy && !isPreparing }
    let repository: DocumentRepository
    private let exportService = ExportService()
    // Canvas exposes confirmed ink only; no predicted points enter a checkpoint.
    var captureActiveStroke: (() -> InkStroke?)?
    var rendererDiagnostics: (() -> String)?
    private(set) var generation = 0
    private var writeSequence = 0
    private var schedule = SaveSchedule()
    private var maintenance: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var saveRunning = false
    private var journalRunning = false
    private var lastCheckpoint = Date.distantPast
    private var lastCheckpointSampleCount = -1
    private var lastCheckpointStrokeID: UUID?
    private var nextSaveAttempt = 0.0
    private var reportedSaveFailure = false
    private(set) var usedSamples = 0
    private(set) var usedVertices = 0

    init(repository: DocumentRepository = DocumentRepository()) { self.repository = repository }

    func startMaintenance() {
        guard maintenance == nil else { return }
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { break }
                guard let self else { break }
                if self.document != nil, !self.busy {
                    if self.schedule.isDue(at: ProcessInfo.processInfo.systemUptime), !self.saveRunning, !self.isDrawing,
                       ProcessInfo.processInfo.systemUptime >= self.nextSaveAttempt {
                        await self.saveNow()
                    }
                    if Date().timeIntervalSince(self.lastCheckpoint) >= 2 {
                        await self.checkpointActiveInk()
                    }
                }
            }
        }
    }
    func stopMaintenance() { maintenance?.cancel(); maintenance = nil }
    func refresh() async {
        do { projects = try await repository.list() }
        catch { self.error = error.localizedDescription }
    }
    private func adopt(_ d: DrawingDocument, recovered: Bool) {
        document = d; history = StrokeHistory()
        writeSequence = max(writeSequence, d.storageRevision)
        generation += 1; nextSaveAttempt = 0; reportedSaveFailure = false
        schedule.saved(); lastCheckpointSampleCount = -1
        lastCheckpointStrokeID = nil
        usedSamples = d.strokes.reduce(0) { $0 + $1.samples.count }
        usedVertices = d.strokes.reduce(0) { $0 + StrokeGeometry.estimatedVertexCount($1) }
        recoveryNotice = recovered
        saveStatus = recovered ? "Recovered confirmed ink" : "Saved on iPad"
    }
    func create(title: String = "Untitled Drawing") async {
        guard document == nil, !busy else { return }
        busy = true; defer { busy = false }
        var d = DrawingDocument()
        let cleaned = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        d.title = cleaned.isEmpty ? "Untitled Drawing" : cleaned
        writeSequence += 1
        do { try await repository.save(d, generation: writeSequence); adopt(d, recovered: false) }
        catch { self.error = error.localizedDescription }
    }
    func open(_ id: UUID) async {
        guard document == nil, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let (d, recovered) = try await repository.open(id)
            adopt(d, recovered: recovered)
        } catch { self.error = error.localizedDescription }
    }
    func importProject(_ url: URL) async {
        guard document == nil, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let d = try await repository.importProject(at: url)
            writeSequence += 1
            try await repository.save(d, generation: writeSequence)
            adopt(d, recovered: false)
        } catch { self.error = error.localizedDescription }
    }
    func renameProject(_ id: UUID, title: String) async {
        guard !busy, document == nil else { return }
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !title.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            var (d, _) = try await repository.open(id)
            d.title = title; d.modified = Date()
            writeSequence = max(writeSequence, d.storageRevision) + 1
            try await repository.save(d, generation: writeSequence)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func setDrawing(_ value: Bool) { isDrawing = value }
    func discardActiveCheckpoint() {
        isDrawing = false
        changed()
        Task { await saveNow() }
    }
    func setPreparing(_ value: Bool) { isPreparing = value }
    func append(_ stroke: InkStroke) {
        // Completion of confirmed input may occur during deactivation.
        guard !busy, var d = document,
              d.layers.contains(where: { $0.id == stroke.layerID && $0.isVisible && !$0.isLocked }) else { return }
        history.recordNewStroke(stroke, in: &d); document = d; changed()
        usedSamples += stroke.samples.count; usedVertices += StrokeGeometry.estimatedVertexCount(stroke)
    }
    func undo() {
        guard canEdit, !isDrawing, var d = document, history.undo(in: &d) else { return }
        document = d; recountInk(); changed()
    }
    func redo() {
        guard canEdit, !isDrawing, var d = document, history.redo(in: &d) else { return }
        document = d; recountInk(); changed()
    }
    private func recountInk() {
        usedSamples = document?.strokes.reduce(0) { $0 + $1.samples.count } ?? 0
        usedVertices = document?.strokes.reduce(0) { $0 + StrokeGeometry.estimatedVertexCount($1) } ?? 0
    }
    func setMirror(_ enabled: Bool) {
        guard canEdit, !isDrawing, document != nil else { return }
        document?.symmetry.mirror = enabled; changed()
    }
    func selectLayer(_ id: UUID) {
        guard canEdit, !isDrawing, document?.layers.contains(where: { $0.id == id }) == true else { return }
        document?.activeLayerID = id; changed()
    }
    private func editLayers(_ edit: (inout DrawingDocument) -> Bool) {
        guard canEdit, !isDrawing, let before = document else { return }
        var after = before
        guard edit(&after) else { return }
        history.recordLayerChange(from: before, to: after)
        document = after; recountInk(); changed()
    }
    func addLayer() { editLayers { LayerManager.add(in: &$0) } }
    func renameLayer(_ id: UUID, name: String) { editLayers { LayerManager.rename(id, name: name, in: &$0) } }
    func toggleLayerVisibility(_ id: UUID) { editLayers { LayerManager.toggleVisibility(id, in: &$0) } }
    func toggleLayerLock(_ id: UUID) { editLayers { LayerManager.toggleLock(id, in: &$0) } }
    func moveLayer(_ id: UUID, up: Bool) { editLayers { LayerManager.move(id, up: up, in: &$0) } }
    func deleteLayer(_ id: UUID) { editLayers { LayerManager.delete(id, in: &$0) } }
    func setRepetitions(_ n: Int) {
        guard canEdit, !isDrawing else { return }
        document?.symmetry.repetitions = max(1, min(64, n)); changed()
    }
    func setWidth(_ width: Double) {
        guard canEdit, !isDrawing, width.isFinite else { return }
        document?.brush.width = max(0.5, min(40, width)); changed()
    }
    func setPressure(_ enabled: Bool) {
        guard canEdit, !isDrawing else { return }
        document?.brush.pressureEnabled = enabled; changed()
    }
    func setStabilization(_ amount: Double) {
        guard canEdit, !isDrawing, amount.isFinite else { return }
        document?.brush.stabilization = max(0, min(0.85, amount)); changed()
    }
    private func changed() {
        document?.version = 3; document?.modified = Date()
        generation += 1
        saveStatus = "Unsaved changes"
        schedule.edited(at: ProcessInfo.processInfo.systemUptime)
    }
    @discardableResult
    func saveNow() async -> Bool {
        guard let snapshot = document else { return true }
        guard !saveRunning, !isDrawing else { return false }
        saveRunning = true; defer { saveRunning = false }
        let requestedGeneration = generation
        writeSequence += 1
        let sequence = writeSequence
        saveStatus = "Saving…"
        do {
            try await repository.save(snapshot, generation: sequence)
            guard document?.id == snapshot.id else { return false }
            nextSaveAttempt = 0; reportedSaveFailure = false
            if generation == requestedGeneration {
                schedule.saved()
                lastCheckpointStrokeID = nil; lastCheckpointSampleCount = -1
                saveStatus = isDrawing ? "Saved · stroke in progress" : "Saved on iPad"
            } else { saveStatus = "Unsaved changes" }
            if var d = document, generation == requestedGeneration {
                d.storageRevision = sequence; document = d
            }
            return generation == requestedGeneration
        } catch {
            saveStatus = "Save failed"
            if !reportedSaveFailure { self.error = error.localizedDescription; reportedSaveFailure = true }
            nextSaveAttempt = ProcessInfo.processInfo.systemUptime + 5
            return false
        }
    }
    func checkpointActiveInk() async {
        guard !journalRunning, !busy, !saveRunning, var snapshot = document,
              let active = captureActiveStroke?(), !active.samples.isEmpty else { return }
        guard active.id != lastCheckpointStrokeID || active.samples.count != lastCheckpointSampleCount else { return }
        journalRunning = true; defer { journalRunning = false }
        lastCheckpoint = Date()
        snapshot.strokes.append(active); snapshot.modified = Date()
        writeSequence += 1
        let sequence = writeSequence
        do {
            try await repository.checkpoint(snapshot, generation: sequence)
            lastCheckpointSampleCount = active.samples.count; lastCheckpoint = Date()
            lastCheckpointStrokeID = active.id
        } catch { saveStatus = "Recovery save failed"; self.error = error.localizedDescription }
    }
    func close() async {
        guard !busy, !isDrawing, !isPreparing else { return }
        busy = true; defer { busy = false }
        // An autosave may already be in flight. Wait for it without permitting edits.
        while saveRunning { try? await Task.sleep(nanoseconds: 10_000_000) }
        let closingGeneration = generation
        guard await saveNow(), generation == closingGeneration else { return }
        let savedDrawing = document
        document = nil; history = StrokeHistory(); captureActiveStroke = nil; rendererDiagnostics = nil
        await refresh()
        if let savedDrawing { prepareThumbnail(savedDrawing) }
    }

    private func prepareThumbnail(_ snapshot: DrawingDocument) {
        // Disk durability gates closing. Replaceable previews must not block the gallery.
        // Keep only the newest pending request; an in-flight Core Graphics render may finish.
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let thumbnail = try await self.exportService.thumbnail(snapshot)
                try Task.checkCancellation()
                try await self.repository.storeThumbnail(thumbnail, id: snapshot.id, generation: snapshot.storageRevision)
                if self.document == nil { await self.refresh() }
            } catch is CancellationError {
                // A newer preview superseded this request.
            } catch {
                if self.document == nil {
                    self.error = "Drawing saved, but its preview could not be generated: \(error.localizedDescription)"
                }
            }
        }
    }
}
