import SwiftUI
import Darwin

enum StudioStyle {
    static let copperFill = Color(red: 0.65, green: 0.36, blue: 0.23)
    static let copper = Color(uiColor: UIColor { @Sendable traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.88, green: 0.65, blue: 0.49, alpha: 1)
            : UIColor(red: 0.65, green: 0.36, blue: 0.23, alpha: 1)
    })
    static let workspace = Color(red: 0.13, green: 0.14, blue: 0.16)
    static let paper = Color(red: 0.97, green: 0.95, blue: 0.91)
}

/// A vector ornament, used as a brand mark rather than a drawing thumbnail.
struct StudioOrnament: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.44
        var path = Path()
        for petal in 0..<12 {
            let angle: Double = Double(petal) * Double.pi / 6
            func point(_ r: CGFloat, _ offset: Double) -> CGPoint {
                let theta: Double = angle + offset
                return CGPoint(x: center.x + CGFloat(Darwin.cos(theta)) * r,
                               y: center.y + CGFloat(Darwin.sin(theta)) * r)
            }
            path.move(to: center)
            path.addCurve(to: point(radius, 0),
                          control1: point(radius * 0.55, -0.65),
                          control2: point(radius * 0.9, -0.3))
            path.addCurve(to: center,
                          control1: point(radius * 0.9, 0.3),
                          control2: point(radius * 0.55, 0.65))
        }
        path.addEllipse(in: CGRect(x: center.x - radius * 0.2, y: center.y - radius * 0.2,
                                   width: radius * 0.4, height: radius * 0.4))
        return path
    }
}

struct StudioPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct StudioIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 18, weight: .medium))
            .frame(width: 44, height: 44).contentShape(Rectangle())
    }
}

@MainActor
struct StudioBrandLogo: View {
    private static let image: UIImage? = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "Ornamentalist-logo", withExtension: "jpg") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }()
    var body: some View {
        Group {
            if let image = Self.image { Image(uiImage: image).resizable().scaledToFit() }
            else { Text("Ornamentalist").font(.title2) }
        }.accessibilityLabel("Ornamentalist logo")
    }
}

// Draw the layers glyph directly; it must not disappear when a system-symbol
// variant is unavailable in the installed iPad editor/runtime.
struct StudioLayersIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2).stroke(lineWidth: 1.8)
                .frame(width: 18, height: 18).offset(x: -3, y: 3)
            RoundedRectangle(cornerRadius: 2).fill(.background)
                .frame(width: 18, height: 18).offset(x: 3, y: -3)
            RoundedRectangle(cornerRadius: 2).stroke(lineWidth: 1.8)
                .frame(width: 18, height: 18).offset(x: 3, y: -3)
        }.frame(width: 44, height: 44).contentShape(Rectangle())
    }
}

extension View {
    func studioSurface() -> some View {
        self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    }
}
