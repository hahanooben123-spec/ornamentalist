import SwiftUI

enum StudioPanel: String, Identifiable {
    case brush = "Fineliner", symmetry = "Symmetry", canvas = "Canvas"
    var id: String { rawValue }
}

@MainActor
struct StudioPanelView: View {
    let panel: StudioPanel
    @ObservedObject var model: StudioModel
    @Binding var appearance: String
    let diagnostics: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text(panel.rawValue).font(.system(.title2, design: .serif))
                    Spacer()
                    Button { dismiss() } label: { StudioIcon(symbol: "xmark") }
                        .accessibilityLabel("Close settings").accessibilityIdentifier("closePanel")
                }
                if let document = model.document {
                    switch panel {
                    case .brush: brush(document)
                    case .symmetry: symmetry(document)
                    case .canvas: canvas
                    }
                }
            }.padding(24)
        }
        .frame(idealWidth: 360, idealHeight: panel == .canvas ? 460 : 440)
        .presentationCompactAdaptation(.popover)
        .disabled(model.isDrawing || !model.canEdit)
    }

    private func brush(_ document: DrawingDocument) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.white)
                BrushPreview().stroke(.black, style: StrokeStyle(lineWidth: min(18, document.brush.width), lineCap: .round))
                    .padding(.horizontal, 24).padding(.vertical, 20)
            }.frame(height: 68).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Line width")
                    Spacer()
                    Text("\(document.brush.width.formatted(.number.precision(.fractionLength(1)))) px")
                        .monospacedDigit().foregroundStyle(.secondary)
                }.font(.subheadline)
                Slider(value: Binding(get: { document.brush.width }, set: { model.setWidth($0) }), in: 0.5...40)
                    .accessibilityLabel("Line width")
                HStack(spacing: 8) {
                    ForEach([2.0, 5, 10, 20], id: \.self) { width in
                        Button { model.setWidth(width) } label: {
                            Text("\(Int(width))").font(.subheadline.monospacedDigit())
                                .frame(maxWidth: .infinity).frame(height: 44)
                                .background(document.brush.width == width ? StudioStyle.copper.opacity(0.16) : Color.secondary.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 12))
                        }.accessibilityLabel("Line width \(Int(width)) pixels")
                    }
                }
            }
            Toggle("Pressure sensitivity", isOn: Binding(get: { document.brush.pressureEnabled }, set: { model.setPressure($0) }))
                .font(.subheadline)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Steady line")
                    Spacer()
                    Text("\(Int(document.brush.stabilization * 100))%").monospacedDigit().foregroundStyle(.secondary)
                }.font(.subheadline)
                Slider(value: Binding(get: { document.brush.stabilization }, set: { model.setStabilization($0) }), in: 0...0.85)
                    .accessibilityLabel("Line stabilization")
                Text("Smooths small movements as you draw.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func symmetry(_ document: DrawingDocument) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ZStack {
                Circle().stroke(.secondary.opacity(0.15), lineWidth: 1)
                SymmetryPreview(count: document.symmetry.repetitions)
                    .stroke(StudioStyle.copper, lineWidth: 1)
            }.frame(height: 100).accessibilityHidden(true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach([1, 4, 6, 8, 12, 16, 24, 32], id: \.self) { count in
                    Button { model.setRepetitions(count) } label: {
                        Text(count == 1 ? "Off" : "×\(count)").font(.subheadline.monospacedDigit())
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .foregroundStyle(document.symmetry.repetitions == count ? Color.white : Color.primary)
                            .background(document.symmetry.repetitions == count ? StudioStyle.copperFill : Color.secondary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 12))
                    }.accessibilityLabel("Symmetry \(count)").accessibilityIdentifier("symmetry-\(count)")
                }
            }
            Stepper(value: Binding(get: { document.symmetry.repetitions }, set: { model.setRepetitions($0) }), in: 1...64) {
                Text("\(document.symmetry.repetitions) copies").monospacedDigit()
            }.font(.subheadline)
            Toggle("Show guides", isOn: $model.guides).font(.subheadline)
            Text("Changes apply to your next stroke. Existing lines keep their symmetry.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var canvas: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Pencil draws. Two fingers move.", systemImage: "hand.draw")
                    .font(.subheadline.weight(.medium))
                Text("Pinch to zoom, twist to rotate, and drag with two fingers to pan.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { model.resetViewToken = UUID(); dismiss() } label: {
                Label("Fit drawing to screen", systemImage: "arrow.up.left.and.arrow.down.right")
                    .frame(minHeight: 44)
            }.accessibilityIdentifier("fitCanvas")
            Divider()
            Toggle("Draw with finger", isOn: $model.fingerDrawing).font(.subheadline)
            VStack(alignment: .leading, spacing: 10) {
                Text("Studio appearance").font(.subheadline)
                Picker("Studio appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }.pickerStyle(.segmented)
            }
            Button("Drawing performance", systemImage: "speedometer", action: diagnostics)
                .font(.subheadline).frame(minHeight: 44)
        }
    }
}

private struct BrushPreview: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.midY),
                   control1: CGPoint(x: rect.width * 0.35, y: rect.minY - 18),
                   control2: CGPoint(x: rect.width * 0.65, y: rect.maxY + 18))
        return p
    }
}

private struct SymmetryPreview: Shape {
    let count: Int
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let radius = min(rect.width, rect.height) / 2
        for index in 0..<count {
            let angle = Double(index) * 2 * .pi / Double(count)
            p.move(to: CGPoint(x: rect.midX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.midX + cos(angle) * radius, y: rect.midY + sin(angle) * radius))
        }
        return p
    }
}
