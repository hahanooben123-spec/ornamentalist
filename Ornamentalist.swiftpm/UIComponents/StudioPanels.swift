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
    @State private var showingAbout = false

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
        .sheet(isPresented: $showingAbout) { StudioAboutView() }
        .disabled(model.isDrawing || !model.canEdit)
    }

    private func symmetry(_ document: DrawingDocument) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Pattern", selection: Binding(get: { document.symmetry.tileCount }, set: { model.setTileCount($0) })) {
                Text("Radial").tag(0); Text("Tiles 2×2").tag(2); Text("Tiles 4×4").tag(4)
            }.pickerStyle(.segmented)
            if document.symmetry.tileCount > 0 {
                Text("Draw in any cell; strokes repeat across the grid. Use a new drawing for a seamless pattern. Export a tile from the export menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ZStack {
                Circle().stroke(.secondary.opacity(0.15), lineWidth: 1)
                SymmetryPreview(count: document.symmetry.guideRayCount)
                    .stroke(StudioStyle.copper, lineWidth: 1)
            }.frame(height: 100).accessibilityHidden(true).opacity(document.symmetry.tileCount > 0 ? 0.2 : 1)
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
            .disabled(document.symmetry.tileCount > 0)
            Stepper(value: Binding(get: { document.symmetry.repetitions }, set: { model.setRepetitions($0) }), in: 1...64) {
                Text("\(document.symmetry.repetitions) sectors").monospacedDigit()
            }.font(.subheadline)
                .accessibilityLabel("Radial copies")
                .accessibilityValue("\(document.symmetry.repetitions)")
                .accessibilityIdentifier("symmetryCopies")
                .disabled(document.symmetry.tileCount > 0)
            Toggle("Mirror", isOn: Binding(get: { document.symmetry.mirror }, set: { model.setMirror($0) }))
                .font(.subheadline).accessibilityIdentifier("mirrorToggle")
                .disabled(document.symmetry.tileCount > 0)
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
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Hold for line or circle", isOn: $model.shapeCorrection).font(.subheadline)
                Text("Draw a line or circle, hold still for 0.6 seconds, then lift to correct it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Parallel copy · \(Int(model.parallelDistance)) px").font(.subheadline)
                Slider(value: $model.parallelDistance, in: -80...80, step: 1)
                    .accessibilityLabel("Parallel copy distance")
                Button("Copy last stroke in parallel", systemImage: "line.3.horizontal") { model.addParallelCopy() }
                    .disabled(!model.canDraw || model.document?.strokes.last(where: { $0.layerID == model.document?.activeLayerID && $0.operation == .ink }) == nil || abs(model.parallelDistance) < 1)
                Text("Copies the last ink stroke on the active layer. Negative distance changes sides. Undo removes the copy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Show Pencil cursor", isOn: Binding(get: { model.showBrushCursor }, set: { model.setShowBrushCursor($0) }))
                    .font(.subheadline).accessibilityIdentifier("showBrushCursor")
                Text("Show the brush-size circle while drawing, adjusting size, and during Pencil hover.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
            Button("About Ornamentalist", systemImage: "info.circle") { showingAbout = true }
                .font(.subheadline).frame(minHeight: 44).accessibilityIdentifier("canvasAbout")
            Text("Ornamentalist 0.11.2").font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("appVersion")
        }
    }
}

@MainActor
struct StudioAboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let version = info["CFBundleShortVersionString"] as? String else { return "Development build" }
        if let build = info["CFBundleVersion"] as? String { return "Version \(version) (\(build))" }
        return "Version \(version)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ornamentalist").font(.system(.title, design: .serif))
                        Text(version).font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("aboutVersion")
                        Text("Created by Christian Mortensen").font(.subheadline)
                    }.padding(.vertical, 12)
                }
                Section("Contact") {
                    Link(destination: URL(string: "mailto:Chrismortensen1997@outlook.dk")!) {
                        Label("Chrismortensen1997@outlook.dk", systemImage: "envelope")
                    }.accessibilityIdentifier("aboutContact")
                }
                Section("Privacy") {
                    Link(destination: URL(string: "https://hahanooben123-spec.github.io/ornamentalist-website/privacy.html")!) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }.accessibilityIdentifier("aboutPrivacy")
                    Text("Your drawings are stored on your device. Export important projects before deleting or reinstalling the app.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("closeAbout")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
