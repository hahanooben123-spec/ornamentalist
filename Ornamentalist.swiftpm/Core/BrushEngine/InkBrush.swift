import Foundation

struct InkBrush: Codable, Equatable, Sendable {
    var width = 5.0
    var pressureEnabled = false
    var stabilization = 0.25
    var geometryVersion = 2
    var preset = BrushPreset.fineliner
    var opacity = 1.0
    var spacing = 0.2
    var density = 0.5
    var usesStamps: Bool { preset != .fineliner && preset != .brushPen }
    func radius(pressure: Double) -> Double {
        guard pressureEnabled else { return width * 0.5 }
        return width * (0.2 + 0.8 * sqrt(max(0, min(1, pressure)))) * 0.5
    }
    var diskSides: Int {
        guard geometryVersion >= 2 else { return 12 }
        // Sagitta <= 0.03 canvas units, capped to keep geometry bounded.
        let angle = acos(max(-1, min(1, 1 - 0.03 / max(0.25, width * 0.5))))
        return max(12, min(64, Int(ceil(.pi / angle))))
    }
}

extension InkBrush {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Double.self, forKey: .width)
        pressureEnabled = try c.decodeIfPresent(Bool.self, forKey: .pressureEnabled) ?? true
        stabilization = try c.decodeIfPresent(Double.self, forKey: .stabilization) ?? 0
        geometryVersion = try c.decodeIfPresent(Int.self, forKey: .geometryVersion) ?? 1
        preset = try c.decodeIfPresent(BrushPreset.self, forKey: .preset) ?? .fineliner
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? 0.2
        density = try c.decodeIfPresent(Double.self, forKey: .density) ?? 0.5
    }
}

enum BrushFamily: String, CaseIterable {
    case ink = "Ink", shading = "Shading", dots = "Dots", texture = "Texture"
}

enum BrushPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case fineliner, brushPen, roundMarker, flatMarker, softShader, airbrush
    case dots, fineDots, stippleLight, stippleDense, dotShader, graphite, charcoal, hatching
    var id: String { rawValue }
    var name: String {
        switch self {
        case .fineliner: return "Fineliner"
        case .brushPen: return "Brush pen"
        case .roundMarker: return "Round marker"
        case .flatMarker: return "Flat marker"
        case .softShader: return "Soft shader"
        case .airbrush: return "Airbrush"
        case .dots: return "Dots"
        case .fineDots: return "Fine dots"
        case .stippleLight: return "Light stipple"
        case .stippleDense: return "Dense stipple"
        case .dotShader: return "Dot shader"
        case .graphite: return "Graphite"
        case .charcoal: return "Charcoal"
        case .hatching: return "Hatching"
        }
    }
    var family: BrushFamily {
        switch self {
        case .fineliner, .brushPen, .roundMarker, .flatMarker: return .ink
        case .softShader, .airbrush: return .shading
        case .dots, .fineDots, .stippleLight, .stippleDense, .dotShader: return .dots
        case .graphite, .charcoal, .hatching: return .texture
        }
    }
    var scattered: Bool {
        [.stippleLight, .stippleDense, .dotShader, .graphite, .charcoal, .hatching].contains(self)
    }
    var softness: Double { self == .softShader || self == .airbrush ? 1 : 0 }
    var hint: String {
        switch self {
        case .dots, .fineDots: return "Separate dots along your stroke. Tap for a single dot."
        case .stippleLight, .stippleDense: return "Scattered dots. Layer strokes to build a darker shade."
        case .dotShader: return "A soft cloud of dots, denser toward the center."
        case .softShader, .airbrush: return "Soft edges. Build tone with overlapping passes."
        case .hatching: return "Small parallel marks for engraved shading."
        default: return "Changes apply to your next stroke. Existing marks keep their brush."
        }
    }
    func makeBrush() -> InkBrush {
        var b = InkBrush(); b.preset = self
        switch self {
        case .fineliner: break
        case .brushPen: b.width = 18; b.pressureEnabled = true
        case .roundMarker: b.width = 28; b.opacity = 0.18; b.spacing = 0.16
        case .flatMarker: b.width = 36; b.opacity = 0.24; b.spacing = 0.1
        case .softShader: b.width = 80; b.opacity = 0.12; b.spacing = 0.12
        case .airbrush: b.width = 120; b.opacity = 0.045; b.spacing = 0.1
        case .dots: b.width = 6; b.spacing = 2
        case .fineDots: b.width = 2; b.spacing = 3
        case .stippleLight: b.width = 36; b.spacing = 0.4; b.density = 0.25
        case .stippleDense: b.width = 48; b.spacing = 0.3; b.density = 0.85
        case .dotShader: b.width = 70; b.spacing = 0.3; b.density = 0.65
        case .graphite: b.width = 18; b.opacity = 0.3; b.spacing = 0.2; b.density = 0.75
        case .charcoal: b.width = 42; b.opacity = 0.2; b.spacing = 0.22; b.density = 0.65
        case .hatching: b.width = 36; b.opacity = 0.65; b.spacing = 0.65; b.density = 0.4
        }
        return b
    }
}
