import Foundation

struct StrokeSample: Codable, Equatable, Sendable {
    var point: Point
    var pressure: Double
    var altitude: Double
    var azimuth: Double
    var time: Double
    var radiusScale = 1.0
    static func midpoint(_ a: StrokeSample, _ b: StrokeSample) -> StrokeSample {
        StrokeSample(point: (a.point + b.point) * 0.5,
                     pressure: (a.pressure + b.pressure) * 0.5,
                     altitude: (a.altitude + b.altitude) * 0.5,
                     azimuth: a.azimuth + atan2(sin(b.azimuth - a.azimuth), cos(b.azimuth - a.azimuth)) * 0.5,
                     time: (a.time + b.time) * 0.5, radiusScale: (a.radiusScale + b.radiusScale) * 0.5)
    }
    func radius(brush: InkBrush) -> Double { brush.radius(pressure: pressure) * radiusScale }
}

extension StrokeSample {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        point = try c.decode(Point.self, forKey: .point)
        pressure = try c.decode(Double.self, forKey: .pressure)
        altitude = try c.decode(Double.self, forKey: .altitude)
        azimuth = try c.decode(Double.self, forKey: .azimuth)
        time = try c.decode(Double.self, forKey: .time)
        radiusScale = try c.decodeIfPresent(Double.self, forKey: .radiusScale) ?? 1
    }
}

enum StrokeOperation: String, Codable, Sendable { case ink, erase }
enum StudioTool: String, Sendable { case brush, eraser, eyedropper }

struct InkStroke: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var brush = InkBrush()
    var symmetry = SymmetryConfiguration()
    var samples: [StrokeSample] = []
    var layerID = DrawingLayer.legacyID
    var color = InkColor.black
    var operation = StrokeOperation.ink
    var geometrySeed: UUID?
    var seedID: UUID { geometrySeed ?? id }
}

extension InkStroke {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        brush = try c.decode(InkBrush.self, forKey: .brush)
        symmetry = try c.decode(SymmetryConfiguration.self, forKey: .symmetry)
        samples = try c.decode([StrokeSample].self, forKey: .samples)
        layerID = try c.decodeIfPresent(UUID.self, forKey: .layerID) ?? DrawingLayer.legacyID
        color = try c.decodeIfPresent(InkColor.self, forKey: .color) ?? .black
        operation = try c.decodeIfPresent(StrokeOperation.self, forKey: .operation) ?? .ink
        geometrySeed = try c.decodeIfPresent(UUID.self, forKey: .geometrySeed)
    }
}

struct DrawingDocument: Codable, Identifiable, Equatable, Sendable {
    var version = 15
    var storageRevision = 0
    var id = UUID()
    var title = "Untitled Drawing"
    var modified = Date()
    var size = Point(x: 2048, y: 2048)
    var symmetry = SymmetryConfiguration()
    var brush = InkBrush()
    var color = InkColor.black
    var recentColors: [InkColor] = []
    var strokes: [InkStroke] = []
    // Bottom to top; stroke storage remains chronological for input/history.
    var layers = [DrawingLayer(id: DrawingLayer.legacyID)]
    var activeLayerID = DrawingLayer.legacyID
    var activeLayer: DrawingLayer? { layers.first { $0.id == activeLayerID } }
    var canDrawOnActiveLayer: Bool { activeLayer.map { $0.isVisible && !$0.isLocked } ?? false }
    var visibleStrokes: [InkStroke] {
        let grouped = Dictionary(grouping: strokes, by: \.layerID)
        return layers.filter(\.isVisible).flatMap { grouped[$0.id] ?? [] }
    }

    func validate() throws {
        guard (1...15).contains(version) else { throw DocumentError.unsupportedVersion }
        let layerIDs = Set(layers.map(\.id))
        guard (1...LayerManager.maximumLayers).contains(layers.count), layerIDs.count == layers.count,
              layerIDs.contains(activeLayerID), layers.allSatisfy({
                  !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 80 &&
                  $0.opacity.isFinite && (0...1).contains($0.opacity)
              }) else { throw DocumentError.invalidData }
        guard size.isFinite, size.x >= 64, size.y >= 64, size.x <= 8192, size.y <= 8192,
              title.count <= 200, strokes.count <= 20_000 else { throw DocumentError.invalidData }
        var rasters: [UUID: LayerRaster] = [:], rasterPixels = 0, rasterBytes = 0
        for raster in layers.compactMap(\.raster) {
            try raster.validate(canvas: size)
            guard version >= 8 || raster.placement == nil else { throw DocumentError.invalidData }
            if let existing = rasters[raster.id],
               existing.png != raster.png || existing.width != raster.width || existing.height != raster.height {
                throw DocumentError.invalidData
            }
            rasters[raster.id] = raster
            rasterPixels += raster.width * raster.height; rasterBytes += raster.png.count
            guard rasterPixels <= LayerRaster.documentPixels, rasterBytes <= LayerRaster.documentBytes else { throw DocumentError.memoryLimit }
        }
        func validSymmetry(_ s: SymmetryConfiguration) -> Bool {
            (1...64).contains(s.repetitions) && s.center.isFinite &&
                (0...size.x).contains(s.center.x) && (0...size.y).contains(s.center.y)
        }
        func validBrush(_ b: InkBrush) -> Bool {
            b.isValid && (version >= 7 || b.usesStamps || b.opacity == 1)
        }
        guard storageRevision >= 0, validSymmetry(symmetry), validBrush(brush), color.isValid,
              recentColors.count <= 12, recentColors.allSatisfy(\.isValid) else {
            throw DocumentError.invalidData
        }
        var total = 0
        var ids = Set<UUID>()
        for stroke in strokes {
            total += stroke.samples.count
            guard total <= DrawingLimits.sampleCount else { throw DocumentError.sampleLimit }
            guard ids.insert(stroke.id).inserted, layerIDs.contains(stroke.layerID),
                  !stroke.samples.isEmpty, stroke.samples.count <= DrawingLimits.strokeSamples,
                  validBrush(stroke.brush), stroke.color.isValid,
                  validSymmetry(stroke.symmetry) else { throw DocumentError.invalidData }
            var lastTime = -Double.infinity
            for sample in stroke.samples {
                guard sample.point.isFinite, abs(sample.point.x) <= 100_000, abs(sample.point.y) <= 100_000,
                      sample.pressure.isFinite, (0...1).contains(sample.pressure),
                      sample.altitude.isFinite, sample.azimuth.isFinite,
                      sample.radiusScale.isFinite, (0...1).contains(sample.radiusScale),
                      sample.time.isFinite, sample.time >= lastTime else { throw DocumentError.invalidData }
                lastTime = sample.time
            }
            let cost = BrushGeometry.estimatedStorageCost(stroke)
            // Geometry is a reconstructible working set, not a document limit.
            guard cost <= DrawingLimits.strokeVertices else {
                throw DocumentError.geometryLimit
            }
        }
    }
}

extension DrawingDocument {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        storageRevision = try c.decodeIfPresent(Int.self, forKey: .storageRevision) ?? 0
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        modified = try c.decode(Date.self, forKey: .modified)
        size = try c.decode(Point.self, forKey: .size)
        symmetry = try c.decode(SymmetryConfiguration.self, forKey: .symmetry)
        brush = try c.decode(InkBrush.self, forKey: .brush)
        color = try c.decodeIfPresent(InkColor.self, forKey: .color) ?? .black
        recentColors = try c.decodeIfPresent([InkColor].self, forKey: .recentColors) ?? []
        strokes = try c.decode([InkStroke].self, forKey: .strokes)
        if version >= 3 {
            layers = try c.decode([DrawingLayer].self, forKey: .layers)
            activeLayerID = try c.decode(UUID.self, forKey: .activeLayerID)
        } else {
            // Old drawings have no layers or reflection; keep their original ink.
            layers = [DrawingLayer(id: DrawingLayer.legacyID)]
            activeLayerID = DrawingLayer.legacyID
        }
    }
}

enum DocumentError: LocalizedError {
    case unsupportedVersion, invalidData, oversized, noMetal, graphics, graphicsMemory, strokeLimit, sampleLimit, geometryLimit, memoryLimit, mergeSize
    var errorDescription: String? {
        switch self {
        case .mergeSize: return "Merging currently supports canvases up to 2048 × 2048 pixels with whole-pixel dimensions."
        case .unsupportedVersion: return "This drawing uses a document version this app cannot open."
        case .invalidData: return "The drawing contains invalid or unsupported data."
        case .oversized: return "This drawing exceeds the 128 MB file limit."
        case .noMetal: return "Metal is unavailable on this device."
        case .graphics: return "The drawing renderer or image export could not be created."
        case .graphicsMemory: return "The graphics device could not allocate a drawing buffer or texture. Your drawing has not reached the geometry limit. Save your work and reopen the drawing."
        case .strokeLimit: return "This stroke has reached its detail limit. Your confirmed ink is kept. Lift the Pencil and continue with a new stroke on this canvas."
        case .sampleLimit: return "This drawing has reached its input-point limit. Your confirmed ink is kept. Save your work."
        case .geometryLimit: return "This drawing has reached its geometry buffer budget. Your confirmed ink is kept. Save your work."
        case .memoryLimit: return "This drawing has reached its geometry or storage limit. Save your work before starting another canvas."
        }
    }
}
