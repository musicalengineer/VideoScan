import SwiftUI
import PhotosUI

/// Family Tree tab.
///
/// Driven by `FamilyTreeLiveModel`: when a GEDCOM exists under
/// App Support/VideoScan/family-tree/originals the canvas shows the real
/// graph (selected person centred, 3 generations up, 2 down). With no
/// .ged the original demo tree stays, behind a banner that says so.
///
/// Photos chosen here (NSOpenPanel / Apple Photos) are in-memory overrides
/// and reset on relaunch; the persistent source is the model's
/// `photoProvider` (codex's FamilyAssetStore, to be wired in later).
/// Nothing here writes to the catalog, POI profiles, Apple Photos, or
/// FamilySearch.
struct FamilyTreeDemoView: View {
    // `@StateObject` ≈ the view owns this object for its lifetime (created
    // once, survives re-renders) — unlike `@State` for plain values.
    @StateObject private var model: FamilyTreeLiveModel
    @State private var zoom: Double = 0.88
    @State private var selectedPhotoItem: PhotosPickerItem?

    // Cross-tab navigation. Both tabs share state via @AppStorage so a
    // right-click in either place can drop the other a hint.
    @AppStorage("selectedTab") private var selectedTab: Int = 0
    @AppStorage("ftHighlightedPersonName") private var incomingHighlight: String = ""
    /// Hallie's "Open in Family Tree: the Breens" offer drops a surname here;
    /// it becomes the sidebar search text and is cleared once applied.
    @AppStorage("ftIncomingSearchText") private var incomingSearchText: String = ""

    init(model: FamilyTreeLiveModel? = nil) {
        _model = StateObject(wrappedValue: model ?? FamilyTreeLiveModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            if case .loaded(live: false) = model.loadState {
                demoBanner
            }
            HSplitView {
                sidebar
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 310)

                treeCanvas
                    .frame(minWidth: 620)

                inspector
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
        }
        .background(Color(red: 0.06, green: 0.07, blue: 0.08))
        .preferredColorScheme(.dark)
        .onChange(of: selectedPhotoItem) { _, item in
            importApplePhoto(item)
        }
        .task {
            if model.loadState == .idle {
                await model.loadFromDisk()
            }
            handleIncomingHighlight()
        }
        .onChange(of: incomingHighlight) { _, _ in handleIncomingHighlight() }
        .onChange(of: incomingSearchText) { _, _ in handleIncomingHighlight() }
        .onChange(of: model.loadState) { _, _ in handleIncomingHighlight() }
    }

    /// If the People tab (or Hallie) dropped a name into AppStorage, find the
    /// matching person on this tree, select them, and clear the hint so it
    /// doesn't fire again next time. A dropped surname becomes the sidebar
    /// search text and selects the first person carrying it.
    private func handleIncomingHighlight() {
        // Wait for the graph: a hint that arrives before the load finishes
        // is picked up again by the loadState onChange.
        guard case .loaded = model.loadState else { return }
        if !incomingSearchText.isEmpty {
            let text = incomingSearchText.trimmingCharacters(in: .whitespaces)
            model.searchText = text
            model.focus(onName: text)
            incomingSearchText = ""
        }
        guard !incomingHighlight.isEmpty else { return }
        model.focus(onName: incomingHighlight)
        incomingHighlight = ""
    }

    // MARK: Banner

    private var demoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.yellow)
            Text("Demo tree — drop your GEDCOM file in Application Support/VideoScan/family-tree/originals")
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            Button("Reveal folder") {
                model.revealOriginalsFolder()
            }
            .controlSize(.small)
            Button {
                Task { await model.loadFromDisk() }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.10))
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Family Tree", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            TextField("Search name, surname, or GEDCOM ID", text: $model.searchText)
                .textFieldStyle(.roundedBorder)

            Divider()

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.filteredPeople) { person in
                        Button {
                            model.select(person.id)
                        } label: {
                            FamilyTreeSidebarRow(
                                person: person,
                                isSelected: model.selectedID == person.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                statRow("People", "\(model.peopleCount)")
                statRow("Showing", "\(model.filteredPeople.count)")
                statRow("Source", model.isLive ? "GEDCOM" : "Demo")
            }
            .font(.system(size: 12))
        }
        .padding(14)
        .background(Color(red: 0.09, green: 0.10, blue: 0.11))
    }

    // MARK: Canvas

    private var canvasTitle: String {
        if model.isLive {
            if let name = model.selectedPerson?.name {
                return "\(name) — 3 generations up, 2 down"
            }
            return "Family tree"
        }
        return "Breen / Hudson media tree (demo)"
    }

    private var treeCanvas: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(canvasTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button {
                    if !model.isLive { model.select(FamilyTreeDemoData.rootID) }
                    zoom = 0.88
                } label: {
                    Label("Center", systemImage: "scope")
                }
                .buttonStyle(.bordered)
                Slider(value: $zoom, in: 0.5...1.08)
                    .frame(width: 130)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(red: 0.075, green: 0.08, blue: 0.09))

            GeometryReader { proxy in
                let size = model.scene.size == .zero
                    ? CGSize(width: 600, height: 400) : model.scene.size
                ScrollView([.horizontal, .vertical]) {
                    ZStack {
                        treeLines
                        ForEach(model.scene.cards) { card in
                            FamilyTreePersonCard(
                                card: card,
                                isSelected: card.person.id == model.selectedID,
                                onSelect: { model.select(card.person.id) },
                                onPickPhoto: { pickPhotoFile(for: card.person.id) },
                                onShowInPeople: { name in
                                    showInPeopleTab(named: name)
                                }
                            )
                            .position(card.position)
                        }
                        if model.scene.cards.isEmpty, case .loaded = model.loadState {
                            Text("Select a person in the sidebar")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(zoom, anchor: .center)
                    .frame(width: size.width * zoom, height: size.height * zoom)
                    .padding(40)
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                }
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.055, green: 0.065, blue: 0.075),
                            Color(red: 0.075, green: 0.08, blue: 0.095)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
    }

    private var treeLines: some View {
        Path { path in
            for edge in model.scene.edges {
                switch edge.kind {
                case .spouse:
                    path.move(to: edge.from)
                    path.addLine(to: edge.to)
                case .child:
                    elbow(&path, edge.from, edge.to)
                }
            }
        }
        .stroke(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }

    /// Down from the parent anchor, across, down to the child's top edge.
    private func elbow(_ path: inout Path, _ start: CGPoint, _ end: CGPoint) {
        let midY = (start.y + end.y) / 2
        path.move(to: start)
        path.addLine(to: CGPoint(x: start.x, y: midY))
        path.addLine(to: CGPoint(x: end.x, y: midY))
        path.addLine(to: end)
    }

    // MARK: Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let person = model.selectedPerson {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.isLive ? "GEDCOM Person" : "Demo Person")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        readOnlyField("Name", person.name)
                        readOnlyField("Life dates", person.years ?? "not recorded")
                        readOnlyField("Surname", person.surname ?? "not recorded")
                        readOnlyField(model.isLive ? "GEDCOM ID" : "Reference", person.reference)

                        HStack(spacing: 8) {
                            Button {
                                pickPhotoFile(for: person.id)
                            } label: {
                                Label("Pick Photo", systemImage: "photo")
                            }
                            .buttonStyle(.bordered)

                            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                Label("Apple Photos", systemImage: "photo.on.rectangle.angled")
                            }
                            .buttonStyle(.bordered)
                        }
                        .controlSize(.small)
                    }
                    .padding(14)
                    .background(panelBackground)

                    if !model.selectedRelatives.isEmpty {
                        relativesPanel(model.selectedRelatives)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("FamilySearch Lookup")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    FamilySearchMatchCard(match: .notConnected)
                }
                .padding(14)
                .background(panelBackground)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Notes")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(model.isLive
                         ? "Names and dates come straight from your GEDCOM file and are shown as recorded. Photos chosen here are kept for this session only."
                         : "This is a placeholder tree. Drop a .ged export into the family-tree/originals folder and reload to see your own family.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(panelBackground)
            }
            .padding(14)
        }
        .background(Color(red: 0.085, green: 0.09, blue: 0.10))
    }

    private func relativesPanel(_ relatives: FamilyTreeRelatives) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Relatives")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            relativeGroup("Parents", relatives.parents, icon: "arrow.up")
            relativeGroup("Spouses", relatives.spouses, icon: "heart")
            relativeGroup("Children", relatives.children, icon: "arrow.down")
            relativeGroup("Siblings", relatives.siblings, icon: "arrow.left.arrow.right")
        }
        .padding(14)
        .background(panelBackground)
    }

    @ViewBuilder
    private func relativeGroup(_ title: String, _ people: [FamilyTreePersonSummary],
                               icon: String) -> some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(people) { person in
                    Button {
                        model.select(person.id)
                    } label: {
                        HStack(spacing: 6) {
                            Text(person.name)
                                .font(.system(size: 12))
                            if let years = person.years {
                                Text(years)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Small pieces

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
        }
    }

    private func readOnlyField(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private var panelBackground: some ShapeStyle {
        Color.white.opacity(0.065)
    }

    // MARK: Photos

    private func pickPhotoFile(for personID: String) {
        model.select(personID)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose Photo"
        panel.message = "Choose a portrait or reference photo for this Family Tree person"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let image = NSImage(contentsOf: url) else { return }
        model.setPhotoOverride(image, for: personID)
    }

    private func importApplePhoto(_ item: PhotosPickerItem?) {
        guard let item, let targetID = model.selectedID else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = NSImage(data: data) else {
                await MainActor.run { selectedPhotoItem = nil }
                return
            }
            await MainActor.run {
                model.setPhotoOverride(image, for: targetID)
                selectedPhotoItem = nil
            }
        }
    }

    /// Drop a hint to the People tab and switch over to it.
    private func showInPeopleTab(named name: String) {
        UserDefaults.standard.set(name, forKey: "peopleHighlightedPOIName")
        selectedTab = 0
    }
}

// MARK: - Card

private extension FamilyTreeSex {
    var accent: Color {
        switch self {
        case .male: return .cyan
        case .female: return .pink
        case .unknown: return .mint
        }
    }
    var symbol: String {
        switch self {
        case .male, .female: return "person.fill"
        case .unknown: return "person.crop.circle.dashed"
        }
    }
}

private struct FamilyTreePersonCard: View {
    let card: FamilyTreeCard
    let isSelected: Bool
    let onSelect: () -> Void
    let onPickPhoto: () -> Void
    let onShowInPeople: (String) -> Void

    private var person: FamilyTreePersonSummary { card.person }
    private var accent: Color { person.sex.accent }

    var body: some View {
        VStack(spacing: 0) {
            // FamilySearch-style sex-stripe across the very top of the card.
            accent
                .frame(height: 4)

            VStack(spacing: 8) {
                HStack {
                    Text(person.sex.glyph)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                    Spacer()
                    if card.isRoot {
                        Image(systemName: "scope")
                            .foregroundStyle(.cyan)
                    }
                }

                ZStack {
                    if let photo = card.photo {
                        Image(nsImage: photo)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 58, height: 58)
                            .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(accent.opacity(0.22))
                            .frame(width: 58, height: 58)
                        Image(systemName: person.sex.symbol)
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(accent)
                    }
                }
                .overlay(Circle().stroke(accent.opacity(0.7), lineWidth: 1.5))
                .contextMenu {
                    Button("Pick Photo") {
                        onSelect()
                        onPickPhoto()
                    }
                }

                Text(person.name)
                    .font(.system(size: 14, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)

                Text(person.years ?? " ")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text(person.surname ?? person.reference)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(10)
        }
        .frame(width: 150, height: 194)
        .background(Color(red: 0.12, green: 0.13, blue: 0.145))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.cyan : accent.opacity(0.7), lineWidth: isSelected ? 2.5 : 1.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button("Center on \(person.name)") {
                onSelect()
            }
            Divider()
            Button("Pick Photo") {
                onSelect()
                onPickPhoto()
            }
            Divider()
            Button("Show \(person.name) in People tab") {
                onShowInPeople(person.name)
            }
        }
    }
}

private struct FamilyTreeSidebarRow: View {
    let person: FamilyTreePersonSummary
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: person.sex.symbol)
                .foregroundStyle(person.sex.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .lineLimit(1)
                    .font(.system(size: 13, weight: .medium))
                if let years = person.years {
                    Text(years)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(isSelected ? Color.cyan.opacity(0.14) : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - FamilySearch card (placeholder until the API is wired)

/// Kept as a component so a real lookup result can fill it later. Tonight
/// the only instance is `.notConnected` — no score, no invented reason.
struct FamilySearchMatch: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    /// nil until real matches exist; the card hides the badge when nil.
    let score: Int?

    static let notConnected = FamilySearchMatch(
        id: "not-connected",
        title: "Not connected to FamilySearch yet",
        detail: "Your GEDCOM file stays the source of truth. FamilySearch matching will appear here once it is wired up.",
        score: nil)
}

private struct FamilySearchMatchCard: View {
    let match: FamilySearchMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(match.title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if let score = match.score {
                    Text("\(score)%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(score > 88 ? .green : .yellow)
                }
            }

            Text(match.detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Label("read-only", systemImage: "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
