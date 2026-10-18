import SwiftUI

@MainActor
struct StudioGallery: View {
    @ObservedObject var model: StudioModel
    let create: () -> Void
    let importProject: () -> Void
    let rename: (ProjectSummary) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    @State private var sortByName = false
    @State private var deleting: ProjectSummary?

    private var projects: [ProjectSummary] {
        let filtered = model.projects.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
        return filtered.sorted {
            sortByName ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.modified > $1.modified
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header(compact: geometry.size.width < 650)
                    if model.projects.isEmpty {
                        emptyStudio
                    } else {
                        collection
                    }
                    HStack(spacing: 7) {
                        Image(systemName: "internaldrive")
                        Text("Your drawings live on this iPad.")
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                .padding(geometry.size.width < 650 ? 24 : 48)
                .frame(maxWidth: 1400).frame(maxWidth: .infinity)
            }
            .background(colorScheme == .dark ? Color(uiColor: .systemBackground) : StudioStyle.paper)
        }
        .disabled(model.busy)
        .overlay { if model.busy { ProgressView().padding(24).studioSurface() } }
        .alert("Delete project?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete project", role: .destructive) {
                if let project = deleting { Task { await model.deleteProject(project.id) } }
                deleting = nil
            }
        } message: { Text("Delete \(deleting?.title ?? "this project") and its recovery copies from this iPad? This cannot be undone.") }
    }

    private func header(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(alignment: .center, spacing: 12) {
                StudioBrandLogo().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ornamentalist").font(.system(size: compact ? 28 : 34, weight: .regular, design: .serif))
                    Text("A LITTLE SYMMETRY. ENDLESS POSSIBILITY.")
                        .font(.system(size: 9, weight: .medium)).tracking(1.6).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !compact { importButton }
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your studio").font(.system(size: compact ? 34 : 46, weight: .regular, design: .serif))
                    Text(model.projects.isEmpty ? "Make space for a new idea." : "Pick up a thread. Create something new.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if !compact { newButton }
            }
            if compact { HStack { newButton; importButton } }
        }
    }

    private var newButton: some View {
        Button(action: create) {
            Label("New drawing", systemImage: "plus").font(.subheadline.weight(.semibold))
                .padding(.horizontal, 20).frame(minHeight: 48)
                .foregroundStyle(.white).background(StudioStyle.copperFill, in: Capsule())
        }.buttonStyle(StudioPressStyle()).accessibilityIdentifier("newDrawing")
    }

    private var importButton: some View {
        Button(action: importProject) {
            Label("Import", systemImage: "square.and.arrow.down").font(.subheadline.weight(.medium))
                .padding(.horizontal, 16).frame(minHeight: 48)
                .contentShape(Rectangle())
        }.buttonStyle(StudioPressStyle()).accessibilityLabel("Import project")
    }

    private var collection: some View {
        VStack(alignment: .leading, spacing: 22) {
            ViewThatFits(in: .horizontal) {
                HStack { search; Spacer(minLength: 20); sortMenu }
                VStack(alignment: .leading) { search; sortMenu }
            }
            if projects.isEmpty {
                ContentUnavailableView.search(text: query).frame(minHeight: 260)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 380), spacing: 24)],
                          alignment: .leading, spacing: 28) {
                    ForEach(projects) { project in projectCard(project) }
                }
            }
        }
    }

    private var search: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find a drawing", text: $query).accessibilityIdentifier("gallerySearch")
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14).frame(minHeight: 48).frame(maxWidth: 340)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort drawings", selection: $sortByName) {
                Text("Recent projects").tag(false)
                Text("Name").tag(true)
            }
        } label: {
            Label(sortByName ? "Name" : "Recent projects", systemImage: "arrow.up.arrow.down")
                .font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
        }.accessibilityLabel("Sort drawings")
    }

    private func projectCard(_ project: ProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { Task { await model.open(project.id) } } label: {
                ZStack {
                    Color.white
                    if let data = project.thumbnail, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit().padding(16)
                    } else {
                        Image(systemName: "pencil.tip.crop.circle").font(.system(size: 40, weight: .ultraLight))
                            .foregroundStyle(StudioStyle.copper.opacity(0.45))
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.black.opacity(0.05)))
                .shadow(color: .black.opacity(0.045), radius: 12, y: 5)
            }
            .buttonStyle(StudioPressStyle()).accessibilityLabel("Open \(project.title)")
            .accessibilityIdentifier("drawing-\(project.title)")
            .contextMenu {
                Button("Rename", systemImage: "pencil") { rename(project) }
                Button("Delete project", systemImage: "trash", role: .destructive) { deleting = project }
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.title).font(.system(.headline, design: .serif)).lineLimit(2)
                    Text(project.modified, format: .dateTime.month(.abbreviated).day())
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Menu {
                    Button("Rename", systemImage: "pencil") { rename(project) }
                    Button("Delete project", systemImage: "trash", role: .destructive) { deleting = project }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("Options for \(project.title)")
            }
        }
    }

    private var emptyStudio: some View {
        VStack(spacing: 24) {
            StudioBrandLogo().frame(width: 250, height: 250)
                .clipShape(RoundedRectangle(cornerRadius: 22)).accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("It starts with a single line.").font(.system(.title2, design: .serif))
                Text("Let symmetry take it from there.\nA quiet canvas, your Pencil, and room to explore.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            newButton
        }
        .frame(maxWidth: .infinity).padding(.vertical, 32)
    }
}

struct NewDrawingSheet: View {
    let create: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 26) {
                StudioOrnament().stroke(StudioStyle.copper, lineWidth: 1).frame(width: 100, height: 100)
                    .accessibilityHidden(true)
                Text("A fresh beginning").font(.system(.largeTitle, design: .serif))
                TextField("Untitled Drawing", text: $title).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("drawingName").submitLabel(.done).onSubmit(start)
                HStack {
                    Label("2048 × 2048 px", systemImage: "square")
                    Spacer()
                    Label("8-fold symmetry", systemImage: "circle.hexagongrid")
                }.font(.caption).foregroundStyle(.secondary)
                Button(action: start) {
                    Text("Create drawing").fontWeight(.semibold).frame(maxWidth: .infinity).frame(height: 52)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(StudioStyle.copperFill)
                .accessibilityIdentifier("createDrawing")
                Spacer(minLength: 0)
            }
            .padding(32)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.height(460)]).presentationDragIndicator(.visible)
    }
    private func start() {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        create(cleaned.isEmpty ? "Untitled Drawing" : String(cleaned.prefix(200)))
        dismiss()
    }
}
