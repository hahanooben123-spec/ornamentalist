import Foundation

struct StrokeSample: Codable, Equatable, Sendable {
    var point: Point
    var pressure: Double
    var altitude: Double
    var azimuth: Double
    var time: Double
    static func midpoint(_ a: StrokeSample, _ b: StrokeSample) -> StrokeSample {
        StrokeSample(point: (a.point + b.point) * 0.5,
                     pressure: (a.pressure + b.pressure) * 0.5,
                     altitude: (a.altitude + b.altitude) * 0.5,
                     azimuth: (a.azimuth + b.azimuth) * 0.5, time: (a.time + b.time) * 0.5)
    }
}

struct InkStroke: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var brush = InkBrush()
    var symmetry = SymmetryConfiguration()
    var samples: [StrokeSample] = []
}

struct DrawingDocument: Codable, Identifiable, Equatable, Sendable {
    var version = 2
    var storageRevision = 0
    var id = UUID()
    var title = "Untitled Drawing"
    var modified = Date()
    var size = Point(x: 2048, y: 2048)
    var symmetry = SymmetryConfiguration()
    var brush = InkBrush()
    var strokes: [InkStroke] = []

    func validate() throws {
        guard (1...2).contains(version) else { throw DocumentError.unsupportedVersion }
        guard size.isFinite, size.x >= 64, size.y >= 64, size.x <= 8192, size.y <= 8192,
              title.count <= 200, strokes.count <= 20_000 else { throw DocumentError.invalidData }
        func validSymmetry(_ s: SymmetryConfiguration) -> Bool {
            (1...64).contains(s.repetitions) && s.center.isFinite &&
                (0...size.x).contains(s.center.x) && (0...size.y).contains(s.center.y)
        }
        func validBrush(_ b: InkBrush) -> Bool {
            b.width.isFinite && (0.5...40).contains(b.width) && b.stabilization.isFinite &&
                (0...0.85).contains(b.stabilization) && (1...2).contains(b.geometryVersion)
        }
        guard storageRevision >= 0, validSymmetry(symmetry), validBrush(brush) else {
            throw DocumentError.invalidData
        }
        var total = 0, vertices = 0
        var ids = Set<UUID>()
        for stroke in strokes {
            total += stroke.samples.count
            guard ids.insert(stroke.id).inserted, total <= DrawingLimits.sampleCount,
                  !stroke.samples.isEmpty, stroke.samples.count <= DrawingLimits.strokeSamples,
                  validBrush(stroke.brush),
                  validSymmetry(stroke.symmetry) else { throw DocumentError.invalidData }
            var lastTime = -Double.infinity
            for sample in stroke.samples {
                guard sample.point.isFinite, abs(sample.point.x) <= 100_000, abs(sample.point.y) <= 100_000,
                      sample.pressure.isFinite, (0...1).contains(sample.pressure),
                      sample.altitude.isFinite, sample.azimuth.isFinite,
                      sample.time.isFinite, sample.time >= lastTime else { throw DocumentError.invalidData }
                lastTime = sample.time
            }
            let cost = StrokeGeometry.estimatedVertexCount(stroke)
            vertices += cost
            guard cost <= DrawingLimits.strokeVertices, vertices <= DrawingLimits.vertexCount else {
                throw DocumentError.memoryLimit
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
        strokes = try c.decode([InkStroke].self, forKey: .strokes)
    }
}

enum DocumentError: LocalizedError {
    case unsupportedVersion, invalidData, oversized, noMetal, graphics, memoryLimit
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "This drawing uses a document version this app cannot open."
        case .invalidData: return "The drawing contains invalid or unsupported data."
        case .oversized: return "This prototype supports drawing files up to 64 MB."
        case .noMetal: return "Metal is unavailable on this device."
        case .graphics: return "The drawing renderer or image export could not be created."
        case .memoryLimit: return "This drawing has reached the prototype's geometry limit. Save your work and start another canvas."
        }
    }
}
