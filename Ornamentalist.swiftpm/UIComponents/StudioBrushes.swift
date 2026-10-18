import SwiftUI
import Darwin

@MainActor
struct StudioBrushesView: View {
    @ObservedObject var model: StudioModel
    let brush: InkBrush
    @State private var family = BrushFamily.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(brush.preset.name).font(.headline).accessibilityIdentifier("selectedBrush")
                BrushSwatch(brush: brush, color: model.document?.color ?? .black).frame(height: 72)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
                Text(brush.preset.hint).font(.caption).foregroundStyle(.secondary)
            }
            Picker("Brush family", selection: $family) {
                ForEach(BrushFamily.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("brushFamily")
            VStack(spacing: 8) {
                ForEach(BrushPreset.allCases.filter { $0.family == family }) { preset in
                    Button { model.setBrush(preset) } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.name).font(.subheadline.weight(.medium))
                                Text(preset.family.rawValue).font(.caption2).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            BrushSwatch(brush: preset.makeBrush(), color: model.document?.color ?? .black).frame(width: 106, height: 38)
                                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                            Image(systemName: brush.preset == preset ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(brush.preset == preset ? StudioStyle.copper : Color.secondary)
                        }.padding(12).frame(minHeight: 60)
                            .background(brush.preset == preset ? StudioStyle.copper.opacity(0.12) : Color.secondary.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).accessibilityLabel(preset.name)
                        .accessibilityIdentifier("brush-\(preset.rawValue)")
                        .accessibilityAddTraits(brush.preset == preset ? .isSelected : [])
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                valueLabel("Size", value: "\(brush.width.formatted(.number.precision(.fractionLength(1)))) px")
                Slider(value: Binding(get: { brush.width }, set: { model.setWidth($0) }), in: 0.5...160)
                    .accessibilityLabel("Line width")
                HStack(spacing: 8) {
                    ForEach([2.0, 5, 20, 80], id: \.self) { width in
                        Button { model.setWidth(width) } label: {
                            Text("\(Int(width))").font(.subheadline.monospacedDigit())
                                .frame(maxWidth: .infinity).frame(height: 44)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }.accessibilityLabel("Line width \(Int(width)) pixels")
                    }
                }
            }
            if brush.usesStamps {
                VStack(alignment: .leading, spacing: 8) {
                    valueLabel("Opacity", value: "\(Int((brush.opacity * 100).rounded()))%")
                    Slider(value: Binding(get: { brush.opacity }, set: { model.setOpacity($0) }), in: 0.01...1)
                        .accessibilityLabel("Brush opacity")
                }
                VStack(alignment: .leading, spacing: 8) {
                    valueLabel("Spacing", value: "\(Int((brush.spacing * 100).rounded()))%")
                    Slider(value: Binding(get: { brush.spacing }, set: { model.setSpacing($0) }), in: 0.06...4)
                        .accessibilityLabel("Brush spacing")
                }
                if brush.preset.scattered {
                    VStack(alignment: .leading, spacing: 8) {
                        valueLabel("Density", value: "\(Int((brush.density * 100).rounded()))%")
                        Slider(value: Binding(get: { brush.density }, set: { model.setDensity($0) }), in: 0.05...1)
                            .accessibilityLabel("Brush density")
                    }
                }
            }
            Toggle("Pressure sensitivity", isOn: Binding(get: { brush.pressureEnabled }, set: { model.setPressure($0) }))
                .font(.subheadline)
            VStack(alignment: .leading, spacing: 8) {
                valueLabel("Steady line", value: "\(Int(brush.stabilization * 100))%")
                Slider(value: Binding(get: { brush.stabilization }, set: { model.setStabilization($0) }), in: 0...0.85)
                    .accessibilityLabel("Line stabilization")
            }
        }.onAppear { family = brush.preset.family }
    }
    private func valueLabel(_ name: String, value: String) -> some View {
        HStack {
            Text(name); Spacer(); Text(value).monospacedDigit().foregroundStyle(.secondary)
        }.font(.subheadline)
    }
}

/// A real stroke through the export painter; the swatch is not an icon or a
/// generic line. All presets use a fixed preview seed and document coordinates.
struct BrushSwatch: View {
    let brush: InkBrush
    var color = InkColor.black
    var body: some View {
        Canvas { context, size in
            var b = brush
            b.width = max(1, min(Double(size.height) * 0.6, brush.width * 0.45))
            var stroke = InkStroke(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                                   brush: b, symmetry: SymmetryConfiguration(repetitions: 1, center: .zero), color: color)
            stroke.samples = (0...48).map { i in
                let t = Double(i) / 48
                return StrokeSample(point: Point(x: 12 + (Double(size.width) - 24) * t,
                                                   y: Double(size.height) * (0.5 + Darwin.sin(t * 2 * Double.pi) * 0.13)),
                                    pressure: 0.25 + t * 0.75, altitude: 1, azimuth: 0, time: t)
            }
            context.withCGContext { PNGExporter.paint(stroke, in: $0) }
        }.accessibilityHidden(true)
    }
}
