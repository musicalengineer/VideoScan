import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Family Tree tab.
///
/// Driven by `FamilyTreeLiveModel`: when a GEDCOM exists in the authorized
/// 40_Family_Tree/GEDCOM directory the canvas shows the real graph (selected
/// person centred, 3 generations up, 2 down). With no
/// .ged the original demo tree stays, behind a banner that says so.
///
/// Photos chosen here (NSOpenPanel / Apple Photos / Adjust) are written as
/// THE choice for the person (`People/<FSID>/chosen-photo.json`, one photo
/// per person shared with the People tab — 2026-08-29) and shown at once
/// through a session override; `FamilyAssetPortrait` reads the store
/// through `PersonPhotoResolver` (choice › bridged profile cover › derived).
/// Nothing here writes to the catalog, POI profiles, Apple Photos, or
/// FamilySearch.
struct FamilyTreeDemoView: View {
    // `@StateObject` ≈ the view owns this object for its lifetime (created
    // once, survives re-renders) — unlike `@State` for plain values.
    @StateObject private var model: FamilyTreeLiveModel
    @EnvironmentObject private var catalogModel: VideoScanModel
    @Environment(\.openWindow) private var openWindow
    private let usesInjectedModel: Bool
    @State private var zoom: Double = FamilyTreeZoomMath.default
    /// Pinch bookkeeping: the zoom when the gesture began (the gesture
    /// reports a multiplier relative to its start, not a delta).
    @State private var zoomStart: Double?
    /// Canvas viewport, kept for "Fit" (⌥⌘0) — the fit scale is pure math
    /// on the scene size and this; no layout re-run.
    @State private var canvasViewport: CGSize = .zero
    /// The tree is the primary view (Rick 2026-08-29): the sidebar hides
    /// (⌥⌘S) so a long line fits; the choice is saved explicitly to
    /// `preferences`. `revealedForSearch` is the ⌘F peek while hidden —
    /// it lasts until the search field loses focus and is never saved.
    @State private var isSidebarVisible: Bool
    @State private var sidebarRevealedForSearch = false
    /// `@FocusState` ≈ a two-way flag for "does this control have keyboard
    /// focus"; setting it true moves the focus.
    @FocusState private var searchFocused: Bool
    private let preferences: UserDefaults
    /// Export line… state: photos on/off (view-local) and the last error.
    @State private var exportIncludesPhotos = true
    @State private var exportError: String?
    @State private var selectedPhotoItem: PhotosPickerItem?
    /// Apple Photos picker, presented from the card's context menu / the
    /// inspector's camera menu (2026-08-28: the photo buttons left the
    /// inspector so its width goes to genealogy). `.photosPicker(isPresented:)`
    /// is the programmatic form of the `PhotosPicker` button.
    @State private var showApplePhotosPicker = false
    /// The Get Family Tree coordinator is owned by the app-wide center, not
    /// this view, so closing the sheet no longer kills the file watcher
    /// (2026-08-25: a 2 h pull finished into a file nobody was watching).
    /// `@ObservedObject` ≈ observe-but-don't-own; the singleton owns itself.
    @ObservedObject private var pullCenter = FamilySearchPullCenter.shared
    /// People-tab identity banner + "Not right?" sheet (2026-08-29).
    @ObservedObject private var identityCenter = TreeIdentityCenter.shared
    @State private var identityPickTarget: TreeIdentityPickTarget?
    @State private var showPullSheet = false
    /// Archivist Notes draft + last save error (view-local, not persisted).
    @State private var draftNote = ""
    @State private var noteError: String?
    /// "Said as" editor: the name word being edited, its draft respelling,
    /// and the last save error (view-local).
    @State private var editingPronunciationWord: String?
    @State private var draftSaidAs = ""
    @State private var pronunciationError: String?
    /// Adjust Photo… sheet. `.sheet(item:)` shows it while this is non-nil
    /// (the item-binding form, per the chained-sheet note in memory).
    @State private var adjustSource: FamilyPhotoAdjustSource?
    @State private var adjustError: String?
    /// Research Person… (2026-08-29). `.sheet(item:)` shows the research
    /// pane while this is non-nil; a refusal (living person, demo tree)
    /// goes to the alert instead.
    @State private var researchTarget: ResearchTarget?
    @State private var researchRefusal: String?

    // Cross-tab navigation. Both tabs share state via @AppStorage so a
    // right-click in either place can drop the other a hint.
    @AppStorage("selectedTab") private var selectedTab: Int = 0
    @AppStorage("ftHighlightedPersonName") private var incomingHighlight: String = ""
    @AppStorage("ftHighlightedPersonID") private var incomingPersonID: String = ""
    /// Hallie's "Open in Family Tree: the Breens" offer drops a surname here;
    /// it becomes the sidebar search text and is cleared once applied.
    @AppStorage("ftIncomingSearchText") private var incomingSearchText: String = ""
    /// Hallie's "Get Family Tree…" chip: a fresh token per request so the
    /// same ask twice presents the sheet twice.
    @AppStorage("ftGetFamilyTreeRequest") private var getFamilyTreeRequest: String = ""

    init(model: FamilyTreeLiveModel? = nil, preferences: UserDefaults = .standard) {
        usesInjectedModel = model != nil
        _model = StateObject(wrappedValue: model ?? FamilyTreeLiveModel())
        self.preferences = preferences
        // `State(initialValue:)` ≈ member initializer for @State storage;
        // it is read once when the view is first created.
        _isSidebarVisible = State(initialValue: FamilyTreeSidebarPreference.load(from: preferences))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.needsRecompile.isEmpty {
                // codex #826: the demo tree is on screen only because the
                // loader refused to demote N pulls to one file — say that,
                // not "no GEDCOM found".
                EmptyView()
            } else if case .loaded(live: false) = model.loadState {
                demoBanner
            } else if model.loadState == .unavailable {
                unavailableBanner
            }
            if let phase = model.loadPhase, model.loadState == .loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(phase).font(.system(size: 12))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            if !model.needsRecompile.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    if ViewerModeCenter.shared.isViewer {
                        // Remote viewer (Phase 1): the tree is compiled on the
                        // master; this build cannot read that generation. No
                        // Recompile here — the fix is on the master, then a sync.
                        Text(FamilyTreeViewerBanner.compiledElsewhereText())
                            .font(.system(size: 12))
                        Spacer()
                    } else {
                        Text("\(model.needsRecompile.count) pulls on disk, none compiled — the compiled tree was built by an older version.")
                            .font(.system(size: 12))
                        Spacer()
                        Button("Recompile") { Task { await model.recompile() } }
                            .disabled(model.isRecompiling)
                    }
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.10))
            }
            if let warning = model.loadWarning {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(warning).font(.system(size: 12))
                    Spacer()
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.10))
            }
            HSplitView {
                // Hidden sidebar = the canvas takes its width. HSplitView
                // is not a NavigationSplitView, so this is a plain
                // conditional child with a slide transition.
                if isSidebarVisible || sidebarRevealedForSearch {
                    sidebar
                        .frame(minWidth: 220, idealWidth: 250, maxWidth: 310)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                treeCanvas
                    .frame(minWidth: 620)

                inspector
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
            .animation(.easeInOut(duration: 0.2), value: isSidebarVisible)
            .animation(.easeInOut(duration: 0.2), value: sidebarRevealedForSearch)
        }
        // Shortcut carriers: zero-size, invisible buttons whose only job is
        // the key equivalent (the visible toolbar buttons live inside the
        // canvas header, which is rebuilt in chain mode). ⌘0 is taken
        // app-wide by Window › Main Window, so Fit is ⌥⌘0.
        .background {
            Group {
                Button("") { toggleSidebar() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button("") { revealSearch() }
                    .keyboardShortcut("f", modifiers: [.command])
                Button("") { zoom = FamilyTreeZoomMath.zoomIn(zoom) }
                    .keyboardShortcut("=", modifiers: [.command])
                Button("") { zoom = FamilyTreeZoomMath.zoomIn(zoom) }
                    .keyboardShortcut("+", modifiers: [.command])
                Button("") { zoom = FamilyTreeZoomMath.zoomOut(zoom) }
                    .keyboardShortcut("-", modifiers: [.command])
                Button("") { fitToViewport() }
                    .keyboardShortcut("0", modifiers: [.command, .option])
            }
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onChange(of: searchFocused) { _, focused in
            // The ⌘F peek ends when focus leaves the field.
            if !focused, sidebarRevealedForSearch { sidebarRevealedForSearch = false }
        }
        .alert("Export failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .background(Color(red: 0.06, green: 0.07, blue: 0.08))
        .preferredColorScheme(.dark)
        .onChange(of: selectedPhotoItem) { _, item in
            importApplePhoto(item)
        }
        .photosPicker(isPresented: $showApplePhotosPicker,
                      selection: $selectedPhotoItem, matching: .images)
        .sheet(item: $adjustSource) { source in
            FamilyPhotoAdjustSheet(
                source: source,
                onSaved: { cropped, url in
                    // The crop wins on the card immediately (session
                    // override) and on relaunch (recorded as THE choice).
                    model.setPhotoOverride(cropped, for: source.personID)
                    appLog.write("Family Tree: saved card photo \(url.lastPathComponent) for \(source.personName)")
                    do {
                        try source.store.recordPhotoChoice(
                            url, for: source.assetPerson, source: PersonPhotoChoiceSource.treeAdjust)
                        model.notePhotoChoiceWritten()
                        adjustError = nil
                    } catch {
                        adjustError = "Crop saved, but not recorded as the chosen photo: \(error.localizedDescription)"
                    }
                    adjustSource = nil
                },
                onCancel: { adjustSource = nil })
        }
        .sheet(item: $researchTarget) { target in
            ResearchPersonSheet(
                model: ResearchPersonModel(
                    subject: target.subject,
                    // People/<FSID>/research/ under the family assets root.
                    store: ResearchStore(
                        peopleRoot: FamilyAssetConfigurationCenter.shared.snapshot().makeStore().peopleDirectory),
                    fetcher: URLSessionResearchFetcher(),
                    speakerName: model.noteAuthor,
                    record: { try model.recordTestimony($0) }),
                onClose: { researchTarget = nil })
        }
        .alert("Can't research this person", isPresented: Binding(
            get: { researchRefusal != nil },
            set: { if !$0 { researchRefusal = nil } })) {
            Button("OK", role: .cancel) { researchRefusal = nil }
        } message: {
            Text(researchRefusal ?? "")
        }
        .sheet(item: $identityPickTarget) { target in
            TreeIdentityPickerSheet(target: target, center: identityCenter,
                                    profiles: POIProfile.cachedSnapshot(),
                                    onPinned: { candidate in
                                        identityPickTarget = nil
                                        identityCenter.showBanner(.pinned, profileName: target.profile.name,
                                                                  candidate: candidate)
                                        model.focus(onID: candidate.personID)
                                    },
                                    onDismiss: { identityPickTarget = nil })
        }
        .sheet(isPresented: $showPullSheet, onDismiss: { pullCenter.dismissIfSettled() }) {
            // The coordinator is created in presentGetFamilyTree() before the
            // flag flips, so this `if let` only guards the impossible case.
            if let coordinator = pullCenter.coordinator {
                FamilySearchPullSheet(
                    coordinator: coordinator,
                    onInstalled: { _ in Task { await model.loadFromDisk() } },
                    onForget: {
                        showPullSheet = false
                        pullCenter.forget()
                    })
            }
        }
        .task(id: sourceRevision) {
            if !usesInjectedModel {
                model.configure(source: FamilyAssetConfigurationCenter.shared.snapshot())
            }
            await model.loadFromDisk()
            await model.loadCyberBrain()
            handleIncomingHighlight()
        }
        .onChange(of: incomingHighlight) { _, _ in handleIncomingHighlight() }
        .onChange(of: incomingPersonID) { _, _ in handleIncomingHighlight() }
        .onChange(of: incomingSearchText) { _, _ in handleIncomingHighlight() }
        .onChange(of: model.loadState) { _, _ in handleIncomingHighlight() }
        .onChange(of: getFamilyTreeRequest) { _, token in
            guard !token.isEmpty else { return }
            getFamilyTreeRequest = ""
            presentGetFamilyTree()
        }
    }

    /// If the People tab (or Hallie) dropped a name into AppStorage, find the
    /// matching person on this tree, select them, and clear the hint so it
    /// doesn't fire again next time. A dropped surname becomes the sidebar
    /// search text and selects the first person carrying it.
    private func handleIncomingHighlight() {
        // Wait for the graph: a hint that arrives before the load finishes
        // is picked up again by the loadState onChange.
        guard case .loaded = model.loadState else { return }
        if !incomingPersonID.isEmpty {
            if !model.focus(onID: incomingPersonID) {
                // GEDCOM pointers are file-local. Never guess by display name
                // if an action's exact pointer is absent after a new export —
                // but say so, don't leave the default person on screen.
                model.reportMissingRecord(id: incomingPersonID,
                                          displayName: incomingHighlight)
            }
            incomingPersonID = ""
            incomingHighlight = ""
            return
        }
        if !incomingSearchText.isEmpty {
            let text = incomingSearchText.trimmingCharacters(in: .whitespaces)
            model.searchText = text
            model.focus(onName: text, profiles: POIProfile.cachedSnapshot())
            incomingSearchText = ""
        }
        guard !incomingHighlight.isEmpty else { return }
        // People-tab names are profile names ("Rick"); the profiles carry
        // the aliases that bridge them to the tree ("Richard Breen"). The
        // snapshot is a read-only cache — listAll() can run a legacy
        // migration (photo copies) and this runs on the main actor.
        model.focus(onName: incomingHighlight, profiles: POIProfile.cachedSnapshot())
        incomingHighlight = ""
    }

    /// Build (or re-surface) the coordinator against whatever GEDCOM
    /// directory this session resolved (archive when one is designated,
    /// Application Support when not) so a downloaded tree always lands where
    /// the tab reads from. A pull already in flight comes back as the SAME
    /// coordinator — the sheet reopens onto it.
    private func presentGetFamilyTree() {
        pullCenter.begin(gedcomDirectory: model.originalsDirectory)
        showPullSheet = true
    }

    // MARK: Banner

    private var demoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.yellow)
            Text("Demo tree — add a GEDCOM file to the 40_Family_Tree/GEDCOM folder")
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            // The badge performs the fix: the fastest way out of the demo
            // tree is to go and fetch a real one.
            Button {
                presentGetFamilyTree()
            } label: {
                Label("Get Family Tree", systemImage: "arrow.down.circle")
            }
            .controlSize(.small)
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

    private var unavailableBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text("Family Tree is unavailable until the designated Master Archive is connected and its identity is verified.")
                .font(.system(size: 12))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }

    private var sourceRevision: String {
        if usesInjectedModel { return "injected" }
        return [
            catalogModel.masterArchiveRootPath ?? "fallback",
            catalogModel.isMasterArchiveOnline ? "online" : "offline",
            catalogModel.masterArchiveIdentityMismatch ?? "identity-ok",
            catalogModel.isReadOnly ? "readonly" : "readwrite",
        ].joined(separator: "|")
    }

    // MARK: Identity banner (People-tab focus)

    /// Three lines (2026-08-29 layout fix — the one-row form elided the
    /// FSID and crowded the controls at a 560 px sidebar):
    ///   1. "Rick is Richard Harding Breen Jr (b. 1959)" — wraps, never elides
    ///   2. the FamilySearch ID, monospaced, with a copy button — never elided
    ///   3. trailing controls: [OK / Undo] · Not right? · ⊗
    /// Semantic fonts (.callout / .caption) follow the system text size.
    private func identityBanner(_ banner: TreeIdentityCenter.Banner) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: banner.kind == .using ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                Text(banner.headline)
                    .font(.callout)
                    // `.fixedSize(horizontal: false, vertical: true)` ≈ "take
                    // the width you're given, grow as tall as you need" — the
                    // SwiftUI way to say "wrap instead of truncate".
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ft.identityBanner.headline")
            }
            HStack(spacing: 6) {
                Text(banner.candidate.code)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    // The identifier is the one thing that must never be
                    // cut short; it is short enough to always fit at 400 px.
                    .fixedSize()
                    .accessibilityIdentifier("ft.identityBanner.code")
                Button {
                    copyToPasteboard(banner.candidate.code)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy \(banner.candidate.code)")
                .accessibilityLabel("Copy FamilySearch ID")
                .accessibilityIdentifier("ft.identityBanner.copy")
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if banner.kind == .using {
                    Button("OK") { identityCenter.dismissBanner() }
                        .controlSize(.small)
                    Button("Undo") { undoIdentityPin(banner) }
                        .controlSize(.small)
                }
                Button("Not right?") { changeIdentityPin(banner) }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .accessibilityIdentifier("ft.identityBanner.notRight")
                Button {
                    identityCenter.dismissBanner()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ft.identityBanner")
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func profileNamed(_ name: String) -> POIProfile? {
        POIProfile.cachedSnapshot().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func undoIdentityPin(_ banner: TreeIdentityCenter.Banner) {
        guard let profile = profileNamed(banner.profileName) else { return }
        identityCenter.unpin(profile)
        identityCenter.dismissBanner()
    }

    private func changeIdentityPin(_ banner: TreeIdentityCenter.Banner) {
        guard let profile = profileNamed(banner.profileName) else { return }
        identityPickTarget = TreeIdentityPickTarget(
            profile: profile, candidates: [banner.candidate], mode: .changePin, current: banner.candidate)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Family Tree", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            // Full-width button on its own row; turns into a live status
            // (spinner / ready / problem) while a download is in flight.
            FamilySearchPullButtonRow(status: pullCenter.status) {
                presentGetFamilyTree()
            }

            TextField("Search name, surname, or GEDCOM ID", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                // Return picks the first match; ↑/↓ walk the list without
                // leaving the field. `.onKeyPress` returning `.handled` ≈
                // "consumed, don't pass to the next responder".
                .onSubmit { model.selectFirstFiltered() }
                .onKeyPress(.upArrow) { model.selectPrevious(); return .handled }
                .onKeyPress(.downArrow) { model.selectNext(); return .handled }
            // Honest miss for "Show X in Family Tree" / Hallie hints: the
            // name is already in the field above; say so instead of leaving
            // the default person looking like the answer.
            if let notice = model.focusMissNotice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ft.focusMissNotice")
            }
            // Identity line after a People-tab focus: who this profile IS
            // on the tree, with the way out if the computer got it wrong.
            if let banner = identityCenter.banner, banner.candidate.personID == model.selectedID {
                identityBanner(banner)
            }

            Divider()

            // `ScrollViewReader` ≈ a handle that lets code scroll to a row by
            // id; the ids are the ForEach ids (person.id).
            ScrollViewReader { proxy in
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
                // `.focusable()` lets the list itself take keyboard focus
                // (click it, then use the arrows). Focus ring is hidden so
                // the dark sidebar doesn't grow a blue border.
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.upArrow) { model.selectPrevious(); return .handled }
                .onKeyPress(.downArrow) { model.selectNext(); return .handled }
                // Keep the selected row visible whether the change came from
                // a keypress, a card click, or the People tab.
                .onChange(of: model.selectedID) { _, id in
                    guard let id, model.selectedFilteredIndex != nil else { return }
                    proxy.scrollTo(id, anchor: .center)
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
                Button {
                    toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.bordered)
                .help(isSidebarVisible ? "Hide the sidebar (⌥⌘S)" : "Show the sidebar (⌥⌘S)")
                .accessibilityIdentifier("ft.toggleSidebar")
                Text(model.lineChain?.title ?? canvasTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if let chain = model.lineChain {
                    Button {
                        zoom = FamilyTreeZoomMath.fitWidthScale(
                            content: FamilyTreeLineChainMetrics.contentSize(cardCount: chain.cards.count),
                            viewport: canvasViewport)
                    } label: {
                        Label("Fit line", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.bordered)
                    .help("Scale the line to the canvas width (⌥⌘0)")
                    Menu {
                        Button("Export as PDF…") { exportLine(format: .pdf) }
                        Button("Export as PNG (2×)…") { exportLine(format: .png) }
                        Divider()
                        Button("Print line…") { FamilyTreeLineExporter.printLine(exportSpec(chain)) }
                        Divider()
                        Toggle("Include photos", isOn: $exportIncludesPhotos)
                    } label: {
                        Label("Export line", systemImage: "square.and.arrow.up")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .help("Save or print this line as a strip: names, years, places, photos")
                    .accessibilityIdentifier("ft.exportLine")
                    Button {
                        model.showFullTree()
                    } label: {
                        Label("Show full tree", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .buttonStyle(.bordered)
                } else {
                    if model.isLive {
                        // Back to the first root (Rick) after wandering up
                        // the tree (2026-08-28).
                        Button {
                            model.focusHome()
                            zoom = FamilyTreeZoomMath.default
                        } label: {
                            Label("Home", systemImage: "house")
                        }
                        .buttonStyle(.bordered)
                        .help("Focus the tree's root person")
                    }
                    Button {
                        if !model.isLive { model.select(FamilyTreeDemoData.rootID) }
                        zoom = FamilyTreeZoomMath.default
                    } label: {
                        Label("Center", systemImage: "scope")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        fitToViewport()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.bordered)
                    .help("Fit the tree to the canvas (⌥⌘0)")
                }
                // Zoom: buttons (⌘− / ⌘+), slider, pinch on the canvas.
                Button { zoom = FamilyTreeZoomMath.zoomOut(zoom) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .help("Zoom out (⌘−)")
                Slider(value: $zoom, in: FamilyTreeZoomMath.range)
                    .frame(width: 130)
                Button { zoom = FamilyTreeZoomMath.zoomIn(zoom) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .help("Zoom in (⌘+)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(red: 0.075, green: 0.08, blue: 0.09))

            if let chain = model.lineChain {
                // Chain mode: O(path length) cards, no tree layout at all.
                FamilyTreeLineChainView(
                    chain: chain,
                    selectedID: model.selectedID,
                    zoom: zoom,
                    onSelect: { model.select($0) })
                .gesture(magnifyGesture)
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
            } else {
                treeScroll
            }
        }
        // Viewport for Fit: the whole canvas column (header included — a
        // ~46 pt overestimate the fit padding absorbs). One place, both
        // modes, so the value is never stale after a sidebar toggle.
        .background {
            GeometryReader { proxy in
                Color.clear
                    // `initial: true` ≈ fire once on appear as well as on change.
                    .onChange(of: proxy.size, initial: true) { _, newSize in
                        canvasViewport = newSize
                    }
            }
        }
        // A chain starts at 1:1 (cards are readable); leaving it goes back
        // to the tree's comfortable default.
        .onChange(of: model.lineChain?.title) { _, title in
            zoom = title == nil ? FamilyTreeZoomMath.default : 1.0
        }
    }

    // MARK: Canvas navigation (sidebar, zoom, fit, export)

    /// Trackpad pinch. `magnification` is a multiplier from the pinch's
    /// start, so the zoom at gesture start is remembered and re-applied.
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomStart == nil { zoomStart = zoom }
                zoom = FamilyTreeZoomMath.clamp((zoomStart ?? zoom) * value.magnification)
            }
            .onEnded { _ in zoomStart = nil }
    }

    private func toggleSidebar() {
        isSidebarVisible.toggle()
        sidebarRevealedForSearch = false
        FamilyTreeSidebarPreference.save(isSidebarVisible, to: preferences)
        appLog.write("Family Tree: sidebar \(isSidebarVisible ? "shown" : "hidden")")
    }

    /// ⌘F: focus the search field; when the sidebar is hidden, peek it
    /// open until the field loses focus (the saved preference is untouched).
    private func revealSearch() {
        if !isSidebarVisible { sidebarRevealedForSearch = true }
        // The field has to exist before it can take focus: defer one turn
        // of the run loop when it is being inserted right now.
        DispatchQueue.main.async { searchFocused = true }
    }

    /// ⌥⌘0: fit the tree scene, or the active line by width.
    private func fitToViewport() {
        if let chain = model.lineChain {
            zoom = FamilyTreeZoomMath.fitWidthScale(
                content: FamilyTreeLineChainMetrics.contentSize(cardCount: chain.cards.count),
                viewport: canvasViewport)
        } else {
            zoom = FamilyTreeZoomMath.fitScale(content: model.scene.size, viewport: canvasViewport)
        }
    }

    private func exportSpec(_ chain: FamilyTreeLineChain) -> FamilyTreeLineExportSpec {
        FamilyTreeLineExportSpec(
            chain: chain,
            includePhotos: exportIncludesPhotos,
            photo: { model.photo(for: $0) })
    }

    private func exportLine(format: UTType) {
        guard let chain = model.lineChain else { return }
        FamilyTreeLineExporter.exportViaPanel(exportSpec(chain), format: format) { result in
            if case .failure(let error)? = result {
                exportError = error.localizedDescription
            }
        }
    }

    /// Id of the 1×1 invisible marker that sits on the focused card's
    /// on-screen point; `ScrollViewReader.scrollTo` targets it.
    private static let focusAnchorID = "ft.canvas.focusAnchor"

    /// Where the focused card is drawn, in the (post-zoom) scroll content.
    private var focusAnchorPoint: CGPoint? {
        guard let id = model.selectedID,
              let card = model.scene.cards.first(where: { $0.person.id == id }) else { return nil }
        return FamilyTreeCanvasFocus.anchorPoint(cardPosition: card.position, zoom: zoom)
    }

    /// Bring the focused card to the middle of the viewport. Deferred one
    /// run-loop turn so the freshly rebuilt scene has been laid out first
    /// (2026-08-29: People → Show in Family Tree landed on a scene whose
    /// root sat far outside the top-left viewport — an "empty" canvas).
    private func scrollToFocus(_ reader: ScrollViewProxy, animated: Bool) {
        guard focusAnchorPoint != nil else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.25)) {
                    reader.scrollTo(Self.focusAnchorID, anchor: .center)
                }
            } else {
                reader.scrollTo(Self.focusAnchorID, anchor: .center)
            }
        }
    }

    private var treeScroll: some View {
            GeometryReader { proxy in
                let size = model.scene.size == .zero
                    ? CGSize(width: 600, height: 400) : model.scene.size
                // `ScrollViewReader` ≈ a handle to scroll programmatically;
                // the canvas never did this before, so a big tree opened
                // on its top-left corner instead of on the selected person.
                ScrollViewReader { reader in
                ScrollView([.horizontal, .vertical]) {
                    ZStack {
                        treeLines
                        ForEach(model.scene.cards) { card in
                            FamilyTreePersonCard(
                                card: card,
                                isSelected: card.person.id == model.selectedID,
                                onSelect: { model.select(card.person.id) },
                                onPickPhoto: { pickPhotoFile(for: card.person.id) },
                                onApplePhoto: {
                                    model.select(card.person.id)
                                    showApplePhotosPicker = true
                                },
                                onAdjustPhoto: {
                                    model.select(card.person.id)
                                    presentAdjustPhoto(for: card.person)
                                },
                                canAdjustPhoto: model.isLive,
                                portraitProfile: model.bridgedProfile(for: card.person.id),
                                photoRevision: model.photoRevision,
                                onAskHallie: { name in
                                    catalogModel.archivistAskRequest = "tell me about \(name)"
                                    openWindow(id: "archivist")
                                },
                                onShowInPeople: { name in
                                    showInPeopleTab(named: name)
                                },
                                onResearch: { presentResearch(for: card.person.id) }
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
                    // Invisible scroll target on the focused card's drawn
                    // point. Placed OUTSIDE the scaleEffect so scrollTo's
                    // geometry matches what is on screen (scaleEffect is a
                    // paint-time transform; layout frames stay unscaled).
                    .overlay(alignment: .topLeading) {
                        if let point = focusAnchorPoint {
                            Color.clear
                                .frame(width: 1, height: 1)
                                .position(point)
                                .id(Self.focusAnchorID)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(40)
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                }
                .gesture(magnifyGesture)
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
                .onAppear { scrollToFocus(reader, animated: false) }
                .onChange(of: model.selectedID) { _, _ in scrollToFocus(reader, animated: true) }
                // A relayout with the same selection (install / reload /
                // generation cap change) moves the card; follow it.
                .onChange(of: model.scene.size) { _, _ in scrollToFocus(reader, animated: false) }
                .onChange(of: zoom) { _, _ in scrollToFocus(reader, animated: false) }
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
                        HStack(alignment: .firstTextBaseline) {
                            Text(model.isLive ? "GEDCOM Person" : "Demo Person")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            // The photo actions moved to right-click /
                            // double-click on the card (Rick 2026-08-28);
                            // this small menu is the discoverable fallback.
                            photoMenu(for: person)
                        }

                        Text(person.name)
                            .font(.system(size: 15, weight: .semibold))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)

                        // Born 1615 (Plymouth, Massachusetts)
                        // Died 1690, age 75 (Sudbury, Massachusetts Bay Colony)
                        if let life = model.selectedLife, !life.lines.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(life.lines, id: \.self) { line in
                                    Text(line)
                                        .font(.system(size: 12.5))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        } else if let years = person.years {
                            Text(years)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No dates recorded")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 10) {
                            if let surname = person.surname {
                                Text(surname)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            copyableID(model.isLive ? "GEDCOM" : "Ref", person.reference)
                            if let fsID = model.selectedFamilySearchID {
                                copyableID("FS", fsID)
                            }
                        }
                        if let adjustError {
                            Text(adjustError)
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(14)
                    .background(panelBackground)

                    if !model.lineOptions.isEmpty {
                        FamilyTreeLineToRow(options: model.lineOptions) { anchorID in
                            model.showLine(to: anchorID)
                        }
                        .padding(14)
                        .background(panelBackground)
                    } else if let caption = model.anchorsCaption {
                        // Stale owner FamilySearch ID (codex #707): say why
                        // there is no "Line to" row instead of guessing root.
                        Text(caption)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                            .background(panelBackground)
                    }

                    if !model.selectedRelatives.isEmpty {
                        relativesPanel(model.selectedRelatives)
                    }
                }

                if model.isLive, model.selectedPerson != nil {
                    archivistNotesPanel
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("FamilySearch Lookup")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    FamilySearchMatchCard(match: .notConnected)
                }
                .padding(14)
                .background(panelBackground)

                FamilyCrestsPane(
                    store: FamilyAssetConfigurationCenter.shared
                        .snapshot().makeStore())
                    .padding(14)
                    .background(panelBackground)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Notes")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(model.isLive
                         ? "Names and dates come straight from your GEDCOM file and are shown as recorded. Saved family photos are read from 40_Family_Tree/People; photos chosen here are kept for this session only."
                         : "This is a clearly labeled placeholder tree. Add a .ged export to 40_Family_Tree/GEDCOM and reload to see your own family.")
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

    // MARK: Archivist Notes

    /// What the family knowledge file says about the selected person, and
    /// a box to add to it. Rows come from `model.selectedNotes` (resolved
    /// once per selection in the model); nothing here touches the brain.
    private var archivistNotesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Archivist Notes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await model.loadCyberBrain() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Re-read the family knowledge file (after telling Hallie something)")
            }

            saidAsRow

            if model.selectedNotes.isEmpty {
                Text(model.notesStatus ?? "Nothing recorded about this person yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.selectedNotes) { note in
                    FamilyTreeNoteRow(note: note)
                }
            }

            Divider()

            // `TextEditor` ≈ NSTextView bound to a String; `$draftNote` is a
            // two-way binding (think reference to the @State storage).
            TextEditor(text: $draftNote)
                .font(.system(size: 12))
                .frame(minHeight: 60, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 5))

            HStack {
                if let noteError {
                    Text(noteError)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer()
                Button("Add note") { saveDraftNote() }
                    .masterOnly()
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(draftNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Saved to the family knowledge file as \(model.noteAuthor); Hallie can answer from it right away. Your GEDCOM is never changed.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(panelBackground)
        // `.onChange` ≈ an observer on the model's selection: a new person
        // closes the editor so a draft never lands on the wrong name.
        .onChange(of: model.selectedID) { _, _ in
            editingPronunciationWord = nil
            pronunciationError = nil
        }
    }

    // MARK: Said as (pronunciations)

    /// One chip per word of the name; click to say how it is pronounced.
    /// Saved on the person's CyberBrain record next to their aliases and
    /// used by Hallie's voice on the very next answer.
    private var saidAsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Said as")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                ForEach(model.selectedPronunciations) { chip in
                    Button { beginEditingPronunciation(chip) } label: {
                        HStack(spacing: 4) {
                            Text(chip.word)
                            if let said = chip.saidAs {
                                Text("· \(said)").foregroundStyle(.secondary)
                                Image(systemName: "pencil").font(.system(size: 8))
                            }
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background((chip.isSet ? Color.cyan : Color.white).opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(chip.isSet
                          ? "Hallie says \(chip.word) as \(chip.saidAs ?? "") — click to change"
                          : chip.inherited.map { "Hallie says \(chip.word) as \($0) (family default) — click to set it for this person" }
                            ?? "Click to tell Hallie how to say \(chip.word)")
                }
                Spacer(minLength: 0)
            }
            if let word = editingPronunciationWord {
                pronunciationEditor(word: word)
            }
        }
    }

    private func pronunciationEditor(word: String) -> some View {
        let chip = model.selectedPronunciations.first { $0.word == word }
        let draft = draftSaidAs.trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("How do you say \(word)?")
                    .font(.system(size: 11))
                // `$draftSaidAs` is a two-way binding to the @State string.
                TextField("", text: $draftSaidAs, prompt: Text("nuh-THAN-yul"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(maxWidth: 170)
                    .onSubmit {
                        guard Self.allowsPronunciationSubmit() else {
                            ViewerWriteGuard.refuse("FamilyTreeDemoView.submitPronunciation")
                            return
                        }
                        savePronunciation(word)
                    }
                Button {
                    // Preview through the same voice Hallie answers with
                    // (Bella when installed): the draft respelling itself, or
                    // the word as she currently says it.
                    HallieSpeaker.shared.speak(draft.isEmpty ? word : draft)
                } label: {
                    Label("Say it", systemImage: "play.fill")
                }
                .controlSize(.small)
                .help("Hear it")
                Button("Save") { savePronunciation(word) }
                    .masterOnly()
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(draft.isEmpty)
                if chip?.isSet == true {
                    Button("Remove") { removePronunciation(word) }
                        .masterOnly()
                        .controlSize(.small)
                }
                Button("Cancel") {
                    editingPronunciationWord = nil
                    pronunciationError = nil
                }
                .controlSize(.small)
            }
            if let pronunciationError {
                Text(pronunciationError)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    static func allowsPronunciationSubmit(
        viewerMode: Bool = ViewerModeCenter.shared.isViewer
    ) -> Bool {
        !viewerMode
    }

    private func beginEditingPronunciation(_ chip: FamilyTreePronunciationChip) {
        editingPronunciationWord = chip.word
        draftSaidAs = chip.effective ?? ""
        pronunciationError = nil
    }

    private func savePronunciation(_ word: String) {
        let draft = draftSaidAs.trimmingCharacters(in: .whitespaces)
        guard !draft.isEmpty else { return }
        do {
            try model.setPronunciation(word: word, saidAs: draft)
            editingPronunciationWord = nil
            pronunciationError = nil
        } catch {
            pronunciationError = error.localizedDescription
        }
    }

    private func removePronunciation(_ word: String) {
        do {
            try model.setPronunciation(word: word, saidAs: nil)
            editingPronunciationWord = nil
            pronunciationError = nil
        } catch {
            pronunciationError = error.localizedDescription
        }
    }

    /// Right-click → Research Person…: the privacy guard decides between
    /// the pane (deceased tree record) and a refusal (living, no dates,
    /// demo tree). Nothing goes online until Run is pressed in the pane.
    private func presentResearch(for id: String) {
        switch ResearchEligibility.evaluate(model.treePerson(id: id)) {
        case .eligible(let subject):
            model.select(id)
            researchTarget = ResearchTarget(subject: subject)
        case .refused(let reason):
            researchRefusal = reason
        }
    }

    private func saveDraftNote() {
        let text = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try model.addNote(text)
            draftNote = ""
            noteError = nil
        } catch {
            noteError = error.localizedDescription
        }
    }

    private func relativesPanel(_ relatives: FamilyTreeRelatives) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Relatives")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            relativeGroup("Parents", relatives.parents, icon: "arrow.up")
            if !model.selectedMarriages.isEmpty {
                // Live tree: one row per recorded marriage, with the MARR
                // year when the family has one ("m. 1952").
                marriagesGroup(model.selectedMarriages)
            } else {
                relativeGroup("Spouses", relatives.spouses, icon: "heart")
            }
            relativeGroup(relatives.children.count > 1
                          ? "Children (\(relatives.children.count))" : "Children",
                          relatives.children, icon: "arrow.down")
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

    /// Spouses with the marriage year beside each ("m. 1952"). A family
    /// with no named spouse still lists its marriage so the date isn't lost.
    @ViewBuilder
    private func marriagesGroup(_ marriages: [FamilyTreeMarriage]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Spouses", systemImage: "heart")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(marriages) { marriage in
                Button {
                    if let spouse = marriage.spouse { model.select(spouse.id) }
                } label: {
                    HStack(spacing: 6) {
                        Text(marriage.spouse?.name ?? "(spouse not recorded)")
                            .font(.system(size: 12))
                            .foregroundStyle(marriage.spouse == nil ? .secondary : .primary)
                        if let years = marriage.spouse?.years {
                            Text(years)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let married = marriage.marriedYear {
                            Text("m. \(married)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(marriage.spouse == nil)
            }
        }
    }

    // MARK: Small pieces

    /// Camera menu in the inspector header: the same three photo actions
    /// that live on the card's right-click, for anyone who never right-clicks.
    private func photoMenu(for person: FamilyTreePersonSummary) -> some View {
        Menu {
            Button("Pick a photo…") { pickPhotoFile(for: person.id) }
            Button("Apple Photos…") {
                model.select(person.id)
                showApplePhotosPicker = true
            }
            Button("Adjust Photo…") { presentAdjustPhoto(for: person) }
                .disabled(!model.isLive)
        } label: {
            Image(systemName: "camera")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Pick, import or adjust this person's card photo (also right-click or double-click the card)")
    }

    /// "FS  G7XY-ABC" in monospace with a copy button — small on purpose;
    /// the pane's width belongs to the genealogy text.
    private func copyableID(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy \(value)")
        }
    }

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
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Decode bounded (≤ 2048 px) via ImageIO, off the main actor. An
        // 8000×6000 scan never becomes a 190 MB bitmap in this process;
        // `Task.detached` ≈ std::async on a background queue.
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                CropRenderer.boundedImage(at: url)
            }.value
            guard let image else {
                adjustError = "Couldn't read \(url.lastPathComponent) as an image."
                return
            }
            persistPhotoChoice(image, for: personID, source: PersonPhotoChoiceSource.treePick)
        }
    }

    /// A picked/imported photo IS the choice for this person (2026-08-29:
    /// it used to be a session override the next tab switch threw away).
    /// The card updates now (override); the bounded decode is written as
    /// JPEG into People/<FSID>/ off the main actor and recorded as the
    /// choice, which the People tab then shows too. A refused write
    /// (read-only / offline archive, demo tree) keeps the override for the
    /// session and says so.
    private func persistPhotoChoice(_ image: CGImage, for personID: String, source: String) {
        model.setPhotoOverride(image, for: personID)
        guard let assetPerson = model.assetPerson(for: personID) else { return }
        let configuration = FamilyAssetConfigurationCenter.shared.snapshot()
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                let store = configuration.makeStore()
                guard let data = CropRenderer.jpegData(image, quality: 0.92) else {
                    return .failure(FamilyAssetStore.StoreError.sourceIsNotARegularImage(store.peopleDirectory))
                }
                do {
                    return .success(try store.choosePhoto(
                        data, fileExtension: "jpg", for: assetPerson, source: source))
                } catch {
                    return .failure(error)
                }
            }.value
            switch outcome {
            case .success:
                adjustError = nil
                model.notePhotoChoiceWritten()
            case .failure(let error):
                adjustError = "Photo shown for this session only — not saved: \(error.localizedDescription)"
            }
        }
    }

    /// Build the Adjust sheet's source: this session's override if the user
    /// just picked one, else the first non-card photo in People/<person>/.
    /// Decoding is bounded to 2048 px (≈ 16 MB) by ImageIO before any
    /// bitmap exists, and happens off the main actor. No NSImage, no TIFF.
    private func presentAdjustPhoto(for person: FamilyTreePersonSummary) {
        guard let assetPerson = model.assetPerson(for: person.id) else {
            adjustError = "Adjust Photo works on people from your GEDCOM."
            return
        }
        let store = FamilyAssetConfigurationCenter.shared.snapshot().makeStore()
        let originalURL = store.originalPhotoURL(for: assetPerson)
        let override = model.photoOverrideSource(for: person.id)
        Task {
            let image: CGImage?
            if let override {
                image = override
            } else if let originalURL {
                image = await Task.detached(priority: .userInitiated) {
                    CropRenderer.boundedImage(at: originalURL)
                }.value
            } else {
                image = nil
            }
            guard let image else {
                adjustError = "No photo yet — use Pick a photo or Apple Photos first (right-click the card)."
                return
            }
            adjustError = nil
            adjustSource = FamilyPhotoAdjustSource(
                personID: person.id, personName: person.name,
                assetPerson: assetPerson, image: image, originalURL: originalURL,
                store: store)
        }
    }

    private func importApplePhoto(_ item: PhotosPickerItem?) {
        guard let item, let targetID = model.selectedID else { return }
        Task {
            let data = try? await item.loadTransferable(type: Data.self)
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let data else { return nil }
                return CropRenderer.boundedImage(data: data)
            }.value
            guard let image else {
                selectedPhotoItem = nil
                return
            }
            persistPhotoChoice(image, for: targetID, source: PersonPhotoChoiceSource.treeApplePhotos)
            selectedPhotoItem = nil
        }
    }

    /// Drop a hint to the People tab and switch over to it.
    private func showInPeopleTab(named name: String) {
        UserDefaults.standard.set(name, forKey: "peopleHighlightedPOIName")
        selectedTab = 0
    }
}

// MARK: - Card

// `accent` lives in FamilyTreeLineChainView.swift (shared with the chain).
private extension FamilyTreeSex {
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
    /// Photo actions (Rick 2026-08-28): right-click menu or double-click on
    /// the card, so the inspector keeps its width for genealogy.
    let onPickPhoto: () -> Void
    let onApplePhoto: () -> Void
    let onAdjustPhoto: () -> Void
    let canAdjustPhoto: Bool
    /// The People-tab profile bridged to this person (its cover is the
    /// photo when no explicit choice exists) and the model's choice
    /// revision, so a fresh choice re-reads the store at once.
    let portraitProfile: POIProfile?
    let photoRevision: Int
    /// Family Tree → Hallie bridge (Rick 2026-08-24: right-click →
    /// "Tell me about this person").
    let onAskHallie: (String) -> Void
    let onShowInPeople: (String) -> Void
    /// Research Person… (2026-08-29): sourced dossier for a deceased
    /// tree person, told to Hallie once confirmed.
    let onResearch: () -> Void

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
                    } else if let assetPerson = card.assetPerson {
                        FamilyAssetPortrait(person: assetPerson, profile: portraitProfile,
                                            revision: photoRevision, accent: accent)
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
                .contextMenu { photoMenuItems }

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
        // Order matters: SwiftUI gives the earlier `count: 2` recognizer
        // first refusal, so a double-click opens the photo picker and a
        // lone click (after the double-click window lapses) still selects.
        .onTapGesture(count: 2) {
            onSelect()
            onPickPhoto()
        }
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button("Tell me about \(person.name)") {
                onAskHallie(person.name)
            }
            Button("Research \(person.name)…") {
                onResearch()
            }
            Divider()
            Button("Center on \(person.name)") {
                onSelect()
            }
            Divider()
            photoMenuItems
            Divider()
            Button("Show \(person.name) in People tab") {
                onShowInPeople(person.name)
            }
        }
    }

    /// The three photo actions, shared by the portrait's and the card's
    /// context menus. `@ViewBuilder` on a computed property ≈ a function
    /// that returns a small view tree without needing an explicit container.
    @ViewBuilder
    private var photoMenuItems: some View {
        Button("Pick a photo…") {
            onSelect()
            onPickPhoto()
        }
        Button("Apple Photos…") {
            onApplePhoto()
        }
        Button("Adjust Photo…") {
            onAdjustPhoto()
        }
        .disabled(!canAdjustPhoto)
    }
}

private struct FamilyAssetPortrait: View {
    let person: FamilyAssetPerson
    let profile: POIProfile?
    let revision: Int
    let accent: Color
    @State private var image: NSImage?

    /// What the `.task` keys on: the person, what the bridged profile
    /// says about its cover, and the choice revision.
    private struct Key: Equatable {
        let person: FamilyAssetPerson
        let profileID: String?
        let cover: String?
        let coverChosenAt: Date?
        let revision: Int
    }
    private var key: Key {
        Key(person: person, profileID: profile?.id, cover: profile?.coverImageFilename,
            coverChosenAt: profile?.photoChosenAt, revision: revision)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(accent.opacity(0.22))
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(Circle())
        .task(id: key) {
            let configuration = FamilyAssetConfigurationCenter.shared.snapshot()
            let bridged = profile
            let decoded = await Task.detached(priority: .utility) {
                let store = configuration.makeStore()
                // Explicit choice › bridged People-tab cover › a "-card"
                // crop › the person's own folder › a group folder.
                guard let url = PersonPhotoResolver(store: store)
                        .treePhoto(for: person, bridgedProfile: bridged)?.url,
                      let cg = store.makeThumbnail(for: url, maxPixelSize: 160)
                else { return nil as NSImage? }
                return NSImage(cgImage: cg, size: .zero)
            }.value
            if !Task.isCancelled { image = decoded }
        }
    }
}

/// One Archivist Notes row: the passage, then who/when + two small badges.
private struct FamilyTreeNoteRow: View {
    let note: FamilyTreeNote

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(note.attribution)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                badge(note.confidence.rawValue, color: confidenceColor)
                badge(note.privacy.rawValue, color: .gray)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var confidenceColor: Color {
        switch note.confidence {
        case .confirmed: return .green
        case .probable: return .cyan
        case .uncertain: return .yellow
        case .disputed: return .orange
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
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
