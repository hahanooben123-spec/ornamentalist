import MetalKit

private struct GPUChunk {
    let buffer: MTLBuffer
    let count: Int
    var offset = 0
    var compactStamp = false
    var fadedStamp = false
    var sourceBounds = CGRect.null
    var storageUnits: Int { compactStamp ? count / 3 : count }
    var byteOffset: Int { compactStamp ? offset / 6 * 32 : offset * 16 }
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
    private let navigationPipeline: MTLRenderPipelineState
    private var lastFrameDocument: UUID?
    private var lastFrameViewport: Viewport?
    private var lastFrameViewSize = Point.zero
    private var lastFrameWidth = 0
    private var lastFrameHeight = 0
    private var navigationTexture: MTLTexture?
    private var navigationQuad: [GPUChunk] = []
    private var navigationDocument: UUID?
    private var navigationToken = UUID()
    private(set) var isViewportNavigating = false
    private(set) var navigationPreviewFrames = 0
    var navigationRefined: (() -> Void)?
    private var rasterTextures: [UUID: MTLTexture] = [:]
    private var rasterQuads: [UUID: RasterQuad] = [:]
    private let singlePipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let restoreSamplesPipeline: MTLRenderPipelineState
    private let restoreTileSamplesPipeline: MTLRenderPipelineState
    private let restoreTileColorPipeline: MTLRenderPipelineState
    private let restoreColorPipeline: MTLRenderPipelineState
    private let clearCoveragePipeline: MTLRenderPipelineState
    private let clearRegionPipeline: MTLRenderPipelineState
    private let clearSingleRegionPipeline: MTLRenderPipelineState
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
    private var liveSourceBounds = CGRect.null
    private var liveWorkStroke: UUID?
    private var liveWorkBounds = CGRect.null
    private var liveTile: MTLTexture?
    private var liveTileMSAA: MTLTexture?
    private var liveTileStencil: MTLTexture?
    private(set) var partialLiveRestores = 0
    private(set) var streamedSubmissions = 0
    private var liveRevision = 0
    private var uploadedLiveRevision = -1
    private var uploadedLive: [GPUChunk] = []
    private var uploadedPrediction: [BrushVertex] = []
    private var predictionBuffers: [GPUChunk] = []
    private let groupInFlight = DispatchSemaphore(value: 1)
    private var cache: [UUID: [GPUChunk]] = [:]
    private var registered: Set<UUID> = []
    private var cacheOrder: [UUID] = []
    private var preparationPins = Set<UUID>()
    private let geometryBudget: Int
    private var strokeBounds: [UUID: CGRect] = [:]
    private(set) var localTileUpdates = 0
    private(set) var layerCompositePasses = 0
    private(set) var liveRestorePasses = 0
    private(set) var geometryRebuilds = 0
    private(set) var isPreparingScene = false
    var preparationChanged: ((Bool) -> Void)?
    var preparationFailed: ((Error) -> Void)?
    private var preparationTask: Task<Void, Never>?
    private var sealed: [GPUChunk] = []
    private var scratch: [SIMD4<Float>] = []
    private let chunkSize = 8190 // Multiple of three.
    private let inFlight = DispatchSemaphore(value: 3)
    private let sampleCount: Int
    private let compactStamps: Bool
    private var paperSize = Point.zero
    private var paper: [GPUChunk] = []
    private var guideKey: [Double] = []
    private var guideBuffers: [GPUChunk] = []
    private var matrixCache: [SymmetryConfiguration: MTLBuffer] = [:]
    private struct TileMatrixKey: Hashable {
        let symmetry: SymmetryConfiguration
        let bounds: [Double]
        let clip: [Double]
    }
    private var tileMatrixCache: [TileMatrixKey: (MTLBuffer, Int)] = [:]
    private var sceneLayerStrokes: [UUID: [InkStroke]] = [:]
    private var scenePaintKeys: [UUID: LayerPaintKey] = [:]
    private var sceneDocumentID: UUID?
    private var sceneRevision: Int?
    private(set) var allocatedVertexCount = 0
    private var allocatedStorageUnits = 0
    var allocatedGeometryBytes: Int { cache.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.buffer.length } } }
    private var sealedVertexCount = 0
    private var sealedStorageUnits = 0
    private var cpuFrameMilliseconds: [Double] = []
    private var gpuFrameMilliseconds: [Double] = []
    private var deferredFrames = 0
    private var redrawAfterGPU = false
    private weak var redrawView: MTKView?

    func performanceReport() -> String {
        func timing(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "No samples yet" }
            let sorted = values.sorted()
            let median = sorted[sorted.count / 2]
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            return String(format: "median %.2f ms · p95 %.2f ms", median, p95)
        }
        let bytes = allocatedGeometryBytes + sealed.reduce(0) { $0 + $1.buffer.length } + scratch.count * 16
        return "Ornamentalist 0.12.0\nCPU frame submission: \(timing(cpuFrameMilliseconds))\nGPU execution: \(timing(gpuFrameMilliseconds))\nDeferred frames: \(deferredFrames)\nSource vertex buffers: \(bytes / 1024) KiB\nGPU geometry budget: \(geometryBudget / 1024) KiB\nPartial live restores: \(partialLiveRestores)\nStreamed submissions: \(streamedSubmissions)\nZoom preview frames: \(navigationPreviewFrames)\nZoom preview texture: \((navigationTexture.map { $0.width * $0.height * 4 } ?? 0) / 1024) KiB\nGeometry reconstructions: \(geometryRebuilds)\nLayer composite passes: \(layerCompositePasses)\nLive full-surface restores: \(liveRestorePasses)\nDirty tile updates: \(localTileUpdates)\nRender caches: \(renderCacheBytes / 1024) KiB\nWorking texture allocations: \(workingTextureAllocations)\nCommitted stroke draws: \(committedStrokeDraws)\nLayer/group rebuilds: \(cachedLayerBuilds)/\(cachedGroupBuilds)\nIncremental commits: \(incrementalLayerUpdates)\nLive confirmed vertex draws: \(liveConfirmedVertexDraws)\n\nLast 240 samples. These timings do not measure Pencil-to-screen latency or total app memory."
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

    init(view: MTKView, compactStamps: Bool = true, geometryBudget: Int = 16 * 1024 * 1024) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw DocumentError.noMetal
        }
        self.device = device
        self.geometryBudget = max(DrawingLimits.strokeVertices * 16, geometryBudget)
        self.compactStamps = compactStamps
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
        descriptor.fragmentFunction = library.makeFunction(name: "rasterFragment")
        attachment.sourceRGBBlendFactor = .one
        navigationPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
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
        descriptor.fragmentFunction = library.makeFunction(name: "restoreTileSamplesFragment")
        restoreTileSamplesPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "restoreTileColorFragment")
        restoreTileColorPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = nil
        attachment.writeMask = []
        clearCoveragePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        attachment.writeMask = .all
        descriptor.fragmentFunction = library.makeFunction(name: "clearRegionFragment")
        clearRegionPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.rasterSampleCount = 1
        descriptor.depthAttachmentPixelFormat = .invalid; descriptor.stencilAttachmentPixelFormat = .invalid
        clearSingleRegionPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
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
        var lowX = points[0].x, highX = lowX, lowY = points[0].y, highY = lowY
        for point in points.dropFirst() {
            lowX = min(lowX, point.x); highX = max(highX, point.x)
            lowY = min(lowY, point.y); highY = max(highY, point.y)
        }
        let bounds = CGRect(x: Double(lowX) - 1, y: Double(lowY) - 1,
                            width: Double(highX - lowX) + 2, height: Double(highY - lowY) + 2)
        if compactStamps, points.count.isMultiple(of: 6), points[0].z < 0, points[0].w < 0 {
            let local: [SIMD2<Float>] = [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, -1), SIMD2(1, 1), SIMD2(-1, 1)]
            let stamps = points.indices.allSatisfy { i in
                let magnitude = abs(points[i].z)
                return (magnitude == 1 || (2...3).contains(magnitude)) && magnitude == abs(points[i / 6 * 6].z) &&
                    SIMD2(points[i].z, points[i].w) == local[i % 6] * magnitude
            }
            if stamps {
                let faded = points.contains { abs($0.z) >= 2 }
                var corners: [SIMD2<Float>] = []
                corners.reserveCapacity(points.count / 6 * 4)
                for start in stride(from: 0, to: points.count, by: 6) {
                    for i in (faded ? [0, 1, 2] : [0, 1, 2, 5]) {
                        corners.append(SIMD2(points[start + i].x, points[start + i].y))
                    }
                    if faded {
                        let magnitude = abs(points[start].z)
                        corners.append(SIMD2(magnitude >= 2 ? magnitude - 2 : 1, 0))
                    }
                }
                let buffer = corners.withUnsafeBytes {
                    device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
                }
                guard let buffer else { throw DocumentError.graphicsMemory }
                return GPUChunk(buffer: buffer, count: points.count, compactStamp: true, fadedStamp: faded, sourceBounds: bounds)
            }
        }
        let buffer = points.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }
        guard let buffer else { throw DocumentError.graphicsMemory }
        return GPUChunk(buffer: buffer, count: points.count, sourceBounds: bounds)
    }
    private func chunks(_ points: [BrushVertex]) throws -> [GPUChunk] {
        var result: [GPUChunk] = []
        for start in stride(from: 0, to: points.count, by: chunkSize) {
            result.append(try chunk(points[start..<min(points.count, start+chunkSize)].map {
                packedVertex($0)
            }))
        }
        return result
    }
    private func packedVertex(_ vertex: BrushVertex) -> SIMD4<Float> {
        // Magnitudes 2...3 encode a constant per-dab opacity without adding
        // vertex attributes. Ordinary solid, raster and legacy stamp data stay unchanged.
        let scale = vertex.opacity < 1 ? 2 + vertex.opacity : 1
        return SIMD4(Float(vertex.point.x), Float(vertex.point.y), Float(vertex.local.x * scale), Float(vertex.local.y * scale))
    }
    func hasBuffers(for strokes: [InkStroke], layers: [DrawingLayer] = []) -> Bool {
        strokes.allSatisfy { registered.contains($0.id) } && layers.compactMap(\.raster).allSatisfy { rasterTextures[$0.id] != nil }
    }
    private func recountBuffers() {
        allocatedVertexCount = cache.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
        allocatedStorageUnits = cache.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.storageUnits } }
    }
    private func retain(_ buffers: [GPUChunk], for id: UUID) {
        cache[id] = nil; cacheOrder.removeAll { $0 == id }
        let bytes = buffers.reduce(0) { $0 + $1.buffer.length }
        var current = allocatedGeometryBytes
        while current + bytes > geometryBudget {
            guard let oldest = cacheOrder.first(where: { !preparationPins.contains($0) }) else {
                // Stream this one stroke without caching it until an upcoming
                // warm stroke has been consumed; do not evict that future work.
                registered.insert(id); recountBuffers(); return
            }
            current -= cache[oldest]?.reduce(0) { $0 + $1.buffer.length } ?? 0
            cache[oldest] = nil; cacheOrder.removeAll { $0 == oldest }
        }
        cache[id] = buffers; cacheOrder.append(id); registered.insert(id)
        recountBuffers()
    }
    private func buffers(for stroke: InkStroke) throws -> [GPUChunk] {
        guard let buffers = cache[stroke.id] else { throw DocumentError.graphics }
        cacheOrder.removeAll { $0 == stroke.id }; cacheOrder.append(stroke.id)
        return buffers
    }
    func prune(_ strokes: [InkStroke], layers: [DrawingLayer] = []) {
        let layerIDs = Set(layers.map(\.id))
        rasterQuads = rasterQuads.filter { layerIDs.contains($0.key) }
        let rasters = Set(layers.compactMap { $0.raster?.id })
        rasterTextures = rasterTextures.filter { rasters.contains($0.key) }
        let ids = Set(strokes.map(\.id))
        cache = cache.filter { ids.contains($0.key) }; cacheOrder.removeAll { !ids.contains($0) }
        registered.formIntersection(ids)
        // Undo needs the removed stroke's old bounds until the dirty tiles are rebuilt.
        let boundsIDs = ids.union(activeKey?.strokes ?? []).union((lowerKey ?? []).flatMap { $0.paint.strokes })
            .union((upperKey ?? []).flatMap { $0.paint.strokes })
        strokeBounds = strokeBounds.filter { boundsIDs.contains($0.key) }
        recountBuffers()
    }
    func synchronize(_ strokes: [InkStroke], layers: [DrawingLayer] = []) async throws {
        prune(strokes, layers: layers)
        let missing = strokes.filter { !registered.contains($0.id) }
        try await Task.detached(priority: .userInitiated) {
            for stroke in missing {
                guard BrushGeometry.estimatedStorageCost(stroke) <= DrawingLimits.strokeVertices else {
                    throw DocumentError.geometryLimit
                }
            }
        }.value
        // Only prewarm geometry that fits. Larger drawings are replayed in bounded
        // GPU submissions by prepareScene, never uploaded as one enormous mesh.
        var available = geometryBudget - allocatedGeometryBytes
        for stroke in missing.reversed() {
            try Task.checkCancellation()
            let estimate = BrushGeometry.estimatedStorageCost(stroke) * 16
            if estimate <= available {
                let points = await Task.detached(priority: .userInitiated) { BrushGeometry.mesh(stroke) }.value
                try Task.checkCancellation()
                let uploaded = try chunks(points)
                retain(uploaded, for: stroke.id)
                available = geometryBudget - allocatedGeometryBytes
            }
            registered.insert(stroke.id)
        }
        let loader = MTKTextureLoader(device: device)
        for raster in layers.compactMap(\.raster) where rasterTextures[raster.id] == nil {
            let image = try PNGExporter.rasterImage(raster)
            let texture = try await loader.newTexture(cgImage: image, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft.rawValue, .generateMipmaps: false])
            try Task.checkCancellation()
            rasterTextures[raster.id] = texture
        }
    }
    func begin() {
        discardUncommittedLiveCache()
        resetInputBuffers()
    }
    private func resetInputBuffers() {
        liveSourceBounds = .null; liveWorkStroke = nil; liveWorkBounds = .null
        sealed.removeAll(); sealedVertexCount = 0; sealedStorageUnits = 0; scratch.removeAll(keepingCapacity: true)
        liveRevision += 1; uploadedLive.removeAll(); uploadedLiveRevision = -1
        uploadedPrediction.removeAll(); predictionBuffers.removeAll()
    }
    func append(_ points: [BrushVertex]) throws {
        if !points.isEmpty { liveRevision += 1 }
        let stamped = points.first.map { $0.local == Point(x: -1, y: -1) }
            ?? scratch.first.map { $0.z < 0 && $0.w < 0 } ?? false
        let liveCost = BrushGeometry.storageCost(vertexCount: scratch.count + points.count, stamped: compactStamps && stamped)
        guard sealedStorageUnits + liveCost <= DrawingLimits.strokeVertices else {
            throw DocumentError.geometryLimit
        }
        for p in points {
            liveSourceBounds = liveSourceBounds.union(CGRect(x: p.point.x, y: p.point.y, width: 0, height: 0))
            scratch.append(packedVertex(p))
            if scratch.count == chunkSize {
                let next = try chunk(scratch)
                sealed.append(next); sealedStorageUnits += next.storageUnits
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
        retain(sealed, for: stroke.id)
        if activeLiveID == stroke.id { pendingLiveCommit = stroke.id }
        resetInputBuffers()
    }
    func cancel() { begin() }

    private func discardUncommittedLiveCache() {
        if activeLiveID != nil && activeLiveID != pendingLiveCommit {
            activeKey = nil; activeLiveID = nil; activeLiveVertices = 0
        }
    }

    /// Flatten the warm layer caches once per gesture, without reading a
    /// framebuffer or disabling MTKView's framebuffer-only optimization.
    func beginViewportNavigation(document: DrawingDocument, guides: Bool) throws -> Bool {
        navigationToken = UUID()
        if navigationTexture != nil, navigationDocument == document.id {
            preparationTask?.cancel(); isViewportNavigating = true; return true
        }
        guard !isPreparingScene, lastFrameDocument == document.id, let viewport = lastFrameViewport,
              lastFrameWidth > 0, lastFrameHeight > 0 else { return false }
        updateScene(document); sceneRevision = nil
        guard !needsStreamedPreparation(document) else { return false }
        let image = try texture(width: lastFrameWidth, height: lastFrameHeight)
        guard let command = queue.makeCommandBuffer() else { throw DocumentError.graphics }
        defer { command.commit() }
        try encodeCachedScene(command: command, output: image, document: document, viewport: viewport,
                              viewSize: lastFrameViewSize, active: nil, preview: [], guides: guides)
        try beginViewportNavigation(image: image, document: document, viewport: viewport, viewSize: lastFrameViewSize)
        return true
    }

    func beginViewportNavigation(image: MTLTexture, document: DrawingDocument, viewport: Viewport, viewSize: Point) throws {
        let corners = viewport.documentCorners(viewSize: viewSize, canvasSize: document.size)
        let a = BrushVertex(corners[0], local: .zero)
        let b = BrushVertex(corners[1], local: Point(x: 1, y: 0))
        let c = BrushVertex(corners[2], local: Point(x: 1, y: 1))
        let d = BrushVertex(corners[3], local: Point(x: 0, y: 1))
        let quad = try chunks([a, b, c, a, c, d])
        navigationTexture = image; navigationQuad = quad; navigationDocument = document.id
        isViewportNavigating = true
    }

    func endViewportNavigation() { isViewportNavigating = false }

    func cancelViewportNavigation() {
        let hadPreview = navigationTexture != nil
        navigationToken = UUID(); isViewportNavigating = false
        navigationTexture = nil; navigationQuad.removeAll(); navigationDocument = nil
        if hadPreview { navigationRefined?() }
    }

    private func completeNavigation(_ token: UUID) {
        guard token == navigationToken, !isViewportNavigating else { return }
        cancelViewportNavigation()
    }

    private func encodeNavigation(command: MTLCommandBuffer, output: MTLTexture, document: DrawingDocument,
                                  viewport: Viewport, viewSize: Point) throws {
        guard let image = navigationTexture, navigationDocument == document.id else { throw DocumentError.graphics }
        let pass = targetPass(output)
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw DocumentError.graphics }
        do {
            // The newly revealed area gets white paper while the final artwork
            // is rebuilding. The snapshot shader clips old workspace pixels.
            try encodeScene(encoder: encoder, document: document, viewport: viewport, viewSize: viewSize,
                            active: nil, preview: [], guides: false, backgroundOnly: true, state: singlePipeline)
            encoder.setRenderPipelineState(navigationPipeline)
            encoder.setFragmentTexture(image, index: 0)
            try encode(navigationQuad, symmetry: SymmetryConfiguration(repetitions: 1, center: .zero),
                       transform: viewport.matrix(viewSize: viewSize, canvasSize: document.size), size: viewSize,
                       canvas: document.size, color: SIMD4(1, 1, 1, 1), encoder: encoder)
        } catch { encoder.endEncoding(); throw error }
        encoder.endEncoding(); navigationPreviewFrames += 1
    }

    /// Native pixel verification uses the exact preview encoder, without a drawable.
    func renderViewportPreview(document: DrawingDocument, viewport: Viewport, width: Int, height: Int) async throws -> [UInt8] {
        guard width > 0, height > 0, width <= 2048, height <= 2048 else { throw DocumentError.invalidData }
        let info = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        info.storageMode = .shared; info.usage = .renderTarget
        guard let image = device.makeTexture(descriptor: info), let command = queue.makeCommandBuffer() else { throw DocumentError.graphicsMemory }
        try encodeNavigation(command: command, output: image, document: document, viewport: viewport,
                             viewSize: Point(x: Double(width), y: Double(height)))
        try await submit(command)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            image.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return pixels
    }

    func draw(view: MTKView, document: DrawingDocument, viewport: Viewport,
              active: InkStroke?, preview: [BrushVertex], guides: Bool, revision: Int) throws {
        let started = ProcessInfo.processInfo.systemUptime
        if sceneDocumentID != document.id || sceneRevision != revision {
            updateScene(document); sceneRevision = revision
        }
        // Never block the touch delivery thread when the GPU is behind.
        redrawView = view
        let navigating = isViewportNavigating && navigationTexture != nil
        guard navigating || !isPreparingScene else { return }
        let size = Point(x: Double(view.bounds.width), y: Double(view.bounds.height))
        let width = Int(view.drawableSize.width), height = Int(view.drawableSize.height)
        guard width > 0, height > 0 else { return }
        if !navigating {
        try configureSurface(document: document, viewport: viewport, viewSize: size, width: width, height: height)
        if needsStreamedPreparation(document, focus: active?.layerID) {
            isPreparingScene = true; preparationChanged?(true)
            preparationTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.isPreparingScene = false; self.preparationChanged?(false)
                }
                do {
                    try await self.prepareScene(document: document, viewport: viewport, viewSize: size,
                                                width: width, height: height, focus: active?.layerID)
                    self.redrawView?.setNeedsDisplay()
                } catch is CancellationError {
                    self.clearLayerCaches(); self.redrawView?.setNeedsDisplay()
                } catch {
                    self.clearLayerCaches()
                    self.preparationFailed?(error)
                }
            }
            return
        }
        }
        guard inFlight.wait(timeout: .now()) == .success else {
            deferredFrames += 1
            redrawAfterGPU = true
            return
        }
        if groupInFlight.wait(timeout: .now()) != .success {
            inFlight.signal(); deferredFrames += 1; redrawAfterGPU = true; return
        }
        redrawAfterGPU = false
        guard let drawable = view.currentDrawable, let command = queue.makeCommandBuffer() else {
            groupInFlight.signal(); inFlight.signal(); return
        }
        let groupGate = groupInFlight
        let gate = inFlight
        let refinement = !navigating && navigationTexture != nil ? navigationToken : nil
        // Metal invokes this on its own queue, never on the renderer's main actor.
        command.addCompletedHandler { @Sendable [weak self] command in
            gate.signal()
            groupGate.signal()
            let gpu = (command.gpuEndTime - command.gpuStartTime) * 1000
            Task { @MainActor in
                self?.completedGPUFrame(gpu)
                if command.status == .completed, let refinement { self?.completeNavigation(refinement) }
                else if command.status == .error {
                    self?.cancelViewportNavigation()
                    self?.preparationFailed?(command.error ?? DocumentError.graphics)
                }
            }
        }
        // Even an allocation error closes the encoder and submits its resources.
        var frameComplete = false
        defer {
            if frameComplete { command.present(drawable) }
            command.commit()
            recordCPU((ProcessInfo.processInfo.systemUptime - started) * 1000)
        }
        if navigating {
            try encodeNavigation(command: command, output: drawable.texture, document: document, viewport: viewport, viewSize: size)
        } else {
            try encodeCachedScene(command: command, output: drawable.texture, document: document,
                                  viewport: viewport, viewSize: size, active: active, preview: preview, guides: guides)
            lastFrameDocument = document.id; lastFrameViewport = viewport; lastFrameViewSize = size
            lastFrameWidth = width; lastFrameHeight = height
        }
        frameComplete = true
    }
    private func completedGPUFrame(_ milliseconds: Double) {
        recordGPU(milliseconds)
        // Coalesce busy draw requests into one retry after GPU completion.
        // setNeedsDisplay inside the busy guard can spin until the GPU finishes.
        if redrawAfterGPU {
            redrawAfterGPU = false
            redrawView?.setNeedsDisplay()
        }
    }

    private func encodeScene(encoder: MTLRenderCommandEncoder, document: DrawingDocument, viewport: Viewport,
                             viewSize: Point, active: InkStroke?, preview: [BrushVertex], guides: Bool,
                             layerOnly: UUID? = nil, backgroundOnly: Bool = false,
                             state: MTLRenderPipelineState? = nil,
                             strokes: [InkStroke]? = nil, includeRaster: Bool = true,
                             region: CGRect? = nil) throws {
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
                       document.size.y, viewport.zoom, viewSize.x, viewSize.y, Double(document.symmetry.tileCount)]
            if guideKey != key {
                let radius = max(document.size.x, document.size.y) * 1.5
                let screenScale = hypot(transform.a, transform.b)
                let brush = InkBrush(width: 0.7 / max(0.01, screenScale))
                var mesh: [Point] = []
                if document.symmetry.tileCount > 0 {
                    let count = document.symmetry.tileCount, step = document.symmetry.tileSize
                    for i in 0...count {
                        let a = StrokeSample(point: Point(x: Double(i) * step.x, y: 0), pressure: 1, altitude: 0, azimuth: 0, time: 0)
                        var b = a; b.point.y = document.size.y
                        mesh += StrokeGeometry.segment(a, b, brush: brush)
                        let c = StrokeSample(point: Point(x: 0, y: Double(i) * step.y), pressure: 1, altitude: 0, azimuth: 0, time: 0)
                        var d = c; d.point.x = document.size.x
                        mesh += StrokeGeometry.segment(c, d, brush: brush)
                    }
                }
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
            if includeRaster, let raster = layer.raster {
                encoder.setDepthStencilState(nil)
                guard let texture = rasterTextures[raster.id] else { throw DocumentError.graphics }
                encoder.setRenderPipelineState(rasterPipeline)
                encoder.setFragmentTexture(texture, index: 0)
                let quad = try rasterQuad(raster, layerID: layer.id, canvas: document.size)
                try encode(quad, symmetry: identity, transform: transform, size: viewSize, canvas: document.size,
                           color: SIMD4(1, 1, 1, 1), encoder: encoder)
            }
            for stroke in strokes ?? sceneLayerStrokes[layer.id] ?? [] {
                if let region, !screenBounds(stroke.id, transform: transform).intersects(region) { continue }
                committedStrokeDraws += 1
                beginStroke(stroke, encoder: encoder)
                try encode(buffers(for: stroke), symmetry: stroke.symmetry, transform: transform,
                           size: viewSize, canvas: document.size, color: inkColor(stroke), brush: stroke.brush, strokeTransform: stroke.transform ?? .init(), selection: stroke.selection, encoder: encoder)
            }
            if let active, active.layerID == layer.id {
                try encodeLive(active, preview: preview, transform: transform, viewSize: viewSize,
                               canvas: document.size, encoder: encoder)
            }
        }
    }

    private func inkColor(_ stroke: InkStroke) -> SIMD4<Float> {
        SIMD4(Float(stroke.color.red), Float(stroke.color.green), Float(stroke.color.blue), Float(stroke.brush.dabOpacity))
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
                   canvas: canvas, color: inkColor(stroke), brush: stroke.brush, strokeTransform: stroke.transform ?? .init(), selection: stroke.selection, encoder: encoder)
        try encode(predictionBuffers, symmetry: stroke.symmetry, transform: transform, size: viewSize,
                   canvas: canvas, color: inkColor(stroke), brush: stroke.brush, strokeTransform: stroke.transform ?? .init(), selection: stroke.selection, encoder: encoder)
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
            result.append(GPUChunk(buffer: chunk.buffer, count: chunk.count - skip, offset: chunk.offset + skip,
                                   compactStamp: chunk.compactStamp, fadedStamp: chunk.fadedStamp, sourceBounds: chunk.sourceBounds))
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
        liveWorkStroke = nil
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
                           command: MTLCommandBuffer, load: MTLLoadAction = .load,
                           region: MTLScissorRect? = nil, clear: Bool = false) throws {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: targetPass(output, load: load)) else { throw DocumentError.graphics }
        layerCompositePasses += 1
        if let region { encoder.setScissorRect(region) }
        if clear {
            encoder.setRenderPipelineState(clearSingleRegionPipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
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
        for stroke in document.strokes where strokeBounds[stroke.id] == nil {
            // Conservative footprint includes scatter, tilt, square stamp corners
            // and AA. Original bounds remain available for removed/undone ink.
            let radius = max(4, stroke.brush.width * 2)
            var bounds = CGRect.null
            for sample in stroke.samples {
                bounds = bounds.union(CGRect(x: sample.point.x - radius, y: sample.point.y - radius,
                                             width: radius * 2, height: radius * 2))
            }
            var mirrored = CGRect.null
            let target = SymmetryConfiguration.bounds(CGRect(x: 0, y: 0, width: document.size.x, height: document.size.y), transformedBy: (stroke.transform ?? .init()).inverse)
            for matrix in stroke.symmetry.matrices(for: bounds, clip: target) { mirrored = mirrored.union(transformed(transformed(bounds, by: matrix), by: stroke.transform ?? .init())) }
            strokeBounds[stroke.id] = mirrored
        }
        scenePaintKeys = Dictionary(uniqueKeysWithValues: document.layers.map { layer in
            (layer.id, LayerPaintKey(id: layer.id, raster: layer.raster?.id,
                                    strokes: (sceneLayerStrokes[layer.id] ?? []).map(\.id), placement: layer.raster?.placement))
        })
    }

    private func transformed(_ rect: CGRect, by matrix: Matrix) -> CGRect {
        guard !rect.isNull else { return .null }
        let points = [Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY),
                      Point(x: rect.maxX, y: rect.maxY), Point(x: rect.minX, y: rect.maxY)].map { matrix.apply($0) }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    private func screenBounds(_ id: UUID, transform: Matrix) -> CGRect {
        guard let bounds = strokeBounds[id] else { return .infinite }
        return transformed(bounds, by: transform).insetBy(dx: -2, dy: -2)
    }

    private func dirtyTiles(from old: LayerPaintKey, to new: LayerPaintKey, document: DrawingDocument,
                            viewport: Viewport, viewSize: Point, target: MTLTexture) -> [(MTLScissorRect, CGRect)]? {
        guard old.id == new.id, old.raster == new.raster, old.placement == new.placement,
              viewSize.x > 0, viewSize.y > 0 else { return nil }
        let previous = Set(old.strokes), next = Set(new.strokes)
        // A reordering changes overlaps even if all stroke IDs are unchanged.
        guard old.strokes.filter({ next.contains($0) }) == new.strokes.filter({ previous.contains($0) }) else { return nil }
        let changed = previous.symmetricDifference(next)
        guard !changed.isEmpty else { return nil }
        let transform = viewport.matrix(viewSize: viewSize, canvasSize: document.size)
        let sx = Double(target.width) / viewSize.x, sy = Double(target.height) / viewSize.y
        let columns = (target.width + 255) / 256
        var tiles = Set<Int>()
        for id in changed {
            guard strokeBounds[id] != nil else { return nil }
            let rect = screenBounds(id, transform: transform)
            let x0 = max(0, Int(floor(rect.minX * sx / 256))), y0 = max(0, Int(floor(rect.minY * sy / 256)))
            let x1 = min(columns - 1, Int(floor(rect.maxX * sx / 256)))
            let y1 = min((target.height - 1) / 256, Int(floor(rect.maxY * sy / 256)))
            if x0 > x1 || y0 > y1 { continue }
            for y in y0...y1 { for x in x0...x1 { tiles.insert(y * columns + x) } }
        }
        return tiles.sorted().map { tile in
            let x = (tile % columns) * 256, y = (tile / columns) * 256
            let width = min(256, target.width - x), height = min(256, target.height - y)
            return (MTLScissorRect(x: x, y: y, width: width, height: height),
                    CGRect(x: Double(x) / sx, y: Double(y) / sy, width: Double(width) / sx, height: Double(height) / sy))
        }
    }

    private func clearRegion(_ encoder: MTLRenderCommandEncoder, scissor: MTLScissorRect) {
        encoder.setScissorRect(scissor); encoder.setDepthStencilState(nil)
        encoder.setRenderPipelineState(clearRegionPipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func configureSurface(document: DrawingDocument, viewport: Viewport, viewSize: Point,
                                  width: Int, height: Int) throws {
        try ensureWorkTargets(width: width, height: height)
        let next = SurfaceKey(document: document.id, canvas: document.size, view: viewSize,
            transform: viewport.matrix(viewSize: viewSize, canvasSize: document.size), width: width, height: height)
        if surfaceKey != next {
            if surfaceKey?.width != next.width || surfaceKey?.height != next.height {
                lowerTexture = nil; upperTexture = nil; activeTexture = nil
            }
            lowerKey = nil; upperKey = nil; activeKey = nil; surfaceKey = next
        }
    }

    private func needsStreamedPreparation(_ document: DrawingDocument, focus: UUID? = nil) -> Bool {
        let index = document.layers.firstIndex { $0.id == (focus ?? document.activeLayerID) } ?? 0
        let below = document.layers.prefix(index).filter { $0.isVisible && $0.opacity > 0 }
        let above = document.layers.dropFirst(index + 1).filter { $0.isVisible && $0.opacity > 0 }
        let lowerChanged = lowerKey != below.map { LayerCompositeKey(paint: paintKey($0), opacity: $0.opacity) }
        let upperChanged = upperKey != above.map { LayerCompositeKey(paint: paintKey($0), opacity: $0.opacity) }
        var required = (lowerChanged ? Array(below) : []) + (upperChanged ? Array(above) : [])
        if document.layers.indices.contains(index) {
            let selected = document.layers[index]
            let key = paintKey(selected)
            if selected.isVisible && selected.opacity > 0, activeKey != key {
                if let old = activeKey, old.id == key.id, old.raster == key.raster, old.placement == key.placement,
                   key.strokes.starts(with: old.strokes) {
                    let added = Set(key.strokes.dropFirst(old.strokes.count))
                    if (sceneLayerStrokes[selected.id] ?? []).contains(where: { added.contains($0.id) && cache[$0.id] == nil }) { return true }
                } else { required.append(selected) }
            }
        }
        return required.contains { layer in (sceneLayerStrokes[layer.id] ?? []).contains { cache[$0.id] == nil } }
    }

    private func submit(_ command: MTLCommandBuffer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { @Sendable finished in
                if finished.status == .error {
                    print("Metal command failed: \(String(describing: finished.error))")
                    continuation.resume(throwing: finished.error ?? DocumentError.graphics)
                }
                else { continuation.resume() }
            }
            command.commit()
        }
        try Task.checkCancellation()
    }

    /// Rebuild one layer with at most one expanded CPU stroke and one submitted
    /// stroke at a time. Awaiting GPU completion releases each submission's
    /// retained buffers before the LRU evicts them; no main-thread GPU wait.
    private func streamLayer(_ layer: DrawingLayer, target: MTLTexture, document: DrawingDocument,
                             viewport: Viewport, viewSize: Point, revision: Int?) async throws {
        guard let first = queue.makeCommandBuffer(), let encoder = first.makeRenderCommandEncoder(
            descriptor: try geometryPass(target)) else { throw DocumentError.graphics }
        do {
            try encodeScene(encoder: encoder, document: document, viewport: viewport, viewSize: viewSize,
                            active: nil, preview: [], guides: false, layerOnly: layer.id, strokes: [])
        } catch { encoder.endEncoding(); throw error }
        encoder.endEncoding(); try await submit(first)
        var pending: MTLCommandBuffer?
        var batchCount = 0, batchBytes = 0
        for stroke in sceneLayerStrokes[layer.id] ?? [] {
            try Task.checkCancellation()
            guard sceneDocumentID == document.id, sceneRevision == revision else { throw CancellationError() }
            let strokeBuffers: [GPUChunk]
            if let existing = cache[stroke.id] { strokeBuffers = existing }
            else {
                let points = await Task.detached(priority: .userInitiated) { BrushGeometry.mesh(stroke) }.value
                try Task.checkCancellation()
                strokeBuffers = try chunks(points)
                retain(strokeBuffers, for: stroke.id); geometryRebuilds += 1
            }
            if pending == nil { pending = queue.makeCommandBuffer() }
            guard let command = pending, let ink = command.makeRenderCommandEncoder(
                descriptor: try geometryPass(target, load: .load)) else { throw DocumentError.graphics }
            do {
                committedStrokeDraws += 1
                beginStroke(stroke, encoder: ink)
                try encode(strokeBuffers, symmetry: stroke.symmetry,
                           transform: viewport.matrix(viewSize: viewSize, canvasSize: document.size),
                           size: viewSize, canvas: document.size, color: inkColor(stroke), brush: stroke.brush, strokeTransform: stroke.transform ?? .init(), selection: stroke.selection, encoder: ink)
            } catch { ink.endEncoding(); throw error }
            ink.endEncoding(); preparationPins.remove(stroke.id)
            batchCount += 1
            batchBytes += strokeBuffers.reduce(0) { $0 + $1.buffer.length }
            // Encoded buffers remain owned by this command even if the LRU evicts
            // them. Submit bounded batches rather than wait after every stroke.
            if batchCount >= 4 || batchBytes >= 2 * 1024 * 1024 {
                try await submit(command); streamedSubmissions += 1
                pending = nil; batchCount = 0; batchBytes = 0
            }
        }
        if let pending { try await submit(pending); streamedSubmissions += 1 }

    }

    private func prepareScene(document: DrawingDocument, viewport: Viewport, viewSize: Point,
                              width: Int, height: Int, focus: UUID? = nil) async throws {
        let revision = sceneRevision
        // A queue barrier retires earlier display submissions before releasing
        // their cache buffers and rebuilding shared render targets.
        guard let barrier = queue.makeCommandBuffer() else { throw DocumentError.graphics }
        try await submit(barrier)
        guard sceneDocumentID == document.id, sceneRevision == revision else { throw CancellationError() }
        clearLayerCaches()
        let visible = Set(document.layers.filter { $0.isVisible && $0.opacity > 0 }.map(\.id))
        preparationPins = Set(document.strokes.filter { visible.contains($0.layerID) && cache[$0.id] != nil }.map(\.id))
        defer { preparationPins.removeAll() }
        try configureSurface(document: document, viewport: viewport, viewSize: viewSize, width: width, height: height)
        let index = document.layers.firstIndex { $0.id == (focus ?? document.activeLayerID) } ?? 0
        // Persistent MSAA is necessary between submissions. A memoryless target
        // cannot preserve coverage while a later stroke is being reconstructed.
        let staging = try texture(width: width, height: height, samples: sampleCount)
        guard let work = workTexture else { throw DocumentError.graphics }
        for (upper, layers) in [(false, Array(document.layers.prefix(index))),
                                 (true, Array(document.layers.dropFirst(index + 1)))] {
            let visible = layers.filter { $0.isVisible && $0.opacity > 0 }
            let result = visible.isEmpty ? nil : try texture(width: width, height: height)
            for (offset, layer) in visible.enumerated() {
                try await streamLayer(layer, target: staging, document: document, viewport: viewport,
                                      viewSize: viewSize, revision: revision)
                guard let command = queue.makeCommandBuffer(), let result else { throw DocumentError.graphics }
                if sampleCount > 1 {
                    guard let resolve = command.makeRenderCommandEncoder(descriptor: targetPass(staging, load: .load, resolve: work))
                    else { throw DocumentError.graphics }
                    resolve.endEncoding()
                }
                try composite(sampleCount > 1 ? work : staging, opacity: layer.opacity, output: result,
                              command: command, load: offset == 0 ? .clear : .load)
                try await submit(command)
            }
            let keys = visible.map { LayerCompositeKey(paint: paintKey($0), opacity: $0.opacity) }
            if upper { upperTexture = result; upperKey = keys }
            else { lowerTexture = result; lowerKey = keys }
        }
        if document.layers.indices.contains(index) {
            let layer = document.layers[index]
            if layer.isVisible && layer.opacity > 0 {
                try await streamLayer(layer, target: staging, document: document, viewport: viewport,
                                      viewSize: viewSize, revision: revision)
                guard sceneDocumentID == document.id, sceneRevision == revision else { throw CancellationError() }
                activeTexture = staging; activeKey = paintKey(layer); cachedLayerBuilds += 1
            }
        }
        cachedGroupBuilds += 1
    }

    private func renderStaticGroup(_ layers: [DrawingLayer], previous: [LayerCompositeKey]?,
                                   target: MTLTexture?, command: MTLCommandBuffer,
                                   document: DrawingDocument, viewport: Viewport, viewSize: Point) throws -> (MTLTexture?, [LayerCompositeKey]) {
        let key = layers.map { LayerCompositeKey(paint: paintKey($0), opacity: $0.opacity) }
        guard !layers.isEmpty else { return (nil, key) }
        if previous == key, let target { return (target, key) }
        liveWorkStroke = nil
        guard let work = workTexture else { throw DocumentError.graphics }
        let result = try target ?? texture(width: work.width, height: work.height)
        if let previous, target != nil, previous.map({ $0.paint.id }) == key.map({ $0.paint.id }),
           zip(previous, key).allSatisfy({ $0.opacity == $1.opacity }) {
            var tiles: [Int: (MTLScissorRect, CGRect)] = [:]
            var local = true
            for (old, new) in zip(previous, key) where old.paint != new.paint {
                guard let changed = dirtyTiles(from: old.paint, to: new.paint, document: document,
                    viewport: viewport, viewSize: viewSize, target: result) else { local = false; break }
                for tile in changed { tiles[tile.0.y * result.width + tile.0.x] = tile }
            }
            if local {
                for (_, tile) in tiles.sorted(by: { $0.key < $1.key }) {
                    for (offset, layer) in layers.enumerated() {
                        let pass = try geometryPass(workMultisample ?? work, resolve: workMultisample == nil ? nil : work)
                        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw DocumentError.graphics }
                        encoder.setScissorRect(tile.0)
                        do {
                            try encodeScene(encoder: encoder, document: document, viewport: viewport, viewSize: viewSize,
                                            active: nil, preview: [], guides: false, layerOnly: layer.id, region: tile.1)
                        } catch { encoder.endEncoding(); throw error }
                        encoder.endEncoding()
                        try composite(work, opacity: layer.opacity, output: result, command: command,
                                      region: tile.0, clear: offset == 0)
                    }
                    localTileUpdates += 1
                }
                return (result, key)
            }
        }
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
        liveWorkStroke = nil
        guard let work = workTexture else { throw DocumentError.graphics }
        let target = try activeTexture ?? texture(width: work.width, height: work.height, samples: sampleCount)
        let incremental: Bool
        if let old = activeKey {
            incremental = old.id == key.id && old.raster == key.raster && old.placement == key.placement && old.strokes.count < key.strokes.count &&
                Array(key.strokes.prefix(old.strokes.count)) == old.strokes
        } else { incremental = false }
        if !incremental, let old = activeKey,
           let tiles = dirtyTiles(from: old, to: key, document: document, viewport: viewport, viewSize: viewSize, target: target) {
            for (scissor, region) in tiles {
                guard let encoder = command.makeRenderCommandEncoder(descriptor: try geometryPass(target, load: .load))
                else { throw DocumentError.graphics }
                clearRegion(encoder, scissor: scissor)
                do {
                    try encodeScene(encoder: encoder, document: document, viewport: viewport, viewSize: viewSize,
                                    active: nil, preview: [], guides: false, layerOnly: layer.id, region: region)
                } catch { encoder.endEncoding(); throw error }
                encoder.endEncoding(); localTileUpdates += 1
            }
            activeTexture = target; activeKey = key
            activeLiveID = nil; activeLiveVertices = 0; pendingLiveCommit = nil
            return
        }
        let pass = try geometryPass(target, load: incremental ? .load : .clear)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw DocumentError.graphics }
        do {
            if incremental, let old = activeKey {
                let transform = viewport.matrix(viewSize: viewSize, canvasSize: document.size)
                for stroke in (sceneLayerStrokes[layer.id] ?? []).dropFirst(old.strokes.count) {
                    committedStrokeDraws += 1
                    beginStroke(stroke, encoder: encoder)
                    let buffers = try buffers(for: stroke)
                    let remaining = pendingLiveCommit == stroke.id && activeLiveID == stroke.id
                        ? suffix(buffers, after: activeLiveVertices) : buffers
                    try encode(remaining, symmetry: stroke.symmetry, transform: transform,
                               size: viewSize, canvas: document.size, color: inkColor(stroke), brush: stroke.brush, strokeTransform: stroke.transform ?? .init(), selection: stroke.selection, encoder: encoder)
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

    private func liveRegion(_ active: InkStroke, preview: [BrushVertex], document: DrawingDocument,
                            viewport: Viewport, viewSize: Point, work: MTLTexture) -> CGRect? {
        let reuse = liveWorkStroke == active.id
        var source = liveSourceBounds
        for vertex in preview { source = source.union(CGRect(x: vertex.point.x, y: vertex.point.y, width: 0, height: 0)) }
        let transform = viewport.matrix(viewSize: viewSize, canvasSize: document.size)
        var screen = CGRect.null
        for matrix in active.symmetry.matrices(for: source) { screen = screen.union(transformed(transformed(source, by: matrix), by: transform)) }
        let sx = Double(work.width) / viewSize.x, sy = Double(work.height) / viewSize.y
        let pixels = CGRect(x: screen.minX * sx, y: screen.minY * sy,
                            width: screen.width * sx, height: screen.height * sy).insetBy(dx: -3, dy: -3)
        // Include prior predictions so a moving/shrinking tail leaves no ghosts.
        liveWorkBounds = liveWorkBounds.union(pixels)
        let clipped = liveWorkBounds.intersection(CGRect(x: 0, y: 0, width: work.width, height: work.height)).integral
        liveWorkStroke = active.id
        guard reuse, !clipped.isNull, !clipped.isEmpty, clipped.width <= 1024, clipped.height <= 1024,
              clipped.width * clipped.height < Double(work.width * work.height) * 0.5 else { return nil }
        return clipped
    }

    private func renderLiveTile(_ active: InkStroke, preview: [BrushVertex], region: CGRect,
                                command: MTLCommandBuffer, document: DrawingDocument, viewport: Viewport,
                                viewSize: Point, base: MTLTexture, work: MTLTexture) throws {
        // A small resolved tile replaces only the dirty rectangle in the full
        // resolved layer. MSAA remains memoryless; no full-screen MSAA history
        // needs to be loaded or stored just to update a short stroke.
        let side = max(region.width, region.height) <= 512 ? 512 : 1024
        if liveTile == nil || liveTile!.width < side {
            liveTile = nil; liveTileMSAA = nil; liveTileStencil = nil
            liveTile = try texture(width: side, height: side)
            if sampleCount > 1 { liveTileMSAA = try texture(width: side, height: side, samples: sampleCount, transient: true) }
        }
        guard let tile = liveTile else { throw DocumentError.graphicsMemory }
        let target = liveTileMSAA ?? tile
        // Keep independent stencil attachments: switching between full layer and
        // small tile must not allocate a replacement stencil on every input event.
        let fullStencil = coverageStencil; coverageStencil = liveTileStencil
        let pass: MTLRenderPassDescriptor
        do { pass = try geometryPass(target, resolve: liveTileMSAA == nil ? nil : tile) }
        catch { liveTileStencil = coverageStencil; coverageStencil = fullStencil; throw error }
        liveTileStencil = coverageStencil; coverageStencil = fullStencil
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw DocumentError.graphics }
        do {
            encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: Int(region.width), height: Int(region.height)))
            encoder.setRenderPipelineState(sampleCount > 1 ? restoreTileSamplesPipeline : restoreTileColorPipeline)
            encoder.setFragmentTexture(base, index: 0)
            var origin = SIMD2<UInt32>(UInt32(region.minX), UInt32(region.minY))
            encoder.setFragmentBytes(&origin, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            let scale = Matrix(a: Double(work.width) / viewSize.x, d: Double(work.height) / viewSize.y)
            let transform = viewport.matrix(viewSize: viewSize, canvasSize: document.size).followed(by: scale)
                .followed(by: .translation(Point(x: -region.minX, y: -region.minY)))
            let size = Point(x: Double(tile.width), y: Double(tile.height))
            if usesUniformOpacity(active) {
                try encodeLive(active, preview: preview, transform: transform, viewSize: size, canvas: document.size, encoder: encoder)
            } else {
                encoder.setRenderPipelineState(active.operation == .erase ? erasePipeline : pipeline)
                try encode(predictionBuffers, symmetry: active.symmetry, transform: transform, size: size,
                           canvas: document.size, color: inkColor(active), brush: active.brush, strokeTransform: active.transform ?? .init(), selection: active.selection, encoder: encoder)
            }
        } catch { encoder.endEncoding(); throw error }
        encoder.endEncoding()
        guard let blit = command.makeBlitCommandEncoder() else { throw DocumentError.graphics }
        blit.copy(from: tile, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: Int(region.width), height: Int(region.height), depth: 1),
                  to: work, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: Int(region.minX), y: Int(region.minY), z: 0))
        blit.endEncoding(); partialLiveRestores += 1
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
            if let region = liveRegion(active, preview: preview, document: document, viewport: viewport, viewSize: viewSize, work: work) {
                try renderLiveTile(active, preview: preview, region: region, command: command, document: document,
                                   viewport: viewport, viewSize: viewSize, base: base, work: work)
                return work
            }
            let pass = try geometryPass(workMultisample ?? work, resolve: workMultisample == nil ? nil : work)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw DocumentError.graphics }
            liveRestorePasses += 1
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
                           size: viewSize, canvas: document.size, color: inkColor(active), brush: active.brush, strokeTransform: active.transform ?? .init(), selection: active.selection, encoder: stable)
            } catch { stable.endEncoding(); throw error }
            stable.endEncoding()
            liveConfirmedVertexDraws += confirmed - activeLiveVertices; activeLiveVertices = confirmed
        }
        if let region = liveRegion(active, preview: preview, document: document, viewport: viewport, viewSize: viewSize, work: work) {
                try renderLiveTile(active, preview: preview, region: region, command: command, document: document,
                                   viewport: viewport, viewSize: viewSize, base: base, work: work)
                return work
            }
            let pass = try geometryPass(workMultisample ?? work, resolve: workMultisample == nil ? nil : work)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw DocumentError.graphics }
        liveRestorePasses += 1
        do {
            encoder.setRenderPipelineState(sampleCount > 1 ? restoreSamplesPipeline : restoreColorPipeline)
            encoder.setFragmentTexture(base, index: 0)
            var alpha: Float = 1
            encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.setRenderPipelineState(active.operation == .erase ? erasePipeline : pipeline)
            try encode(predictionBuffers, symmetry: active.symmetry,
                       transform: viewport.matrix(viewSize: viewSize, canvasSize: document.size), size: viewSize,
                       canvas: document.size, color: inkColor(active), brush: active.brush, strokeTransform: active.transform ?? .init(), selection: active.selection, encoder: encoder)
        } catch { encoder.endEncoding(); throw error }
        encoder.endEncoding()
        return work
    }

    private func resolveActiveLayer(command: MTLCommandBuffer) throws -> MTLTexture {
        liveWorkStroke = nil
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
            clearLayerCaches(); cache.removeAll(); cacheOrder.removeAll(); recountBuffers()
            throw DocumentError.graphicsMemory
        } catch {
            clearLayerCaches(); throw error
        }
    }

    private func clearLayerCaches() {
        liveWorkStroke = nil; liveWorkBounds = .null
        lowerTexture = nil; upperTexture = nil; activeTexture = nil
        lowerKey = nil; upperKey = nil; activeKey = nil; renderCacheBytes = 0
        activeLiveID = nil; activeLiveVertices = 0; pendingLiveCommit = nil
    }

    func handleMemoryPressure() {
        liveTile = nil; liveTileMSAA = nil; liveTileStencil = nil
        cancelViewportNavigation(); lastFrameDocument = nil; lastFrameViewport = nil
        clearLayerCaches()
        cache.removeAll(); cacheOrder.removeAll(); recountBuffers()
        matrixCache.removeAll(); tileMatrixCache.removeAll(); rasterQuads.removeAll(); guideBuffers.removeAll(); guideKey.removeAll()
        // Recover through the bounded streaming path on the next frame.
        cacheBudget = 160 * 1024 * 1024
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
        if reference { liveWorkStroke = nil }
        if isPreparingScene { await preparationTask?.value }
        updateScene(document); sceneRevision = nil
        let viewSize = Point(x: Double(width), y: Double(height))
        try configureSurface(document: document, viewport: viewport, viewSize: viewSize, width: width, height: height)
        if !reference, needsStreamedPreparation(document, focus: active?.layerID) {
            try await prepareScene(document: document, viewport: viewport, viewSize: viewSize,
                                   width: width, height: height, focus: active?.layerID)
        }
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
        if reference && document.strokes.contains(where: { cache[$0.id] == nil }) {
            // Large reference/export draws use independent sequential layers,
            // with the same bounded submissions as a viewport rebuild.
            guard let background = command.makeRenderCommandEncoder(descriptor: targetPass(output)) else { throw DocumentError.graphics }
            do {
                try encodeScene(encoder: background, document: document, viewport: viewport, viewSize: viewSize,
                                active: nil, preview: [], guides: guides, backgroundOnly: true, state: singlePipeline)
            } catch { background.endEncoding(); throw error }
            background.endEncoding(); try await submit(command)
            let target = try texture(width: width, height: height, samples: sampleCount)
            guard let work = workTexture else { throw DocumentError.graphics }
            for layer in document.layers where layer.isVisible && layer.opacity > 0 {
                try await streamLayer(layer, target: target, document: document, viewport: viewport, viewSize: viewSize, revision: nil)
                guard let compositeCommand = queue.makeCommandBuffer() else { throw DocumentError.graphics }
                if let active, active.layerID == layer.id {
                    guard let ink = compositeCommand.makeRenderCommandEncoder(descriptor: try geometryPass(target, load: .load))
                    else { throw DocumentError.graphics }
                    do {
                        try encodeLive(active, preview: preview, transform: viewport.matrix(viewSize: viewSize, canvasSize: document.size),
                                       viewSize: viewSize, canvas: document.size, encoder: ink)
                    } catch { ink.endEncoding(); throw error }
                    ink.endEncoding()
                }
                if sampleCount > 1 {
                    guard let resolve = compositeCommand.makeRenderCommandEncoder(descriptor: targetPass(target, load: .load, resolve: work))
                    else { throw DocumentError.graphics }
                    resolve.endEncoding()
                }
                try composite(sampleCount > 1 ? work : target, opacity: layer.opacity, output: output, command: compositeCommand)
                try await submit(compositeCommand)
            }
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes {
                output.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            return pixels
        } else if !reference {
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
                if command.status == .error {
                    print("Metal readback failed: \(String(describing: command.error))")
                    continuation.resume(throwing: command.error ?? DocumentError.graphics)
                }
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
                        size: Point, canvas: Point, color: SIMD4<Float>, brush: InkBrush = InkBrush(), strokeTransform: Matrix = .init(),
                        selection: StrokeSelection? = nil, encoder: MTLRenderCommandEncoder) throws {
        // Six aligned float4s in both Swift and Metal (96 bytes).
        let uniforms: [SIMD4<Float>] = [
            SIMD4(Float(transform.a), Float(transform.b), Float(transform.c), Float(transform.d)),
            SIMD4(Float(transform.tx), Float(transform.ty), Float(size.x), Float(size.y)),
            SIMD4(Float(canvas.x), Float(canvas.y), Float(brush.effectiveSoftness), brush.usesStamps ? 1 : 0), color,
            SIMD4(Float(strokeTransform.a), Float(strokeTransform.b), Float(strokeTransform.c), Float(strokeTransform.d)),
            SIMD4(Float(strokeTransform.tx), Float(strokeTransform.ty), 0, 0)
        ]
        var selectionCount = UInt32(selection?.points.count ?? 0)
        let polygon = selection?.points.map { SIMD2<Float>(Float($0.x), Float($0.y)) } ?? [SIMD2<Float>(0, 0)]
        polygon.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.setFragmentBytes(&selectionCount, length: MemoryLayout<UInt32>.stride, index: 2)
        var selectionBounds = SIMD4<Float>(polygon.map(\.x).min()!, polygon.map(\.y).min()!,
                                          polygon.map(\.x).max()!, polygon.map(\.y).max()!)
        encoder.setFragmentBytes(&selectionBounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
        let matrices: MTLBuffer
        let instanceCount: Int
        if symmetry.tileCount > 0 && symmetry.tileSymmetry {
            let bounds = chunks.reduce(CGRect.null) { $0.union($1.sourceBounds) }
            guard !bounds.isNull else { return }
            let clip = SymmetryConfiguration.bounds(CGRect(x: 0, y: 0, width: canvas.x, height: canvas.y), transformedBy: strokeTransform.inverse)
            let key = TileMatrixKey(symmetry: symmetry,
                bounds: [Double(bounds.minX), Double(bounds.minY), Double(bounds.maxX), Double(bounds.maxY)],
                clip: [Double(clip.minX), Double(clip.minY), Double(clip.maxX), Double(clip.maxY)])
            if let cached = tileMatrixCache[key] { matrices = cached.0; instanceCount = cached.1 }
            else {
                let transforms = symmetry.matrices(for: bounds, clip: clip)
                guard !transforms.isEmpty else { return }
                let values: [SIMD4<Float>] = transforms.flatMap { m in
                    [SIMD4(Float(m.a), Float(m.b), Float(m.c), Float(m.d)), SIMD4(Float(m.tx), Float(m.ty), 0, 0)]
                }
                guard let buffer = values.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else { throw DocumentError.graphicsMemory }
                if tileMatrixCache.count >= 128 { tileMatrixCache.removeAll() }
                matrices = buffer; instanceCount = transforms.count; tileMatrixCache[key] = (buffer, instanceCount)
            }
        } else {
            if matrixCache[symmetry] == nil {
                let values: [SIMD4<Float>] = symmetry.matrices.flatMap { m in
                    [SIMD4(Float(m.a), Float(m.b), Float(m.c), Float(m.d)), SIMD4(Float(m.tx), Float(m.ty), 0, 0)]
                }
                let buffer = values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
                guard let buffer else { throw DocumentError.graphicsMemory }
                matrixCache[symmetry] = buffer
            }
            matrices = matrixCache[symmetry]!; instanceCount = symmetry.instanceCount
        }
        uniforms.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
        // 64 sectors + Mirror uses 128 transforms (4096 bytes), so use a buffer
        // rather than the small inline setVertexBytes argument limit.
        encoder.setVertexBuffer(matrices, offset: 0, index: 2)
        for chunk in chunks {
            var compact: UInt32 = chunk.compactStamp ? (chunk.fadedStamp ? 2 : 1) : 0
            encoder.setVertexBytes(&compact, length: MemoryLayout<UInt32>.stride, index: 3)
            encoder.setVertexBuffer(chunk.buffer, offset: chunk.byteOffset, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: chunk.count,
                                   instanceCount: instanceCount)
        }
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    fragment float4 clearRegionFragment() { return float4(0); }
    struct Uniforms { float4 matrix; float4 offsetSize; float4 canvas; float4 color; float4 strokeMatrix; float4 strokeOffset; };
    struct Output { float4 position [[position]]; float2 canvas; float2 source; float2 limit; float4 color; float2 local; float2 stamp; };
    vertex Output inkVertex(uint v [[vertex_id]], uint instance [[instance_id]],
                           const device float2 *vertices [[buffer(0)]],
                           constant Uniforms &u [[buffer(1)]], constant float4 *symmetry [[buffer(2)]],
                           constant uint &compact [[buffer(3)]]) {
        float4 m = symmetry[instance * 2];
        const uint corner[6] = {0, 1, 2, 0, 2, 3};
        const float2 local[4] = {float2(-1,-1), float2(1,-1), float2(1,1), float2(-1,1)};
        uint base = (v / 6) * 4, c = corner[v % 6];
        float2 p = compact != 0 ? vertices[base + c] : vertices[v * 2];
        float2 shape = compact != 0 ? local[c] : vertices[v * 2 + 1];
        float fade = 1;
        if (compact == 2) {
            if (c == 3) p = vertices[base] + vertices[base + 2] - vertices[base + 1];
            fade = vertices[base + 3].x;
        } else if (compact == 0 && abs(shape.x) >= 2 && abs(shape.x) <= 3) {
            fade = abs(shape.x) - 2; shape = sign(shape);
        }
        float2 source = p;
        p = float2(m.x*p.x + m.z*p.y, m.y*p.x + m.w*p.y) + symmetry[instance*2+1].xy;
        float4 sm = u.strokeMatrix;
        p = float2(sm.x*p.x + sm.z*p.y, sm.y*p.x + sm.w*p.y) + u.strokeOffset.xy;
        float4 t = u.matrix;
        float2 screen = float2(t.x*p.x + t.z*p.y, t.y*p.x + t.w*p.y) + u.offsetSize.xy;
        Output out;
        out.position = float4(screen.x/u.offsetSize.z*2-1, 1-screen.y/u.offsetSize.w*2, 0, 1);
        out.canvas = p; out.source = source; out.limit = u.canvas.xy; out.color = u.color;
        out.color.a *= fade;
        out.local = shape; out.stamp = u.canvas.zw;
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
    fragment float4 restoreTileSamplesFragment(CompositeOutput in [[stage_in]],
        texture2d_ms<float, access::read> image [[texture(0)]], constant uint2 &origin [[buffer(0)]], uint sample [[sample_id]]) {
        return image.read(uint2(in.position.xy) + origin, sample);
    }
    fragment float4 restoreTileColorFragment(CompositeOutput in [[stage_in]],
        texture2d<float, access::read> image [[texture(0)]], constant uint2 &origin [[buffer(0)]]) {
        return image.read(uint2(in.position.xy) + origin);
    }
    fragment float4 restoreSamplesFragment(CompositeOutput in [[stage_in]],
                                           texture2d_ms<float, access::read> layer [[texture(0)]],
                                           uint sample [[sample_id]]) {
        return layer.read(uint2(in.position.xy), sample);
    }
    fragment float4 inkFragment(Output in [[stage_in]], constant float2 *polygon [[buffer(1)]],
                                constant uint &count [[buffer(2)]], constant float4 &bounds [[buffer(3)]]) {
        if (count >= 3) {
            if (any(in.source < bounds.xy) || any(in.source > bounds.zw)) discard_fragment();
            bool inside = false;
            uint j = count - 1;
            for (uint i = 0; i < count; j = i++) {
                float2 a = polygon[i], b = polygon[j];
                if ((a.y > in.source.y) != (b.y > in.source.y) &&
                    in.source.x < (b.x-a.x) * (in.source.y-a.y) / (b.y-a.y) + a.x) inside = !inside;
            }
            if (!inside) discard_fragment();
        }
        if (any(in.canvas < float2(0)) || any(in.canvas > in.limit)) discard_fragment();
        float4 color = in.color;
        if (in.stamp.y > 0.5) {
            float radius = length(in.local);
            if (radius > 1) discard_fragment();
            if (in.stamp.x > 0) color.a *= 1 - smoothstep(1.0 - in.stamp.x, 1.0, radius);
        }
        return color;
    }
    """
}
