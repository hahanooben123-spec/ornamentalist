import Foundation

struct DrawingLayer: Codable, Equatable, Identifiable, Sendable {
    // Stable migration ID also preserves existing source/test stroke initializers.
    static let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var id = UUID()
    var name = "Layer 1"
    var isVisible = true
    var isLocked = false
    var opacity = 1.0
    var raster: LayerRaster?
}

extension DrawingLayer {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isVisible = try c.decode(Bool.self, forKey: .isVisible)
        isLocked = try c.decode(Bool.self, forKey: .isLocked)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        raster = try c.decodeIfPresent(LayerRaster.self, forKey: .raster)
    }
}

enum LayerManager {
    static let maximumLayers = 32

    static func duplicate(_ id: UUID, in document: inout DrawingDocument) throws -> Bool {
        var candidate = document
        guard let i = candidate.layers.firstIndex(where: { $0.id == id }) else { return false }
        guard candidate.layers.count < maximumLayers else { throw DocumentError.memoryLimit }
        var copy = candidate.layers[i]; copy.id = UUID(); copy.isLocked = false
        let base = String(copy.name.prefix(65))
        var name = "\(base) copy", number = 2
        while candidate.layers.contains(where: { $0.name == name }) { name = "\(base) copy \(number)"; number += 1 }
        copy.name = name
        let strokes = candidate.strokes.filter { $0.layerID == id }.map { original -> InkStroke in
            var ink = original
            ink.geometrySeed = original.seedID; ink.id = UUID(); ink.layerID = copy.id
            return ink
        }
        candidate.layers.insert(copy, at: i + 1); candidate.strokes += strokes; candidate.activeLayerID = copy.id
        try candidate.validate()
        document = candidate
        return true
    }

    static func canMergeDown(_ id: UUID, in document: DrawingDocument) -> Bool {
        guard let i = document.layers.firstIndex(where: { $0.id == id }), i > 0 else { return false }
        let a = document.layers[i], b = document.layers[i - 1]
        return a.isVisible && b.isVisible && !a.isLocked && !b.isLocked
    }

    static func mergeDown(_ id: UUID, raster: LayerRaster, in document: inout DrawingDocument) throws -> Bool {
        var candidate = document
        guard canMergeDown(id, in: document), let i = candidate.layers.firstIndex(where: { $0.id == id }) else { return false }
        try raster.validate(canvas: candidate.size)
        let lower = candidate.layers[i - 1].id
        candidate.layers[i - 1].raster = raster; candidate.layers[i - 1].opacity = 1
        candidate.layers.remove(at: i)
        candidate.strokes.removeAll { $0.layerID == id || $0.layerID == lower }
        candidate.activeLayerID = lower
        try candidate.validate()
        document = candidate
        return true
    }

    static func add(in document: inout DrawingDocument) -> Bool {
        guard document.layers.count < maximumLayers else { return false }
        var number = document.layers.count + 1
        while document.layers.contains(where: { $0.name == "Layer \(number)" }) { number += 1 }
        let layer = DrawingLayer(name: "Layer \(number)")
        document.layers.append(layer)
        document.activeLayerID = layer.id
        return true
    }

    static func rename(_ id: UUID, name: String, in document: inout DrawingDocument) -> Bool {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty, let i = document.layers.firstIndex(where: { $0.id == id }),
              document.layers[i].name != name else { return false }
        document.layers[i].name = name
        return true
    }

    static func toggleVisibility(_ id: UUID, in document: inout DrawingDocument) -> Bool {
        guard let i = document.layers.firstIndex(where: { $0.id == id }) else { return false }
        document.layers[i].isVisible.toggle()
        return true
    }

    static func setOpacity(_ id: UUID, value: Double, in document: inout DrawingDocument) -> Bool {
        guard value.isFinite, let i = document.layers.firstIndex(where: { $0.id == id }) else { return false }
        let clamped = max(0, min(1, value))
        guard document.layers[i].opacity != clamped else { return false }
        document.layers[i].opacity = clamped
        return true
    }

    static func toggleLock(_ id: UUID, in document: inout DrawingDocument) -> Bool {
        guard let i = document.layers.firstIndex(where: { $0.id == id }) else { return false }
        document.layers[i].isLocked.toggle()
        return true
    }

    static func move(_ id: UUID, up: Bool, in document: inout DrawingDocument) -> Bool {
        guard let i = document.layers.firstIndex(where: { $0.id == id }) else { return false }
        let destination = i + (up ? 1 : -1)
        guard document.layers.indices.contains(destination) else { return false }
        document.layers.swapAt(i, destination)
        return true
    }

    /// Storage order is bottom to top; the panel displays the reverse.
    static func move(_ id: UUID, relativeTo target: UUID, above: Bool, in document: inout DrawingDocument) -> Bool {
        guard id != target, let source = document.layers.firstIndex(where: { $0.id == id }),
              document.layers.contains(where: { $0.id == target }) else { return false }
        let previous = document.layers.map(\.id)
        let layer = document.layers.remove(at: source)
        let destination = document.layers.firstIndex(where: { $0.id == target })!
        document.layers.insert(layer, at: destination + (above ? 1 : 0))
        return previous != document.layers.map(\.id)
    }

    static func delete(_ id: UUID, in document: inout DrawingDocument) -> Bool {
        guard document.layers.count > 1,
              let i = document.layers.firstIndex(where: { $0.id == id }) else { return false }
        document.layers.remove(at: i)
        document.strokes.removeAll { $0.layerID == id }
        if document.activeLayerID == id {
            document.activeLayerID = document.layers[min(i, document.layers.count - 1)].id
        }
        return true
    }
}
