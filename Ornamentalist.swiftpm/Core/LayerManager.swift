import Foundation

struct DrawingLayer: Codable, Equatable, Identifiable, Sendable {
    // Stable migration ID also preserves existing source/test stroke initializers.
    static let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var id = UUID()
    var name = "Layer 1"
    var isVisible = true
    var isLocked = false
    var opacity = 1.0
}

extension DrawingLayer {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isVisible = try c.decode(Bool.self, forKey: .isVisible)
        isLocked = try c.decode(Bool.self, forKey: .isLocked)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
    }
}

enum LayerManager {
    static let maximumLayers = 32

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
