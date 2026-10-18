import SwiftUI
import Darwin

enum StudioPanel: String, Identifiable {
    case brush = "Brushes", symmetry = "Symmetry", layers = "Layers", canvas = "Canvas", colors = "Colors"
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
        VStack(spacing: 0) {
            HStack {
                Text(panel.rawValue).font(.system(.title2, design: .serif))
                Spacer()
                Button { dismiss() } label: { StudioIcon(symbol: "xmark") }
                    .accessibilityLabel("Close settings").accessibilityIdentifier("closePanel")
            }.padding(.horizontal, 24).padding(.top, 12)
            ScrollView {
                if let document = model.document {
                    VStack(alignment: .leading, spacing: 24) {
                        switch panel {
                        case .brush:
                            if model.tool == .eraser { StudioEraserView(model: model) }
                            else { StudioBrushesView(model: model, brush: document.brush) }
                        case .symmetry: symmetry(document)
                        case .canvas: canvas
                        case .layers: StudioLayersView(model: model)
                        case .colors: StudioColorsView(model: model)
                        }
                    }.padding(24)
                }
            }
        }
        .frame(idealWidth: 360, idealHeight: panel == .symmetry ? 560 : panel == .layers ? 520 : panel == .canvas ? 460 : 620)
        .presentationCompactAdaptation(.popover)
        .disabled(model.isDrawing || !model.canEdit)
    }

    private func symmetry(_ document: DrawingDocument) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ZStack {
                Circle().stroke(.secondary.opacity(0.15), lineWidth: 1)
                SymmetryPreview(count: document.symmetry.guideRayCount)
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
                        .accessibilityAddTraits(document.symmetry.repetitions == count ? .isSelected : [])
                }
            }
            Stepper(value: Binding(get: { document.symmetry.repetitions }, set: { model.setRepetitions($0) }), in: 1...64) {
                Text("\(document.symmetry.repetitions) sectors").monospacedDigit()
            }.font(.subheadline)
                .accessibilityLabel("Radial copies")
                .accessibilityValue("\(document.symmetry.repetitions)")
                .accessibilityIdentifier("symmetryCopies")
            Toggle("Mirror", isOn: Binding(get: { document.symmetry.mirror }, set: { model.setMirror($0) }))
                .font(.subheadline).accessibilityIdentifier("mirrorToggle")
            Text(document.symmetry.mirror ? "\(document.symmetry.instanceCount) copies · Reflected across the guides." : "Rotate each stroke around the center.")
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("mirrorSummary")
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
                Text("Two-finger tap: Undo. Three-finger tap: Redo.")
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
            Text("Ornamentalist 0.8.4").font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("appVersion")
        }
    }
}

private struct SymmetryPreview: Shape {
    let count: Int
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let radius = min(rect.width, rect.height) / 2
        for index in 0..<count {
            let angle: Double = Double(index) * 2 * Double.pi / Double(count)
            let dx: CGFloat = CGFloat(Darwin.cos(angle)) * radius
            let dy: CGFloat = CGFloat(Darwin.sin(angle)) * radius
            p.move(to: CGPoint(x: rect.midX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.midX + dx, y: rect.midY + dy))
        }
        return p
    }
}
