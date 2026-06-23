// PersonFinderView.swift
// Multi-volume person-finding UI — jobs list, progress bars, results, console.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os.log

private let pfViewLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "personfinder.view")

// MARK: - Main View

struct PersonFinderView: View {
    // NOTE: Don't subscribe to DashboardState here. Earlier this view had
    // `@EnvironmentObject var dashboard: DashboardState` but never read
    // `dashboard.*` in its body — only used it once in onAppear to wire
    // `model.dashboard = dashboard`. Each of DashboardState's 51 @Published
    // properties (visionFPS, visionMsPerFrame, visionWorkers, etc.) gets
    // written multiple times per second during scans, retriggering this
    // view's body and cascading through every ScanJobRow. The Matt-scan
    // sample showed PersonFinderView.body 166× in 30s as the dominant
    // SwiftUI hot path. Wiring is now done in ContentView, which already
    // observes the model that owns the dashboard reference.
    @EnvironmentObject var model: PersonFinderModel
    @EnvironmentObject var catalogModel: VideoScanModel
    @AppStorage("selectedTab") private var selectedTab: Int = 0
    @AppStorage("ftHighlightedPersonName") private var ftHighlight: String = ""

    @State private var selectedResultIDs = Set<UUID>()
    @State private var inspectorShown = false
    @State private var inspectorStreamInfo: StreamInspectInfo?
    @State private var inspectorLoading = false
    @State private var resultSortOrder = [KeyPathComparator(\ClipResult.videoFilename)]
    @State private var resultTableData: [ClipResult] = []
    @AppStorage("resultsTableCollapsed") private var resultsCollapsed = false
    @AppStorage("peoplePaneCollapsed") private var peopleCollapsed = false
    @AppStorage("searchesPaneCollapsed") private var searchesCollapsed = false
    @AppStorage("showAllSearchHistory") private var showAllSearchHistory = false

    /// How many terminal (done/paused/cancelled) jobs to show before
    /// collapsing the rest behind a "Show more" affordance. Rick:
    /// "Display the last 5 searches with an options to show more history."
    private static let visibleHistoryDefault = 5

    var selectedJobID: UUID? {
        get { model.selectedJobID }
        nonmutating set { model.selectedJobID = newValue }
    }
    var expandedJobIDs: Set<UUID> {
        get { model.expandedJobIDs }
        nonmutating set { model.expandedJobIDs = newValue }
    }
    var selectedJob: ScanJob? { model.jobs.first { $0.id == selectedJobID } }
    var hasAnyResults: Bool { model.jobs.contains { !$0.results.isEmpty } }

    var body: some View {
        VStack(spacing: 0) {
            // Section 1: People
            sectionHeader("People", icon: "person.2.fill",
                          collapsed: $peopleCollapsed,
                          badge: model.savedProfiles.isEmpty ? nil : "\(model.savedProfiles.count)")
            if !peopleCollapsed {
                peopleGallery
                Divider()
                loadedFacesStrip
            }
            Divider()

            // Section 2: Searches
            sectionHeader("Searches", icon: "magnifyingglass",
                          collapsed: $searchesCollapsed,
                          badge: model.jobs.isEmpty ? nil : "\(model.jobs.count)") {
                searchHeaderButtons
            }
            if !searchesCollapsed {
                jobsSection
                    .frame(minHeight: 90, maxHeight: resultsCollapsed ? .infinity : 300)
            }
            Divider()

            // Section 3: Results
            sectionHeader("Results", icon: "list.bullet",
                          collapsed: $resultsCollapsed,
                          badge: resultTableData.isEmpty ? nil : "\(resultTableData.count)")
            if !resultsCollapsed {
                resultsTable
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(minWidth: 960, maxHeight: .infinity, alignment: .top)
    }

    private func sectionHeader(_ title: String, icon: String,
                               collapsed: Binding<Bool>,
                               badge: String? = nil,
                               @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { collapsed.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 14)
                    Image(systemName: icon)
                        .font(.system(size: 13))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    if let badge {
                        Text(badge)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                .foregroundColor(.primary)
            }
            .buttonStyle(.plain)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.7))
    }

    @ViewBuilder
    private var searchHeaderButtons: some View {
        Menu {
            ForEach(model.savedProfiles) { profile in
                Button {
                    addJobForPerson(profile)
                } label: {
                    Label(profile.name, systemImage: "person.circle")
                }
            }
            if model.savedProfiles.isEmpty {
                Text("Add people in the gallery above first")
            }
        } label: {
            Label("New Search\u{2026}", systemImage: "plus.circle.fill")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.savedProfiles.isEmpty)

        Button {
            PreviewWindowController.shared.show(model: model)
        } label: {
            Label("Face Detection", systemImage: "eye.fill")
                .font(.system(size: 11))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.jobs.isEmpty)

        Button {
            JobConsoleWindowController.shared.show(model: model, focusJobID: selectedJobID)
        } label: {
            Label("Console", systemImage: "terminal")
                .font(.system(size: 11))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.jobs.isEmpty)

        // Experimental ArcFace recognition options — previously defaults-only.
        Menu {
            Section("Experimental — ArcFace engine") {
                Toggle(isOn: Binding(
                    get: { model.settings.arcfaceLandmarkAlignment },
                    set: { model.settings.arcfaceLandmarkAlignment = $0 }   // didSet saves
                )) {
                    Text("5-landmark alignment (norm_crop)")
                }
            }
            Text("Warps each face to the model's canonical 112×112 before embedding (how ArcFace was trained). May improve match accuracy across decades. Start a new search to see the effect.")
        } label: {
            Label("Engine Options", systemImage: "gearshape")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Experimental ArcFace recognition options")

        let anyIdle   = model.jobs.contains { $0.status.isIdle }
        let anyActive = model.jobs.contains { $0.status.isActive }
        if model.jobs.count > 1 && anyIdle {
            Button { model.startAll(); if selectedJobID == nil { selectedJobID = model.jobs.first?.id } } label: {
                Label("Start All", systemImage: "play.fill").font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        if model.jobs.count > 1 && anyActive {
            Button { model.stopAll() } label: {
                Label("Stop All", systemImage: "stop.fill").font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: People Gallery — saved family profiles

    @State private var confirmDeleteProfile: POIProfile?
    @State private var editingProfile: POIProfile?
    /// Drives the Confirm-Person sheet. Set by the "Confirm…" context
    /// menu item on a PersonCard; the sheet presents the candidate
    /// labeling UI and clears this on dismiss. Rick 2026-06-16.
    @State private var confirmTarget: ConfirmSheetTarget?
    /// Drives the View Confirmations sheet (cumulative progress).
    @State private var confirmationsTarget: ConfirmationsTarget?
    /// The original name of the profile being edited (nil when adding new).
    @State private var editingOriginalName: String?
    /// Briefly set after a profile save to flash confirmation on the card.
    @State private var justSavedProfileID: String?
    /// Alert message shown when user tries to edit/switch during a scan.
    @State private var scanLockMessage: String?
    /// Profile ID currently being dragged for reordering.
    @State private var draggingProfileID: String?
    /// Drag-resizable height for the People gallery row. Default leans large
    /// so the family portraits read as the centerpiece — Rick wants the app
    /// to feel like it's about people first when he shows it off.
    @AppStorage("peopleGalleryHeight") private var peopleGalleryHeight: Double = 180

    /// Image diameter scales linearly with the gallery height, leaving
    /// ~70pt headroom for the name label and padding. Clamped so cards
    /// stay tappable at the floor and don't overflow at the ceiling.
    private var personImageSize: CGFloat {
        CGFloat(min(max(peopleGalleryHeight - 70, 56), 260))
    }
    private var personCardWidth: CGFloat {
        max(personImageSize + 24, 96)
    }
    private var personNameFontSize: CGFloat {
        min(max(11 + (personImageSize - 64) * 0.07, 11), 20)
    }

    /// Inline undo affordance for the most recent POI delete. Stays visible
    /// until the user clicks Undo / dismisses with the × / a new delete
    /// supersedes it / app relaunch (session-scope state). No auto-dismiss
    /// timer — Rick wants to take his time.
    @ViewBuilder
    private var undoBanner: some View {
        if let snap = model.lastDeletedPOI {
            HStack(spacing: 10) {
                Image(systemName: "trash.slash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.orange)
                if let err = model.lastUndoError {
                    Text(err)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.red)
                } else {
                    Text("Deleted '\(snap.name)'.")
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                }
                Button("Undo") {
                    Task { @MainActor in
                        _ = await model.undoLastDelete()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut("z", modifiers: .command)

                Spacer()

                Button {
                    model.dismissUndoBanner()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.secondary, Color.secondary.opacity(0.2))
                }
                .buttonStyle(.plain)
                .help("Dismiss — the POI stays in ~/dev/VideoScan/.trash/ for manual recovery")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.orange.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    var peopleGallery: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Inline undo banner — armed by deletePOI, dismissed by undo /
            // dismiss / superseded by next delete / app relaunch. No timers.
            // Sits ABOVE the header so it never reflows the grid below
            // (the VStack just gets one more row).
            undoBanner

            HStack {
                Image(systemName: "person.2.fill")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                Text("Family")
                    .font(.headline)
                Spacer()
                if !model.savedProfiles.isEmpty {
                    Text("\(model.savedProfiles.count) people")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }

            if model.savedProfiles.isEmpty {
                // Empty state — prominent Add Person button
                VStack(spacing: 10) {
                    Button {
                        editingOriginalName = nil
                        editingProfile = POIProfile(name: "", referencePath: "")
                    } label: {
                        Label("Add Person\u{2026}", systemImage: "person.badge.plus")
                            .font(.title3.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Text("Add family members, choose their reference photos, and scan your video library to find them")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        // Add Person — always left-aligned
                        Button {
                            editingOriginalName = nil
                            editingProfile = POIProfile(name: "", referencePath: "")
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                                        .foregroundColor(.secondary.opacity(0.4))
                                        .frame(width: personImageSize, height: personImageSize)
                                    Image(systemName: "plus")
                                        .font(.system(size: personImageSize * 0.34, weight: .medium))
                                        .foregroundColor(.secondary)
                                }
                                Text("Add Person")
                                    .font(.system(size: personNameFontSize, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .frame(width: personCardWidth)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)

                        // Build set of all people currently being scanned across all active jobs
                        let scanningNames = Set(model.jobs.filter { $0.status.isActive }.compactMap { $0.assignedProfile?.name.lowercased() })
                        ForEach(model.savedProfiles) { profile in
                            let isBeingScanned = scanningNames.contains(profile.name.lowercased())
                            let isActive = isBeingScanned
                            PersonCard(profile: profile,
                                       isActive: isActive,
                                       justSaved: justSavedProfileID == profile.id,
                                       imageSize: personImageSize,
                                       cardWidth: personCardWidth,
                                       nameFontSize: personNameFontSize)
                                .opacity(isBeingScanned ? 0.7 : 1.0)
                                .onTapGesture {
                                    if isBeingScanned {
                                        scanLockMessage = "Cannot edit \(profile.name) while scanning for \(profile.name)."
                                        return
                                    }
                                    // Load this person's reference faces into the strip for inspection
                                    model.settings.applyProfile(profile)
                                    model.settings.save()
                                    model.referenceFaces.removeAll()
                                    model.referenceLoadFailures.removeAll()
                                    Task { await model.loadReference() }
                                }
                                .draggable(profile.id) {
                                    PersonCard(profile: profile,
                                               isActive: false,
                                               imageSize: personImageSize * 0.8,
                                               cardWidth: personCardWidth * 0.8,
                                               nameFontSize: personNameFontSize)
                                        .opacity(0.8)
                                }
                                .dropDestination(for: String.self) { items, _ in
                                    guard let fromID = items.first else { return false }
                                    model.reorderProfiles(fromID: fromID, toID: profile.id)
                                    draggingProfileID = nil
                                    return true
                                } isTargeted: { targeted in
                                    if targeted { draggingProfileID = profile.id }
                                }
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.accentColor, lineWidth: 2)
                                        .opacity(draggingProfileID == profile.id ? 1 : 0)
                                        .animation(.easeInOut(duration: 0.15), value: draggingProfileID)
                                )
                                .contextMenu {
                                    Button("Search for \(profile.name)\u{2026}") {
                                        addJobForPerson(profile)
                                    }
                                    Divider()
                                    Button("Show \(profile.name) in Family Tree") {
                                        ftHighlight = profile.name
                                        selectedTab = 5
                                    }
                                    Divider()
                                    Button("Edit \(profile.name)\u{2026}") {
                                        editingOriginalName = profile.name
                                        editingProfile = profile
                                    }
                                    Divider()
                                    Button("Confirm \(profile.name)\u{2026}") {
                                        confirmTarget = ConfirmSheetTarget(profile: profile)
                                    }
                                    .help("Rate catalog-flagged candidates Definitely / Likely / No. Builds the labeled set the classifier trains on.")
                                    Button("View Confirmations\u{2026}") {
                                        confirmationsTarget = ConfirmationsTarget(profile: profile)
                                    }
                                    .help("Cumulative progress: outcomes, signal precision, rounds, what remains.")
                                    if !model.referenceFaces.isEmpty && model.settings.personName.lowercased() == profile.name.lowercased() {
                                        Divider()
                                        Menu("Remove Low-Confidence Photos") {
                                            let poorCount = model.referenceFaces.filter { $0.confidence < 0.60 }.count
                                            let belowGoodCount = model.referenceFaces.filter { $0.confidence < 0.80 }.count
                                            Button("Below Fair (< 60%) — \(poorCount) photo\(poorCount == 1 ? "" : "s")") {
                                                model.removeReferenceFaces(belowConfidence: 0.60)
                                            }
                                            .disabled(poorCount == 0)
                                            Button("Below Good (< 80%) — \(belowGoodCount) photo\(belowGoodCount == 1 ? "" : "s")") {
                                                model.removeReferenceFaces(belowConfidence: 0.80)
                                            }
                                            .disabled(belowGoodCount == 0)
                                        }
                                    }
                                    Divider()
                                    Button("Delete \(profile.name)\u{2026}", role: .destructive) {
                                        confirmDeleteProfile = profile
                                    }
                                    .keyboardShortcut(.delete, modifiers: .command)
                                }
                        }

                        // Step 3: "Search for Family" — fan a scan across
                        // every saved POI profile against a folder picked
                        // via NSOpenPanel. One click, N parallel jobs.
                        // Disabled until at least one profile has photos
                        // loaded, otherwise enqueueFamilyJobs filters
                        // them all out and the click would no-op silently.
                        Button {
                            browseForFamilyScanFolder()
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                                        .foregroundColor(.accentColor.opacity(0.6))
                                        .frame(width: personImageSize, height: personImageSize)
                                    Image(systemName: "person.2.crop.square.stack.fill")
                                        .font(.system(size: personImageSize * 0.34, weight: .medium))
                                        .foregroundColor(.accentColor)
                                }
                                Text("Search for Family")
                                    .font(.system(size: personNameFontSize, weight: .medium))
                                    .foregroundColor(.accentColor)
                                    .lineLimit(1)
                            }
                            .frame(width: personCardWidth)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.savedProfiles.allSatisfy { $0.referencePath.isEmpty })
                        .help("Pick a folder or volume — every saved person will be scanned against it in parallel. Catalog rows for matched files get tagged with the detected name(s).")
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }
                .frame(height: peopleGalleryHeight)

                // Drag handle to resize the People gallery — the photos
                // grow/shrink with the pane height, so this is also the
                // size control. Mirrors the reference-faces-strip pattern.
                Rectangle()
                    .fill(Color(NSColor.separatorColor))
                    .frame(height: 5)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                peopleGalleryHeight = max(110, min(420, peopleGalleryHeight + value.translation.height))
                            }
                    )
                    .help("Drag to resize the People gallery — photos scale to fit")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, model.savedProfiles.isEmpty ? 10 : 0)
        .background(Color(NSColor.windowBackgroundColor))
        .alert("Delete '\(confirmDeleteProfile?.name ?? "")' and all reference photos?",
               isPresented: Binding(
            get: { confirmDeleteProfile != nil },
            set: { if !$0 { confirmDeleteProfile = nil } }
        )) {
            Button("Cancel", role: .cancel) { confirmDeleteProfile = nil }
            Button("Delete", role: .destructive) {
                if let p = confirmDeleteProfile {
                    let name = p.name
                    Task { @MainActor in
                        let ok = await model.deletePOI(named: name)
                        if !ok {
                            scanLockMessage = "Could not move '\(name)' into .trash/. Check ~/dev/VideoScan/.trash/ permissions."
                        }
                    }
                    confirmDeleteProfile = nil
                }
            }
        } message: {
            Text("Data is moved to ~/dev/VideoScan/.trash/POI-\(POIStorage.sanitize(confirmDeleteProfile?.name ?? ""))-<UTC>/ and is recoverable until you empty the trash manually. Nothing is permanently deleted.")
        }
        .alert("Scan in Progress", isPresented: Binding(
            get: { scanLockMessage != nil },
            set: { if !$0 { scanLockMessage = nil } }
        )) {
            Button("OK", role: .cancel) { scanLockMessage = nil }
        } message: {
            Text(scanLockMessage ?? "")
        }
        .sheet(item: $editingProfile) { profile in
            PersonEditSheet(profile: profile) { updated in
                model.updateProfile(updated, oldName: editingOriginalName)
                // If this person is now the active POI, reload their faces
                if model.settings.personName.lowercased() == updated.name.lowercased() {
                    Task { await model.loadPOI(updated) }
                }
                // Flash the saved indicator on the card
                justSavedProfileID = updated.id
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    justSavedProfileID = nil
                }
            }
        }
        .sheet(item: $confirmTarget) { target in
            ConfirmPersonSheet(profile: target.profile)
                .environmentObject(model)
                .environmentObject(catalogModel)
        }
        .sheet(item: $confirmationsTarget) { target in
            ConfirmationsView(profile: target.profile, onConfirmMore: {
                confirmTarget = ConfirmSheetTarget(profile: target.profile)
            })
            .environmentObject(model)
            .environmentObject(catalogModel)
        }
    }

    // MARK: Loaded Faces Strip — compact scan-readiness indicator

    @State private var showFailures = false
    @AppStorage("facesStripHeight") private var facesStripHeight: Double = 90
    /// User-toggleable hide for the reference photo grid: keep the header
    /// (so you can still see who's loaded) but free up vertical space for
    /// the People gallery above. Persisted across launches.
    @AppStorage("referencePaneCollapsed") private var referencePaneCollapsed: Bool = false

    /// Derive thumbnail cell size from the pane height: photos scale with
    /// the drag-resizable strip. Clamped so thumbs stay usable at extremes.
    /// Issue #38 — replaced the explicit thumbnail-size slider.
    private var derivedThumbSize: CGFloat {
        CGFloat(min(max(facesStripHeight * 0.55, 40), 140))
    }
    @State private var inspectedFace: ReferenceFace?

    @ViewBuilder
    var loadedFacesStrip: some View {
        if model.referenceFaces.isEmpty && !model.isLoadingReference && model.referenceLoadError == nil {
            // Empty state — no person loaded yet
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.body)
                    .foregroundColor(.secondary)
                Text("Click a person above to load their reference faces, or use Find Person below to start a search")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if model.isLoadingReference {
                        ProgressView().scaleEffect(0.7)
                        Text("Loading reference photos\u{2026}")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if !model.referenceFaces.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.body)
                        Text("\(model.settings.personName)")
                            .font(.body.weight(.semibold))
                        Text("\u{2014} \(model.referencePhotoCount) faces loaded")
                            .font(.body)
                            .foregroundStyle(.secondary)

                        let good = model.referenceFaces.filter { $0.quality == .good }.count
                        let fair = model.referenceFaces.filter { $0.quality == .fair }.count
                        let poor = model.referenceFaces.filter { $0.quality == .poor }.count
                        HStack(spacing: 6) {
                            if good > 0 { Text("\(good) good").foregroundColor(.green).font(.callout) }
                            if fair > 0 { Text("\(fair) fair").foregroundColor(.yellow).font(.callout) }
                            if poor > 0 { Text("\(poor) poor").foregroundColor(.red).font(.callout) }
                        }
                    }

                    if let err = model.referenceLoadError {
                        Label(err, systemImage: "info.circle.fill")
                            .foregroundColor(.orange)
                            .font(.callout)
                    }

                    if !model.referenceLoadFailures.isEmpty {
                        Button {
                            showFailures.toggle()
                        } label: {
                            Label("\(model.referenceLoadFailures.count) skipped",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showFailures) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Photos Without Usable Faces")
                                    .font(.headline)
                                    .padding(.bottom, 4)
                                ForEach(model.referenceLoadFailures) { f in
                                    HStack(spacing: 6) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.red)
                                            .font(.system(size: 11))
                                        Text(f.filename)
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .lineLimit(1)
                                        Text("\u{2014} \(f.reason)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(12)
                            .frame(minWidth: 320, maxHeight: 300)
                        }
                    }
                    Spacer()

                    // Collapse / expand the reference grid. Sized and tinted
                    // so it's findable at a glance — the chevron alone read
                    // too small in usability testing.
                    if !model.referenceFaces.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                referencePaneCollapsed.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: referencePaneCollapsed
                                      ? "chevron.down.circle.fill"
                                      : "chevron.up.circle.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                Text(referencePaneCollapsed ? "Show Photos" : "Hide Photos")
                                    .font(.callout.weight(.medium))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(Color.accentColor)
                            )
                        }
                        .buttonStyle(.plain)
                        .help(referencePaneCollapsed
                              ? "Show reference photos"
                              : "Hide reference photos — gives more room to the People gallery")
                    }
                }

                // Face thumbnails — wrapping grid in a resizable pane
                if !model.referenceFaces.isEmpty && !referencePaneCollapsed {
                    let cellSize = derivedThumbSize
                    let columns = [GridItem(.adaptive(minimum: cellSize + 4), spacing: 6)]
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(model.referenceFaces) { face in
                                CompactFaceThumbnail(
                                    face: face,
                                    size: cellSize,
                                    onRemove: { model.removeReferenceFace(id: face.id) },
                                    sourceFileURL: referenceFaceURL(for: face)
                                )
                                .onTapGesture(count: 2) {
                                    inspectedFace = face
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.bottom, 4)
                    }
                    .frame(height: facesStripHeight)
                    .popover(item: $inspectedFace) { face in
                        faceDetailPopover(face)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            // Drag handle to resize the faces pane (hidden while collapsed)
            if !model.referenceFaces.isEmpty && !referencePaneCollapsed {
                Rectangle()
                    .fill(Color(NSColor.separatorColor))
                    .frame(height: 5)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                facesStripHeight = max(60, min(500, facesStripHeight + value.translation.height))
                            }
                    )
            }
        } // else (faces loaded)
    }

    // MARK: Jobs list helpers

    /// Partition jobs into "active" (idle/loading/scanning/paused — though
    /// paused is technically terminal in our isTerminal sense, the user
    /// still treats it as work-in-flight so we keep it in the active list)
    /// and "terminal" (done/cancelled/failed). Terminal jobs sort newest
    /// first by completedAt so the most recent search appears at the top
    /// of history. Pure function — testable in isolation.
    static func splitJobs(_ jobs: [ScanJob]) -> (active: [ScanJob], terminal: [ScanJob]) {
        var active: [ScanJob] = []
        var terminal: [ScanJob] = []
        for job in jobs {
            // .paused is technically not isTerminal in the model sense, but
            // for the UI we want paused jobs to stay with active ones so the
            // user sees them at the top when they relaunch and want to resume.
            if job.status.isTerminal && job.status != .paused {
                terminal.append(job)
            } else {
                active.append(job)
            }
        }
        terminal.sort { (lhs, rhs) in
            (lhs.completedAt ?? .distantPast) > (rhs.completedAt ?? .distantPast)
        }
        return (active, terminal)
    }

    @ViewBuilder
    private func jobRow(_ job: ScanJob) -> some View {
        ScanJobRow(
            job: job,
            model: model,
            isSelected: selectedJobID == job.id,
            isExpanded: expandedJobIDs.contains(job.id),
            threshold: model.settings.threshold,
            savedProfiles: model.savedProfiles,
            onToggleExpand: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expandedJobIDs.contains(job.id) {
                        expandedJobIDs.remove(job.id)
                    } else {
                        expandedJobIDs.insert(job.id)
                    }
                }
            },
            onStart: { selectedJobID = job.id; expandedJobIDs.insert(job.id); model.startJob(job) },
            onStop: { model.stopJob(job) },
            onPause: { model.togglePauseJob(job) },
            onReset: { job.reset() },
            onRemove: { expandedJobIDs.remove(job.id); model.removeJob(job) },
            onPreview: { PreviewWindowController.shared.show(model: model, focusJobID: job.id) }
        )
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded { selectedJobID = job.id }
        )
    }

    @ViewBuilder
    private func historyToggle(totalHistory: Int) -> some View {
        let hidden = totalHistory - Self.visibleHistoryDefault
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                showAllSearchHistory.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showAllSearchHistory ? "chevron.up" : "chevron.down")
                Text(showAllSearchHistory
                     ? "Show fewer"
                     : "Show \(hidden) more older search\(hidden == 1 ? "" : "es")")
            }
            .font(.system(size: 12))
            .foregroundColor(.accentColor)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func historyFooter(retention: Int) -> some View {
        Text("Older searches auto-removed after \(retention) — your most recent ones are kept.")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
    }

    // MARK: Jobs section

    var jobsSection: some View {
        VStack(spacing: 0) {
            if model.jobs.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.body).foregroundColor(.secondary)
                    Text("Use \"New Search\" to start finding people in your videos")
                        .font(.callout).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        // Active jobs always visible (the user wants to watch
                        // live work). Terminal jobs sort newest-first and
                        // collapse to 5 by default so the list doesn't grow
                        // unbounded — "Show more" reveals the rest, up to
                        // the ScanJobsStorage retention cap (10).
                        let split = Self.splitJobs(model.jobs)
                        ForEach(split.active) { job in
                            jobRow(job)
                        }
                        let visibleHistory = showAllSearchHistory
                            ? split.terminal
                            : Array(split.terminal.prefix(Self.visibleHistoryDefault))
                        ForEach(visibleHistory) { job in
                            jobRow(job)
                        }
                        if split.terminal.count > Self.visibleHistoryDefault {
                            historyToggle(totalHistory: split.terminal.count)
                        }
                        if !split.terminal.isEmpty {
                            historyFooter(retention: ScanJobsStorage.defaultLimit)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: Results table

    private func matchColor(_ dist: Float) -> Color {
        if dist < 0.5 { return .green }
        if dist < 0.65 { return .yellow }
        return .orange
    }

    private var resultTableView: some View {
        resultTableCore
            .onChange(of: resultSortOrder) {
                resultTableData.sort(using: resultSortOrder)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                resultContextMenu(ids: ids)
            } primaryAction: { ids in
                guard let id = ids.first,
                      let rec = resultTableData.first(where: { $0.id == id }) else { return }
                playInQuickTime(rec)
            }
            .frame(minHeight: 120)
            .popover(isPresented: $inspectorShown, arrowEdge: .trailing) {
                if let rec = selectedResult {
                    inspectorPopover(rec)
                }
            }
            .onChange(of: selectedResultIDs) {
                guard inspectorShown, let rec = selectedResult else { return }
                loadStreamInfo(for: rec)
            }
            .onKeyPress(phases: .down) { press in
                guard press.key == KeyEquivalent("i"),
                      press.modifiers == .command,
                      let rec = selectedResult else { return .ignored }
                openInspector(for: rec)
                return .handled
            }
    }

    private var resultTableCore: some View {
        Table(resultTableData, selection: $selectedResultIDs, sortOrder: $resultSortOrder) {
            TableColumn("Video File", value: \.videoFilename) { r in
                Text(r.videoFilename)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .help(r.videoPath)
            }
            .width(min: 200, ideal: 300)

            TableColumn("Duration", value: \.videoDuration) { r in
                Text(pfFormatDuration(r.videoDuration))
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 70, ideal: 80)

            TableColumn("Presence", value: \.presenceSecs) { r in
                Text(pfFormatDuration(r.presenceSecs))
                    .font(.system(.body, design: .monospaced).weight(.medium))
                    .foregroundColor(.green)
            }
            .width(min: 70, ideal: 80)

            TableColumn("Clips", value: \.segmentCount) { r in
                Text("\(r.segmentCount)")
                    .font(.body)
            }
            .width(min: 50, ideal: 60)

            TableColumn("Best Match", value: \.bestDistance) { r in
                Text(String(format: "%.3f", r.bestDistance))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(matchColor(r.bestDistance))
            }
            .width(min: 80, ideal: 90)
        }
    }

    private var selectedResult: ClipResult? {
        guard let id = selectedResultIDs.first else { return nil }
        return resultTableData.first { $0.id == id }
    }

    private func recomputeResults() {
        let raw = selectedJob?.results ?? model.jobs.flatMap { $0.results }
        resultTableData = raw.sorted(using: resultSortOrder)
    }

    var resultsTable: some View {
        Group {
            if resultTableData.isEmpty {
                HStack(spacing: 6) {
                    let anyDone = model.jobs.contains { $0.status == .done || $0.status == .cancelled }
                    let anyActive = model.jobs.contains { $0.status.isActive }
                    Image(systemName: "tray")
                        .foregroundColor(.secondary)
                    Text(anyDone && !anyActive
                         ? "No matches found"
                         : anyActive
                         ? "Results will appear as matches are found"
                         : "Results will appear here when matches are found")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            } else {
                VStack(spacing: 0) {
                    resultTableView
                    if let rec = selectedResult {
                        Divider()
                        resultDetailBar(rec)
                    }
                }
            }
        }
        .onAppear { recomputeResults() }
        .onChange(of: selectedJobID) { recomputeResults() }
        .onChange(of: model.jobs.flatMap(\.results).count) { recomputeResults() }
    }

    private func resultDetailBar(_ rec: ClipResult) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.videoFilename)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                Text(rec.videoPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            HStack(spacing: 14) {
                VStack(spacing: 2) {
                    Text("Duration")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text(pfFormatDuration(rec.videoDuration))
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                }
                VStack(spacing: 2) {
                    Text("Presence")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text(pfFormatDuration(rec.presenceSecs))
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundColor(.green)
                }
                VStack(spacing: 2) {
                    Text("Clips")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text("\(rec.segmentCount)")
                        .font(.system(size: 16, weight: .medium))
                }
                VStack(spacing: 2) {
                    Text("Best Match")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text(String(format: "%.3f", rec.bestDistance))
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundColor(rec.bestDistance < 0.5 ? .green : rec.bestDistance < 0.65 ? .yellow : .orange)
                }
            }

            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.selectFile(rec.videoPath, inFileViewerRootedAtPath: "")
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.blue)

                Button {
                    playInQuickTime(rec)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(.blue)

                Button {
                    openInspector(for: rec)
                } label: {
                    Label("Inspect", systemImage: "info.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.blue)
                .keyboardShortcut("i", modifiers: .command)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    /// Launches QuickTime Player for the given result. Used by the Play
    /// button, the context menu, and the table-row double-click action.
    private func playInQuickTime(_ rec: ClipResult) {
        guard let qtURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.QuickTimePlayerX"
        ) else {
            pfViewLog.error("QuickTime Player not found on this machine")
            return
        }
        pfViewLog.info("Open in QuickTime: \(rec.videoPath, privacy: .public)")
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: rec.videoPath)],
            withApplicationAt: qtURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    // Console pane removed from main window — use the Console toolbar
    // button which opens a floating window with a per-job picker.

    // MARK: Result Context Menu

    @ViewBuilder
    private func resultContextMenu(ids: Set<UUID>) -> some View {
        if let id = ids.first,
           let rec = resultTableData.first(where: { $0.id == id }) {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(rec.videoPath, inFileViewerRootedAtPath: "")
            }
            Button("Open in QuickTime Player") {
                playInQuickTime(rec)
            }
            if !rec.clipFiles.isEmpty {
                Button("Reveal Clips in Finder") {
                    revealClips(for: rec)
                }
            }
            Divider()
            Button("Inspect\u{2026}") {
                openInspector(for: rec)
            }
            Button("Show in Catalog") {
                showInCatalog(path: rec.videoPath)
            }
            .disabled(!isInCatalog(path: rec.videoPath))
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rec.videoPath, forType: .string)
            }
        }
    }

    // MARK: Catalog Navigation

    private func isInCatalog(path: String) -> Bool {
        catalogModel.records.contains { $0.fullPath == path }
    }

    private func showInCatalog(path: String) {
        guard let rec = catalogModel.records.first(where: { $0.fullPath == path }) else { return }
        catalogModel.pendingCatalogSelection = rec.id
        selectedTab = 1
    }

    // MARK: Inspector

    private func openInspector(for rec: ClipResult) {
        selectedResultIDs = [rec.id]
        inspectorStreamInfo = nil
        inspectorShown = true
        loadStreamInfo(for: rec)
    }

    private func loadStreamInfo(for rec: ClipResult) {
        inspectorStreamInfo = nil
        inspectorLoading = true
        Task {
            let info = await StreamInspectInfo.probe(path: rec.videoPath)
            inspectorStreamInfo = info
            inspectorLoading = false
        }
    }

    func inspectorPopover(_ rec: ClipResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(rec.videoFilename).font(.headline)
                Spacer()
                Text("\u{2191}\u{2193} to browse")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Divider()
            infoRow("Path", rec.videoPath)
            infoRow("Duration", pfFormatDuration(rec.videoDuration))
            infoRow("Presence", pfFormatDuration(rec.presenceSecs))
            infoRow("Segments", "\(rec.segmentCount)")
            infoRow("Best Match", String(format: "%.3f", rec.bestDistance))
            if !rec.outputDir.isEmpty {
                infoRow("Output Dir", rec.outputDir)
            }

            if !rec.clipFiles.isEmpty {
                Divider()
                Text("Clip Files").font(.subheadline.weight(.medium))
                ForEach(rec.clipFiles, id: \.self) { clip in
                    Text(clip)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Divider()

            if inspectorLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Probing streams\u{2026}")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            } else if let info = inspectorStreamInfo {
                infoRow("Format", info.formatName)
                infoRow("File Size", info.fileSize)
                infoRow("Bitrate", info.bitrate)

                if info.streams.isEmpty {
                    Text("No streams detected")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                } else {
                    ForEach(Array(info.streams.enumerated()), id: \.offset) { _, stream in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: stream.icon)
                                .foregroundColor(stream.color)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stream.summary)
                                    .font(.system(size: 11, design: .monospaced))
                                if !stream.detail.isEmpty {
                                    Text(stream.detail)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                if info.hasVideo && !info.hasAudio {
                    Label("No audio track", systemImage: "speaker.slash.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.orange)
                }

                if let diagnosis = info.diagnosis {
                    Label(diagnosis, systemImage: info.diagnosisIsWarning
                          ? "exclamationmark.triangle" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(info.diagnosisIsWarning ? .yellow : .red)
                }
            }
        }
        .padding()
        .frame(minWidth: 360, maxWidth: 520)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    func faceDetailPopover(_ face: ReferenceFace) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(nsImage: NSImage(cgImage: face.thumbnail, size: NSSize(width: 120, height: 120)))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 6) {
                    Text(face.sourceFilename)
                        .font(.headline)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(face.quality == .good ? .green : face.quality == .fair ? .orange : .red)
                            .frame(width: 8, height: 8)
                        Text(face.quality == .good ? "Good" : face.quality == .fair ? "Fair" : "Poor")
                            .font(.callout.weight(.medium))
                    }
                    Text(face.angleDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Divider()
            infoRow("Confidence", String(format: "%.0f%%", face.confidence * 100))
            infoRow("Yaw", String(format: "%.1f°", face.yawDeg))
            infoRow("Pitch", String(format: "%.1f°", face.pitchDeg))
            infoRow("Roll", String(format: "%.1f°", face.rollDeg))
            infoRow("Face Area", String(format: "%.1f%% of image", face.faceAreaPct))
        }
        .padding()
        .frame(minWidth: 300, maxWidth: 400)
    }

    // MARK: Helpers

    /// Add a search row for a specific person, expanded and ready for volume selection.
    func addJobForPerson(_ profile: POIProfile) {
        model.selectedPersonForNewJobs = profile
        model.addJob()
        if let job = model.jobs.last {
            expandedJobIDs.insert(job.id)
            selectedJobID = job.id
        }
    }

    /// Step 3 entry point. Ask for a folder, then fan a scan across every
    /// saved POI profile against it. Each profile becomes its own ScanJob
    /// running on its own detached Task — engines run in parallel.
    /// Expands the first new job so the user sees activity immediately.
    func browseForFamilyScanFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Pick a folder or volume — every saved person will be scanned in parallel"
        panel.prompt = "Search for Family"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                Self.recordRecentPath(url.path)
                let newJobs = model.startFamilyScan(at: url.path)
                if let first = newJobs.first {
                    expandedJobIDs.insert(first.id)
                    selectedJobID = first.id
                }
            }
        }
    }

    /// Mounted volumes (excluding system volumes) for the volume picker.
    static var mountedVolumes: [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeIsRemovableKey]
        guard let vols = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                               options: [.skipHiddenVolumes]) else { return [] }
        return vols.filter { url in
            // Skip the boot volume (/) and system partials
            url.path != "/" && !url.path.hasPrefix("/System")
        }
    }

    /// Recently used search paths, persisted across sessions.
    static let recentPathsKey = "PersonFinder.recentSearchPaths"
    static var recentPaths: [String] {
        UserDefaults.standard.stringArray(forKey: recentPathsKey) ?? []
    }
    static func recordRecentPath(_ path: String) {
        var paths = recentPaths.filter { $0 != path }
        paths.insert(path, at: 0)
        if paths.count > 10 { paths = Array(paths.prefix(10)) }
        UserDefaults.standard.set(paths, forKey: recentPathsKey)
    }

    /// Resolve a reference face back to its source image on disk. Returns
    /// nil if the file doesn't actually exist where expected — don't surface
    /// a broken Show-in-Finder item in that case.
    private func referenceFaceURL(for face: ReferenceFace) -> URL? {
        let refPath = model.settings.referencePath
        guard !refPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: refPath).appendingPathComponent(face.sourceFilename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func browseForOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose folder where clips and compiled video will be saved"
        panel.prompt = "Select"
        panel.begin { [model] response in
            if response == .OK, let url = panel.url {
                model.settings.outputDir = url.path
                model.settings.save()
            }
        }
    }

    func browsePython() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the Python executable (e.g. venv/bin/python)"
        panel.prompt = "Select"
        panel.begin { [model] response in
            if response == .OK, let url = panel.url {
                model.settings.pythonPath = url.path
                model.settings.save()
            }
        }
    }

    func browseScript() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.message = "Select the face_recognize.py script"
        panel.prompt = "Select"
        panel.begin { [model] response in
            if response == .OK, let url = panel.url {
                model.settings.recognitionScript = url.path
                model.settings.save()
            }
        }
    }

    func revealClips(for result: ClipResult) {
        let dir = result.outputDir
        if let first = result.clipFiles.first(where: { !$0.isEmpty }) {
            let fullPath = (dir as NSString).appendingPathComponent(first)
            if FileManager.default.fileExists(atPath: fullPath) {
                NSWorkspace.shared.selectFile(fullPath, inFileViewerRootedAtPath: dir)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: dir))
            }
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: dir))
        }
    }
}

