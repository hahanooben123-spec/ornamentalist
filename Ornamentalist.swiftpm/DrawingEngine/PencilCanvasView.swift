import SwiftUI
import MetalKit

@MainActor
struct PencilCanvas: UIViewRepresentable {
    @ObservedObject var model: StudioModel
    func makeUIView(context: Context) -> PencilCanvasView { PencilCanvasView(model: model) }
    func updateUIView(_ view: PencilCanvasView, context: Context) { view.synchronize() }
}

@MainActor
final class PencilCanvasView: MTKView, MTKViewDelegate, UIGestureRecognizerDelegate {
    private let model: StudioModel
    private var renderer: MetalCanvasRenderer?
    private var viewport = Viewport()
    private var resetToken: UUID
    private var session: StrokeSession?
    private var active: InkStroke? { session?.stroke }
    private var preparation: Task<Void, Never>?
    private var preparationID = UUID()
    private var pendingPreparation = false
    private var synchronizedIDs: [UUID] = []
    private var synchronizedRasters: [UUID] = []
    private var drawingTouch: UITouch?
    private var colorTouch: UITouch?
    private var preview: [BrushVertex] = []
    private var navigationGestures: [UIGestureRecognizer] = []
    private let brushCursor = CAShapeLayer()
    private let cursorHalo = CAShapeLayer()
    private var hoverPoint: CGPoint?
    private var cursorCanvasPoint: Point?
    private let transformOutline = CAShapeLayer()
    private let transformHandles = CAShapeLayer()
    private var transformTouch: UITouch?
    private var transformLastPoint: Point?
    private var scalingHandle = false

    init(model: StudioModel) {
        self.model = model
        resetToken = model.resetViewToken
        super.init(frame: .zero, device: nil)
        isMultipleTouchEnabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(suspendDrawing),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(releaseRenderCaches),
                                               name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        accessibilityLabel = "Ornamentalist drawing canvas"
        accessibilityIdentifier = "drawingCanvas"
        isAccessibilityElement = true
        accessibilityHint = "Draw with Apple Pencil. Two-finger tap undoes; three-finger tap redoes. Use two fingers to pan, pinch to zoom, or rotate."
        for cursor in [cursorHalo, brushCursor] {
            cursor.fillColor = UIColor.clear.cgColor
            cursor.actions = ["path": NSNull(), "hidden": NSNull(), "position": NSNull()]
            layer.addSublayer(cursor)
        }
        cursorHalo.strokeColor = UIColor.white.cgColor; cursorHalo.lineWidth = 3
        brushCursor.strokeColor = UIColor.black.withAlphaComponent(0.85).cgColor; brushCursor.lineWidth = 1
        transformOutline.strokeColor = UIColor.systemBlue.cgColor; transformOutline.fillColor = UIColor.clear.cgColor
        transformOutline.lineWidth = 1.5
        transformHandles.strokeColor = UIColor.systemBlue.cgColor; transformHandles.fillColor = UIColor.white.cgColor
        transformHandles.lineWidth = 2
        for overlay in [transformOutline, transformHandles] {
            overlay.actions = ["path": NSNull(), "hidden": NSNull()]
            layer.addSublayer(overlay)
        }
        updateBrushCursor()
        do {
            renderer = try MetalCanvasRenderer(view: self)
            delegate = self
        } catch { report(error) }
        model.captureActiveStroke = { [weak self] in self?.session?.stroke }
        model.rendererDiagnostics = { [weak self] in self?.renderer?.performanceReport() ?? "Renderer unavailable" }
        model.brushPreviewRequested = { [weak self] editing in self?.showSizePreview(editing) }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panCanvas(_:)))
        pan.minimumNumberOfTouches = 2; pan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchCanvas(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(rotateCanvas(_:)))
        let undo = UITapGestureRecognizer(target: self, action: #selector(undoTap(_:)))
        undo.numberOfTouchesRequired = 2
        let redo = UITapGestureRecognizer(target: self, action: #selector(redoTap(_:)))
        redo.numberOfTouchesRequired = 3
        undo.require(toFail: redo)
        let transforms: [UIGestureRecognizer] = [pan, pinch, rotate]
        for tap in [undo, redo] {
            for navigation in transforms { tap.require(toFail: navigation) }
        }
        navigationGestures = [pan, pinch, rotate, undo, redo]
        for gesture in navigationGestures {
            gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            gesture.cancelsTouchesInView = false
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverPencil(_:)))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        hover.cancelsTouchesInView = false
        hover.delegate = self; addGestureRecognizer(hover)
    }
    required init(coder: NSCoder) { fatalError("Create PencilCanvasView programmatically") }
    deinit { preparation?.cancel(); NotificationCenter.default.removeObserver(self) }
    override func layoutSubviews() {
        super.layoutSubviews()
        updateBrushCursor()
        updateTransformOutline()
    }
    func synchronize() {
        if resetToken != model.resetViewToken {
            resetToken = model.resetViewToken; viewport = Viewport()
        }
        updateBrushCursor()
        updateTransformOutline()
        guard let document = model.displayDocument, let renderer else { return }
        let ids = document.strokes.map(\.id)
        let rasters = document.layers.compactMap { $0.raster?.id }
        if ids != synchronizedIDs || rasters != synchronizedRasters {
            synchronizedIDs = ids; synchronizedRasters = rasters
            preparation?.cancel()
            preparationID = UUID()
            let request = preparationID
            renderer.prune(document.strokes, layers: document.layers)
            if !renderer.hasBuffers(for: document.strokes, layers: document.layers) {
                pendingPreparation = true
                preparation = Task { [weak self] in
                    guard let self, self.preparationID == request, !Task.isCancelled else { return }
                    self.model.setPreparing(true)
                    defer {
                        if self.preparationID == request {
                            self.pendingPreparation = false; self.model.setPreparing(false); self.setNeedsDisplay()
                        }
                    }
                    do { try await renderer.synchronize(document.strokes, layers: document.layers) }
                    catch is CancellationError { }
                    catch { self.report(error) }
                }
            } else {
                // Undo/Redo can replace an upload before its task starts. Do not
                // leave a stale preparation flag blocking an otherwise ready canvas.
                pendingPreparation = false
                preparation = nil
                Task { [weak self] in
                    guard let self, self.preparationID == request else { return }
                    self.model.setPreparing(false)
                }
            }
        }
        setNeedsDisplay()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // A resize changes the inverse mapping; end a stroke in its old coordinate frame.
        finishStroke()
        setNeedsDisplay()
    }
    func draw(in view: MTKView) {
        // Never warm a layer cache with missing source buffers while uploads run.
        guard !pendingPreparation, !model.isPreparing, let document = model.displayDocument,
              bounds.width > 0, bounds.height > 0 else { return }
        do {
            try renderer?.draw(view: self, document: document, viewport: viewport,
                               active: active, preview: preview, guides: model.guides, revision: model.generation)
        } catch { report(error) }
    }
    private var canvasMatrix: Matrix {
        viewport.matrix(viewSize: Point(x: Double(bounds.width), y: Double(bounds.height)),
                        canvasSize: model.document?.size ?? Point(x: 2048, y: 2048))
    }
    private func point(_ touch: UITouch) -> Point {
        let p = touch.preciseLocation(in: self)
        return canvasMatrix.inverse.apply(Point(x: Double(p.x), y: Double(p.y)))
    }
    private func sample(_ touch: UITouch) -> StrokeSample {
        let force = touch.type == .pencil && touch.maximumPossibleForce > 0
            ? Double(touch.force / touch.maximumPossibleForce) : 0.6
        return StrokeSample(point: point(touch), pressure: max(0, min(1, force)),
                            altitude: touch.type == .pencil ? Double(touch.altitudeAngle) : .pi / 2,
                            azimuth: touch.type == .pencil ? Double(touch.azimuthAngle(in: self)) - viewport.rotation : 0,
                            time: touch.timestamp)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let fingers = event?.allTouches?.filter { $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled }.count ?? 0
        if model.isTransforming {
            guard fingers <= 1, let touch = touches.first else { transformTouch = nil; transformLastPoint = nil; return }
            transformTouch = touch; transformLastPoint = point(touch)
            let location = touch.preciseLocation(in: self)
            scalingHandle = transformScreenCorners().contains { hypot($0.x - location.x, $0.y - location.y) < 28 }
            return
        }
        if fingers > 1 && !touches.contains(where: { $0.type == .pencil }) {
            colorTouch = nil
            discardFingerStroke()
            return
        }
        hoverPoint = nil; updateBrushCursor()
        if model.tool == .eyedropper, model.canEdit, active == nil,
           let touch = touches.first(where: { $0.type == .pencil }) ?? touches.first(where: { $0.type == .direct }) {
            if touch.type == .pencil {
                let picked = point(touch)
                Task { await model.pickColor(at: picked) }
            } else {
                // Wait for release: a second finger may turn this into history
                // or navigation rather than a color selection.
                colorTouch = touch
            }
            return
        }
        guard active == nil, !pendingPreparation, let document = model.document, model.canDraw, renderer != nil,
              document.strokes.count < 20_000 else { return }
        let selected = touches.first(where: { $0.type == .pencil }) ??
            (model.fingerDrawing ? touches.first(where: { $0.type == .direct }) : nil)
        guard let touch = selected else { return }
        if touch.type == .direct, (event?.allTouches?.filter { $0.type == .direct && $0.phase != .ended }.count ?? 0) > 1 {
            return
        }
        let p = point(touch)
        guard (0...document.size.x).contains(p.x), (0...document.size.y).contains(p.y) else { return }
        guard model.usedSamples < DrawingLimits.sampleCount, model.usedVertices < DrawingLimits.vertexCount else {
            report(DocumentError.memoryLimit); return
        }
        drawingTouch = touch
        session = StrokeSession(brush: model.tool == .eraser ? model.eraserBrush : document.brush, symmetry: document.symmetry,
                                existingSamples: model.usedSamples, existingVertices: model.usedVertices,
                                layerID: document.activeLayerID, color: document.color, operation: model.tool == .eraser ? .erase : .ink,
                                inputScale: hypot(canvasMatrix.a, canvasMatrix.b))
        renderer?.begin(); model.setDrawing(true)
        // Navigation is frozen for the duration of a Pencil stroke: palms cannot move the canvas.
        if touch.type == .pencil { navigationGestures.forEach { $0.isEnabled = false } }
        ingest(touch, event: event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if model.isTransforming, let touch = transformTouch, touches.contains(touch), let previous = transformLastPoint {
            let current = point(touch)
            if scalingHandle, let placement = model.imageTransform {
                let oldDistance = (previous - placement.center).length
                if oldDistance > 0.1 { model.scaleImage(by: (current - placement.center).length / oldDistance) }
            } else { model.moveImage(by: current - previous) }
            transformLastPoint = current; updateTransformOutline(); setNeedsDisplay()
            return
        }
        guard let touch = drawingTouch, touches.contains(touch) else { return }
        ingest(touch, event: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if model.isTransforming { transformTouch = nil; transformLastPoint = nil; return }
        if let touch = colorTouch, touches.contains(touch) {
            colorTouch = nil
            let picked = point(touch)
            Task { await model.pickColor(at: picked) }
            return
        }
        guard let touch = drawingTouch, touches.contains(touch) else { return }
        ingest(touch, event: event); finishStroke()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if model.isTransforming { transformTouch = nil; transformLastPoint = nil; return }
        if let touch = colorTouch, touches.contains(touch) { colorTouch = nil }
        guard let touch = drawingTouch, touches.contains(touch) else { return }
        // System cancellation preserves confirmed ink; predictions are always discarded.
        finishStroke()
    }
    private func ingest(_ touch: UITouch, event: UIEvent?) {
        guard session != nil else { return }
        cursorCanvasPoint = point(touch)
        updateBrushCursor()
        do {
            for t in event?.coalescedTouches(for: touch) ?? [touch] {
                if let addition = try session?.append(sample(t)) { try renderer?.append(addition) }
            }
            if let session {
                preview = session.preview(predictions: (event?.predictedTouches(for: touch) ?? []).prefix(12).map { sample($0) })
            }
            setNeedsDisplay()
        } catch {
            finishStroke(rebuild: true); report(error)
        }
    }
    private func finishStroke(rebuild: Bool = false) {
        guard let completed = session else { return }
        let stroke = completed.finishedStroke()
        session = nil; drawingTouch = nil; preview = []
        if rebuild { renderer?.cancel() }
        else {
            do { try renderer?.commit(stroke) } catch { renderer?.cancel(); report(error) }
        }
        model.setDrawing(false)
        if !stroke.samples.isEmpty { model.append(stroke, estimatedVertices: completed.estimatedVertexCount) }
        navigationGestures.forEach { $0.isEnabled = true }
        updateBrushCursor()
        setNeedsDisplay()
    }
    @objc private func suspendDrawing() {
        colorTouch = nil
        finishStroke()
        Task { await model.saveNow() }
    }
    @objc private func releaseRenderCaches() {
        renderer?.handleMemoryPressure()
        setNeedsDisplay()
    }
    private func report(_ error: Error) {
        // UIViewRepresentable may be updating; publish after that update finishes.
        Task { @MainActor [weak self] in self?.model.error = error.localizedDescription }
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if model.isTransforming {
            return !(gestureRecognizer is UITapGestureRecognizer) && !model.busy && !model.isPreparing
        }
        // In optional finger mode, a second finger abandons the tentative finger stroke.
        if navigationGestures.contains(where: { $0 === gestureRecognizer }) {
            colorTouch = nil; discardFingerStroke()
        }
        return active == nil && model.canEdit
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // A tap never shares recognition with a pan/pinch/rotation or another tap.
        !(gestureRecognizer is UITapGestureRecognizer) && !(otherGestureRecognizer is UITapGestureRecognizer)
    }
    private func discardFingerStroke() {
        guard drawingTouch?.type == .direct else { return }
        session = nil; drawingTouch = nil; preview = []; renderer?.cancel(); model.discardActiveCheckpoint()
        setNeedsDisplay()
    }
    @objc private func undoTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, active == nil, model.canEdit else { return }
        model.undo()
    }
    @objc private func redoTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, active == nil, model.canEdit else { return }
        model.redo()
    }
    private func showSizePreview(_: Bool) {
        updateBrushCursor()
    }
    @objc private func hoverPencil(_ gesture: UIHoverGestureRecognizer) {
        if gesture.state == .began || gesture.state == .changed {
            hoverPoint = gesture.location(in: self)
            if let hoverPoint {
                cursorCanvasPoint = canvasMatrix.inverse.apply(Point(x: Double(hoverPoint.x), y: Double(hoverPoint.y)))
            }
        }
        else { hoverPoint = nil }
        updateBrushCursor()
    }
    private func updateBrushCursor() {
        let hidden = model.tool == .eyedropper || !model.canDraw
        accessibilityValue = "Strokes: \(model.document?.strokes.count ?? 0)"
        brushCursor.isHidden = hidden; cursorHalo.isHidden = hidden
        guard !hidden, bounds.width > 0, bounds.height > 0 else { return }
        let fallback = CGPoint(x: bounds.midX, y: bounds.midY)
        var center = hoverPoint ?? fallback
        if hoverPoint == nil, let cursorCanvasPoint {
            let position = canvasMatrix.apply(cursorCanvasPoint)
            center = CGPoint(x: position.x, y: position.y)
        }
        if !bounds.contains(center) { center = fallback }
        let diameter = CGFloat(model.inputBrush.width * hypot(canvasMatrix.a, canvasMatrix.b))
        let circle = CGPath(ellipseIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                             width: diameter, height: diameter), transform: nil)
        brushCursor.path = circle; cursorHalo.path = circle
    }
    @objc private func panCanvas(_ gesture: UIPanGestureRecognizer) {
        if model.isTransforming {
            let delta = gesture.translation(in: self), inverse = canvasMatrix.inverse
            model.moveImage(by: inverse.apply(Point(x: Double(delta.x), y: Double(delta.y))) - inverse.apply(.zero))
            gesture.setTranslation(.zero, in: self); updateTransformOutline(); setNeedsDisplay(); return
        }
        guard active == nil else { return }
        let p = gesture.translation(in: self)
        viewport.pan = viewport.pan + Point(x: Double(p.x), y: Double(p.y))
        gesture.setTranslation(.zero, in: self); setNeedsDisplay()
        updateBrushCursor()
    }
    private func anchor(_ gesture: UIGestureRecognizer) -> Point {
        let p = gesture.location(in: self)
        return Point(x: Double(p.x), y: Double(p.y))
    }
    @objc private func pinchCanvas(_ gesture: UIPinchGestureRecognizer) {
        if model.isTransforming {
            model.scaleImage(by: Double(gesture.scale)); gesture.scale = 1
            updateTransformOutline(); setNeedsDisplay(); return
        }
        guard active == nil else { return }
        let screen = anchor(gesture), canvas = canvasMatrix.inverse.apply(screen)
        viewport.zoom = max(0.25, min(12, viewport.zoom * Double(gesture.scale)))
        viewport.pan = viewport.pan + screen - canvasMatrix.apply(canvas)
        gesture.scale = 1; setNeedsDisplay()
        updateBrushCursor()
    }
    @objc private func rotateCanvas(_ gesture: UIRotationGestureRecognizer) {
        if model.isTransforming {
            model.rotateImage(by: Double(gesture.rotation)); gesture.rotation = 0
            updateTransformOutline(); setNeedsDisplay(); return
        }
        guard active == nil else { return }
        let screen = anchor(gesture), canvas = canvasMatrix.inverse.apply(screen)
        viewport.rotation += Double(gesture.rotation)
        viewport.pan = viewport.pan + screen - canvasMatrix.apply(canvas)
        gesture.rotation = 0; setNeedsDisplay()
        updateBrushCursor()
    }
    private func transformScreenCorners() -> [CGPoint] {
        guard model.isTransforming, let d = model.displayDocument, let raster = d.activeLayer?.raster else { return [] }
        return raster.corners(canvas: d.size).map {
            let p = canvasMatrix.apply($0)
            return CGPoint(x: p.x, y: p.y)
        }
    }
    private func updateTransformOutline() {
        let corners = transformScreenCorners()
        transformOutline.isHidden = corners.isEmpty; transformHandles.isHidden = corners.isEmpty
        guard let first = corners.first else { transformTouch = nil; transformLastPoint = nil; return }
        let outline = UIBezierPath(); outline.move(to: first)
        for point in corners.dropFirst() { outline.addLine(to: point) }
        outline.close(); transformOutline.path = outline.cgPath
        let handles = UIBezierPath()
        for point in corners { handles.append(UIBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))) }
        transformHandles.path = handles.cgPath
    }
}
