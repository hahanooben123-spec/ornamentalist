import MetalKit

private struct GPUChunk {
    let buffer: MTLBuffer
    let count: Int
    var offset = 0
}

private struct LayerPaintKey: Equatable {
    let id: UUID
    let raster: UUID?
    let strokes: [UUID]
    var placement: RasterPlacement? = nil
}

private struct RasterQuad {
    let raster: UUID
    let placement: RasterPlacement?
    let canvas: Point
    let buffers: [GPUChunk]
}

private struct LayerCompositeKey: Equatable {
    let paint: LayerPaintKey
    let opacity: Double
}

private struct SurfaceKey: Equatable {
    let document: UUID
    let canvas: Point
    let view: Point
    let transform: Matrix
    let width: Int
    let height: Int
}

/// All Metal resources are owned on the main thread. Immutable vertex buffers
/// remain valid while the GPU consumes previous frames; no shared-buffer races.
@MainActor
final class MetalCanvasRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let erasePipeline: MTLRenderPipelineState
    private let rasterPipeline: MTLRenderPipelineState
    private var rasterTextures: [UUID: MTLTexture] = [:]
    private var rasterQuads: [UUID: RasterQuad] = [:]
    private let singlePipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let restoreSamplesPipeline: MTLRenderPipelineState
    private let restoreColorPipeline: MTLRenderPipelineState
    private let clearCoveragePipeline: MTLRenderPipelineState
    private let clearCoverageState: MTLDepthStencilState
    private let paintOnceState: MTLDepthStencilState
    private var coverageStencil: MTLTexture?
    private var workTexture: MTLTexture?
    private var workMultisample: MTLTexture?
    private var surfaceKey: SurfaceKey?
    private var lowerTexture: MTLTexture?
    private var upperTexture: MTLTexture?
    private var lowerKey: [LayerCompositeKey]?
    private var upperKey: [LayerCompositeKey]?
    private var activeTexture: MTLTexture?
    private var activeKey: LayerPaintKey?
    private var activeLiveID: UUID?
    private var activeLiveVertices = 0
    private var pendingLiveCommit: UUID?
    private var cacheBudget = 160 * 1024 * 1024
    private(set) var workingTextureAllocations = 0
    private(set) var committedStrokeDraws = 0
    private(set) var cachedGroupBuilds = 0
    private(set) var cachedLayerBuilds = 0
    private(set) var incrementalLayerUpdates = 0
    private(set) var liveConfirmedVertexDraws = 0
    private(set) var renderCacheBytes = 0
    private var liveRevision = 0
    private var uploadedLiveRevision = -1
    private var uploadedLive: [GPUChunk] = []
    private var uploadedPrediction: [BrushVertex] = []
    private var predictionBuffers: [GPUChunk] = []
    private let groupInFlight = DispatchSemaphore(value: 1)
    private var cache: [UUID: [GPUChunk]] = [:]
    private var sealed: [GPUChunk] = []
    private var scratch: [SIMD4<Float>] = []
    private let chunkSize = 8190 // Multiple of three.
    private let inFlight = DispatchSemaphore(value: 3)
    private let sampleCount: Int
    private var paperSize = Point.zero
    private var paper: [GPUChunk] = []
    private var guideKey: [Double] = []
    private var guideBuffers: [GPUChunk] = []
    private var matrixCache: [SymmetryConfiguration: MTLBuffer] = [:]
    private var sceneLayerStrokes: [UUID: [InkStroke]] = [:]
    private var scenePaintKeys: [UUID: LayerPaintKey] = [:]
    private var sceneDocumentID: UUID?
    private var sceneRevision: Int?
    private(set) var allocatedVertexCount = 0
    private var sealedVertexCount = 0
    private var cpuFrameMilliseconds: [Double] = []
    private var gpuFrameMilliseconds: [Double] = []
    private var deferredFrames = 0

    func performanceReport() -> String {
        func timing(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "No samples yet" }
            let sorted = values.sorted()
            let median = sorted[sorted.count / 2]
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            return String(format: "median %.2f ms · p95 %.2f ms", median, p95)
        }
        let bytes = (allocatedVertexCount + sealedVertexCount + scratch.count) * MemoryLayout<SIMD4<Float>>.stride
        return "Ornamentalist 0.9.1\nCPU frame submission: \(timing(cpuFrameMilliseconds))\nGPU execution: \(timing(gpuFrameMilliseconds))\nDeferred frames: \(deferredFrames)\nSource vertex buffers: \(bytes / 1024) KiB\nRender caches: \(renderCacheBytes / 1024) KiB\nWorking texture allocations: \(workingTextureAllocations)\nCommitted stroke draws: \(committedStrokeDraws)\nLayer/group rebuilds: \(cachedLayerBuilds)/\(cachedGroupBuilds)\nIncremental commits: \(incrementalLayerUpdates)\nLive confirmed vertex draws: \(liveConfirmedVertexDraws)\n\nLast 240 samples. These timings do not measure Pencil-to-screen latency or total app memory."
    }
    private func recordCPU(_ milliseconds: Double) {
        cpuFrameMilliseconds.append(milliseconds)
        if cpuFrameMilliseconds.count > 240 { cpuFrameMilliseconds.removeFirst() }
    }
    private func recordGPU(_ milliseconds: Double) {
        guard milliseconds > 0 else { return }
        gpuFrameMilliseconds.append(milliseconds)
        if gpuFrameMilliseconds.count > 240 { gpuFrameMilliseconds.removeFirst() }
    }

    init(view: MTKView) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw DocumentError.noMetal
        }
        self.device = device
        self.queue = queue
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        let preferredSampleCount = device.supportsTextureSampleCount(4) ? 4 : 1
        sampleCount = preferredSampleCount
        // MSAA lives in our reusable layer targets. Avoid allocating a second,
        // unused full-screen multisample drawable in MTKView.
        view.sampleCount = 1
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "inkVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "inkFragment")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.rasterSampleCount = sampleCount
        descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        let attachment = descriptor.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        attachment.sourceRGBBlendFactor = .zero
        attachment.sourceAlphaBlendFactor = .zero
        erasePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "rasterFragment")
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        rasterPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "inkFragment")
        attachment.sourceRGBBlendFactor = .sourceAlpha
        descriptor.rasterSampleCount = 1
        descriptor.stencilAttachmentPixelFormat = .invalid
        descriptor.depthAttachmentPixelFormat = .invalid
        singlePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.vertexFunction = library.makeFunction(name: "compositeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "compositeFragment")
        attachment.sourceRGBBlendFactor = .one // Layer textures are premultiplied.
        compositePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.rasterSampleCount = sampleCount
        descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        attachment.isBlendingEnabled = false
        restoreColorPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "restoreSamplesFragment")
        restoreSamplesPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = nil
        attachment.writeMask = []
        clearCoveragePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = .always
        stencil.depthStencilPassOperation = .replace
        let depth = MTLDepthStencilDescriptor()
        depth.frontFaceStencil = stencil; depth.backFaceStencil = stencil
        guard let clearing = device.makeDepthStencilState(descriptor: depth) else { throw DocumentError.graphics }
        clearCoverageState = clearing
        stencil.stencilCompareFunction = .notEqual
        depth.frontFaceStencil = stencil; depth.backFaceStencil = stencil
        guard let once = device.makeDepthStencilState(descriptor: depth) else { throw DocumentError.graphics }
        paintOnceState = once
        view.clearColor = MTLClearColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.preferredFramesPerSecond = 120
        view.isOpaque = true
    }

    private func chunk(_ points: [SIMD4<Float>]) throws -> GPUChunk {
        guard !points.isEmpty else { throw DocumentError.graphics }
        let buffer = points.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }
        guard let buffer else { throw DocumentError.graphicsMemory }
        return GPUChunk(buffer: buffer, count: points.count)
    }
    private func chunks(_ points: [BrushVertex]) throws -> [GPUChunk] {
        var result: [GPUChunk] = []
        for start in stride(from: 0, to: points.count, by: chunkSize) {
            result.append(try chunk(points[start..<min(points.count, start+chunkSize)].map {
                SIMD4(Float($0.point.x), Float($0.point.y), Float($0.local.x), Float($0.local.y))
            }))
        }
        return result
    }
    func hasBuffers(for strokes: [InkStroke], layers: [DrawingLayer] = []) -> Bool {
        strokes.allSatisfy { cache[$0.id] != nil } && layers.compactMap(\.raster).allSatisfy { rasterTextures[$0.id] != nil }
    }
    func prune(_ strokes: [InkStroke], layers: [DrawingLayer] = []) {
        let layerIDs = Set(layers.map(\.id))
        rasterQuads = rasterQuads.filter { layerIDs.contains($0.key) }
        let rasters = Set(layers.compactMap { $0.raster?.id })
        rasterTextures = rasterTextures.filter { rasters.contains($0.key) }
        let ids = Set(strokes.map(\.id))
        cache = cache.filter { ids.contains($0.key) }
        allocatedVertexCount = cache.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
    }
    func synchronize(_ strokes: [InkStroke], layers: [DrawingLayer] = []) async throws {
        let missing = strokes.filter { cache[$0.id] == nil }
        let prepared = try await Task.detached(priority: .userInitiated) {
            var total = 0
            for stroke in strokes {
                total += StrokeGeometry.estimatedVertexCount(stroke)
                guard total <= DrawingLimits.vertexCount else { throw DocumentError.memoryLimit }
            }
            return try missing.map { stroke -> (UUID, [BrushVertex]) in
                try Task.checkCancellation()
                guard StrokeGeometry.estimatedVertexCount(stroke) <= DrawingLimits.strokeVertices else {
                    throw DocumentError.memoryLimit
                }
                return (stroke.id, BrushGeometry.mesh(stroke))
            }
        }.value
        try Task.checkCancellation()
        let incoming = prepared.reduce(0) { $0 + $1.1.count }
        let kept = strokes.filter { cache[$0.id] != nil }.reduce(0) { n, s in
            n + (cache[s.id]?.reduce(0) { $0 + $1.count } ?? 0)
        }
        guard incoming + kept <= DrawingLimits.vertexCount else { throw DocumentError.memoryLimit }
        var uploaded: [UUID: [GPUChunk]] = [:]
        for (id, points) in prepared { uploaded[id] = try chunks(points) }
        let loader = MTKTextureLoader(device: device)
        for raster in layers.compactMap(\.raster) where rasterTextures[raster.id] == nil {
            let image = try PNGExporter.rasterImage(raster)
            let texture = try await loader.newTexture(cgImage: image, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft.rawValue, .generateMipmaps: false])
            try Task.checkCancellation()
            rasterTextures[raster.id] = texture
        }
        prune(strokes, layers: layers)
        for (id, buffers) in uploaded { cache[id] = buffers }
        allocatedVertexCount = cache.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
    }
    func begin() {
        discardUncommittedLiveCache()
        resetInputBuffers()
    }
    private func resetInputBuffers() {
        sealed.removeAll(); sealedVertexCount = 0; scratch.removeAll(keepingCapacity: true)
        liveRevision += 1; uploadedLive.removeAll(); uploadedLiveRevision = -1
        uploadedPrediction.removeAll(); predictionBuffers.removeAll()
    }
    func append(_ points: [BrushVertex]) throws {
        if !points.isEmpty { liveRevision += 1 }
        guard allocatedVertexCount + sealedVertexCount + scratch.count + points.count <= DrawingLimits.vertexCount else {
            throw DocumentError.memoryLimit
        }
        for p in points {
            scratch.append(SIMD4(Float(p.point.x), Float(p.point.y), Float(p.local.x), Float(p.local.y)))
            if scratch.count == chunkSize {
                sealed.append(try chunk(scratch))
                sealedVertexCount += scratch.count
                scratch.removeAll(keepingCapacity: true)
            }
        }
    }
    func append(_ points: [Point]) throws { try append(points.map { BrushVertex($0) }) }
    func commit(_ stroke: InkStroke) throws {
        if !stroke.brush.usesStamps, stroke.brush.taperEnd > 0 || stroke.brush.taperStart > 0 {
            // The ending changes only on Pencil lift. Rebuild this stroke once;
            // input and frame updates retain incremental geometry throughout.
            discardUncommittedLiveCache()
            activeKey = nil; activeLiveID = nil; activeLiveVertices = 0
            resetInputBuffers()
            try append(BrushGeometry.mesh(stroke))
        } else {
            try append(BrushGeometry.tail(stroke))
        }
        if !scratch.isEmpty { sealed.append(try chunk(scratch)) }
        cache[stroke.id] = sealed
        allocatedVertexCount = cache.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
        if activeLiveID == stroke.id { pendingLiveCommit = stroke.id }
        resetInputBuffers()
    }
    func cancel() { begin() }

    private func discardUncommittedLiveCache() {
        if activeLiveID != nil && activeLiveID != pendingLiveCommit {
            activeKey = nil; activeLiveID = nil; activeLiveVertices = 0
        }
    }

    func draw(view: MTKView, document: DrawingDocument, viewport: Viewport,
              active: InkStroke?, preview: [BrushVertex], guides: Bool, revision: Int) throws {
        let started = ProcessInfo.processInfo.systemUptime
        if sceneDocumentID != document.id || sceneRevision != revision {
            updateScene(document); sceneRevision = revision
        }
        // Never block the touch delivery thread when the GPU is behind.
        guard inFlight.wait(timeout: .now()) == .success else {
            deferredFrames += 1
            view.setNeedsDisplay()
            return
        }
        if groupInFlight.wait(timeout: .now()) != .success {
            inFlight.signal(); deferredFrames += 1; view.setNeedsDisplay(); return
        }
        guard let drawable = view.currentDrawable, let command = queue.makeCommandBuffer() else {
            groupInFlight.signal(); inFlight.signal(); return
        }
        let groupGate = groupInFlight
        let gate = inFlight
        // Metal invokes this on its own queue, never on the renderer's main actor.
        command.addCompletedHandler { @Sendable [weak self] command in
            gate.signal()
            groupGate.signal()
            let gpu = (command.gpuEndTime - command.gpuStartTime) * 1000
            Task { @MainActor in self?.recordGPU(gpu) }
        }
        // Even an allocation error closes the encoder and submits its resources.
        defer {
            command.present(drawable); command.commit()
            recordCPU((ProcessInfo.processInfo.systemUptime - started) * 1000)
        }
        let size = Point(x: Double(view.bounds.width), y: Double(view.bounds.height))
        try encodeCachedScene(command: command, output: drawable.texture, document: document,
                              viewport: viewport, viewSize: size, active: active, preview: preview, guides: guides)
    }

    private func encodeScene(encoder: MTLRenderCommandEncoder, document: DrawingDocument, viewport: Viewport,
                             viewSize: Point, active: InkStroke?, preview: [BrushVertex], guides: Bool,
                             layerOnly: UUID? = nil, backgroundOnly: Bool = false,
                             state: MTLRenderPipelineState? = nil) throws {
        encoder.setDepthStencilState(nil)
        encoder.setRenderPipelineState(state ?? pipeline)
        let transform = viewport.matrix(viewSize: viewSize, canvasSize: document.size)
        let identity = SymmetryConfiguration(repetitions: 1, center: .zero)
        if layerOnly == nil {
        if paperSize != document.size || paper.isEmpty {
            paperSize = document.size
            let a = BrushVertex(.zero, local: .zero)
            let b = BrushVertex(Point(x: document.size.x, y: 0), local: Point(x: 1, y: 0))
            let c = BrushVertex(document.size, local: Point(x: 1, y: 1))
            let d = BrushVertex(Point(x: 0, y: document.size.y), local: Point(x: 0, y: 1))
            paper = try chunks([a, b, c, a, c, d])
        }
        try encode(paper, symmetry: identity, transform: transform, size: viewSize,
                   canvas: document.size, color: SIMD4(1, 1, 1, 1), encoder: encoder)
        // Guides are cached, translucent, and BELOW the black artwork.
        if guides {
            let center = document.symmetry.center
            let key = [center.x, center.y, Double(document.symmetry.repetitions), document.symmetry.mirror ? 1 : 0, document.size.x,
                       document.size.y, viewport.zoom, viewSize.x, viewSize.y]
            if guideKey != key {
                let radius = max(document.size.x, document.size.y) * 1.5
                let screenScale = hypot(transform.a, transform.b)
                let brush = InkBrush(width: 0.7 / max(0.01, screenScale))
                var mesh: [Point] = []
                for ray in 0..<document.symmetry.guideRayCount {
                    let a = StrokeSample(point: center, pressure: 1, altitude: 0, azimuth: 0, time: 0)
                    let angle = Double(ray) * 2 * Double.pi / Double(document.symmetry.guideRayCount)
                    var b = a; b.point = center + Matrix.rotation(angle).apply(Point(x: radius, y: 0))
                    mesh += StrokeGeometry.segment(a, b, brush: brush)
                }
                guideBuffers = try chunks(mesh.map { BrushVertex($0) }); guideKey = key
            }
            try encode(guideBuffers, symmetry: identity, transform: transform, size: viewSize,
                       canvas: document.size, color: SIMD4(0.1, 0.5, 0.55, 0.22), encoder: encoder)
        }
        }
        if backgroundOnly { return }
        for layer in document.layers where layer.isVisible && layer.opacity > 0 && (layerOnly == nil || layerOnly == layer.id) {
            if let raster = layer.raster {
                encoder.setDepthStencilState(nil)
                guard let texture = rasterTextures[raster.id] else { throw DocumentError.graphics }
                encoder.setRenderPipelineState(rasterPipeline)
                encoder.setFragmentTexture(texture, index: 0)
                let quad = try rasterQuad(raster, layerID: layer.id, canvas: document.size)
                try encode(quad, symmetry: identity, transform: transform, size: viewSize, canvas: document.size,
                           color: SIMD4(1, 1, 1, 1), encoder: encoder)
            }
            for stroke in sceneLayerStrokes[layer.id] ?? [] {
                committedStrokeDraws += 1
                beginStroke(stroke, encoder: encoder)
                try encode(cache[stroke.id] ?? [], symmetry: stroke.symmetry, transform: transform,
                           size: viewSize, canvas: document.size, color: inkColor(stroke), brush: stroke.brush, encoder: encoder)
            }
            if let active, active.layerID == layer.id {
                try encodeLive(active, preview: preview, transform: transform, viewSize: viewSize,
                               canvas: document.size, encoder: encoder)
            }
        }
    }

    private func inkColor(_ stroke: InkStroke) -> SIMD4<Float> {
        SIMD4(Float(stroke.color.red), Float(stroke.color.green), Float(stroke.color.blue), Float(stroke.brush.opacity))
    }
    private func rasterQuad(_ raster: LayerRaster, layerID: UUID, canvas: Point) throws -> [GPUChunk] {
        if let existing = rasterQuads[layerID], existing.raster == raster.id,
           existing.placement == raster.placement, existing.canvas == canvas { return existing.buffers }
        let p = raster.corners(canvas: canvas)
        let a = BrushVertex(p[0], local: .zero), b = BrushVertex(p[1], local: Point(x: 1, y: 0))
        let c = BrushVertex(p[2], local: Point(x: 1, y: 1)), d = BrushVertex(p[3], local: Point(x: 0, y: 1))
        let buffers = try chunks([a, b, c, a, c, d])
        rasterQuads[layerID] = RasterQuad(raster: raster.id, placement: raster.placement, canvas: canvas, buffers: buffers)
        return buffers
    }

    private func usesUniformOpacity(_ stroke: InkStroke) -> Bool {
        !stroke.brush.usesStamps && stroke.brush.opacity < 1
    }
    private func beginStroke(_ stroke: InkStroke, encoder: MTLRenderCommandEncoder) {
        if usesUniformOpacity(stroke) {
            // Clear only coverage, leaving the layer's color intact. A sample
            // receives this solid stroke's opacity once across chunks/symmetry.
            encoder.setDepthStencilState(clearCoverageState)
            encoder.setStencilReferenceValue(0)
            encoder.setRenderPipelineState(clearCoveragePipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.setDepthStencilState(paintOnceState)
            encoder.setStencilReferenceValue(1)
        } else { encoder.setDepthStencilState(nil) }
        encoder.setRenderPipelineState(stroke.operation == .erase ? erasePipeline : pipeline)
    }

    private func encodeLive(_ stroke: InkStroke, preview: [BrushVertex], transform: Matrix,
                            viewSize: Point, canvas: Point, encoder: MTLRenderCommandEncoder) throws {
        try prepareLiveBuffers(preview)
        beginStroke(stroke, encoder: encoder)
        try encode(uploadedLive, symmetry: stroke.symmetry, transform: transform, size: viewSize,
                   canvas: canvas, color: inkColor(stroke), brush: stroke.brush, encoder: encoder)
        try encode(predictionBuffers, symmetry: stroke.symmetry, transform: transform, size: viewSize,
                   canvas: canvas, color: inkColor(stroke), brush: stroke.brush, encoder: encoder)
    }

    private func prepareLiveBuffers(_ preview: [BrushVertex]) throws {
        if uploadedLiveRevision != liveRevision {
            uploadedLive = sealed
            if !scratch.isEmpty { uploadedLive.append(try chunk(scratch)) }
            uploadedLiveRevision = liveRevision
        }
        if uploadedPrediction != preview {
            predictionBuffers = try chunks(preview); uploadedPrediction = preview
        }
    }

    private func suffix(_ chunks: [GPUChunk], after count: Int) -> [GPUChunk] {
        var skip = count, result: [GPUChunk] = []
        for chunk in chunks {
            if skip >= chunk.count { skip -= chunk.count; continue }
            result.append(GPUChunk(buffer: chunk.buffer, count: chunk.count - skip, offset: chunk.offset + skip))
            skip = 0
        }
        return result
    }

    private func texture(width: Int, height: Int, samples: Int = 1, transient: Bool = false) throws -> MTLTexture {
        let info = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                            width: width, height: height, mipmapped: false)
        if samples > 1 { info.textureType = .type2DMultisample; info.sampleCount = samples }
        #if targetEnvironment(simulator)
        info.storageMode = .private // Simulator requires private MSAA targets.
        #else
        info.storageMode = transient && device.supportsFamily(.apple1) ? .memoryless : .private
        #endif
        info.usage = transient ? [.renderTarget] : [.renderTarget, .shaderRead]
        // Keep the fast tile-memory path where available. Some device/format
        // combinations can reject it despite reporting Apple-family support.
        var allocated = device.makeTexture(descriptor: info)
        if allocated == nil, info.storageMode == .memoryless {
            info.storageMode = .private
            allocated = device.makeTexture(descriptor: info)
        }
        guard let result = allocated else { throw DocumentError.graphicsMemory }
        workingTextureAllocations += 1
        return result
    }

    private func ensureWorkTargets(width: Int, height: Int) throws {
        if workTexture?.width == width && workTexture?.height == height { return }
        // Release the old viewport before allocating its replacement. Submitted
        // command buffers retain resources still needed by the GPU.
        clearLayerCaches(); workTexture = nil; workMultisample = nil; coverageStencil = nil
        let resolved = try texture(width: width, height: height)
        let multisample: MTLTexture?
        if sampleCount > 1 { multisample = try texture(width: width, height: height, samples: sampleCount, transient: true) }
        else { multisample = nil }
        workTexture = resolved; workMultisample = multisample
    }

    private func targetPass(_ target: MTLTexture, load: MTLLoadAction = .clear,
                            resolve: MTLTexture? = nil) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        let color = pass.colorAttachments[0]!
        color.texture = target; color.loadAction = load
        color.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        color.resolveTexture = resolve
        color.storeAction = resolve == nil ? .store : .multisampleResolve
        return pass
    }

    private func attachCoverage(to pass: MTLRenderPassDescriptor, target: MTLTexture) throws {
        if coverageStencil?.width != target.width || coverageStencil?.height != target.height {
            coverageStencil = nil
            let info = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float_stencil8,
                width: target.width, height: target.height, mipmapped: false)
            if sampleCount > 1 { info.textureType = .type2DMultisample; info.sampleCount = sampleCount }
            #if targetEnvironment(simulator)
            info.storageMode = .private // Includes combined depth/stencil in Simulator.
            #else
            info.storageMode = device.supportsFamily(.apple1) ? .memoryless : .private
            #endif
            info.usage = .renderTarget
            var allocated = device.makeTexture(descriptor: info)
            if allocated == nil, info.storageMode == .memoryless {
                info.storageMode = .private
                allocated = device.makeTexture(descriptor: info)
            }
            guard let stencil = allocated else { throw DocumentError.graphicsMemory }
            coverageStencil = stencil; workingTextureAllocations += 1
        }
        pass.depthAttachment.texture = coverageStencil
        pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        pass.stencilAttachment.texture = coverageStencil
        pass.stencilAttachment.loadAction = .clear; pass.stencilAttachment.storeAction = .dontCare
        pass.stencilAttachment.clearStencil = 0
    }
    private func geometryPass(_ target: MTLTexture, load: MTLLoadAction = .clear,
                              resolve: MTLTexture? = nil) throws -> MTLRenderPassDescriptor {
        let pass = targetPass(target, load: load, resolve: resolve)
        try attachCoverage(to: pass, target: target)
        return pass
    }

    private func composite(_ source: MTLTexture, opacity: Double, output: MTLTexture,
                           command: MTLCommandBuffer, load: MTLLoadAction = .load) throws {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: targetPass(output, load: load)) else { throw DocumentError.graphics }
        encoder.setRenderPipelineState(compositePipeline)
        encoder.setFragmentTexture(source, index: 0)
        var alpha = Float(opacity)
        encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }

    private func paintKey(_ layer: DrawingLayer) -> LayerPaintKey {
        scenePaintKeys[layer.id] ?? LayerPaintKey(id: layer.id, raster: layer.raster?.id, strokes: [])
    }

    private func updateScene(_ document: DrawingDocument) {
        sceneDocumentID = document.id
        sceneLayerStrokes = Dictionary(grouping: document.strokes, by: \.layerID)
        scenePaintKeys = Dictionary(uniqueKeysWithValues: document.layers.map { layer in
            (layer.id, LayerPaintKey(id: layer.id, raster: layer.raster?.id,
                                    strokes: (sceneLayerStrokes[layer.id] ?? []).map(\.id), placement: layer.raster?.placement))
        })
    }

    private func renderStaticGroup(_ layers: [DrawingLayer], previous: [LayerCompositeKey]?,
                                   target: MTLTexture?, command: MTLCommandBuffer,
                                   document: DrawingDocument, viewport: Viewport, viewSize: Point) throws -> (MTLTexture?, [LayerCompositeKey]) {
        let key = layers.map { LayerCompositeKey(paint: paintKey($0), opacity: $0.opacity) }
        guard !layers.isEmpty else { return (nil, key) }
        if previous == key, let target { return (target, key) }
        guard let work = workTexture else { throw DocumentError.graphics }
        let result = try target ?? texture(width: work.width, height: work.height)
        for (index, layer) in layers.enumerated() {
            let pass = try geometryPass(workMultisample ?? work, resolve: workMultisample == nil ? nil : work)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw DocumentError.graphics }
            do {
                try encodeScene(encoder: encoder, document: document, viewport: viewport, viewSize: viewSize,
                                active: nil, preview: [], guides: false, layerOnly: layer.id)
            } catch { encoder.endEncoding(); throw error }
            encoder.endEncoding()
            try composite(work, opacity: layer.opacity, output: result, command: command, load: index == 0 ? .clear : .load)
        }
        cachedGroupBuilds += 1
        return (result, key)
    }

    private func prepareActiveLayer(_ layer: DrawingLayer, command: MTLCommandBuffer,
                                    document: DrawingDocument, viewport: Viewport, viewSize: Point) throws {
        let key = paintKey(layer)
        if activeKey == key, activeTexture != nil { return }
        guard let work = workTexture else { throw DocumentError.graphics }
        let target = try activeTexture ?? texture(width: work.width, height: work.height, samples: sampleCount)
        let incremental: Bool
        if let old = activeKey {
            incremental = old.id == key.id && old.raster == key.raster && old.placement == key.placement && old.strokes.count < key.strokes.count &&
                Array(key.strokes.prefix(old.strokes.count)) == old.strokes
        } else { incremental = false }
        let pass = try geometryPass(target, load: incremental ? .load : .clear)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw DocumentError.graphics }
        do {
            if incremental, let old = activeKey {
                let transform = viewport.matrix(viewSize: viewSize, canvasSize: document.size)
                for stroke in (sceneLayerStrokes[layer.id] ?? []).dropFirst(old.strokes.count) {
                    committedStrokeDraws += 1
                    beginStroke(stroke, encoder: encoder)
                    let buffers = cache[stroke.id] ?? []
                    let remaining = pendingLiveCommit == stroke.id && activeLiveID == stroke.id
                        ? suffix(buffers, after: activeLiveVertices) : buffers
                    try encode(remaining, symmetry: stroke.symmetry, transform: transform,
                               size: viewSize, canvas: document.size, color: inkColor(stroke), brush: stroke.brush, encoder: encoder)
                }
                incrementalLayerUpdates += 1
            } else {
                try encodeScene(encoder: encoder, document: document, viewport: viewport, viewSize: viewSize,
                                active: nil, preview: [], guides: false, layerOnly: layer.id)
                cachedLayerBuilds += 1
            }
        } catch { encoder.endEncoding(); throw error }
        encoder.endEncoding()
        activeTexture = target; activeKey = key
        activeLiveID = nil; activeLiveVertices = 0; pendingLiveCommit = nil
    }

    /// Keep per-sample committed coverage: restoring a resolved bitmap here would
    /// change soft ink/eraser edges when a new stroke overlaps older MSAA samples.
    private func renderLiveLayer(_ active: InkStroke, preview: [BrushVertex], command: MTLCommandBuffer,
                                 document: DrawingDocument, viewport: Viewport, viewSize: Point) throws -> MTLTexture {
        guard let base = activeTexture, let work = workTexture else { throw DocumentError.graphics }
        try prepareLiveBuffers(preview)
        if usesUniformOpacity(active) {
            // Solid translucent ink is a union, not accumulating flow. Reuse
            // committed layers, then cover each live sample once across the
            // confirmed mesh and prediction. Opaque/stamped ink keeps its
            // incremental confirmed-prefix path below.
            let pass = try geometryPass(workMultisample ?? work, resolve: workMultisample == nil ? nil : work)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw DocumentError.graphics }
            do {
                encoder.setRenderPipelineState(sampleCount > 1 ? restoreSamplesPipeline : restoreColorPipeline)
                encoder.setFragmentTexture(base, index: 0)
                var alpha: Float = 1
                encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                try encodeLive(active, preview: preview, transform: viewport.matrix(viewSize: viewSize, canvasSize: document.size),
                               viewSize: viewSize, canvas: document.size, encoder: encoder)
            } catch { encoder.endEncoding(); throw error }
            encoder.endEncoding()
            return work
        }
        let confirmed = sealedVertexCount + scratch.count
        if activeLiveID == nil { activeLiveID = active.id; activeLiveVertices = 0 }
        if confirmed > activeLiveVertices {
            let delta = suffix(uploadedLive, after: activeLiveVertices)
            guard let stable = command.makeRenderCommandEncoder(descriptor: try geometryPass(base, load: .load)) else { throw DocumentError.graphics }
            do {
                stable.setRenderPipelineState(active.operation == .erase ? erasePipeline : pipeline)
                try encode(delta, symmetry: active.symmetry, transform: viewport.matrix(viewSize: viewSize, canvasSize: document.size),
                           size: viewSize, canvas: document.size, color: inkColor(active), brush: active.brush, encoder: stable)
            } catch { stable.endEncoding(); throw error }
            stable.endEncoding()
            liveConfirmedVertexDraws += confirmed - activeLiveVertices; activeLiveVertices = confirmed
        }
        let pass = try geometryPass(workMultisample ?? work, resolve: workMultisample == nil ? nil : work)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw DocumentError.graphics }
        do {
            encoder.setRenderPipelineState(sampleCount > 1 ? restoreSamplesPipeline : restoreColorPipeline)
            encoder.setFragmentTexture(base, index: 0)
            var alpha: Float = 1
            encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.setRenderPipelineState(active.operation == .erase ? erasePipeline : pipeline)
            try encode(predictionBuffers, symmetry: active.symmetry,
                       transform: viewport.matrix(viewSize: viewSize, canvasSize: document.size), size: viewSize,
                       canvas: document.size, color: inkColor(active), brush: active.brush, encoder: encoder)
        } catch { encoder.endEncoding(); throw error }
        encoder.endEncoding()
        return work
    }

    private func resolveActiveLayer(command: MTLCommandBuffer) throws -> MTLTexture {
        guard let base = activeTexture, let work = workTexture else { throw DocumentError.graphics }
        guard sampleCount > 1 else { return base }
        let pass = targetPass(base, load: .load, resolve: work)
        pass.colorAttachments[0].storeAction = .storeAndMultisampleResolve
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw DocumentError.graphics }
        encoder.endEncoding()
        return work
    }

    private func encodeCachedScene(command: MTLCommandBuffer, output: MTLTexture, document: DrawingDocument,
                                   viewport: Viewport, viewSize: Point, active: InkStroke?,
                                   preview: [BrushVertex], guides: Bool) throws {
        try ensureWorkTargets(width: output.width, height: output.height)
        let next = SurfaceKey(document: document.id, canvas: document.size, view: viewSize,
            transform: viewport.matrix(viewSize: viewSize, canvasSize: document.size), width: output.width, height: output.height)
        if surfaceKey != next {
            if surfaceKey?.width != next.width || surfaceKey?.height != next.height {
                lowerTexture = nil; upperTexture = nil; activeTexture = nil
            }
            lowerKey = nil; upperKey = nil; activeKey = nil; surfaceKey = next
        }
        let backgroundPass = targetPass(output)
        backgroundPass.colorAttachments[0].clearColor = MTLClearColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1)
        guard let background = command.makeRenderCommandEncoder(descriptor: backgroundPass) else { throw DocumentError.graphics }
        do {
            try encodeScene(encoder: background, document: document, viewport: viewport, viewSize: viewSize,
                            active: nil, preview: [], guides: guides, backgroundOnly: true, state: singlePipeline)
        } catch { background.endEncoding(); throw error }
        background.endEncoding()
        let focus = active?.layerID ?? document.activeLayerID
        let index = document.layers.firstIndex { $0.id == focus } ?? 0
        let below = document.layers.prefix(index).filter { $0.isVisible && $0.opacity > 0 }
        let above = document.layers.dropFirst(index + 1).filter { $0.isVisible && $0.opacity > 0 }
        let selected = document.layers.first { $0.id == focus && $0.isVisible && $0.opacity > 0 }
        let surfaces = (below.isEmpty ? 0 : 1) + (above.isEmpty ? 0 : 1) + (selected == nil ? 0 : sampleCount)
        let bytes = output.width * output.height * 4 * surfaces
        guard bytes <= cacheBudget else {
            clearLayerCaches()
            try encodeGroups(command: command, output: output, document: document, viewport: viewport,
                             viewSize: viewSize, active: active, preview: preview, guides: guides)
            return
        }
        do {
        let lower = try renderStaticGroup(Array(below), previous: lowerKey, target: lowerTexture,
            command: command, document: document, viewport: viewport, viewSize: viewSize)
        lowerTexture = lower.0; lowerKey = lower.1
        let upper = try renderStaticGroup(Array(above), previous: upperKey, target: upperTexture,
            command: command, document: document, viewport: viewport, viewSize: viewSize)
        upperTexture = upper.0; upperKey = upper.1
        renderCacheBytes = bytes
        if let lowerTexture { try composite(lowerTexture, opacity: 1, output: output, command: command) }
        if let selected {
            if let liveID = activeLiveID, liveID != active?.id {
                let promoted = pendingLiveCommit == liveID && paintKey(selected).strokes.contains(liveID)
                if !promoted {
                    activeKey = nil; activeLiveID = nil; activeLiveVertices = 0; pendingLiveCommit = nil
                }
            }
            try prepareActiveLayer(selected, command: command, document: document, viewport: viewport, viewSize: viewSize)
            let image: MTLTexture
            if let active, active.layerID == selected.id {
                image = try renderLiveLayer(active, preview: preview, command: command, document: document, viewport: viewport, viewSize: viewSize)
            } else { image = try resolveActiveLayer(command: command) }
            try composite(image, opacity: selected.opacity, output: output, command: command)
        } else {
            activeTexture = nil; activeKey = nil; activeLiveID = nil; activeLiveVertices = 0; pendingLiveCommit = nil
        }
        if let upperTexture { try composite(upperTexture, opacity: 1, output: output, command: command) }
        } catch DocumentError.graphicsMemory {
            clearLayerCaches(); cacheBudget = 0
            try encodeGroups(command: command, output: output, document: document, viewport: viewport,
                             viewSize: viewSize, active: active, preview: preview, guides: guides)
        } catch {
            clearLayerCaches(); throw error
        }
    }

    private func clearLayerCaches() {
        lowerTexture = nil; upperTexture = nil; activeTexture = nil
        lowerKey = nil; upperKey = nil; activeKey = nil; renderCacheBytes = 0
        activeLiveID = nil; activeLiveVertices = 0; pendingLiveCommit = nil
    }

    func handleMemoryPressure() {
        clearLayerCaches()
        cacheBudget = 0 // Keep the bounded, uncached renderer available for this session.
    }
    private func requiresGroups(_ document: DrawingDocument, active: InkStroke? = nil) -> Bool {
        active?.operation == .erase || document.strokes.contains { $0.operation == .erase } ||
        document.layers.contains { $0.isVisible && $0.opacity > 0 && $0.opacity < 1 }
    }

    /// One isolated layer target reused sequentially inside this command buffer.
    /// At most one grouped display frame is in flight, bounding temporary targets
    /// independently of layer count. Ink retains the canvas MSAA sample count.
    private func encodeGroups(command: MTLCommandBuffer, output: MTLTexture, document: DrawingDocument,
                              viewport: Viewport, viewSize: Point, active: InkStroke?,
                              preview: [BrushVertex], guides: Bool) throws {
        try ensureWorkTargets(width: output.width, height: output.height)
        guard let layerTexture = workTexture else { throw DocumentError.graphics }
        let multisample = workMultisample
        func outputPass(load: MTLLoadAction) -> MTLRenderPassDescriptor {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = load; pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1)
            return pass
        }
        guard let background = command.makeRenderCommandEncoder(descriptor: outputPass(load: .clear)) else { throw DocumentError.graphics }
        do {
            try encodeScene(encoder: background, document: document, viewport: viewport, viewSize: viewSize,
                            active: nil, preview: [], guides: guides, backgroundOnly: true, state: singlePipeline)
        } catch { background.endEncoding(); throw error }
        background.endEncoding()
        for layer in document.layers where layer.isVisible && layer.opacity > 0 {
            let pass = MTLRenderPassDescriptor()
            let color = pass.colorAttachments[0]!
            color.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0); color.loadAction = .clear
            if let multisample {
                color.texture = multisample; color.resolveTexture = layerTexture; color.storeAction = .multisampleResolve
            } else { color.texture = layerTexture; color.storeAction = .store }
            try attachCoverage(to: pass, target: multisample ?? layerTexture)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw DocumentError.graphics }
            do {
                try encodeScene(encoder: encoder, document: document, viewport: viewport, viewSize: viewSize,
                                active: active, preview: preview, guides: false, layerOnly: layer.id)
            } catch { encoder.endEncoding(); throw error }
            encoder.endEncoding()
            guard let composite = command.makeRenderCommandEncoder(descriptor: outputPass(load: .load)) else { throw DocumentError.graphics }
            composite.setRenderPipelineState(compositePipeline)
            composite.setFragmentTexture(layerTexture, index: 0)
            var opacity = Float(layer.opacity)
            composite.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
            composite.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            composite.endEncoding()
        }
    }

    /// Test/readback path uses the SAME pipeline, geometry, clipping and transforms
    /// as the visible canvas. BGRA rows are returned in top-left screen order.
    func renderOffscreen(document: DrawingDocument, viewport: Viewport, width: Int, height: Int,
                         active: InkStroke? = nil, preview: [BrushVertex] = [], guides: Bool = false,
                         reference: Bool = false) async throws -> [UInt8] {
        guard width > 0, height > 0, width <= 2048, height <= 2048 else { throw DocumentError.invalidData }
        updateScene(document); sceneRevision = nil
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                      width: width, height: height, mipmapped: false)
        outputDescriptor.storageMode = .shared
        outputDescriptor.usage = [.renderTarget]
        guard let output = device.makeTexture(descriptor: outputDescriptor),
              let command = queue.makeCommandBuffer() else { throw DocumentError.graphics }
        let pass = MTLRenderPassDescriptor()
        let color = pass.colorAttachments[0]!
        color.clearColor = MTLClearColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1)
        color.loadAction = .clear
        if reference && sampleCount > 1 && !requiresGroups(document, active: active) {
            let msaa = MTLTextureDescriptor()
            msaa.textureType = .type2DMultisample; msaa.pixelFormat = .bgra8Unorm
            msaa.width = width; msaa.height = height; msaa.sampleCount = sampleCount
            msaa.storageMode = .private; msaa.usage = .renderTarget
            guard let texture = device.makeTexture(descriptor: msaa) else { throw DocumentError.graphics }
            color.texture = texture; color.resolveTexture = output; color.storeAction = .multisampleResolve
        } else { color.texture = output; color.storeAction = .store }
        if !reference {
            try encodeCachedScene(command: command, output: output, document: document, viewport: viewport,
                                  viewSize: Point(x: Double(width), y: Double(height)), active: active, preview: preview, guides: guides)
        } else if requiresGroups(document, active: active) {
            try encodeGroups(command: command, output: output, document: document, viewport: viewport,
                             viewSize: Point(x: Double(width), y: Double(height)), active: active, preview: preview, guides: guides)
        } else {
            try attachCoverage(to: pass, target: color.texture!)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw DocumentError.graphics }
            do {
                try encodeScene(encoder: encoder, document: document, viewport: viewport,
                                viewSize: Point(x: Double(width), y: Double(height)),
                                active: active, preview: preview, guides: guides)
            } catch { encoder.endEncoding(); throw error }
            encoder.endEncoding()
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { @Sendable command in
                if command.status == .error { continuation.resume(throwing: DocumentError.graphics) }
                else { continuation.resume() }
            }
            command.commit()
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            output.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return pixels
    }

    private func encode(_ chunks: [GPUChunk], symmetry: SymmetryConfiguration, transform: Matrix,
                        size: Point, canvas: Point, color: SIMD4<Float>, brush: InkBrush = InkBrush(), encoder: MTLRenderCommandEncoder) throws {
        // Layout is four aligned float4s in both Swift and Metal (64 bytes).
        let uniforms: [SIMD4<Float>] = [
            SIMD4(Float(transform.a), Float(transform.b), Float(transform.c), Float(transform.d)),
            SIMD4(Float(transform.tx), Float(transform.ty), Float(size.x), Float(size.y)),
            SIMD4(Float(canvas.x), Float(canvas.y), Float(brush.preset.softness), brush.usesStamps ? 1 : 0), color
        ]
        if matrixCache[symmetry] == nil {
            let values: [SIMD4<Float>] = symmetry.matrices.flatMap { m in
                [SIMD4(Float(m.a), Float(m.b), Float(m.c), Float(m.d)), SIMD4(Float(m.tx), Float(m.ty), 0, 0)]
            }
            let buffer = values.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            }
            guard let buffer else { throw DocumentError.graphicsMemory }
            matrixCache[symmetry] = buffer
        }
        let matrices = matrixCache[symmetry]!
        uniforms.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
        // 64 sectors + Mirror uses 128 transforms (4096 bytes), so use a buffer
        // rather than the small inline setVertexBytes argument limit.
        encoder.setVertexBuffer(matrices, offset: 0, index: 2)
        for chunk in chunks {
            encoder.setVertexBuffer(chunk.buffer, offset: chunk.offset * MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: chunk.count,
                                   instanceCount: symmetry.instanceCount)
        }
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms { float4 matrix; float4 offsetSize; float4 canvas; float4 color; };
    struct Output { float4 position [[position]]; float2 canvas; float2 limit; float4 color; float2 local; float2 stamp; };
    vertex Output inkVertex(uint v [[vertex_id]], uint instance [[instance_id]],
                           const device float4 *vertices [[buffer(0)]],
                           constant Uniforms &u [[buffer(1)]], constant float4 *symmetry [[buffer(2)]]) {
        float4 m = symmetry[instance * 2];
        float2 p = vertices[v].xy;
        p = float2(m.x*p.x + m.z*p.y, m.y*p.x + m.w*p.y) + symmetry[instance*2+1].xy;
        float4 t = u.matrix;
        float2 screen = float2(t.x*p.x + t.z*p.y, t.y*p.x + t.w*p.y) + u.offsetSize.xy;
        Output out;
        out.position = float4(screen.x/u.offsetSize.z*2-1, 1-screen.y/u.offsetSize.w*2, 0, 1);
        out.canvas = p; out.limit = u.canvas.xy; out.color = u.color;
        out.local = vertices[v].zw; out.stamp = u.canvas.zw;
        return out;
    }
    fragment float4 rasterFragment(Output in [[stage_in]], texture2d<float> image [[texture(0)]]) {
        if (any(in.canvas < float2(0)) || any(in.canvas > in.limit)) discard_fragment();
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        return image.sample(s, in.local);
    }
    struct CompositeOutput { float4 position [[position]]; float2 uv; };
    vertex CompositeOutput compositeVertex(uint v [[vertex_id]]) {
        const float2 uv[6] = {float2(0,0), float2(1,0), float2(1,1), float2(0,0), float2(1,1), float2(0,1)};
        CompositeOutput out; out.uv = uv[v];
        out.position = float4(out.uv.x*2-1, 1-out.uv.y*2, 0, 1); return out;
    }
    fragment float4 compositeFragment(CompositeOutput in [[stage_in]], texture2d<float> layer [[texture(0)]],
                                       constant float &opacity [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
        return layer.sample(s, in.uv) * opacity;
    }
    fragment float4 restoreSamplesFragment(CompositeOutput in [[stage_in]],
                                           texture2d_ms<float, access::read> layer [[texture(0)]],
                                           uint sample [[sample_id]]) {
        return layer.read(uint2(in.position.xy), sample);
    }
    fragment float4 inkFragment(Output in [[stage_in]]) {
        if (any(in.canvas < float2(0)) || any(in.canvas > in.limit)) discard_fragment();
        float4 color = in.color;
        if (in.stamp.y > 0.5) {
            float radius = length(in.local);
            if (radius > 1) discard_fragment();
            if (in.stamp.x > 0) color.a *= 1 - smoothstep(0.0, 1.0, radius);
        }
        return color;
    }
    """
}
