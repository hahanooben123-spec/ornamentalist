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
    private var cache: [UUID: [GPUChunk]] = [:]
    private var sealed: [GPUChunk] = []
    private var scratch: [SIMD2<Float>] = []
    private let chunkSize = 8190 // Multiple of three.
    private let inFlight = DispatchSemaphore(value: 3)
    private let sampleCount: Int
    private var paperSize = Point.zero
    private var paper: [GPUChunk] = []
    private var guideKey: [Double] = []
    private var guideBuffers: [GPUChunk] = []
    private var matrixCache: [SymmetryConfiguration: [SIMD4<Float>]] = [:]
    private(set) var allocatedVertexCount = 0
    private var sealedVertexCount = 0

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
        view.clearColor = MTLClearColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.preferredFramesPerSecond = 120
        view.isOpaque = true
    }

    private func chunk(_ points: [SIMD2<Float>]) throws -> GPUChunk {
        guard !points.isEmpty else { throw DocumentError.graphics }
        let buffer = points.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }
        guard let buffer else { throw DocumentError.memoryLimit }
        return GPUChunk(buffer: buffer, count: points.count)
    }
    private func chunks(_ points: [Point]) throws -> [GPUChunk] {
        var result: [GPUChunk] = []
        for start in stride(from: 0, to: points.count, by: chunkSize) {
            result.append(try chunk(points[start..<min(points.count, start+chunkSize)].map {
                SIMD2(Float($0.x), Float($0.y))
            }))
        }
        return result
    }
    func hasBuffers(for strokes: [InkStroke]) -> Bool { strokes.allSatisfy { cache[$0.id] != nil } }
    func prune(_ strokes: [InkStroke]) {
        let ids = Set(strokes.map(\.id))
        cache = cache.filter { ids.contains($0.key) }
        allocatedVertexCount = cache.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
    }
    func synchronize(_ strokes: [InkStroke]) async throws {
        let missing = strokes.filter { cache[$0.id] == nil }
        let prepared = try await Task.detached(priority: .userInitiated) {
            var total = 0
            for stroke in strokes {
                total += StrokeGeometry.estimatedVertexCount(stroke)
                guard total <= DrawingLimits.vertexCount else { throw DocumentError.memoryLimit }
            }
            return try missing.map { stroke -> (UUID, [Point]) in
                try Task.checkCancellation()
                guard StrokeGeometry.estimatedVertexCount(stroke) <= DrawingLimits.strokeVertices else {
                    throw DocumentError.memoryLimit
                }
                return (stroke.id, StrokeGeometry.mesh(stroke))
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
        prune(strokes)
        for (id, buffers) in uploaded { cache[id] = buffers }
        allocatedVertexCount = cache.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
    }
    func begin() { sealed.removeAll(); sealedVertexCount = 0; scratch.removeAll(keepingCapacity: true) }
    func append(_ points: [Point]) throws {
        guard allocatedVertexCount + sealedVertexCount + scratch.count + points.count <= DrawingLimits.vertexCount else {
            throw DocumentError.memoryLimit
        }
        for p in points {
            scratch.append(SIMD2(Float(p.x), Float(p.y)))
            if scratch.count == chunkSize {
                sealed.append(try chunk(scratch))
                sealedVertexCount += scratch.count
                scratch.removeAll(keepingCapacity: true)
            }
        }
    }
    func commit(_ stroke: InkStroke) throws {
        try append(StrokeGeometry.tail(samples: stroke.samples, brush: stroke.brush))
        if !scratch.isEmpty { sealed.append(try chunk(scratch)) }
        cache[stroke.id] = sealed
        allocatedVertexCount = cache.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
        begin()
    }
    func cancel() { begin() }

    func draw(view: MTKView, document: DrawingDocument, viewport: Viewport,
              active: InkStroke?, preview: [Point], guides: Bool) throws {
        // Never block the touch delivery thread when the GPU is behind.
        guard inFlight.wait(timeout: .now()) == .success else {
            view.setNeedsDisplay()
            return
        }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal()
            return
        }
        let gate = inFlight
        command.addCompletedHandler { _ in gate.signal() }
        // Even an allocation error closes the encoder and submits its resources.
        defer { encoder.endEncoding(); command.present(drawable); command.commit() }
        try encodeScene(encoder: encoder, document: document, viewport: viewport,
                        viewSize: Point(x: Double(view.bounds.width), y: Double(view.bounds.height)),
                        active: active, preview: preview, guides: guides)
    }

    private func encodeScene(encoder: MTLRenderCommandEncoder, document: DrawingDocument, viewport: Viewport,
                             viewSize: Point, active: InkStroke?, preview: [Point], guides: Bool) throws {
        encoder.setRenderPipelineState(pipeline)
        let transform = viewport.matrix(viewSize: viewSize, canvasSize: document.size)
        let identity = SymmetryConfiguration(repetitions: 1, center: .zero)
        if paperSize != document.size || paper.isEmpty {
            paperSize = document.size
            paper = try chunks([.zero, Point(x: document.size.x, y: 0), document.size,
                                .zero, document.size, Point(x: 0, y: document.size.y)])
        }
        try encode(paper, symmetry: identity, transform: transform, size: viewSize,
                   canvas: document.size, color: SIMD4(1, 1, 1, 1), encoder: encoder)
        // Guides are cached, translucent, and BELOW the black artwork.
        if guides {
            let center = document.symmetry.center
            let key = [center.x, center.y, Double(document.symmetry.repetitions), document.size.x,
                       document.size.y, viewport.zoom, viewSize.x, viewSize.y]
            if guideKey != key {
                let radius = max(document.size.x, document.size.y) * 1.5
                let screenScale = hypot(transform.a, transform.b)
                let brush = InkBrush(width: 0.7 / max(0.01, screenScale))
                var mesh: [Point] = []
                for matrix in document.symmetry.matrices {
                    let a = StrokeSample(point: center, pressure: 1, altitude: 0, azimuth: 0, time: 0)
                    var b = a; b.point = matrix.apply(center + Point(x: radius, y: 0))
                    mesh += StrokeGeometry.segment(a, b, brush: brush)
                }
                guideBuffers = try chunks(mesh); guideKey = key
            }
            try encode(guideBuffers, symmetry: identity, transform: transform, size: viewSize,
                       canvas: document.size, color: SIMD4(0.1, 0.5, 0.55, 0.22), encoder: encoder)
        }
        for stroke in document.strokes {
            try encode(cache[stroke.id] ?? [], symmetry: stroke.symmetry, transform: transform,
                       size: viewSize, canvas: document.size, color: SIMD4(0, 0, 0, 1), encoder: encoder)
        }
        if let active {
            var live = sealed
            if !scratch.isEmpty { live.append(try chunk(scratch)) }
            live += try chunks(preview)
            try encode(live, symmetry: active.symmetry, transform: transform, size: viewSize,
                       canvas: document.size, color: SIMD4(0, 0, 0, 1), encoder: encoder)
        }
    }

    /// Test/readback path uses the SAME pipeline, geometry, clipping and transforms
    /// as the visible canvas. BGRA rows are returned in top-left screen order.
    func renderOffscreen(document: DrawingDocument, viewport: Viewport, width: Int, height: Int,
                         active: InkStroke? = nil, preview: [Point] = [], guides: Bool = false) async throws -> [UInt8] {
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
        if sampleCount > 1 {
            let msaa = MTLTextureDescriptor()
            msaa.textureType = .type2DMultisample; msaa.pixelFormat = .bgra8Unorm
            msaa.width = width; msaa.height = height; msaa.sampleCount = sampleCount
            msaa.storageMode = .private; msaa.usage = .renderTarget
            guard let texture = device.makeTexture(descriptor: msaa) else { throw DocumentError.graphics }
            color.texture = texture; color.resolveTexture = output; color.storeAction = .multisampleResolve
        } else { color.texture = output; color.storeAction = .store }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw DocumentError.graphics }
        do {
            try encodeScene(encoder: encoder, document: document, viewport: viewport,
                            viewSize: Point(x: Double(width), y: Double(height)),
                            active: active, preview: preview, guides: guides)
        } catch { encoder.endEncoding(); throw error }
        encoder.endEncoding()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { command in
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
                        size: Point, canvas: Point, color: SIMD4<Float>, encoder: MTLRenderCommandEncoder) throws {
        // Layout is four aligned float4s in both Swift and Metal (64 bytes).
        var uniforms: [SIMD4<Float>] = [
            SIMD4(Float(transform.a), Float(transform.b), Float(transform.c), Float(transform.d)),
            SIMD4(Float(transform.tx), Float(transform.ty), Float(size.x), Float(size.y)),
            SIMD4(Float(canvas.x), Float(canvas.y), 0, 0), color
        ]
        if matrixCache[symmetry] == nil {
            matrixCache[symmetry] = symmetry.matrices.flatMap { m in
                [SIMD4(Float(m.a), Float(m.b), Float(m.c), Float(m.d)), SIMD4(Float(m.tx), Float(m.ty), 0, 0)]
            }
        }
        let matrices = matrixCache[symmetry]!
        uniforms.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
        matrices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 2) }
        for chunk in chunks {
            encoder.setVertexBuffer(chunk.buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: chunk.count,
                                   instanceCount: symmetry.repetitions)
        }
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms { float4 matrix; float4 offsetSize; float4 canvas; float4 color; };
    struct Output { float4 position [[position]]; float2 canvas; float2 limit; float4 color; };
    vertex Output inkVertex(uint v [[vertex_id]], uint instance [[instance_id]],
                           const device float2 *vertices [[buffer(0)]],
                           constant Uniforms &u [[buffer(1)]], constant float4 *symmetry [[buffer(2)]]) {
        float4 m = symmetry[instance * 2];
        float2 p = vertices[v];
        p = float2(m.x*p.x + m.z*p.y, m.y*p.x + m.w*p.y) + symmetry[instance*2+1].xy;
        float4 t = u.matrix;
        float2 screen = float2(t.x*p.x + t.z*p.y, t.y*p.x + t.w*p.y) + u.offsetSize.xy;
        Output out;
        out.position = float4(screen.x/u.offsetSize.z*2-1, 1-screen.y/u.offsetSize.w*2, 0, 1);
        out.canvas = p; out.limit = u.canvas.xy; out.color = u.color;
        return out;
    }
    fragment float4 inkFragment(Output in [[stage_in]]) {
        if (any(in.canvas < float2(0)) || any(in.canvas > in.limit)) discard_fragment();
        return in.color;
    }
    """
}
