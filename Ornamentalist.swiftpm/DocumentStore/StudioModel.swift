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
    @Published private(set) var isDrawing = false { didSet { rescheduleMaintenance() } }
    @Published private(set) var busy = false { didSet { rescheduleMaintenance() } }
    @Published private(set) var isPreparing = false { didSet { rescheduleMaintenance() } }
    @Published private(set) var isNavigating = false
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
    @Published private(set) var recoveryMessage = "Confirmed ink was recovered from the recovery journal or a previous backup. The last unsaved moments may be missing. Save to keep this version."
    @Published var guides = true { didSet { preferences?.set(guides, forKey: "guides") } }
    @Published var fingerDrawing = false { didSet { preferences?.set(fingerDrawing, forKey: "fingerDrawing") } }
    @Published var shapeCorrection = false { didSet { preferences?.set(shapeCorrection, forKey: "shapeCorrection") } }
    @Published var parallelDistance = 12.0 { didSet { preferences?.set(parallelDistance, forKey: "parallelDistance") } }
    @Published private(set) var showBrushCursor = true
    @Published var resetViewToken = UUID()
    @Published private(set) var tool = StudioTool.brush
    @Published private(set) var eraserBrush = InkBrush(width: 32, stabilization: 0.15)
    var canEdit: Bool { !busy && !isPreparing && !isTransforming && !isNavigating }
    let repository: DocumentRepository
    private let exportService = ExportService()
    private let previewService = ExportService()
    private var appendLineage = UUID()
    // Canvas exposes confirmed ink only; no predicted points enter a checkpoint.
    var captureActiveStroke: (() -> InkStroke?)?
    var rendererDiagnostics: (() -> String)?
    // UIKit owns the transient cursor; hover never publishes a model revision.
    var brushPreviewRequested: ((Bool) -> Void)?
    private var brushSettings: [BrushPreset: InkBrush] = [:]
    private var eraserSettings: [BrushPreset: InkBrush] = [:]
    private var preferredBrushPreset = BrushPreset.fineliner
    private let preferences: UserDefaults?
    private(set) var generation = 0
    private var writeSequence = 0
    private var schedule = SaveSchedule()
    private var maintenance: Task<Void, Never>?
    private var maintenanceEnabled = false
    private var maintenanceRequest = UUID()
    private(set) var maintenanceWakeups = 0
    var hasScheduledMaintenance: Bool { maintenance != nil }
    private var lastCheckpointUptime = 0.0
    private var thumbnailTask: Task<Void, Never>?
    private var thumbnailRequest = UUID()
    private var thumbnailRefreshIDs = Set<UUID>()
    private var saveRunning = false { didSet { rescheduleMaintenance() } }
    private var journalRunning = false { didSet { rescheduleMaintenance() } }
    private var historyCompacting = false
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
        guides = preferences?.object(forKey: "guides") as? Bool ?? true
        fingerDrawing = preferences?.object(forKey: "fingerDrawing") as? Bool ?? false
        shapeCorrection = preferences?.object(forKey: "shapeCorrection") as? Bool ?? false
        if let distance = preferences?.object(forKey: "parallelDistance") as? Double, distance.isFinite {
            parallelDistance = max(-80, min(80, distance))
        }
        showBrushCursor = preferences?.object(forKey: "showBrushCursor") as? Bool ?? true
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
           let brush = try? JSONDecoder().decode(InkBrush.self, from: data), brush.isValid {
            eraserBrush = brush
        }
        if let data = preferences?.data(forKey: "eraserBrushSettings"),
           let settings = try? JSONDecoder().decode([String: InkBrush].self, from: data) {
            for (key, brush) in settings where brush.isValid {
                if let preset = BrushPreset(rawValue: key), preset == brush.preset { eraserSettings[preset] = brush }
            }
        }
        eraserSettings[eraserBrush.preset] = eraserBrush
        if preferences?.bool(forKey: "softOpacityNormalizedV1") != true {
            for (preset, stored) in brushSettings where preset.softness > 0 {
                var brush = stored; brush.normalizedOpacity = true; brushSettings[preset] = brush
            }
            let settings = Dictionary(uniqueKeysWithValues: brushSettings.map { ($0.key.rawValue, $0.value) })
            if let data = try? JSONEncoder().encode(settings) { preferences?.set(data, forKey: "brushSettings") }
            preferences?.set(true, forKey: "softOpacityNormalizedV1")
        }
        for (preset, stored) in eraserSettings where preset.softness > 0 {
            var brush = stored; brush.normalizedOpacity = true; eraserSettings[preset] = brush
        }
        if eraserBrush.preset.softness > 0 { eraserBrush.normalizedOpacity = true }
        if preferences?.bool(forKey: "lightPencilPressureV1") != true {
            for (preset, stored) in brushSettings {
                var brush = stored; brush.pressureGain = 2.5; brushSettings[preset] = brush
            }
            for (preset, stored) in eraserSettings {
                var brush = stored; brush.pressureGain = 2.5; eraserSettings[preset] = brush
            }
            eraserBrush.pressureGain = 2.5
            let brushes = Dictionary(uniqueKeysWithValues: brushSettings.map { ($0.key.rawValue, $0.value) })
            let erasers = Dictionary(uniqueKeysWithValues: eraserSettings.map { ($0.key.rawValue, $0.value) })
            if let data = try? JSONEncoder().encode(brushes) { preferences?.set(data, forKey: "brushSettings") }
            if let data = try? JSONEncoder().encode(erasers) { preferences?.set(data, forKey: "eraserBrushSettings") }
            if let data = try? JSONEncoder().encode(eraserBrush) { preferences?.set(data, forKey: "eraserSettings") }
            preferences?.set(true, forKey: "lightPencilPressureV1")
        }
        if preferences?.bool(forKey: "fullLinerStabilizationV1") != true {
            for (preset, stored) in brushSettings where preset.family == .ink {
                var brush = stored; brush.stabilization = 1; brush.stabilizationEnabled = true
                brushSettings[preset] = brush
            }
            let settings = Dictionary(uniqueKeysWithValues: brushSettings.map { ($0.key.rawValue, $0.value) })
            if let data = try? JSONEncoder().encode(settings) { preferences?.set(data, forKey: "brushSettings") }
            preferences?.set(true, forKey: "fullLinerStabilizationV1")
        }
    }

    func startMaintenance() {
        maintenanceEnabled = true
        rescheduleMaintenance()
    }
    func stopMaintenance() {
        maintenanceEnabled = false
        maintenanceRequest = UUID(); maintenance?.cancel(); maintenance = nil
    }
    private func rescheduleMaintenance() {
        maintenanceRequest = UUID(); maintenance?.cancel(); maintenance = nil
        guard maintenanceEnabled, document != nil, !busy, !isPreparing,
              !saveRunning, !journalRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let deadline: Double
        if isDrawing {
            deadline = max(now + 0.01, lastCheckpointUptime + 2)
        } else if history.needsCompaction && !historyCompacting {
            deadline = now + 0.05
        } else if let due = schedule.deadline {
            deadline = max(max(now + 0.01, due), nextSaveAttempt)
        } else { return } // No periodic wake-ups while the app is idle.
        let request = maintenanceRequest
        maintenance = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0.01, deadline - now) * 1_000_000_000)) }
            catch { return }
            guard let self, self.maintenanceEnabled, self.maintenanceRequest == request else { return }
            self.maintenance = nil; self.maintenanceWakeups += 1
            if self.isDrawing {
                self.lastCheckpointUptime = ProcessInfo.processInfo.systemUptime
                await self.checkpointActiveInk()
            } else if !self.busy && !self.isPreparing {
                if !self.historyCompacting, self.history.needsCompaction, let id = self.document?.id {
                    self.historyCompacting = true
                    let snapshot = self.history
                    Task { [weak self] in
                        let compacted = await snapshot.compacted()
                        guard let self else { return }
                        self.historyCompacting = false
                        if self.document?.id == id, self.history.revision == snapshot.revision { self.history = compacted }
                        self.rescheduleMaintenance()
                    }
                }
                let current = ProcessInfo.processInfo.systemUptime
                if self.schedule.isDue(at: current), current >= self.nextSaveAttempt {
                    await self.saveNow(incremental: true)
                }
            }
            self.rescheduleMaintenance()
        }
    }
    func refresh() async {
        do {
            projects = try await repository.list()
            prepareGalleryThumbnails()
        }
        catch { self.error = error.localizedDescription }
    }
    private func adopt(_ d: DrawingDocument, recovered: Bool, warning: String? = nil) {
        recoveryMessage = warning ?? "Confirmed ink was recovered from the recovery journal or a previous backup. The last unsaved moments may be missing. Save to keep this version."
        imageTransform = nil; transformLayerID = nil
        thumbnailTask?.cancel(); thumbnailTask = nil; thumbnailRequest = UUID()
        opacityEditBefore = nil
        tool = .brush
        var adopted = d
        // Project settings must not overwrite newer personal brush preferences.
        // Stored strokes retain their own brushes and are never rewritten.
        if let remembered = brushSettings[d.brush.preset] { adopted.brush = remembered }
        else {
            if adopted.brush.preset.family == .ink {
                adopted.brush.stabilization = 1; adopted.brush.stabilizationEnabled = true
            }
            if adopted.brush.usesStamps, adopted.brush.tiltShading == 0 { adopted.brush.tiltShading = 0.7 }
            if adopted.brush.preset.softness > 0 { adopted.brush.normalizedOpacity = true }
            adopted.brush.pressureGain = 2.5
            rememberBrush(adopted.brush)
        }
        appendLineage = UUID()
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
            let warning = await repository.recoveryWarning(for: id)
            adopt(d, recovered: recovered, warning: warning)
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
    func setDrawing(_ value: Bool) {
        if value { finishLayerOpacityEdit(); lastCheckpointUptime = ProcessInfo.processInfo.systemUptime }
        isDrawing = value
    }
    func discardActiveCheckpoint() {
        isDrawing = false
        changed()
        Task { await saveNow() }
    }
    func setPreparing(_ value: Bool) { isPreparing = value }
    func setNavigating(_ value: Bool) { isNavigating = value }
    func append(_ stroke: InkStroke, estimatedVertices: Int? = nil) {
        // Completion of confirmed input may occur during deactivation.
        guard !busy, var d = document,
              d.layers.contains(where: { $0.id == stroke.layerID && $0.isVisible && !$0.isLocked }) else { return }
        history.recordNewStroke(stroke, in: &d); document = d; changed(appending: true)
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
    func addParallelCopy() {
        guard canDraw, !isDrawing, let d = document,
              let source = d.strokes.last(where: { $0.layerID == d.activeLayerID && $0.operation == .ink }),
              let copy = StrokeGeometry.parallelCopy(source, distance: parallelDistance) else { return }
        var candidate = d; candidate.strokes.append(copy)
        do { try candidate.validate(); append(copy) }
        catch { self.error = error.localizedDescription }
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
        try await previewService.layerThumbnail(snapshot, id: id)
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
            after.layers[index].raster = raster; after.version = 17
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
            after.layers[index].raster?.placement = p; after.version = 17
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
    func setShowBrushCursor(_ visible: Bool) {
        showBrushCursor = visible
        preferences?.set(visible, forKey: "showBrushCursor")
        brushPreviewRequested?(false)
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
            eraserBrush.opacity = max(0, min(1, value)); rememberEraser()
        }
        else { setOpacity(value) }
    }
    func setSoftEraser(_ soft: Bool) {
        guard canEdit, !isDrawing else { return }
        let previous = eraserBrush
        eraserSettings[previous.preset] = previous
        let preset: BrushPreset = soft ? .softShader : .fineliner
        eraserBrush = eraserSettings[preset] ?? (soft ? preset.makeBrush() : InkBrush(width: previous.width, stabilization: 0.15))
        eraserBrush.width = previous.width; eraserBrush.opacity = previous.opacity
        eraserBrush.pressureEnabled = previous.pressureEnabled; eraserBrush.stabilization = previous.stabilization
        eraserBrush.stabilizationEnabled = previous.stabilizationEnabled
        rememberEraser()
    }
    func setEraserBrush(_ preset: BrushPreset) {
        guard canEdit, !isDrawing, document != nil else { return }
        eraserSettings[eraserBrush.preset] = eraserBrush
        eraserBrush = eraserSettings[preset] ?? preset.makeBrush()
        tool = .eraser; rememberEraser()
    }
    private func editInputBrush(_ edit: (inout InkBrush) -> Void) {
        guard canEdit, !isDrawing, document != nil else { return }
        var brush = inputBrush; edit(&brush)
        guard brush.isValid else { return }
        if tool == .eraser { eraserBrush = brush; rememberEraser() }
        else { document?.brush = brush; changed() }
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
    func applyTapTool(at point: Point) async {
        if tool == .fill { await fill(at: point) }
        else if tool == .eyedropper { await pickColor(at: point) }
    }
    func fill(at point: Point) async {
        finishLayerOpacityEdit()
        guard canDraw, !isDrawing, let before = document, point.isFinite,
              (0..<before.size.x).contains(point.x), (0..<before.size.y).contains(point.y),
              before.brush.opacity > 0 else { return }
        guard before.layers.count < LayerManager.maximumLayers else { error = DocumentError.memoryLimit.localizedDescription; return }
        busy = true; defer { busy = false }
        do {
            let raster = try await exportService.filledRegion(before, point: point)
            guard document?.id == before.id,
                  let index = before.layers.firstIndex(where: { $0.id == before.activeLayerID }) else { return }
            var after = before
            var layer = DrawingLayer(); layer.name = "Fill \(after.layers.count + 1)"; layer.raster = raster
            after.layers.insert(layer, at: index)
            // Keep the linework active so another fill stays underneath it.
            try after.validate()
            history.recordLayerChange(from: before, to: after)
            document = after; changed()
        } catch { self.error = error.localizedDescription }
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
    func setTileCount(_ count: Int) {
        guard canEdit, !isDrawing, let size = document?.size, [0, 2, 4].contains(count) else { return }
        document?.symmetry.tileCount = count; document?.symmetry.tileCanvas = size; changed()
    }
    func setWidth(_ width: Double) {
        guard canEdit, !isDrawing, width.isFinite else { return }
        document?.brush.width = max(0.5, min(160, width)); changed()
    }
    func setBrush(_ preset: BrushPreset) {
        guard canEdit, !isDrawing, document != nil else { return }
        if let current = document?.brush { brushSettings[current.preset] = current }
        var selected = brushSettings[preset] ?? preset.makeBrush()
        // Upgrade the selected brush only. Brushes embedded in old strokes
        // retain their original geometry, including their legacy random seed.
        if preset == .dotShader, selected.pressureDensity == nil {
            selected.pressureDensity = true; selected.pressureGain = 1; selected.pressureCurve = 1
        }
        document?.brush = selected; changed()
        preferredBrushPreset = preset
        preferences?.set(preset.rawValue, forKey: "activeBrushPreset")
        tool = .brush
    }
    func setOpacity(_ value: Double) {
        guard canEdit, !isDrawing, value.isFinite, document != nil else { return }
        document?.brush.opacity = max(0, min(1, value)); changed()
    }
    func setSpacing(_ value: Double) {
        guard value.isFinite else { return }
        editInputBrush { $0.spacing = max(0.06, min(4, value)) }
    }
    func setDensity(_ value: Double) {
        guard value.isFinite else { return }
        editInputBrush { $0.density = max(0.05, min(1, value)) }
    }
    func setDotResponse(pressureDensity: Bool? = nil, size: Double? = nil) {
        guard inputBrush.preset == .dotShader else { return }
        editInputBrush {
            if let pressureDensity { $0.pressureDensity = pressureDensity }
            if let size, size.isFinite { $0.dotSize = max(0.5, min(8, size)) }
        }
    }
    func setPressure(_ enabled: Bool) {
        editInputBrush { $0.pressureEnabled = enabled }
    }
    func setStabilization(_ amount: Double) {
        guard amount.isFinite else { return }
        editInputBrush { $0.stabilization = max(0, min(1, amount)) }
    }
    func setStabilizationEnabled(_ enabled: Bool) {
        editInputBrush { $0.stabilizationEnabled = enabled }
    }
    func setPenResponse(adaptive: Bool? = nil, curve: Double? = nil, minimum: Double? = nil,
                        start: Double? = nil, end: Double? = nil, tilt: Double? = nil,
                        softness: Double? = nil, falloff: Double? = nil, gain: Double? = nil) {
        guard canEdit, !isDrawing, document != nil else { return }
        var brush = inputBrush
        if let adaptive { brush.adaptiveStabilization = adaptive }
        if let curve, curve.isFinite { brush.pressureCurve = max(0.2, min(3, curve)) }
        if let minimum, minimum.isFinite { brush.minimumSize = max(0, min(1, minimum)) }
        if let start, start.isFinite { brush.taperStart = max(0, min(2, start)) }
        if let end, end.isFinite { brush.taperEnd = max(0, min(2, end)) }
        if let tilt, tilt.isFinite { brush.tiltShading = max(0, min(1, tilt)) }
        if let softness, softness.isFinite { brush.edgeSoftness = max(0, min(1, softness)) }
        if let falloff, falloff.isFinite { brush.falloff = max(0, min(1, falloff)) }
        if let gain, gain.isFinite { brush.pressureGain = max(1, min(5, gain)) }
        if tool == .eraser { eraserBrush = brush; rememberEraser() }
        else { document?.brush = brush; changed() }
    }
    private func changed(appending: Bool = false) {
        if !appending { appendLineage = UUID() }
        document?.version = 17; document?.modified = Date()
        if let brush = document?.brush { rememberBrush(brush) }
        generation += 1
        saveStatus = "Unsaved changes"
        schedule.edited(at: ProcessInfo.processInfo.systemUptime)
        rescheduleMaintenance()
    }
    var inkBudgetReport: String {
        "Input points: \(usedSamples) / \(DrawingLimits.sampleCount)\nDocument geometry estimate (reconstructible): \(usedVertices * 16 / 1024) KiB\nStrokes: \(document?.strokes.count ?? 0)"
    }
    private func rememberBrush(_ brush: InkBrush) {
        guard brushSettings[brush.preset] != brush else { return }
        brushSettings[brush.preset] = brush
        let settings = Dictionary(uniqueKeysWithValues: brushSettings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(settings) { preferences?.set(data, forKey: "brushSettings") }
    }
    private func rememberEraser() {
        eraserSettings[eraserBrush.preset] = eraserBrush
        if let data = try? JSONEncoder().encode(eraserBrush) { preferences?.set(data, forKey: "eraserSettings") }
        let settings = Dictionary(uniqueKeysWithValues: eraserSettings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(settings) { preferences?.set(data, forKey: "eraserBrushSettings") }
    }
    @discardableResult
    func saveNow(incremental: Bool = false) async -> Bool {
        guard let expectedID = document?.id else { return true }
        while saveRunning {
            do { try await Task.sleep(nanoseconds: 10_000_000) }
            catch { return false }
            guard document?.id == expectedID else { return false }
        }
        guard let snapshot = document, !isDrawing else { return false }
        saveRunning = true; defer { saveRunning = false }
        let lineage = appendLineage
        let requestedGeneration = generation
        writeSequence += 1
        let sequence = writeSequence
        saveStatus = "Saving…"
        do {
            if incremental { try await repository.autosave(snapshot, generation: sequence, appendLineage: lineage) }
            else { try await repository.save(snapshot, generation: sequence, appendLineage: lineage) }
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
            try await repository.checkpoint(snapshot, generation: sequence, appendLineage: appendLineage)
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
                    let thumbnail = try await self.previewService.thumbnail(snapshot)
                    try Task.checkCancellation()
                    try await self.repository.storeThumbnail(thumbnail, id: snapshot.id, generation: snapshot.storageRevision)
                    guard !Task.isCancelled, self.document == nil, self.thumbnailRequest == request else { return }
                    self.thumbnailRefreshIDs.remove(project.id)
                    if let index = self.projects.firstIndex(where: { $0.id == project.id }) {
                        self.projects[index].thumbnail = thumbnail
                    }
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
