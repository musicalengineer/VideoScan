import SwiftUI
import PhotosUI

/// Placeholder Family Tree tab.
///
/// This is intentionally demo-only for now: all people, links, edits, and
/// chosen photos live in memory and reset on app relaunch. It does not write
/// to the catalog, POI profiles, Apple Photos, or FamilySearch.
struct FamilyTreeDemoView: View {
    @State private var people = FamilyTreeDemoData.people
    @State private var selectedID: FamilyTreePerson.ID = FamilyTreeDemoData.rootID
    @State private var linkedPersonIDs: Set<FamilyTreePerson.ID> = [FamilyTreeDemoData.rootID]
    @State private var searchText = ""
    @State private var showOnlyArchivePeople = false
    @State private var zoom: Double = 0.88
    @State private var selectedPhotoItem: PhotosPickerItem?

    // Cross-tab navigation. Both tabs share state via @AppStorage so a
    // right-click in either place can drop the other a hint.
    @AppStorage("selectedTab") private var selectedTab: Int = 0
    @AppStorage("ftHighlightedPersonName") private var incomingHighlight: String = ""
    /// Hallie's "Open in Family Tree: the Breens" offer drops a surname here;
    /// it becomes the sidebar search text and is cleared once applied.
    @AppStorage("ftIncomingSearchText") private var incomingSearchText: String = ""

    private var selectedPerson: FamilyTreePerson {
        people.first(where: { $0.id == selectedID }) ?? people[0]
    }

    private var selectedPersonBinding: Binding<FamilyTreePerson> {
        Binding(
            get: { selectedPerson },
            set: { updated in
                guard let index = people.firstIndex(where: { $0.id == updated.id }) else { return }
                people[index] = updated
            }
        )
    }

    private var filteredPeople: [FamilyTreePerson] {
        people.filter { person in
            let matchesSearch = searchText.isEmpty
                || person.name.localizedCaseInsensitiveContains(searchText)
                || person.familySearchID.localizedCaseInsensitiveContains(searchText)
            let matchesArchive = !showOnlyArchivePeople || person.videoCount > 0
            return matchesSearch && matchesArchive
        }
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 310)

            treeCanvas
                .frame(minWidth: 620)

            inspector(person: selectedPersonBinding)
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
        }
        .background(Color(red: 0.06, green: 0.07, blue: 0.08))
        .preferredColorScheme(.dark)
        .onChange(of: selectedPhotoItem) { _, item in
            importApplePhoto(item)
        }
        .onAppear { handleIncomingHighlight() }
        .onChange(of: incomingHighlight) { _, _ in handleIncomingHighlight() }
        .onChange(of: incomingSearchText) { _, _ in handleIncomingHighlight() }
    }

    /// If the People tab (or Hallie) dropped a name into AppStorage, find the
    /// matching person on this tree, select them, and clear the hint so it
    /// doesn't fire again next time. A dropped surname becomes the sidebar
    /// search text instead.
    private func handleIncomingHighlight() {
        if !incomingSearchText.isEmpty {
            searchText = incomingSearchText.trimmingCharacters(in: .whitespaces)
            incomingSearchText = ""
        }
        guard !incomingHighlight.isEmpty else { return }
        let trimmed = incomingHighlight.trimmingCharacters(in: .whitespaces)
        if let match = people.first(where: {
            $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            selectedID = match.id
        }
        incomingHighlight = ""
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Family Tree", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            TextField("Search people or FamilySearch ID", text: $searchText)
                .textFieldStyle(.roundedBorder)

            Toggle("Only people found in archive", isOn: $showOnlyArchivePeople)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

            Divider()

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filteredPeople) { person in
                        Button {
                            selectedID = person.id
                        } label: {
                            FamilyTreeSidebarRow(
                                person: person,
                                isSelected: selectedID == person.id,
                                isLinked: linkedPersonIDs.contains(person.id)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                statRow("Archive people", "\(people.filter { $0.videoCount > 0 }.count)")
                statRow("Linked to FamilySearch", "\(linkedPersonIDs.count)")
                statRow("Demo matches", "\(FamilyTreeDemoData.matches.count)")
            }
            .font(.system(size: 12))
        }
        .padding(14)
        .background(Color(red: 0.09, green: 0.10, blue: 0.11))
    }

    private var treeCanvas: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Breen / Hudson media tree")
                    .font(.headline)
                Spacer()
                Button {
                    selectedID = FamilyTreeDemoData.rootID
                    zoom = 0.88
                } label: {
                    Label("Center", systemImage: "scope")
                }
                .buttonStyle(.bordered)
                Slider(value: $zoom, in: 0.72...1.08)
                    .frame(width: 130)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(red: 0.075, green: 0.08, blue: 0.09))

            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    ZStack {
                        treeLines
                        ForEach($people) { $person in
                            FamilyTreePersonCard(
                                person: $person,
                                isSelected: person.id == selectedID,
                                isLinked: linkedPersonIDs.contains(person.id),
                                onSelect: { selectedID = person.id },
                                onLink: { linkedPersonIDs.insert(person.id) },
                                onPickPhoto: { pickPhotoFile(for: person.id) },
                                onShowInPeople: { name in
                                    showInPeopleTab(named: name)
                                }
                            )
                            .position(person.position)
                        }
                    }
                    .frame(width: 1200, height: 920)
                    .scaleEffect(zoom, anchor: .center)
                    .frame(width: 1200 * zoom, height: 920 * zoom)
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

    private func inspector(person: Binding<FamilyTreePerson>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("VideoScan Person")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    editableField("Name", text: person.name)
                    editableField("Life dates", text: person.years)
                    editableField("FamilySearch ID", text: person.familySearchID)

                    HStack(spacing: 8) {
                        Button {
                            pickPhotoFile(for: person.wrappedValue.id)
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

                    HStack(spacing: 8) {
                        metricBadge("\(person.wrappedValue.videoCount)", "videos", "film")
                        metricBadge("\(person.wrappedValue.photoCount)", "photos", "photo")
                        metricBadge(person.wrappedValue.confidence, "ID", "person.crop.circle.badge.checkmark")
                    }

                    HStack {
                        Stepper("Videos: \(person.wrappedValue.videoCount)", value: person.videoCount, in: 0...999)
                        Stepper("Photos: \(person.wrappedValue.photoCount)", value: person.photoCount, in: 0...999)
                    }
                    .font(.system(size: 12))

                    editableField("Confidence", text: person.confidence)
                }
                .padding(14)
                .background(panelBackground)

                VStack(alignment: .leading, spacing: 10) {
                    Text("FamilySearch Lookup")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(FamilyTreeDemoData.matches(for: person.wrappedValue)) { match in
                        FamilySearchMatchCard(match: match) {
                            linkedPersonIDs.insert(person.wrappedValue.id)
                        }
                    }
                }
                .padding(14)
                .background(panelBackground)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Media Evidence")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    editableNote("Best face", text: person.bestFaceNote, icon: "face.smiling")
                    editableNote("Likely clips", text: person.clipNote, icon: "film.stack")
                    editableNote("Review state", text: person.reviewState, icon: "checklist.checked")
                }
                .padding(14)
                .background(panelBackground)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Demo Notes")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Names on the tree are editable in place. FamilySearch cards are mocked as read-only search results, with explicit linking controlled by the user.")
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

    private var treeLines: some View {
        Path { path in
            spouse(&path, CGPoint(x: 280, y: 100), CGPoint(x: 450, y: 100))
            spouse(&path, CGPoint(x: 760, y: 100), CGPoint(x: 930, y: 100))
            spouse(&path, CGPoint(x: 405, y: 335), CGPoint(x: 705, y: 335))
            spouse(&path, CGPoint(x: 560, y: 560), CGPoint(x: 760, y: 560))
            parentCouple(&path, CGPoint(x: 365, y: 195), CGPoint(x: 405, y: 240))
            parentCouple(&path, CGPoint(x: 845, y: 195), CGPoint(x: 705, y: 240))
            parentCouple(&path, CGPoint(x: 555, y: 430), CGPoint(x: 560, y: 465))
            childLine(&path, CGPoint(x: 660, y: 655), CGPoint(x: 660, y: 760))
        }
        .stroke(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }

    private func spouse(_ path: inout Path, _ left: CGPoint, _ right: CGPoint) {
        path.move(to: CGPoint(x: left.x + 76, y: left.y))
        path.addLine(to: CGPoint(x: right.x - 76, y: right.y))
    }

    private func parentCouple(_ path: inout Path, _ coupleCenter: CGPoint, _ childTop: CGPoint) {
        path.move(to: coupleCenter)
        path.addLine(to: CGPoint(x: coupleCenter.x, y: childTop.y - 30))
        path.addLine(to: CGPoint(x: childTop.x, y: childTop.y - 30))
        path.addLine(to: childTop)
    }

    private func childLine(_ path: inout Path, _ start: CGPoint, _ end: CGPoint) {
        let midY = (start.y + end.y) / 2
        path.move(to: start)
        path.addLine(to: CGPoint(x: start.x, y: midY))
        path.addLine(to: CGPoint(x: end.x, y: midY))
        path.addLine(to: end)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
        }
    }

    private func metricBadge(_ value: String, _ label: String, _ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(value)
                .fontWeight(.semibold)
            Text(label)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func editableField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func editableNote(_ title: String, text: Binding<String>, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.cyan)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                TextField(title, text: text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .lineLimit(2...4)
            }
            Spacer()
        }
    }

    private var panelBackground: some ShapeStyle {
        Color.white.opacity(0.065)
    }

    private func pickPhotoFile(for personID: FamilyTreePerson.ID) {
        selectedID = personID
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
        setPhoto(image, for: personID)
    }

    private func importApplePhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        let targetID = selectedID
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = NSImage(data: data) else {
                await MainActor.run { selectedPhotoItem = nil }
                return
            }
            await MainActor.run {
                setPhoto(image, for: targetID)
                selectedPhotoItem = nil
            }
        }
    }

    private func setPhoto(_ image: NSImage, for personID: FamilyTreePerson.ID) {
        guard let index = people.firstIndex(where: { $0.id == personID }) else { return }
        people[index].photo = image
    }

    /// Drop a hint to the People tab and switch over to it.
    private func showInPeopleTab(named name: String) {
        UserDefaults.standard.set(name, forKey: "peopleHighlightedPOIName")
        selectedTab = 0
    }
}

private struct FamilyTreePersonCard: View {
    @Binding var person: FamilyTreePerson
    let isSelected: Bool
    let isLinked: Bool
    let onSelect: () -> Void
    let onLink: () -> Void
    let onPickPhoto: () -> Void
    let onShowInPeople: (String) -> Void
    @State private var isEditingName = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // FamilySearch-style sex-stripe across the very top of the card.
            person.accent
                .frame(height: 4)

            VStack(spacing: 8) {
            HStack {
                Image(systemName: person.videoCount > 0 ? "film.circle.fill" : "circle")
                    .foregroundStyle(person.videoCount > 0 ? .cyan : .secondary)
                Spacer()
                Button(action: onLink) {
                    Image(systemName: isLinked ? "link.circle.fill" : "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(isLinked ? .green : .cyan)
            }

            ZStack {
                if let photo = person.photo {
                    Image(nsImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 58, height: 58)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(person.accent.opacity(0.22))
                        .frame(width: 58, height: 58)
                    Image(systemName: person.symbol)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(person.accent)
                }
            }
            .overlay(Circle().stroke(person.accent.opacity(0.7), lineWidth: 1.5))
            .contextMenu {
                Button("Pick Photo") {
                    onSelect()
                    onPickPhoto()
                }
            }

            if isEditingName {
                TextField("Name", text: $person.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .focused($nameFocused)
                    .onSubmit { isEditingName = false }
                    .onAppear { nameFocused = true }
            } else {
                Text(person.name)
                    .font(.system(size: 14, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }

            Text(person.years)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(person.familySearchID)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            if person.videoCount > 0 {
                Label("\(person.videoCount) clips", systemImage: "play.rectangle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.cyan.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            } // end inner VStack
            .padding(10)
        }
        .frame(width: 150, height: 194)
        .background(Color(red: 0.12, green: 0.13, blue: 0.145))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.cyan : person.accent.opacity(0.7), lineWidth: isSelected ? 2.5 : 1.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onTapGesture(count: 2) {
            onSelect()
            beginNameEdit()
        }
        .contextMenu {
            Button("Edit Name") {
                onSelect()
                beginNameEdit()
            }
            Button(isLinked ? "Linked to FamilySearch" : "Link Demo Match") {
                onLink()
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

    private func beginNameEdit() {
        isEditingName = true
        Task { @MainActor in
            nameFocused = true
        }
    }
}

private struct FamilyTreeSidebarRow: View {
    let person: FamilyTreePerson
    let isSelected: Bool
    let isLinked: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: person.symbol)
                .foregroundStyle(person.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .lineLimit(1)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    if person.videoCount > 0 {
                        Label("\(person.videoCount)", systemImage: "film")
                    }
                    if isLinked {
                        Label("linked", systemImage: "link")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(isSelected ? Color.cyan.opacity(0.14) : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct FamilySearchMatchCard: View {
    let match: FamilySearchMatch
    let onLink: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.name)
                        .font(.system(size: 14, weight: .semibold))
                    Text("\(match.years)  \(match.familySearchID)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(match.score)%")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(match.score > 88 ? .green : .yellow)
            }

            Text(match.reason)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Label("read-only", systemImage: "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Link") {
                    onLink()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct FamilyTreePerson: Identifiable {
    let id: UUID
    var name: String
    var years: String
    var familySearchID: String
    var videoCount: Int
    var photoCount: Int
    var confidence: String
    let symbol: String
    let accent: Color
    let position: CGPoint
    var photo: NSImage?
    var bestFaceNote: String
    var clipNote: String
    var reviewState: String
}

private struct FamilySearchMatch: Identifiable {
    let id = UUID()
    let name: String
    let years: String
    let familySearchID: String
    let score: Int
    let reason: String
}

private enum FamilyTreeDemoData {
    static let rootID = UUID(uuidString: "56C8C137-A07E-439B-9A98-A9909295D59B") ?? UUID()

    static let people: [FamilyTreePerson] = [
        person("A5D82A12-1D18-4081-8EEA-26E395E56A2F", "George Breen", "1898-1995", "G2S4-WS4", 0, 2, "review", "person.fill", .cyan, CGPoint(x: 280, y: 100), "No confirmed face yet", "No archive clips linked", "FamilySearch-only ancestor"),
        person("D7FB4F98-66B9-405B-AF9F-4F7A8875AA9E", "Muriel Lamb", "1902-1977", "LYRH-QND", 1, 3, "72%", "person.crop.circle.fill", .pink, CGPoint(x: 450, y: 100), "One black-and-white portrait candidate", "Appears in reel 03 intro", "Needs name confirmation"),
        person("2C1DF4F6-A1F3-42DD-A260-4BA09498B0D0", "David McGill Latta", "1902-1983", "LX9M-WJG", 0, 1, "review", "person.fill", .cyan, CGPoint(x: 760, y: 100), "No confirmed face yet", "No archive clips linked", "FamilySearch-only ancestor"),
        person("960D2FE6-4EE4-4EA6-A747-9EB13C9122E1", "Mary Catherine O'Connor", "1904-1985", "G89Q-34N", 0, 1, "review", "person.fill", .pink, CGPoint(x: 930, y: 100), "No confirmed face yet", "No archive clips linked", "FamilySearch-only ancestor"),
        person("7F28D58B-F8B7-4F55-B14D-76DA3F3B4AC2", "richard hardin breen", "1929-2008", "G2S4-JF4", 9, 18, "96%", "person.crop.circle.fill", .cyan, CGPoint(x: 405, y: 335), "Strong match across Dad_Reel_01 and Christmas_1988", "9 likely clips, 4 already confirmed", "Ready to link"),
        person("8D78A735-6A0C-4C06-B0C2-48F37251869E", "Eileen Latta", "1930-2023", "G2CR-R4H", 7, 14, "94%", "person.crop.circle.fill", .pink, CGPoint(x: 705, y: 335), "Strong match across reunion and kitchen scenes", "7 likely clips, 5 already confirmed", "Ready to link"),
        person(rootID.uuidString, "Richard Breen", "1959-Living", "G2CX-4XR", 14, 26, "99%", "person.crop.circle.fill", .cyan, CGPoint(x: 560, y: 560), "Primary subject from face library", "14 clips across 6 tapes", "Linked demo identity"),
        person("9358518A-9D4B-498E-8931-A5D8F09F7479", "Donna Hudson", "1959-Living", "G2CL-86B", 11, 22, "98%", "person.crop.circle.fill", .pink, CGPoint(x: 760, y: 560), "Primary subject from face library", "11 clips across family compilation", "Name editable for correction"),
        person("15C1B2D7-4FD7-4108-A2F9-00C904F47F34", "Next Generation", "Private", "local-only", 0, 0, "draft", "person.2.fill", .mint, CGPoint(x: 660, y: 820), "Placeholder child/sibling branch", "No clips linked yet", "Demo placeholder")
    ]

    static let matches: [FamilySearchMatch] = [
        FamilySearchMatch(name: "Richard Breen", years: "1959-Living", familySearchID: "G2CX-4XR", score: 96, reason: "Same full name, linked spouse Donna Hudson, parents Richard Hardie Breen and Eileen Latta."),
        FamilySearchMatch(name: "Richard H. Breen", years: "1958-Living", familySearchID: "K8N4-P2V", score: 71, reason: "Similar name and birth decade, but spouse and parents do not match the local tree."),
        FamilySearchMatch(name: "Donna Hudson", years: "1959-Living", familySearchID: "G2LC-6BF", score: 95, reason: "Same name, spouse match, and shared child relationship hints from the local VideoScan tree.")
    ]

    static func matches(for person: FamilyTreePerson) -> [FamilySearchMatch] {
        let direct = matches.filter { $0.name.localizedCaseInsensitiveContains(person.name) || person.name.localizedCaseInsensitiveContains($0.name) }
        if !direct.isEmpty { return direct }
        return [
            FamilySearchMatch(
                name: person.name,
                years: person.years,
                familySearchID: person.familySearchID,
                score: person.videoCount > 0 ? 88 : 76,
                reason: person.videoCount > 0
                    ? "Demo candidate generated from name, lifespan, and media-linked relatives."
                    : "Demo candidate from FamilySearch tree context. No local media evidence yet."
            )
        ]
    }

    private static func person(
        _ id: String,
        _ name: String,
        _ years: String,
        _ familySearchID: String,
        _ videoCount: Int,
        _ photoCount: Int,
        _ confidence: String,
        _ symbol: String,
        _ accent: Color,
        _ position: CGPoint,
        _ bestFaceNote: String,
        _ clipNote: String,
        _ reviewState: String
    ) -> FamilyTreePerson {
        FamilyTreePerson(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            years: years,
            familySearchID: familySearchID,
            videoCount: videoCount,
            photoCount: photoCount,
            confidence: confidence,
            symbol: symbol,
            accent: accent,
            position: position,
            photo: nil,
            bestFaceNote: bestFaceNote,
            clipNote: clipNote,
            reviewState: reviewState
        )
    }
}
