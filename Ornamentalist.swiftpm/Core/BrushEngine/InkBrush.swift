import Foundation

struct InkBrush: Codable, Equatable, Sendable {
    var width = 5.0
    var pressureEnabled = false
    var stabilization = 0.25
    var stabilizationEnabled = true
    var geometryVersion = 2
    var preset = BrushPreset.fineliner
    var opacity = 1.0
    var normalizedOpacity = false
    var spacing = 0.2
    var density = 0.5
    var adaptiveStabilization = false
    var pressureCurve = 0.5
    var minimumSize = 0.2
    var taperStart = 0.0
    var taperEnd = 0.0
    var tiltShading = 0.0
    var edgeSoftness: Double?
    var falloff = 0.0
    var effectiveSoftness: Double { edgeSoftness ?? preset.softness }
    var falloffLength: Double { falloff > 0 ? width * 2 / (falloff * falloff) : .infinity }
    func falloffOpacity(distance: Double) -> Double {
        guard falloff > 0 else { return 1 }
        let t = max(0, min(1, distance / falloffLength))
        return 1 - t * t * (3 - 2 * t)
    }
    var usesStamps: Bool { preset != .fineliner && preset != .brushPen }
    var isValid: Bool {
        [pressureCurve, minimumSize, taperStart, taperEnd, tiltShading, falloff, effectiveSoftness].allSatisfy { $0.isFinite } &&
        (0...1).contains(falloff) && (0...1).contains(effectiveSoftness) &&
        (0.2...3).contains(pressureCurve) && (0...1).contains(minimumSize) &&
        (0...2).contains(taperStart) && (0...2).contains(taperEnd) && (0...1).contains(tiltShading) &&
        width.isFinite && (0.5...160).contains(width) && stabilization.isFinite &&
        (0...1).contains(stabilization) && (1...2).contains(geometryVersion) &&
        opacity.isFinite && (0...1).contains(opacity) &&
        spacing.isFinite && (0.06...4).contains(spacing) && density.isFinite && (0.05...1).contains(density)
    }
    func radius(pressure: Double) -> Double {
        guard pressureEnabled else { return width * 0.5 }
        return width * (minimumSize + (1 - minimumSize) * pow(max(0, min(1, pressure)), pressureCurve)) * 0.5
    }
    /// Soft dabs overlap several times per brush diameter. Normalize their
    /// accumulation so small opacity changes do not immediately saturate a pass.
    var dabOpacity: Double {
        guard normalizedOpacity, usesStamps, preset.softness > 0, opacity > 0, opacity < 1 else { return opacity }
        return 1 - pow(1 - opacity, min(1, spacing / 0.7))
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
        stabilizationEnabled = try c.decodeIfPresent(Bool.self, forKey: .stabilizationEnabled) ?? true
        geometryVersion = try c.decodeIfPresent(Int.self, forKey: .geometryVersion) ?? 1
        preset = try c.decodeIfPresent(BrushPreset.self, forKey: .preset) ?? .fineliner
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        normalizedOpacity = try c.decodeIfPresent(Bool.self, forKey: .normalizedOpacity) ?? false
        spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? 0.2
        density = try c.decodeIfPresent(Double.self, forKey: .density) ?? 0.5
        adaptiveStabilization = try c.decodeIfPresent(Bool.self, forKey: .adaptiveStabilization) ?? false
        pressureCurve = try c.decodeIfPresent(Double.self, forKey: .pressureCurve) ?? 0.5
        minimumSize = try c.decodeIfPresent(Double.self, forKey: .minimumSize) ?? 0.2
        taperStart = try c.decodeIfPresent(Double.self, forKey: .taperStart) ?? 0
        taperEnd = try c.decodeIfPresent(Double.self, forKey: .taperEnd) ?? 0
        tiltShading = try c.decodeIfPresent(Double.self, forKey: .tiltShading) ?? 0
        edgeSoftness = try c.decodeIfPresent(Double.self, forKey: .edgeSoftness)
        falloff = try c.decodeIfPresent(Double.self, forKey: .falloff) ?? 0
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
        b.adaptiveStabilization = true
        if self == .brushPen { b.minimumSize = 0.03; b.taperStart = 0.6; b.taperEnd = 0.8 }
        if b.usesStamps { b.tiltShading = 0.7 }
        if softness > 0 { b.normalizedOpacity = true }
        return b
    }
}
