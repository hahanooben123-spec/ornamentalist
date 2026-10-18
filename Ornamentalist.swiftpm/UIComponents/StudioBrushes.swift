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
            VStack(alignment: .leading, spacing: 8) {
                    valueLabel("Opacity", value: "\(Int((brush.opacity * 100).rounded()))%")
                    Slider(value: Binding(get: { brush.opacity }, set: { model.setOpacity($0) }), in: 0.01...1)
                        .accessibilityLabel("Brush opacity")
            }
            if brush.usesStamps {
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

/// Native sliders retain UIKit's tracking and adjustable accessibility behavior.
/// Rotating their own bounds avoids stealing canvas touches beside the rail.
@MainActor
private struct VerticalBrushSlider: UIViewRepresentable {
    @Binding var value: Double
    let label: String
    let identifier: String
    let editing: (Bool) -> Void

    func makeUIView(context: Context) -> VerticalSliderContainer {
        let view = VerticalSliderContainer()
        view.slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        view.slider.addTarget(context.coordinator, action: #selector(Coordinator.began), for: .touchDown)
        view.slider.addTarget(context.coordinator, action: #selector(Coordinator.ended), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return view
    }
    func updateUIView(_ view: VerticalSliderContainer, context: Context) {
        context.coordinator.parent = self
        if !view.slider.isTracking { view.slider.value = Float(value) }
        view.slider.accessibilityLabel = label
        view.slider.accessibilityIdentifier = identifier
        view.slider.isEnabled = context.environment.isEnabled
        view.slider.minimumTrackTintColor = UIColor(StudioStyle.copper)
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject {
        var parent: VerticalBrushSlider
        init(_ parent: VerticalBrushSlider) { self.parent = parent }
        @objc func changed(_ slider: UISlider) { parent.value = Double(slider.value) }
        @objc func began() { parent.editing(true) }
        @objc func ended() { parent.editing(false) }
    }
}

@MainActor
private final class VerticalSliderContainer: UIView {
    let slider = UISlider()
    override init(frame: CGRect) {
        super.init(frame: frame)
        slider.minimumValue = 0; slider.maximumValue = 1
        addSubview(slider)
    }
    required init?(coder: NSCoder) { fatalError("Create sliders programmatically") }
    override func layoutSubviews() {
        super.layoutSubviews()
        slider.transform = .identity
        slider.bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
        slider.center = CGPoint(x: bounds.midX, y: bounds.midY)
        slider.transform = CGAffineTransform(rotationAngle: -.pi / 2)
    }
}

@MainActor
struct StudioBrushRail: View {
    @ObservedObject var model: StudioModel
    let sliderHeight: CGFloat
    var body: some View {
        let brush = model.inputBrush
        VStack(spacing: 8) {
            Image(systemName: model.tool == .eraser ? "eraser" : "pencil.tip").font(.title3)
                .accessibilityHidden(true)
            Text("Size").font(.caption2)
            Text(brush.width.formatted(.number.precision(.fractionLength(1))))
                .font(.caption.monospacedDigit()).accessibilityIdentifier("railSizeValue")
            VerticalBrushSlider(value: Binding(get: { sqrt((brush.width - 0.5) / 159.5) },
                set: { model.setInputWidth(0.5 + $0 * $0 * 159.5) }), label: "Quick brush size", identifier: "railSize") {
                    model.brushPreviewRequested?($0)
                }.frame(width: 44, height: sliderHeight)
            Divider().padding(.vertical, 4)
            Text("Opacity").font(.caption2)
            Text("\(Int((brush.opacity * 100).rounded()))%")
                .font(.caption.monospacedDigit()).accessibilityIdentifier("railOpacityValue")
            VerticalBrushSlider(value: Binding(get: { (brush.opacity - 0.01) / 0.99 },
                set: { model.setInputOpacity(0.01 + $0 * 0.99) }), label: "Quick brush opacity", identifier: "railOpacity") { _ in }
                .frame(width: 44, height: sliderHeight)
        }
        .padding(.horizontal, 8).padding(.vertical, 14).frame(width: 68)
        .studioSurface()
        .disabled(model.isDrawing || !model.canEdit || model.tool == .eyedropper)
        .accessibilityElement(children: .contain).accessibilityIdentifier("brushRail")
        .onDisappear { model.brushPreviewRequested?(false) }
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
