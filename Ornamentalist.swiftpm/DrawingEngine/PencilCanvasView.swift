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
    private var drawingTouch: UITouch?
    private var preview: [Point] = []
    private var navigationGestures: [UIGestureRecognizer] = []

    init(model: StudioModel) {
        self.model = model
        resetToken = model.resetViewToken
        super.init(frame: .zero, device: nil)
        isMultipleTouchEnabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(suspendDrawing),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        accessibilityLabel = "Ornamentalist drawing canvas"
        accessibilityHint = "Draw with Apple Pencil. Use two fingers to pan, pinch to zoom, or rotate."
        do {
            renderer = try MetalCanvasRenderer(view: self)
            delegate = self
        } catch { report(error) }
        model.captureActiveStroke = { [weak self] in self?.session?.stroke }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panCanvas(_:)))
        pan.minimumNumberOfTouches = 2; pan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchCanvas(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(rotateCanvas(_:)))
        navigationGestures = [pan, pinch, rotate]
        for gesture in navigationGestures {
            gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            gesture.cancelsTouchesInView = false
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
    }
    required init(coder: NSCoder) { fatalError("Create PencilCanvasView programmatically") }
    deinit { preparation?.cancel(); NotificationCenter.default.removeObserver(self) }
    func synchronize() {
        if resetToken != model.resetViewToken {
            resetToken = model.resetViewToken; viewport = Viewport()
        }
        guard let document = model.document, let renderer else { return }
        let ids = document.strokes.map(\.id)
        if ids != synchronizedIDs {
            synchronizedIDs = ids
            preparation?.cancel()
            preparationID = UUID()
            let request = preparationID
            renderer.prune(document.strokes)
            if !renderer.hasBuffers(for: document.strokes) {
                pendingPreparation = true
                preparation = Task { [weak self] in
                    guard let self else { return }
                    self.model.setPreparing(true)
                    defer {
                        if self.preparationID == request {
                            self.pendingPreparation = false; self.model.setPreparing(false); self.setNeedsDisplay()
                        }
                    }
                    do { try await renderer.synchronize(document.strokes) }
                    catch is CancellationError { }
                    catch { self.report(error) }
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
        guard let document = model.document, bounds.width > 0, bounds.height > 0 else { return }
        do {
            try renderer?.draw(view: self, document: document, viewport: viewport,
                               active: active, preview: preview, guides: model.guides)
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
                            altitude: Double(touch.altitudeAngle), azimuth: Double(touch.azimuthAngle(in: self)) - viewport.rotation,
                            time: touch.timestamp)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard active == nil, !pendingPreparation, let document = model.document, model.canEdit, renderer != nil,
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
        session = StrokeSession(brush: document.brush, symmetry: document.symmetry,
                                existingSamples: model.usedSamples, existingVertices: model.usedVertices)
        renderer?.begin(); model.setDrawing(true)
        // Navigation is frozen for the duration of a Pencil stroke: palms cannot move the canvas.
        if touch.type == .pencil { navigationGestures.forEach { $0.isEnabled = false } }
        ingest(touch, event: event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }
        ingest(touch, event: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }
        ingest(touch, event: event); finishStroke()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }
        // System cancellation preserves confirmed ink; predictions are always discarded.
        finishStroke()
    }
    private func ingest(_ touch: UITouch, event: UIEvent?) {
        guard session != nil else { return }
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
        guard let stroke = session?.stroke else { return }
        session = nil; drawingTouch = nil; preview = []
        if rebuild { renderer?.cancel() }
        else {
            do { try renderer?.commit(stroke) } catch { renderer?.cancel(); report(error) }
        }
        model.setDrawing(false)
        if !stroke.samples.isEmpty { model.append(stroke) }
        navigationGestures.forEach { $0.isEnabled = true }
        setNeedsDisplay()
    }
    @objc private func suspendDrawing() {
        finishStroke()
        Task { await model.saveNow() }
    }
    private func report(_ error: Error) {
        // UIViewRepresentable may be updating; publish after that update finishes.
        Task { @MainActor [weak self] in self?.model.error = error.localizedDescription }
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // In optional finger mode, a second finger abandons the tentative finger stroke.
        if drawingTouch?.type == .direct {
            session = nil; drawingTouch = nil; preview = []; renderer?.cancel(); model.setDrawing(false)
        }
        return active == nil
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    @objc private func panCanvas(_ gesture: UIPanGestureRecognizer) {
        guard active == nil else { return }
        let p = gesture.translation(in: self)
        viewport.pan = viewport.pan + Point(x: Double(p.x), y: Double(p.y))
        gesture.setTranslation(.zero, in: self); setNeedsDisplay()
    }
    private func anchor(_ gesture: UIGestureRecognizer) -> Point {
        let p = gesture.location(in: self)
        return Point(x: Double(p.x), y: Double(p.y))
    }
    @objc private func pinchCanvas(_ gesture: UIPinchGestureRecognizer) {
        guard active == nil else { return }
        let screen = anchor(gesture), canvas = canvasMatrix.inverse.apply(screen)
        viewport.zoom = max(0.25, min(12, viewport.zoom * Double(gesture.scale)))
        viewport.pan = viewport.pan + screen - canvasMatrix.apply(canvas)
        gesture.scale = 1; setNeedsDisplay()
    }
    @objc private func rotateCanvas(_ gesture: UIRotationGestureRecognizer) {
        guard active == nil else { return }
        let screen = anchor(gesture), canvas = canvasMatrix.inverse.apply(screen)
        viewport.rotation += Double(gesture.rotation)
        viewport.pan = viewport.pan + screen - canvasMatrix.apply(canvas)
        gesture.rotation = 0; setNeedsDisplay()
    }
}
