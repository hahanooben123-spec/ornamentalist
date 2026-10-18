import Foundation

/// Persist explicit sRGB components, never a platform/dynamic UI color.
struct InkColor: Codable, Equatable, Hashable, Sendable {
    var red = 0.0
    var green = 0.0
    var blue = 0.0
    static let black = InkColor()
    var isValid: Bool { [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
    init(red: Double = 0, green: Double = 0, blue: Double = 0) {
        self.red = red; self.green = green; self.blue = blue
    }
    init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard value.count == 6, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let n = UInt32(value, radix: 16) else { return nil }
        red = Double((n >> 16) & 255) / 255; green = Double((n >> 8) & 255) / 255; blue = Double(n & 255) / 255
    }
    init(hue: Double, saturation: Double, brightness: Double) {
        let h = (hue - floor(hue)) * 6, c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = brightness - c
        let rgb: (Double, Double, Double)
        switch Int(h) {
        case 0: rgb = (c, x, 0)
        case 1: rgb = (x, c, 0)
        case 2: rgb = (0, c, x)
        case 3: rgb = (0, x, c)
        case 4: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        red = rgb.0 + m; green = rgb.1 + m; blue = rgb.2 + m
    }
    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let high = max(red, green, blue), low = min(red, green, blue), delta = high - low
        var h = 0.0
        if delta > 0 {
            if high == red { h = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) }
            else if high == green { h = (blue - red) / delta + 2 }
            else { h = (red - green) / delta + 4 }
            h /= 6; if h < 0 { h += 1 }
        }
        return (h, high > 0 ? delta / high : 0, high)
    }
}
