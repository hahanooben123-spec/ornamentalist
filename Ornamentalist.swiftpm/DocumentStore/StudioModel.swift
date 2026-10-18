import SwiftUI

@MainActor
final class StudioModel: ObservableObject {
    @Published private(set) var document: DrawingDocument?
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private var history = StrokeHistory()
    var redoStack: [InkStroke] { history.redoStrokes }
    var canUndo: Bool { document.map { history.canUndo(in: $0) } ?? false }
    var canRedo: Bool { history.canRedo }
    var canDraw: Bool { canEdit && !isTransforming && (document?.canDrawOnActiveLayer ?? false) }
    @Published private(set) var imageTransform: RasterPlacement?
    private var transformLayerID: UUID?
    var isTransforming: Bool { imageTransform != nil }
    var displayDocument: DrawingDocument? {
        guard var d = document, let placement = imageTransform,
              let index = d.layers.firstIndex(where: { $0.id == transformLayerID }) else { return document }
        d.layers[index].raster?.placement = placement
        return d
    }
    @Published private(set) var saveStatus = "Saved on iPad"
    @Published private(set) var isDrawing = false
    @Published private(set) var busy = false
    @Published private(set) var isPreparing = false
    @Published private var presentedError: String?
    private var recentErrors: [String] = []
    // Concurrent renderer/save failures must not replace an alert being read.
    var error: String? {
        get { presentedError }
        set {
            guard let message = newValue else { presentedError = nil; return }
            if recentErrors.last != message {
                recentErrors.append(message)
                if recentErrors.count > 20 { recentErrors.removeFirst() }
            }
            if presentedError == nil { presentedError = message }
        }
    }
    var errorReport: String {
        var messages = presentedError.map { [$0] } ?? []
        messages += recentErrors.filter { $0 != presentedError }
        return messages.joined(separator: "\n\n")
    }
    @Published var recoveryNotice = false
    @Published var guides = true
    @Published var fingerDrawing = false
    @Published var resetViewToken = UUID()
    @Published private(set) var tool = StudioTool.brush
    @Published private(set) var eraserBrush = InkBrush(width: 32, stabilization: 0.15)
    var canEdit: Bool { !busy && !isPreparing && !isTransforming }
    let repository: DocumentRepository
    private let exportService = ExportService()
    // Canvas exposes confirmed ink only; no predicted points enter a checkpoint.
    var captureActiveStroke: (() -> InkStroke?)?
    var rendererDiagnostics: (() -> String)?
    // UIKit owns the transient cursor; hover never publishes a model revision.
    var brushPreviewRequested: ((Bool) -> Void)?
    private var brushSettings: [BrushPreset: InkBrush] = [:]
    private var preferredBrushPreset = BrushPreset.fineliner
    private let preferences: UserDefaults?
    private(set) var generation = 0
    private var writeSequence = 0
    private var schedule = SaveSchedule()
    private var maintenance: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var thumbnailRequest = UUID()
    private var thumbnailRefreshIDs = Set<UUID>()
    private var saveRunning = false
    private var journalRunning = false
    private var lastCheckpoint = Date.distantPast
    private var lastCheckpointSampleCount = -1
    private var lastCheckpointStrokeID: UUID?
    private var nextSaveAttempt = 0.0
    private var reportedSaveFailure = false
    private(set) var usedSamples = 0
    private(set) var usedVertices = 0
    private var opacityEditBefore: DrawingDocument?

    init(repository: DocumentRepository = DocumentRepository(), preferences: UserDefaults? = nil) {
        self.repository = repository; self.preferences = preferences
        if let data = preferences?.data(forKey: "brushSettings"),
           let settings = try? JSONDecoder().decode([String: InkBrush].self, from: data) {
            for (key, brush) in settings where brush.isValid {
                if let preset = BrushPreset(rawValue: key), preset == brush.preset { brushSettings[preset] = brush }
            }
        }
        // Enable the new default once, while respecting later choices to turn
        // tilt off. Never change the brushes embedded in existing strokes.
        if preferences?.bool(forKey: "tiltDefaultEnabledV1") != true {
            for (preset, stored) in brushSettings where stored.usesStamps && stored.tiltShading == 0 {
                var brush = stored
                brush.tiltShading = 0.7
                brushSettings[preset] = brush
            }
            let settings = Dictionary(uniqueKeysWithValues: brushSettings.map { ($0.key.rawValue, $0.value) })
            if let data = try? JSONEncoder().encode(settings) { preferences?.set(data, forKey: "brushSettings") }
            preferences?.set(true, forKey: "tiltDefaultEnabledV1")
        }
        if let raw = preferences?.string(forKey: "activeBrushPreset"), let preset = BrushPreset(rawValue: raw) {
            preferredBrushPreset = preset
        }
        if let data = preferences?.data(forKey: "eraserSettings"),
           let brush = try? JSONDecoder().decode(InkBrush.self, from: data), brush.isValid,
           brush.preset == .fineliner || brush.preset == .softShader {
            eraserBrush = brush
        }
    }

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
        do {
            projects = try await repository.list()
            prepareGalleryThumbnails()
        }
        catch { self.error = error.localizedDescription }
    }
    private func adopt(_ d: DrawingDocument, recovered: Bool) {
        imageTransform = nil; transformLayerID = nil
        thumbnailTask?.cancel(); thumbnailTask = nil; thumbnailRequest = UUID()
        opacityEditBefore = nil
        tool = .brush
        var adopted = d
        // Project settings must not overwrite newer personal brush preferences.
        // Stored strokes retain their own brushes and are never rewritten.
        if let remembered = brushSettings[d.brush.preset] { adopted.brush = remembered }
        else {
            if adopted.brush.usesStamps, adopted.brush.tiltShading == 0 { adopted.brush.tiltShading = 0.7 }
            rememberBrush(adopted.brush)
        }
        document = adopted; history = StrokeHistory()
        preferredBrushPreset = adopted.brush.preset
        preferences?.set(preferredBrushPreset.rawValue, forKey: "activeBrushPreset")
        writeSequence = max(writeSequence, d.storageRevision)
        generation += 1; nextSaveAttempt = 0; reportedSaveFailure = false
        schedule.saved(); lastCheckpointSampleCount = -1
        lastCheckpointStrokeID = nil
        usedSamples = d.strokes.reduce(0) { $0 + $1.samples.count }
        usedVertices = d.strokes.reduce(0) { $0 + BrushGeometry.estimatedStorageCost($1) }
        recoveryNotice = recovered
        saveStatus = recovered ? "Recovered confirmed ink" : "Saved on iPad"
    }
    func create(title: String = "Untitled Drawing") async {
        guard document == nil, !busy else { return }
        busy = true; defer { busy = false }
        var d = DrawingDocument()
        d.brush = brushSettings[preferredBrushPreset] ?? preferredBrushPreset.makeBrush()
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
    func deleteProject(_ id: UUID) async {
        guard document == nil, !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await repository.delete(id)
        } catch { self.error = error.localizedDescription }
        await refresh()
    }
    func setDrawing(_ value: Bool) { if value { finishLayerOpacityEdit() }; isDrawing = value }
    func discardActiveCheckpoint() {
        isDrawing = false
        changed()
        Task { await saveNow() }
    }
    func setPreparing(_ value: Bool) { isPreparing = value }
    func append(_ stroke: InkStroke, estimatedVertices: Int? = nil) {
        // Completion of confirmed input may occur during deactivation.
        guard !busy, var d = document,
              d.layers.contains(where: { $0.id == stroke.layerID && $0.isVisible && !$0.isLocked }) else { return }
        history.recordNewStroke(stroke, in: &d); document = d; changed()
        usedSamples += stroke.samples.count
        usedVertices += estimatedVertices ?? BrushGeometry.estimatedStorageCost(stroke)
    }
    func undo() {
        finishLayerOpacityEdit()
        guard canEdit, !isDrawing, var d = document, history.undo(in: &d) else { return }
        document = d; recountInk(); changed()
    }
    func redo() {
        finishLayerOpacityEdit()
        guard canEdit, !isDrawing, var d = document, history.redo(in: &d) else { return }
        document = d; recountInk(); changed()
    }
    private func recountInk() {
        usedSamples = document?.strokes.reduce(0) { $0 + $1.samples.count } ?? 0
        usedVertices = document?.strokes.reduce(0) { $0 + BrushGeometry.estimatedStorageCost($1) } ?? 0
    }
    func setMirror(_ enabled: Bool) {
        guard canEdit, !isDrawing, document != nil else { return }
        document?.symmetry.mirror = enabled; changed()
    }
    func selectLayer(_ id: UUID) {
        finishLayerOpacityEdit()
        guard canEdit, !isDrawing, document?.layers.contains(where: { $0.id == id }) == true else { return }
        document?.activeLayerID = id; changed()
    }
    private func editLayers(_ edit: (inout DrawingDocument) throws -> Bool) {
        finishLayerOpacityEdit()
        guard canEdit, !isDrawing, let before = document else { return }
        var after = before
        do { guard try edit(&after) else { return } }
        catch { self.error = error.localizedDescription; return }
        history.recordLayerChange(from: before, to: after)
        document = after
        if before.strokes.count != after.strokes.count { recountInk() }
        changed()
    }
    func addLayer() { editLayers { LayerManager.add(in: &$0) } }
    func renameLayer(_ id: UUID, name: String) { editLayers { LayerManager.rename(id, name: name, in: &$0) } }
    func toggleLayerVisibility(_ id: UUID) { editLayers { LayerManager.toggleVisibility(id, in: &$0) } }
    func toggleLayerLock(_ id: UUID) { editLayers { LayerManager.toggleLock(id, in: &$0) } }
    func moveLayer(_ id: UUID, up: Bool) { editLayers { LayerManager.move(id, up: up, in: &$0) } }
    func deleteLayer(_ id: UUID) { editLayers { LayerManager.delete(id, in: &$0) } }
    func duplicateLayer(_ id: UUID) { editLayers { try LayerManager.duplicate(id, in: &$0) } }
    func mergeLayerDown(_ id: UUID) async {
        finishLayerOpacityEdit()
        guard canEdit, !isDrawing, let before = document, LayerManager.canMergeDown(id, in: before) else { return }
        busy = true; defer { busy = false }
        do {
            let raster = try await exportService.mergedLayer(before, topID: id)
            var after = before
            guard try LayerManager.mergeDown(id, raster: raster, in: &after) else { return }
            history.recordLayerChange(from: before, to: after)
            document = after; recountInk(); changed()
        } catch { self.error = error.localizedDescription }
    }
    func layerThumbnail(_ snapshot: DrawingDocument, id: UUID) async throws -> Data {
        try await exportService.layerThumbnail(snapshot, id: id)
    }
    func insertImage(_ data: Data) async {
        guard canEdit, !isDrawing, !isTransforming, let before = document else { return }
        busy = true
        do {
            let raster = try await exportService.importedImage(data, canvas: before.size)
            guard document?.id == before.id else { busy = false; return }
            var after = before
            guard LayerManager.add(in: &after), let index = after.layers.firstIndex(where: { $0.id == after.activeLayerID }) else {
                throw DocumentError.memoryLimit
            }
            after.layers[index].name = "Image \(after.layers.count)"
            after.layers[index].raster = raster; after.version = 10
            try after.validate()
            history.recordLayerChange(from: before, to: after)
            document = after; changed(); busy = false
            beginImageTransform()
        } catch { busy = false; self.error = error.localizedDescription }
    }
    func insertImageFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= DrawingLimits.encodedBytes else { throw DocumentError.oversized }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            await insertImage(data)
        } catch { self.error = error.localizedDescription }
    }
    func beginImageTransform() {
        guard canEdit, !isDrawing, let d = document, let layer = d.activeLayer,
              layer.isVisible, !layer.isLocked, let raster = layer.raster else { return }
        finishLayerOpacityEdit()
        transformLayerID = layer.id
        imageTransform = raster.placement ?? RasterPlacement(center: d.size * 0.5)
        generation += 1
    }
    func moveImage(by delta: Point) {
        guard var p = imageTransform, delta.isFinite else { return }
        p.center = p.center + delta
        if p.isValid { imageTransform = p; generation += 1 }
    }
    func scaleImage(by factor: Double) {
        guard var p = imageTransform, factor.isFinite, factor > 0 else { return }
        p.scale = min(64, max(0.01, p.scale * factor))
        imageTransform = p; generation += 1
    }
    func rotateImage(by angle: Double) {
        guard var p = imageTransform, angle.isFinite else { return }
        p.rotation = (p.rotation + angle).truncatingRemainder(dividingBy: .pi * 2)
        imageTransform = p; generation += 1
    }
    func flipImage(horizontal: Bool) {
        guard var p = imageTransform else { return }
        if horizontal { p.flipHorizontal.toggle() } else { p.flipVertical.toggle() }
        imageTransform = p; generation += 1
    }
    func finishImageTransform(apply: Bool) {
        guard let p = imageTransform, let id = transformLayerID else { return }
        if apply, var after = document, let index = after.layers.firstIndex(where: { $0.id == id }), let before = document {
            after.layers[index].raster?.placement = p; after.version = 10
            do {
                try after.validate()
                if before.layers != after.layers {
                    history.recordLayerChange(from: before, to: after)
                    document = after; changed()
                }
            } catch { self.error = error.localizedDescription }
        }
        imageTransform = nil; transformLayerID = nil; generation += 1
    }
    func selectTool(_ tool: StudioTool) {
        guard canEdit, !isDrawing, document != nil else { return }
        self.tool = tool
    }
    func setEraserWidth(_ width: Double) {
        guard canEdit, !isDrawing, width.isFinite else { return }
        eraserBrush.width = max(0.5, min(160, width))
        rememberEraser()
    }
    var inputBrush: InkBrush { tool == .eraser ? eraserBrush : document?.brush ?? InkBrush() }
    func setInputWidth(_ width: Double) {
        if tool == .eraser { setEraserWidth(width) } else { setWidth(width) }
    }
    func setInputOpacity(_ value: Double) {
        guard canEdit, !isDrawing, value.isFinite else { return }
        if tool == .eraser {
            eraserBrush.opacity = max(0.01, min(1, value)); rememberEraser()
        }
        else { setOpacity(value) }
    }
    func setSoftEraser(_ soft: Bool) {
        guard canEdit, !isDrawing else { return }
        let previous = eraserBrush
        eraserBrush = soft ? BrushPreset.softShader.makeBrush() : InkBrush(width: previous.width, stabilization: 0.15)
        eraserBrush.width = previous.width; eraserBrush.opacity = previous.opacity
        eraserBrush.pressureEnabled = previous.pressureEnabled; eraserBrush.stabilization = previous.stabilization
        rememberEraser()
    }
    func pickColor(at point: Point) async {
        guard canEdit, !isDrawing, let snapshot = document, point.isFinite,
              (0..<snapshot.size.x).contains(point.x), (0..<snapshot.size.y).contains(point.y) else { return }
        busy = true
        do {
            let color = try await exportService.sampledColor(snapshot, point: point)
            busy = false; setColor(color); tool = .brush
        } catch { busy = false; self.error = error.localizedDescription }
    }
    func beginLayerOpacityEdit() {
        guard canEdit, !isDrawing, opacityEditBefore == nil else { return }
        opacityEditBefore = document
    }
    func finishLayerOpacityEdit() {
        defer { opacityEditBefore = nil }
        guard let before = opacityEditBefore, let after = document, before.id == after.id,
              before.layers != after.layers else { return }
        history.recordLayerChange(from: before, to: after)
    }
    func setLayerOpacity(_ id: UUID, value: Double) {
        guard canEdit, !isDrawing, var d = document else { return }
        let before = d
        guard LayerManager.setOpacity(id, value: value, in: &d) else { return }
        if opacityEditBefore == nil { history.recordLayerChange(from: before, to: d) }
        document = d; changed()
    }
    func setColor(_ color: InkColor, remember: Bool = true) {
        guard canEdit, !isDrawing, color.isValid, document != nil else { return }
        document?.color = color
        if remember { rememberColor() } else { changed() }
    }
    func rememberColor() {
        guard canEdit, !isDrawing, let color = document?.color else { return }
        document?.recentColors.removeAll { $0 == color }
        document?.recentColors.insert(color, at: 0)
        document?.recentColors = Array((document?.recentColors ?? []).prefix(12))
        changed()
    }
    func setRepetitions(_ n: Int) {
        guard canEdit, !isDrawing else { return }
        document?.symmetry.repetitions = max(1, min(64, n)); changed()
    }
    func setWidth(_ width: Double) {
        guard canEdit, !isDrawing, width.isFinite else { return }
        document?.brush.width = max(0.5, min(160, width)); changed()
    }
    func setBrush(_ preset: BrushPreset) {
        guard canEdit, !isDrawing, document != nil else { return }
        if let current = document?.brush { brushSettings[current.preset] = current }
        document?.brush = brushSettings[preset] ?? preset.makeBrush(); changed()
        preferredBrushPreset = preset
        preferences?.set(preset.rawValue, forKey: "activeBrushPreset")
        tool = .brush
    }
    func setOpacity(_ value: Double) {
        guard canEdit, !isDrawing, value.isFinite, document != nil else { return }
        document?.brush.opacity = max(0.01, min(1, value)); changed()
    }
    func setSpacing(_ value: Double) {
        guard canEdit, !isDrawing, value.isFinite else { return }
        document?.brush.spacing = max(0.06, min(4, value)); changed()
    }
    func setDensity(_ value: Double) {
        guard canEdit, !isDrawing, value.isFinite else { return }
        document?.brush.density = max(0.05, min(1, value)); changed()
    }
    func setPressure(_ enabled: Bool) {
        guard canEdit, !isDrawing else { return }
        document?.brush.pressureEnabled = enabled; changed()
    }
    func setStabilization(_ amount: Double) {
        guard canEdit, !isDrawing, amount.isFinite else { return }
        document?.brush.stabilization = max(0, min(1, amount)); changed()
    }
    func setPenResponse(adaptive: Bool? = nil, curve: Double? = nil, minimum: Double? = nil,
                        start: Double? = nil, end: Double? = nil, tilt: Double? = nil) {
        guard canEdit, !isDrawing, var brush = document?.brush else { return }
        if let adaptive { brush.adaptiveStabilization = adaptive }
        if let curve, curve.isFinite { brush.pressureCurve = max(0.2, min(3, curve)) }
        if let minimum, minimum.isFinite { brush.minimumSize = max(0, min(1, minimum)) }
        if let start, start.isFinite { brush.taperStart = max(0, min(2, start)) }
        if let end, end.isFinite { brush.taperEnd = max(0, min(2, end)) }
        if let tilt, tilt.isFinite { brush.tiltShading = max(0, min(1, tilt)) }
        document?.brush = brush; changed()
    }
    private func changed() {
        document?.version = 10; document?.modified = Date()
        if let brush = document?.brush { rememberBrush(brush) }
        generation += 1
        saveStatus = "Unsaved changes"
        schedule.edited(at: ProcessInfo.processInfo.systemUptime)
    }
    private func rememberBrush(_ brush: InkBrush) {
        guard brushSettings[brush.preset] != brush else { return }
        brushSettings[brush.preset] = brush
        let settings = Dictionary(uniqueKeysWithValues: brushSettings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(settings) { preferences?.set(data, forKey: "brushSettings") }
    }
    private func rememberEraser() {
        if let data = try? JSONEncoder().encode(eraserBrush) { preferences?.set(data, forKey: "eraserSettings") }
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
        finishLayerOpacityEdit()
        guard !busy, !isDrawing, !isPreparing, !isTransforming else { return }
        busy = true; defer { busy = false }
        // An autosave may already be in flight. Wait for it without permitting edits.
        while saveRunning { try? await Task.sleep(nanoseconds: 10_000_000) }
        let closingGeneration = generation
        guard await saveNow(), generation == closingGeneration else { return }
        if let id = document?.id { thumbnailRefreshIDs.insert(id) }
        document = nil; history = StrokeHistory(); captureActiveStroke = nil; rendererDiagnostics = nil
        await refresh()
    }

    private func prepareGalleryThumbnails() {
        // Repair old/missing previews on gallery entry, not just the last closed
        // project. Render serially off the main actor; never hold up closing.
        guard document == nil, thumbnailTask == nil,
              projects.contains(where: { $0.thumbnail == nil || thumbnailRefreshIDs.contains($0.id) }) else { return }
        let request = UUID(); thumbnailRequest = request
        thumbnailTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.thumbnailRequest == request { self.thumbnailTask = nil } }
            var attempted = Set<UUID>()
            while !Task.isCancelled, self.document == nil, self.thumbnailRequest == request,
                  let project = self.projects.first(where: {
                      !attempted.contains($0.id) && ($0.thumbnail == nil || self.thumbnailRefreshIDs.contains($0.id))
                  }) {
                attempted.insert(project.id)
                do {
                    let (snapshot, _) = try await self.repository.open(project.id)
                    try Task.checkCancellation()
                    let thumbnail = try await self.exportService.thumbnail(snapshot)
                    try Task.checkCancellation()
                    try await self.repository.storeThumbnail(thumbnail, id: snapshot.id, generation: snapshot.storageRevision)
                    let updated = try await self.repository.list()
                    guard !Task.isCancelled, self.document == nil, self.thumbnailRequest == request else { return }
                    self.thumbnailRefreshIDs.remove(project.id)
                    self.projects = updated
                } catch is CancellationError { return }
                catch {
                    if self.document == nil {
                        self.error = "Drawing saved, but its preview could not be generated: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}
