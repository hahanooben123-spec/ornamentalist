import MetalKit

private struct GPUChunk {
    let buffer: MTLBuffer
    let count: Int
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
    private let singlePipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
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
    private var sceneStrokeIDs: [UUID] = []
    private var sceneLayerIDs: [UUID] = []
    private var sceneStrokes: [InkStroke] = []
    private var sceneLayerStrokes: [UUID: [InkStroke]] = [:]
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
        return "CPU frame submission: \(timing(cpuFrameMilliseconds))\nGPU execution: \(timing(gpuFrameMilliseconds))\nDeferred frames: \(deferredFrames)\nSource vertex buffers: \(bytes / 1024) KiB\n\nLast 240 samples. These timings do not measure Pencil-to-screen latency or total app memory."
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
        view.sampleCount = preferredSampleCount
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "inkVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "inkFragment")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.rasterSampleCount = view.sampleCount
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
        singlePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.vertexFunction = library.makeFunction(name: "compositeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "compositeFragment")
        attachment.sourceRGBBlendFactor = .one // Layer textures are premultiplied.
        compositePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
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
        guard let buffer else { throw DocumentError.memoryLimit }
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
            rasterTextures[raster.id] = try loader.newTexture(cgImage: image, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft.rawValue, .generateMipmaps: false])
        }
        prune(strokes, layers: layers)
        for (id, buffers) in uploaded { cache[id] = buffers }
        allocatedVertexCount = cache.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
    }
    func begin() { sealed.removeAll(); sealedVertexCount = 0; scratch.removeAll(keepingCapacity: true) }
    func append(_ points: [BrushVertex]) throws {
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
        try append(BrushGeometry.tail(stroke))
        if !scratch.isEmpty { sealed.append(try chunk(scratch)) }
        cache[stroke.id] = sealed
        allocatedVertexCount = cache.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
        begin()
    }
    func cancel() { begin() }

    func draw(view: MTKView, document: DrawingDocument, viewport: Viewport,
              active: InkStroke?, preview: [BrushVertex], guides: Bool) throws {
        let started = ProcessInfo.processInfo.systemUptime
        // Never block the touch delivery thread when the GPU is behind.
        guard inFlight.wait(timeout: .now()) == .success else {
            deferredFrames += 1
            view.setNeedsDisplay()
            return
        }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let grouped = requiresGroups(document, active: active)
        if grouped && groupInFlight.wait(timeout: .now()) != .success {
            inFlight.signal(); deferredFrames += 1; view.setNeedsDisplay(); return
        }
        let groupGate = groupInFlight
        let gate = inFlight
        // Metal invokes this on its own queue, never on the renderer's main actor.
        command.addCompletedHandler { @Sendable [weak self] command in
            gate.signal()
            if grouped { groupGate.signal() }
            let gpu = (command.gpuEndTime - command.gpuStartTime) * 1000
            Task { @MainActor in self?.recordGPU(gpu) }
        }
        // Even an allocation error closes the encoder and submits its resources.
        defer {
            command.present(drawable); command.commit()
            recordCPU((ProcessInfo.processInfo.systemUptime - started) * 1000)
        }
        let size = Point(x: Double(view.bounds.width), y: Double(view.bounds.height))
        if grouped {
            try encodeGroups(command: command, output: drawable.texture, document: document,
                             viewport: viewport, viewSize: size, active: active, preview: preview, guides: guides)
        } else {
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw DocumentError.graphics }
            defer { encoder.endEncoding() }
            try encodeScene(encoder: encoder, document: document, viewport: viewport, viewSize: size,
                            active: active, preview: preview, guides: guides)
        }
    }

    private func encodeScene(encoder: MTLRenderCommandEncoder, document: DrawingDocument, viewport: Viewport,
                             viewSize: Point, active: InkStroke?, preview: [BrushVertex], guides: Bool,
                             layerOnly: UUID? = nil, backgroundOnly: Bool = false,
                             state: MTLRenderPipelineState? = nil) throws {
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
        if layerOnly == nil {
        let strokeIDs = document.strokes.map(\.id)
        let layerIDs = document.layers.filter(\.isVisible).map(\.id)
        if sceneStrokeIDs != strokeIDs || sceneLayerIDs != layerIDs {
            sceneStrokeIDs = strokeIDs; sceneLayerIDs = layerIDs
            sceneStrokes = document.visibleStrokes
            sceneLayerStrokes = Dictionary(grouping: sceneStrokes, by: \.layerID)
        }
        }
        if backgroundOnly { return }
        for layer in document.layers where layer.isVisible && layer.opacity > 0 && (layerOnly == nil || layerOnly == layer.id) {
            if let raster = layer.raster {
                guard let texture = rasterTextures[raster.id] else { throw DocumentError.graphics }
                encoder.setRenderPipelineState(rasterPipeline)
                encoder.setFragmentTexture(texture, index: 0)
                try encode(paper, symmetry: identity, transform: transform, size: viewSize, canvas: document.size,
                           color: SIMD4(1, 1, 1, 1), encoder: encoder)
            }
            for stroke in sceneLayerStrokes[layer.id] ?? [] {
                encoder.setRenderPipelineState(stroke.operation == .erase ? erasePipeline : pipeline)
                try encode(cache[stroke.id] ?? [], symmetry: stroke.symmetry, transform: transform,
                           size: viewSize, canvas: document.size, color: inkColor(stroke), brush: stroke.brush, encoder: encoder)
            }
            if let active, active.layerID == layer.id {
                encoder.setRenderPipelineState(active.operation == .erase ? erasePipeline : pipeline)
                var live = sealed
                if !scratch.isEmpty { live.append(try chunk(scratch)) }
                live += try chunks(preview)
                try encode(live, symmetry: active.symmetry, transform: transform, size: viewSize,
                           canvas: document.size, color: inkColor(active), brush: active.brush, encoder: encoder)
            }
        }
    }

    private func inkColor(_ stroke: InkStroke) -> SIMD4<Float> {
        SIMD4(Float(stroke.color.red), Float(stroke.color.green), Float(stroke.color.blue), Float(stroke.brush.opacity))
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
        let textureInfo = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                            width: output.width, height: output.height, mipmapped: false)
        textureInfo.storageMode = .private; textureInfo.usage = [.renderTarget, .shaderRead]
        guard let layerTexture = device.makeTexture(descriptor: textureInfo) else { throw DocumentError.memoryLimit }
        var multisample: MTLTexture?
        if sampleCount > 1 {
            let info = MTLTextureDescriptor()
            info.textureType = .type2DMultisample; info.pixelFormat = .bgra8Unorm
            info.width = output.width; info.height = output.height; info.sampleCount = sampleCount
            info.storageMode = .private; info.usage = .renderTarget
            multisample = device.makeTexture(descriptor: info)
            guard multisample != nil else { throw DocumentError.memoryLimit }
        }
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
                         active: InkStroke? = nil, preview: [BrushVertex] = [], guides: Bool = false) async throws -> [UInt8] {
        guard width > 0, height > 0, width <= 2048, height <= 2048 else { throw DocumentError.invalidData }
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
        if sampleCount > 1 && !requiresGroups(document, active: active) {
            let msaa = MTLTextureDescriptor()
            msaa.textureType = .type2DMultisample; msaa.pixelFormat = .bgra8Unorm
            msaa.width = width; msaa.height = height; msaa.sampleCount = sampleCount
            msaa.storageMode = .private; msaa.usage = .renderTarget
            guard let texture = device.makeTexture(descriptor: msaa) else { throw DocumentError.graphics }
            color.texture = texture; color.resolveTexture = output; color.storeAction = .multisampleResolve
        } else { color.texture = output; color.storeAction = .store }
        if requiresGroups(document, active: active) {
            try encodeGroups(command: command, output: output, document: document, viewport: viewport,
                             viewSize: Point(x: Double(width), y: Double(height)), active: active, preview: preview, guides: guides)
        } else {
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
            guard let buffer else { throw DocumentError.memoryLimit }
            matrixCache[symmetry] = buffer
        }
        let matrices = matrixCache[symmetry]!
        uniforms.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
        // 64 sectors + Mirror uses 128 transforms (4096 bytes), so use a buffer
        // rather than the small inline setVertexBytes argument limit.
        encoder.setVertexBuffer(matrices, offset: 0, index: 2)
        for chunk in chunks {
            encoder.setVertexBuffer(chunk.buffer, offset: 0, index: 0)
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
