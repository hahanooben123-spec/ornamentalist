// Adapted from hendriku/ColorPicker (ColorPickerRing), commit
// fb251fa294637ee9ac5337bb678bf4b44f76abeb. Copyright (c) 2020 Hendrik Ulbrich.
// MIT License: see ThirdParty/ColorPickerRing-LICENSE.txt in the distribution.
// Adaptation: no DynamicColor dependency; explicit Double/CGFloat boundaries,
// HSB binding, ring hit testing and an independent saturation/value square.
import SwiftUI
import Darwin

struct StudioColorWheel: View {
    @Binding var hue: Double
    @Binding var saturation: Double
    @Binding var brightness: Double
    let commit: () -> Void
    private let thickness: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let radius = side / 2 - thickness / 2
            let offsetX = CGFloat(Darwin.cos(hue * 2 * Double.pi)) * radius
            let offsetY = CGFloat(Darwin.sin(hue * 2 * Double.pi)) * radius
            ZStack {
                Circle().strokeBorder(AngularGradient(gradient: Gradient(colors: (0...12).map {
                    Color(hue: Double($0) / 12, saturation: 1, brightness: 1)
                }), center: .center), lineWidth: thickness)
                    .contentShape(Circle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let dx = Double(value.location.x - side / 2), dy = Double(value.location.y - side / 2)
                        guard Darwin.hypot(dx, dy) >= Double(side / 2 - thickness - 12) else { return }
                        let angle = Darwin.atan2(dy, dx) / (2 * Double.pi)
                        hue = angle < 0 ? angle + 1 : angle
                    }.onEnded { _ in commit() })
                    .accessibilityLabel("Hue wheel").accessibilityValue("\(Int(hue * 360)) degrees")
                    .accessibilityAdjustableAction { direction in
                        hue = (hue + (direction == .increment ? 1.0 / 36 : -1.0 / 36) + 1).truncatingRemainder(dividingBy: 1)
                        commit()
                    }
                Circle().fill(Color(hue: hue, saturation: 1, brightness: 1))
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .shadow(radius: 2).frame(width: thickness, height: thickness)
                    .offset(x: offsetX, y: offsetY).allowsHitTesting(false).accessibilityHidden(true)
                saturationSquare(side: side * 0.53)
            }.frame(width: side, height: side)
        }.aspectRatio(1, contentMode: .fit)
    }
    private func saturationSquare(side: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(hue: hue, saturation: 1, brightness: 1))
            Rectangle().fill(LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing))
            Rectangle().fill(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
            Circle().stroke(.white, lineWidth: 2).shadow(color: .black, radius: 1)
                .frame(width: 14, height: 14)
                .offset(x: CGFloat(saturation) * side - 7, y: CGFloat(1 - brightness) * side - 7)
                .allowsHitTesting(false)
        }.frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                saturation = max(0, min(1, Double(value.location.x / side)))
                brightness = max(0, min(1, 1 - Double(value.location.y / side)))
            }.onEnded { _ in commit() })
            .accessibilityLabel("Saturation and brightness square")
    }
}
