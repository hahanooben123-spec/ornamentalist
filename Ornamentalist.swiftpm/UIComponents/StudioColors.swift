import SwiftUI

extension InkColor {
    var swiftUIColor: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}

@MainActor
struct StudioColorsView: View {
    @ObservedObject var model: StudioModel
    @State private var hue = 0.0
    @State private var saturation = 0.0
    @State private var brightness = 0.0
    @State private var hex = ""
    @State private var invalidHex = false
    @State private var mode = "Disc"
    @FocusState private var hexFocused: Bool
    private let palette = ["#000000", "#FFFFFF", "#D64545", "#EA8A23", "#F0CA3C", "#4B9654",
                           "#279C9C", "#327DD1", "#5946B2", "#B04E98", "#966448", "#85939A"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Circle().fill((model.document?.color ?? .black).swiftUIColor)
                    .overlay(Circle().stroke(.secondary.opacity(0.3))).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Drawing color").font(.headline)
                    Text(model.document?.color.hex ?? "#000000").font(.caption.monospaced())
                        .accessibilityIdentifier("currentColorHex")
                }
                Spacer()
            }
            Picker("Color controls", selection: $mode) {
                Text("Disc").tag("Disc"); Text("Values").tag("Values")
            }.pickerStyle(.segmented).accessibilityIdentifier("colorMode")
            if mode == "Disc" {
                StudioColorWheel(hue: component(0), saturation: component(1), brightness: component(2)) { model.rememberColor() }
                    .frame(height: 260)
            }
            VStack(spacing: 12) {
                colorSlider("Hue", value: component(0), text: "\(Int(hue * 360))°")
                colorSlider("Saturation", value: component(1), text: "\(Int(saturation * 100))%")
                colorSlider("Brightness", value: component(2), text: "\(Int(brightness * 100))%")
            }
            HStack {
                TextField("#RRGGBB", text: $hex).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .font(.body.monospaced()).textFieldStyle(.roundedBorder).accessibilityIdentifier("colorHex")
                    .focused($hexFocused).submitLabel(.done).onSubmit(applyHex)
                Button("Apply", action: applyHex).frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("applyColorHex")
            }
            if invalidHex { Text("Use six hexadecimal digits, for example #327DD1.").font(.caption).foregroundStyle(.red) }
            Text("Studio palette").font(.subheadline.weight(.medium))
            swatches(palette.compactMap { InkColor(hex: $0) })
            if let recent = model.document?.recentColors, !recent.isEmpty {
                Text("Recent colors").font(.subheadline.weight(.medium)); swatches(recent)
            }
            Text("Color changes apply to your next stroke. Brush opacity and layer opacity are separate controls.")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { adopt(model.document?.color ?? .black) }
    }
    private func component(_ index: Int) -> Binding<Double> {
        Binding(get: { index == 0 ? hue : index == 1 ? saturation : brightness }, set: { value in
            if index == 0 { hue = value } else if index == 1 { saturation = value } else { brightness = value }
            let color = InkColor(hue: hue, saturation: saturation, brightness: brightness)
            hex = color.hex; invalidHex = false; model.setColor(color, remember: false)
        })
    }
    private func colorSlider(_ name: String, value: Binding<Double>, text: String) -> some View {
        VStack(spacing: 4) {
            HStack { Text(name); Spacer(); Text(text).monospacedDigit().foregroundStyle(.secondary) }.font(.caption)
            Slider(value: value, in: 0...1, onEditingChanged: { if !$0 { model.rememberColor() } })
                .accessibilityLabel(name)
        }
    }
    private func adopt(_ color: InkColor) {
        let values = color.hsb
        hue = values.hue; saturation = values.saturation; brightness = values.brightness
        hex = color.hex; invalidHex = false
    }
    private func applyHex() {
        guard let color = InkColor(hex: hex) else { invalidHex = true; return }
        adopt(color); model.setColor(color); hexFocused = false
    }
    private func swatches(_ colors: [InkColor]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                Button { adopt(color); model.setColor(color) } label: {
                    RoundedRectangle(cornerRadius: 9).fill(color.swiftUIColor)
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.secondary.opacity(0.3)))
                        .frame(minHeight: 44)
                }.accessibilityLabel(color.hex).accessibilityIdentifier("color-\(color.hex)")
            }
        }
    }
}
