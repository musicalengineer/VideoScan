import SwiftUI

// MARK: - Root (Tab switcher)

struct ContentView: View {
    @EnvironmentObject var model: VideoScanModel
    @EnvironmentObject var catalogSync: CatalogSync
    @StateObject private var personFinderModel = PersonFinderModel()
    @StateObject private var identifyFamilyModel = IdentifyFamilyModel()
    @AppStorage("selectedTab") private var selectedTab: Int = 0
    private let tabFontSize: Double = 18

    private let tabs: [(label: String, icon: String, tag: Int)] = [
        ("People", "person.2.fill", 0),
        ("Catalog", "film.stack", 1),
        ("Triage", "checklist", 2),
        ("Workbench", "hammer.fill", 3),
        ("Archive", "archivebox.fill", 4),
        ("Family Tree", "person.3.fill", 5)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Viewer-mode banner — invisible on the master. Shows
            // last-good-snapshot timestamp + a Refresh button.
            if catalogSync.mode == .viewer {
                CatalogSyncBanner(sync: catalogSync)
            }
            // Custom tab bar — centered with traffic-light inset
            HStack(spacing: 0) {
                // Reserve space for window traffic-light buttons
                Color.clear.frame(width: 76, height: 1)

                Spacer()
                HStack(spacing: 24) {
                    ForEach(tabs, id: \.tag) { tab in
                        Button {
                            selectedTab = tab.tag
                        } label: {
                            Label(tab.label, systemImage: tab.icon)
                                .font(.system(size: tabFontSize, weight: selectedTab == tab.tag ? .bold : .regular))
                                .foregroundStyle(selectedTab == tab.tag ? .primary : .secondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // XCUITest hook: e.g. "tab.Catalog" — added for the
                        // first UI test. Only used by tests; UI is unchanged.
                        .accessibilityIdentifier("tab.\(tab.label)")
                        .background(
                            selectedTab == tab.tag
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .bottom) {
                            if selectedTab == tab.tag {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(Color.accentColor)
                                    .frame(height: 2.5)
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
            Divider()

            // Tab content — fill all available space to prevent layout jumps
            Group {
                switch selectedTab {
                case 0:
                    PeopleTabView()
                        .environmentObject(personFinderModel)
                        .environmentObject(identifyFamilyModel)
                case 1:
                    CatalogView()
                case 2:
                    TriageView()
                case 3:
                    WorkbenchView()
                case 4:
                    ArchiveView()
                case 5:
                    FamilyTreeDemoView()
                default:
                    PeopleTabView()
                        .environmentObject(personFinderModel)
                        .environmentObject(identifyFamilyModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            // Wire PersonFinder scan code to the shared DashboardState
            // (visionFPS / msPerFrame / workers updates flow through here).
            // Moved out of PersonFinderView so that view can stop subscribing
            // to DashboardState's 51 @Published props — the subscription was
            // the dominant SwiftUI hot path during long scans.
            personFinderModel.dashboard = model.dashboard

            // Bridge PersonFinder scan completions to catalog writeback:
            // every "Donna found in /v/X.mov" produces a tag on that
            // VideoRecord — confirmed matches go to `detectedPeople`,
            // borderline matches to `suspectedPeople`. Weak ref on the
            // catalog model so teardown is clean under test hosts.
            personFinderModel.onScanComplete = {
                [weak model] person, confirmed, suspected in
                model?.applyDetectedPeople(
                    confirmed: confirmed,
                    suspected: suspected,
                    person: person
                )
            }
        }
    }
}

// MARK: - Catalog View Filter

enum CatalogViewFilter: String, CaseIterable, Hashable {
    case onlineOnly       = "Online Media Only"
    case videoAndAudioOnly = "Video+Audio Only"
    case unpairedOnly     = "Unpaired Only"
    case ratedOnly        = "Rated Only"
    case hasFamily        = "Has Family"
    case untaggedOnly     = "Untagged (junk candidate)"

    var icon: String {
        switch self {
        case .onlineOnly:        return "externaldrive.fill.badge.checkmark"
        case .videoAndAudioOnly: return "film"
        case .unpairedOnly:      return "exclamationmark.triangle"
        case .ratedOnly:         return "star.fill"
        case .hasFamily:         return "person.2.fill"
        case .untaggedOnly:      return "questionmark.folder"
        }
    }
}

// MARK: - Volume Filter

enum VolumeFilter: String, CaseIterable, Hashable {
    case connected      = "Connected"
    case network        = "Network Drives"
    case allScanned     = "All Ever Scanned"
    case uncataloged    = "Uncataloged"
    case withErrors     = "With Errors"

    var icon: String {
        switch self {
        case .connected:   return "externaldrive.fill"
        case .network:     return "network"
        case .allScanned:  return "clock.arrow.circlepath"
        case .uncataloged: return "questionmark.folder"
        case .withErrors:  return "exclamationmark.triangle"
        }
    }
}

// MARK: - Catalog Tab

struct CatalogView: View {
    @EnvironmentObject var model: VideoScanModel
    @AppStorage("selectedTab") private var selectedTab: Int = 0
    @State private var selectedIDs: Set<UUID> = []
    @State private var showCombineSheet = false
    @State private var showRelocateSheet = false
    @State private var showDashboard = false
    @State private var showInspector = true
    @State private var sortOrder = [KeyPathComparator(\VideoRecord.filename)]
    @State private var searchText: String = ""
    @State private var showDeleteDuplicatesConfirm = false
    @State private var deleteTargetVolume: String = ""
    @State private var deleteTargetCount: Int = 0
    @State private var showDiscoverVolumes = false
    @State private var showVolumeCompare = false
    /// Set by Archive tab navigation — filters catalog to specific record IDs.
    @State private var filterByIDs: Set<UUID> = []
    /// When `filterByIDs` was populated by Find A/V Pair, the candidate's score
    /// (0–14) so the focus banner can show a Best/Better/Good/Maybe label.
    @State private var focusMatchScore: Int?
    // Volume pane height is now managed by NSSplitView (VerticalSplitView)
    @State private var showPairsOnly = false
    @State private var catalogViewFilters: Set<CatalogViewFilter> = []
    /// Whether purged ("removed from catalog") rows are included in the table.
    /// Persisted across launches like other catalog UI prefs.
    /// Default OFF — purged rows hidden until the user opts in.
    @AppStorage("catalogShowRemoved") private var showRemoved: Bool = false
    /// Strict-catalog policy: scan targets that have never been scanned and
    /// aren't currently doing anything are hidden from the Scan Volumes
    /// table by default. The user opts in with a small toggle near the table.
    /// `@AppStorage` ≈ a C++ singleton bool persisted via NSUserDefaults.
    @AppStorage("catalogShowUnscannedTargets") private var showUnscannedTargets: Bool = false
    /// Whether the "Clean up unscanned…" confirmation alert is showing.
    @State private var showCleanupUnscannedConfirm = false
    @State private var combinePairItem: CombinePairItem?
    /// Set of scan-target searchPaths whose records the user wants to see in
    /// the catalog table. Derived from `selectedVolumeIDs` so that selecting
    /// a volume row (single-click) filters the catalog to that volume, and
    /// multi-select (Cmd-click or Shift-click) expands the filter. Empty
    /// selection = show all volumes.
    private var filterTargetPaths: Set<String> {
        Set(selectedVolumeIDs.compactMap { target(for: $0)?.searchPath })
    }
    /// The searchPath of the volume containing the currently selected file.
    /// Used to highlight the matching volume row in the Scan Targets pane.
    @State private var highlightedTargetPath: String = ""
    /// Volume Options filter — controls which scan targets are visible.
    @State private var volumeFilters: Set<VolumeFilter> = [.allScanned]
    @State private var showDeleteAllCatalogConfirm = false
    @State private var showDeleteVolumeCatalogConfirm = false
    @State private var deleteVolumeCatalogTarget: CatalogScanTarget?
    /// Selected volume IDs in the scan volumes table.
    @State private var selectedVolumeIDs: Set<UUID> = []
    /// Per-volume aggregate cache (file count, error count, byte sum,
    /// pre-built Cmd+I popover text). Recomputed once per records or
    /// scan-target change via the `.onChange` modifiers below. Without
    /// this cache, `volumeTableRows` triple-walked the full ~13K record
    /// catalog for every visible target on every SwiftUI body re-eval —
    /// every click of a volume row caused ~620K iterations on the main
    /// thread, racing NSTableView's selection visuals and producing
    /// the "highlight sometimes appears, sometimes doesn't" lag.
    @State private var volumeAggregateCache: [UUID: VolumeAggregate] = [:]
    /// Sort order for the Scan Volumes table. Defaults to volume-name
    /// ascending, which matches the historical implicit ordering. Bound
    /// to the Table via `Table(_:selection:sortOrder:)` so column-header
    /// clicks rotate through ascending → descending → none.
    @State private var volumeTableSortOrder: [KeyPathComparator<VolumeRow>] = [
        KeyPathComparator(\VolumeRow.name)
    ]
    /// True when the user clicked Hide on the Migrate progress sheet to
    /// suppress it without canceling the in-flight job — lets them queue
    /// another volume. Auto-resets when `isRelocateActivelyWorking` flips
    /// back to false (run ends), so the next queued job's progress sheet
    /// appears automatically.
    @State private var progressSheetHiddenByUser: Bool = false
    /// Caption Videos orchestration state. Lifted to app level so the
    /// separate Dossier Dashboard window observes the same in-flight
    /// state — see VideoScanApp's @StateObject.
    @EnvironmentObject var captionOrchestrator: CaptionOrchestrator
    @State private var showCaptionProgress = false
    /// Opens an independent resizable window keyed by CatalogInfoItem value.
    /// Defined as a `WindowGroup(for:)` scene in VideoScanApp.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VerticalSplitView(
            topMinHeight: 60,
            topIdealHeight: scanTargetsPaneAutoHeight,
            topMaxHeight: 400,
            top: {
                scanTargetsPane
            },
            bottom: {
                VStack(spacing: 0) {

            // MARK: Toolbar (post-scan actions)
            CatalogToolbar(
                isScanning: model.isScanning,
                isCombining: model.isCombining,
                isCorrelating: model.isCorrelating,
                isAnalyzingDuplicates: model.isAnalyzingDuplicates,
                correlateStatus: model.correlateStatus,
                duplicateStatus: model.duplicateStatus,
                videoOnlyCount: model.records.filter { $0.streamType == .videoOnly }.count,
                audioOnlyCount: model.records.filter { $0.streamType == .audioOnly }.count,
                hasRecords: !model.records.isEmpty,
                hasCorrelatedPairs: !model.correlatedPairs.isEmpty,
                outputCSVPath: model.outputCSVPath,
                selectedIDs: selectedIDs,
                showCombineSheet: $showCombineSheet,
                showRelocateSheet: $showRelocateSheet,
                showDashboard: $showDashboard,
                searchText: $searchText,
                showInspector: $showInspector,
                cacheCount: model.cacheCount,
                dashboard: model.dashboard,
                onStopCombine: { model.stopCombine() },
                onCorrelateAll: {
                    model.log("\nCorrelating all audio-only and video-only files...")
                    model.correlate()
                },
                onCorrelateSelected: {
                    model.log("\nCorrelating \(selectedIDs.count) selected files...")
                    model.correlate(selectedIDs: selectedIDs)
                },
                onCorrelateAcrossVolumes: {
                    model.log("\n━━ Finding Avid A/V pairs across all volumes ━━")
                    model.correlateAcrossVolumes()
                },
                onAnalyzeDuplicatesAll: {
                    model.log("\nAnalyzing duplicate candidates across all scanned media...")
                    model.analyzeDuplicates()
                },
                onAnalyzeDuplicatesSelected: {
                    model.log("\nAnalyzing duplicate candidates in \(selectedIDs.count) selected files...")
                    model.analyzeDuplicates(selectedIDs: selectedIDs)
                },
                volumesWithDeletableDups: model.volumesWithDeletableDuplicates(),
                onDeleteDuplicates: { path, count in
                    deleteTargetVolume = path
                    deleteTargetCount = count
                    showDeleteDuplicatesConfirm = true
                },
                onClearResults: { model.clearResults() },
                onClearCache: { _ = model.clearCache() },
                onScanAvidBins: { model.scanAvidBins() },
                avidBinCount: model.avidBinResults.reduce(0) { $0 + $1.clips.count },
                avidBinFiles: model.avidBinResults.count,
                showPairsOnly: $showPairsOnly,
                viewFilters: $catalogViewFilters,
                showRemoved: $showRemoved,
                dashboardContent: {
                    if model.isScanning || model.isCombining {
                        CompactDashboard(
                            dashboard: model.dashboard,
                            isScanning: model.isScanning,
                            isCombining: model.isCombining,
                            isExpanded: $showDashboard
                        )
                        .popover(isPresented: $showDashboard, arrowEdge: .bottom) {
                            ExpandedDashboard(
                                dashboard: model.dashboard,
                                isScanning: model.isScanning,
                                isCombining: model.isCombining
                            )
                        }
                    }
                }
            )

            Divider()

            // MARK: Split — Table + Player left, Inspector right
            CatalogContent(
                records: model.records,
                selectedIDs: $selectedIDs,
                sortOrder: $sortOrder,
                searchText: searchText,
                filterTargetPaths: filterTargetPaths,
                showPairsOnly: showPairsOnly,
                viewFilters: catalogViewFilters,
                showRemoved: showRemoved,
                filterByIDs: filterByIDs,
                focusMatchScore: focusMatchScore,
                previewImage: model.previewImage,
                previewFilename: model.previewFilename,
                previewOfflineVolumeName: model.previewOfflineVolumeName,
                showInspector: $showInspector,
                onSort: { model.records.sort(using: $0) },
                onSelect: { id in
                    if let rec = model.records.first(where: { $0.id == id }),
                       rec.streamType == .videoOnly || rec.streamType == .videoAndAudio {
                        model.generateThumbnail(for: rec)
                    } else {
                        model.previewImage = nil
                        model.previewFilename = ""
                        model.previewOfflineVolumeName = nil
                    }
                },
                onClearPreview: {
                    model.previewImage = nil
                    model.previewFilename = ""
                    model.previewOfflineVolumeName = nil
                },
                onCombinePair: { video, audio in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        combinePairItem = CombinePairItem(video: video, audio: audio)
                    }
                },
                onShowPair: { id1, id2 in
                    searchText = ""
                    selectedVolumeIDs = []
                    showPairsOnly = false
                    filterByIDs = [id1, id2]
                    selectedIDs = [id1, id2]
                    focusMatchScore = nil
                },
                onFindAVPair: { rec in
                    findAVPairFocus(for: rec)
                },
                onClearFilter: {
                    filterByIDs = []
                    focusMatchScore = nil
                },
                onShowInArchive: { rec in
                    model.focusedMediaIDs = model.focusSet(for: rec.id)
                    model.pendingArchiveSelection = rec.id
                    selectedTab = 2
                }
            )
            .onChange(of: selectedIDs) {
                // Update volume highlight when table selection changes
                if let id = selectedIDs.first,
                   let rec = model.records.first(where: { $0.id == id }) {
                    let path = rec.fullPath
                    highlightedTargetPath = model.scanTargets
                        .first(where: { !$0.searchPath.isEmpty && path.hasPrefix($0.searchPath) })?
                        .searchPath ?? ""
                } else {
                    highlightedTargetPath = ""
                }
            }
            .onAppear {
                handlePendingCatalogNavigation()
                restoreFocusedMedia()
            }
            .onChange(of: model.pendingCatalogSelection) { handlePendingCatalogNavigation() }
            // Clear the ID filter and focus when user types in search or selects a volume
            .onChange(of: searchText) {
                if !searchText.isEmpty { filterByIDs = []; focusMatchScore = nil; model.focusedMediaIDs = [] }
            }
            .onChange(of: selectedVolumeIDs) {
                if !selectedVolumeIDs.isEmpty { filterByIDs = []; focusMatchScore = nil; model.focusedMediaIDs = [] }
            }
                }  // end bottom VStack
            }  // end VerticalSplitView
        )
        .sheet(isPresented: $showCombineSheet) {
            CombineSheet(selectedIDs: selectedIDs)
        }
        .sheet(isPresented: $showRelocateSheet) {
            RelocateSheet()
        }
        // In-flight progress — autostarts when isRelocating flips true,
        // dismisses when the run completes (after the model's min-800ms
        // visibility pad). Summary sheet pops in its place.
        // Binding is read-only (the model owns the flag); setter is a
        // no-op so a stray dismiss gesture can't desync the UI from the
        // engine. The engine clears the flag itself when runRelocate
        // returns.
        .sheet(isPresented: Binding(
            get: { model.isRelocateActivelyWorking && !progressSheetHiddenByUser },
            set: { newValue in
                if !newValue { progressSheetHiddenByUser = true }
            }
        )) {
            RelocateProgressSheet(
                dashboard: model.dashboard,
                onHide: { progressSheetHiddenByUser = true }
            )
                .environmentObject(model)
        }
        .onChange(of: model.isRelocateActivelyWorking) { _, working in
            // Reset the suppression flag when work stops, so the next
            // queued job's progress sheet appears automatically.
            if !working { progressSheetHiddenByUser = false }
        }
        // Post-Apply summary. Set by runRelocate AFTER the work
        // completes (real run OR dry-run). The Done button calls
        // `model.acknowledgeRelocateSummary()`, which is the single
        // trigger that fires the §1B retire offer — so the user is
        // never rushed into Retire without seeing this sheet first.
        .sheet(item: $model.pendingRelocateSummary) { summary in
            RelocateSummarySheet(summary: summary)
                .environmentObject(model)
        }
        // §1B Retire Volume — surfaces automatically after a Relocate
        // run that leaves 100% of the source volume's records marked
        // .manuallyDeleted, AND only after the post-Apply summary has
        // been acknowledged. See docs/relocate_volume_plan.md §1B.
        .sheet(item: $model.pendingRetireOffer) { offer in
            RelocateRetireSheet(offer: offer)
        }
        .sheet(item: $combinePairItem) { item in
            CombinePairSheet(originalVideo: item.video, originalAudio: item.audio)
        }
        .alert("Delete Duplicates", isPresented: $showDeleteDuplicatesConfirm) {
            Button("Delete \(deleteTargetCount) Files", role: .destructive) {
                model.deleteDuplicates(onVolume: deleteTargetVolume)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently delete \(deleteTargetCount) high-confidence duplicate(s) on:\n\n\(deleteTargetVolume)\n\nOnly duplicates whose keeper is also on this same volume will be deleted. Cross-volume duplicates are never touched.\n\nAre you sure? Do you have backups and/or are these really junk or duplicates?")
        }
        .sheet(isPresented: $showDiscoverVolumes) {
            DiscoverVolumesSheet(model: model)
        }
        .sheet(isPresented: $showVolumeCompare) {
            VolumeCompareSheet(model: model)
        }
        .sheet(isPresented: $showCaptionProgress) {
            CaptionProgressSheet(
                orchestrator: captionOrchestrator,
                isPresented: $showCaptionProgress
            )
        }
        .alert("Delete Catalog", isPresented: $showDeleteAllCatalogConfirm) {
            Button("Delete All", role: .destructive) {
                model.deleteAllCatalog()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will delete all \(model.records.count) catalog records across every volume. The probe cache is unaffected.\n\nAre you sure?")
        }
        .alert("Clean up unscanned scan targets?", isPresented: $showCleanupUnscannedConfirm) {
            Button("Remove", role: .destructive) {
                let removed = model.cleanupUnscannedTargets()
                model.log("User confirmed cleanup of \(removed) unscanned scan target(s)")
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            let count = model.unscannedTargetCount
            Text("Remove \(count) scan target\(count == 1 ? "" : "s") that have never been scanned? You can always re-add them later via Add Scan Target. Existing catalog records are not affected.")
        }
        .alert("Delete Volume Catalog", isPresented: $showDeleteVolumeCatalogConfirm) {
            Button("Delete", role: .destructive) {
                if let target = deleteVolumeCatalogTarget {
                    model.deleteCatalogForTarget(target)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let target = deleteVolumeCatalogTarget {
                let count = model.records.filter { $0.fullPath.hasPrefix(target.searchPath) || ($0.originalFullPath?.hasPrefix(target.searchPath) ?? false) }.count
                Text("Delete \(count) catalog record(s) for \(VolumeReachability.displayLabel(forPath: target.searchPath))?\n\nThe probe cache is unaffected — a re-scan will replay quickly from cache.")
            } else {
                Text("Delete catalog records for this volume?")
            }
        }
        .alert(
            model.missingDependency?.alertTitle ?? "Missing Dependency",
            isPresented: Binding(
                get: { model.missingDependency != nil },
                set: { if !$0 { model.missingDependency = nil } }
            ),
            presenting: model.missingDependency
        ) { dep in
            Button("Copy Install Command") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(dep.installHint, forType: .string)
            }
            Button("OK", role: .cancel) { }
        } message: { dep in
            Text(dep.alertMessage)
        }
    }

    // MARK: - Find A/V Pair (on-demand single-file pair search)

    /// Right-click "Find A/V Pair" handler. Builds a focus set in the catalog
    /// containing the selected file + its online duplicates + the best pair
    /// candidate + that pair's online duplicates. Stays cross-volume so offline
    /// pairs surface their online copies as alternates.
    private func findAVPairFocus(for rec: VideoRecord) {
        searchText = ""
        selectedVolumeIDs = []
        showPairsOnly = false

        let durationTolerance: Double = 1.0
        let timestampTolerance: TimeInterval = 5.0

        var partner: VideoRecord?
        var score: Int?

        if let existing = rec.pairedWith {
            partner = existing
            score = rec.pairConfidence.map { conf in
                switch conf {
                case .high: return 8
                case .medium: return 5
                case .low: return 3
                }
            }
        } else if let cand = CorrelationScorer.findBestPair(
            for: rec,
            in: model.records,
            durationTolerance: durationTolerance,
            timestampTolerance: timestampTolerance
        ) {
            partner = (rec.streamType == .videoOnly) ? cand.audio : cand.video
            score = cand.score
        }

        guard let pair = partner else {
            let alert = NSAlert()
            alert.messageText = "No A/V Pair Found"
            alert.informativeText = "No matching \(rec.streamType == .videoOnly ? "audio" : "video")-only file scored highly enough against:\n\n\(rec.filename)"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        var ids: Set<UUID> = [rec.id, pair.id]
        if let g = rec.duplicateGroupID {
            for r in model.records where r.duplicateGroupID == g { ids.insert(r.id) }
        }
        if let g = pair.duplicateGroupID {
            for r in model.records where r.duplicateGroupID == g { ids.insert(r.id) }
        }

        focusMatchScore = score
        filterByIDs = ids
        selectedIDs = [rec.id]
    }

    // MARK: - Archive → Catalog Navigation

    private func handlePendingCatalogNavigation() {
        guard let id = model.pendingCatalogSelection else { return }
        let pairMode = model.pendingCatalogPairMode
        model.pendingCatalogSelection = nil
        model.pendingCatalogPairMode = false

        // Clear other filters so filterByIDs takes full effect
        selectedVolumeIDs = []
        searchText = ""
        showPairsOnly = false

        let ids = VideoScanModel.catalogFilterIDs(for: id, pairMode: pairMode, in: model.records)
        filterByIDs = ids
        focusMatchScore = nil
        selectedIDs = ids
        model.focusedMediaIDs = model.focusSet(for: id)
        // Generate thumbnail
        if let rec = model.records.first(where: { $0.id == id }),
           rec.streamType == .videoOnly || rec.streamType == .videoAndAudio {
            model.generateThumbnail(for: rec)
        }
    }

    private func restoreFocusedMedia() {
        guard model.pendingCatalogSelection == nil,
              !model.focusedMediaIDs.isEmpty else { return }
        selectedVolumeIDs = []
        searchText = ""
        showPairsOnly = false
        filterByIDs = model.focusedMediaIDs
        focusMatchScore = nil
        selectedIDs = model.focusedMediaIDs
    }

    // MARK: - Volume Filter Helpers

    private func toggleVolumeFilter(_ filter: VolumeFilter) {
        if filter == .allScanned {
            // "All Ever Scanned" also restores catalog-only volumes
            let count = model.restoreTargetsFromCatalog()
            if count > 0 {
                model.log("Restored \(count) volume(s) from catalog history.")
            }
        }
        if volumeFilters.contains(filter) {
            volumeFilters.remove(filter)
        } else {
            volumeFilters.insert(filter)
        }
        // If nothing is checked, default back to All Scanned
        if volumeFilters.isEmpty {
            volumeFilters = [.allScanned]
        }
    }

    /// Open the Catalog Info window for a given target. Shared by the
    /// right-click menu Button and the Cmd-I global shortcut. Window identity
    /// is the volume path, so repeat invocations focus the existing window
    /// rather than stacking duplicates.
    private func showCatalogInfo(for target: CatalogScanTarget) {
        let volName = VolumeReachability.displayLabel(forPath: target.searchPath)
        let recs = model.records.filter { $0.fullPath.hasPrefix(target.searchPath) || ($0.originalFullPath?.hasPrefix(target.searchPath) ?? false) }
        let item = CatalogInfoItem(
            volumePath: target.searchPath,
            title: "Catalog Info — \(volName)",
            message: Self.buildCatalogInfo(records: recs, target: target)
        )
        openWindow(value: item)
    }

    /// Cmd-I handler: resolves the volume-table selection to a target and
    /// opens Catalog Info. Requires exactly one row selected.
    private func showCatalogInfoForSelection() {
        guard selectedVolumeIDs.count == 1,
              let id = selectedVolumeIDs.first,
              let t = target(for: id) else { return }
        showCatalogInfo(for: t)
    }

    /// Single-window "Catalog Info" builder: combines provenance (where/when/
    /// how the catalog was captured — from ScanContext) with the catalog
    /// content summary (counts, sizes, codecs, errors). Sections are separated
    /// by bold rules so the resizable sheet reads like a printable report.
    static func buildCatalogInfo(records: [VideoRecord], target: CatalogScanTarget) -> String {
        guard !records.isEmpty else { return "No catalog data for this volume." }
        let rule = String(repeating: "━", count: 48)
        var lines: [String] = []
        lines.append(contentsOf: catalogInfoProvenanceLines(records: records, target: target, rule: rule))
        lines.append(contentsOf: catalogInfoSummaryLines(records: records, target: target, rule: rule))
        lines.append(contentsOf: catalogInfoErrorLines(records: records))
        return lines.joined(separator: "\n")
    }

    /// Section 1 — PROVENANCE: where/when/how the catalog was captured.
    private static func catalogInfoProvenanceLines(
        records: [VideoRecord],
        target: CatalogScanTarget,
        rule: String
    ) -> [String] {
        let populated = records.filter { $0.scanContext.isPopulated }
        let unpopulated = records.count - populated.count
        var lines: [String] = [
            rule,
            "  PROVENANCE",
            rule,
            "Volume Path: \(target.searchPath)",
            "Records: \(records.count) (with provenance: \(populated.count), without: \(unpopulated))"
        ]
        guard !populated.isEmpty else {
            lines.append("")
            lines.append("No scan-provenance data has been captured yet.")
            lines.append("Rescan this volume to populate scan host, mount type,")
            lines.append("volume UUID, and remote-server fields.")
            return lines
        }

        let hosts       = Set(populated.map { $0.scanContext.scanHost }.filter { !$0.isEmpty })
        let mountTypes  = Set(populated.map { $0.scanContext.volumeMountType }.filter { !$0.isEmpty })
        let uuids       = Set(populated.map { $0.scanContext.volumeUUID }.filter { !$0.isEmpty })
        let remoteHosts = Set(populated.map { $0.scanContext.remoteServerName }.filter { !$0.isEmpty })

        lines.append("Scanned By: \(hosts.isEmpty ? "(unknown)" : hosts.sorted().joined(separator: ", "))")
        lines.append("Mount Type: \(mountTypes.isEmpty ? "(unknown)" : mountTypes.sorted().joined(separator: ", "))")
        if !remoteHosts.isEmpty {
            lines.append("Remote Server: \(remoteHosts.sorted().joined(separator: ", "))")
        }
        if uuids.isEmpty {
            lines.append("Volume UUID: (none — filesystem did not vend one)")
        } else if let onlyUUID = uuids.first, uuids.count == 1 {
            lines.append("Volume UUID: \(onlyUUID)")
        } else {
            lines.append("Volume UUID: \(uuids.count) distinct UUIDs seen:")
            for u in uuids.sorted() { lines.append("  \(u)") }
        }

        let scanDates = populated.compactMap { $0.scanContext.scannedAt }
        if let earliest = scanDates.min(), let latest = scanDates.max() {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            if earliest == latest {
                lines.append("Scan Time: \(fmt.string(from: earliest))")
            } else {
                lines.append("Scan Time Range: \(fmt.string(from: earliest)) → \(fmt.string(from: latest))")
            }
        }

        if unpopulated > 0 {
            lines.append("")
            lines.append("Note: \(unpopulated) record(s) predate provenance capture — rescan to backfill.")
        }
        return lines
    }

    /// Section 2 — CATALOG SUMMARY: counts, sizes, codecs, extensions, etc.
    private static func catalogInfoSummaryLines(
        records: [VideoRecord],
        target: CatalogScanTarget,
        rule: String
    ) -> [String] {
        let totalBytes = records.reduce(into: Int64(0)) { $0 += $1.sizeBytes }
        let va = records.filter { $0.streamType == .videoAndAudio }.count
        let vo = records.filter { $0.streamType == .videoOnly }.count
        let ao = records.filter { $0.streamType == .audioOnly }.count
        let noStreams = records.filter { $0.streamType == .noStreams }.count

        let catBytes = records.count * 2048
        let catSize = catBytes < 1_048_576
            ? String(format: "%.0f KB", Double(catBytes) / 1024)
            : String(format: "%.1f MB", Double(catBytes) / 1_048_576)
        let mediaSize = totalBytes < 1_073_741_824
            ? String(format: "%.1f MB", Double(totalBytes) / 1_048_576)
            : String(format: "%.1f GB", Double(totalBytes) / 1_073_741_824)

        let codecs = Set(records.compactMap { $0.videoCodec.isEmpty ? nil : $0.videoCodec })
        let containers = Set(records.compactMap { $0.container.isEmpty ? nil : $0.container })
        let resolutions = Set(records.compactMap { $0.resolution.isEmpty ? nil : $0.resolution })
        let audioCodecs = Set(records.compactMap { $0.audioCodec.isEmpty ? nil : $0.audioCodec })

        let totalDuration = records.reduce(0.0) { $0 + $1.durationSeconds }
        let hours = Int(totalDuration) / 3600
        let mins = (Int(totalDuration) % 3600) / 60
        let durationStr = hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"

        let extCounts = Dictionary(grouping: records, by: { $0.ext.lowercased() })
            .mapValues { $0.count }
            .sorted { $0.value > $1.value }
            .prefix(8)
            .map { "\($0.key) (\($0.value))" }

        var lines: [String] = [
            "",
            rule,
            "  CATALOG SUMMARY",
            rule,
            "Files: \(records.count)",
            "Total Duration: \(durationStr)",
            "Media Size: \(mediaSize)",
            "Catalog Size: \(catSize)"
        ]
        if let date = target.lastScannedDate {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            lines.append("Last Scanned: \(fmt.string(from: date))")
        }

        lines.append("")
        lines.append("— Stream Types —")
        lines.append("Video + Audio: \(va)")
        lines.append("Video Only: \(vo)")
        lines.append("Audio Only: \(ao)")
        if noStreams > 0 { lines.append("No Streams: \(noStreams)") }

        if !extCounts.isEmpty {
            lines.append("")
            lines.append("— File Types —")
            lines.append(extCounts.joined(separator: ", "))
        }
        if !codecs.isEmpty {
            lines.append("")
            lines.append("— Video Codecs —")
            lines.append(codecs.sorted().joined(separator: ", "))
        }
        if !audioCodecs.isEmpty {
            lines.append("— Audio Codecs —")
            lines.append(audioCodecs.sorted().joined(separator: ", "))
        }
        if !containers.isEmpty {
            lines.append("— Containers —")
            lines.append(containers.sorted().joined(separator: ", "))
        }
        if !resolutions.isEmpty {
            lines.append("— Resolutions —")
            lines.append(resolutions.sorted().joined(separator: ", "))
        }
        return lines
    }

    /// Section 3 — ERRORS: grouped failure reasons + example filenames.
    private static func catalogInfoErrorLines(records: [VideoRecord]) -> [String] {
        let failedRecs = records.filter { $0.streamType == .ffprobeFailed }
        guard !failedRecs.isEmpty else { return [] }

        var lines: [String] = [
            "",
            "— Errors (\(failedRecs.count)) —"
        ]

        // Group by error reason (from isPlayable + notes)
        var reasonCounts: [String: Int] = [:]
        for rec in failedRecs {
            let reason: String
            if !rec.notes.isEmpty {
                reason = String(rec.notes.prefix(80))
            } else if !rec.isPlayable.isEmpty {
                reason = rec.isPlayable
            } else {
                reason = "Unknown error"
            }
            reasonCounts[reason, default: 0] += 1
        }
        for (reason, count) in reasonCounts.sorted(by: { $0.value > $1.value }).prefix(10) {
            lines.append("  \(count)x  \(reason)")
        }

        let examples = failedRecs.prefix(5).map { $0.filename }
        lines.append("")
        lines.append("Example files:")
        for name in examples {
            lines.append("  \(name)")
        }
        if failedRecs.count > 5 {
            lines.append("  … and \(failedRecs.count - 5) more")
        }
        return lines
    }

    /// Build VolumeRow values from filtered scan targets for the Table.
    private var volumeTableRows: [VolumeRow] {
        // Snapshot global activity flags once per table redraw so every row
        // computes its `uiStatus` against the same instant. Without the
        // snapshot a model update mid-loop could flip the meaning of
        // adjacent rows. (Cheap — these are scalar reads.)
        let isCombining = model.isCombining
        let isBackfilling = model.isBackfillingProvenance
        let verifyingIDs = model.verifyingTargetIDs

        let rows = filteredScanTargets.map { target in
            // Pull the file/byte/error/Cmd+I aggregate from the cache. On
            // a cache miss (cold start before the first refresh fires, or
            // a target added since the last refresh) we serve a zeroed
            // placeholder — the next `.onChange` trigger populates it.
            // O(1) per row vs the old O(records) filter.
            let agg = volumeAggregateCache[target.id]
            let isNet = VolumeReachability.isNetworkVolume(path: target.searchPath)

            // Per-target progress, if scan tracking has populated counts.
            // 0/0 → nil (discovery phase), else clamped to 0…1.
            let progress: Double?
            if target.filesFound > 0 {
                progress = min(1.0, Double(target.filesScanned) / Double(target.filesFound))
            } else {
                progress = nil
            }

            let uiStatus = VolumeUIStatus.compute(VolumeUIStatusInputs(
                mountReachable: target.isReachable,
                targetStatus: target.status,
                isCombining: isCombining,
                isBackfilling: isBackfilling,
                isVerifyingThisVolume: verifyingIDs.contains(target.id),
                scanProgress: progress
            ))

            return VolumeRow(
                id: target.id,
                name: VolumeReachability.displayLabel(forPath: target.searchPath),
                path: target.searchPath,
                status: target.status,
                uiStatus: uiStatus,
                files: agg?.files ?? 0,
                errors: agg?.errors ?? 0,
                mediaBytes: agg?.mediaBytes ?? 0,
                phase: target.phase,
                lastScanned: target.lastScannedDate,
                isReachable: target.isReachable,
                isNetwork: isNet,
                catalogStatusText: agg?.catalogStatusText ?? "Loading catalog data…",
                role: target.role,
                trust: target.trust
            )
        }
        // Apply the user-controlled sort. KeyPathComparator is cheap for
        // ~15 rows; no need to memoize. Empty sort order falls back to
        // the natural map order from filteredScanTargets.
        return volumeTableSortOrder.isEmpty
            ? rows
            : rows.sorted(using: volumeTableSortOrder)
    }

    /// Walk the catalog once and bucket records into each volume's
    /// aggregate. Replaces the per-row O(records) filters that used to
    /// dominate `volumeTableRows`. Single pass over `model.records`,
    /// per-record prefix check against every scan target — total work
    /// O(records × targets), done once per records-changed trigger
    /// rather than once per render.
    ///
    /// A record can belong to BOTH the volume it currently lives on AND
    /// the volume it originated from (Bucket-A copy / Bucket-D adoption
    /// rewrites `fullPath` but preserves `originalFullPath`). That
    /// matches the historical filter semantics — the Volumes table
    /// counted those records on the source volume even after migration
    /// — so we preserve the double-count.
    private func recomputeVolumeAggregates() {
        let targets = model.scanTargets
        guard !targets.isEmpty else {
            volumeAggregateCache = [:]
            return
        }
        // Sort prefixes longest-first so nested target paths
        // (e.g. /Volumes/MyBook AND /Volumes/MyBook/Sub) both match
        // correctly — `hasPrefix` is greedy on this side anyway, but the
        // sort keeps semantics explicit.
        let entries: [(id: UUID, target: CatalogScanTarget, prefix: String)] = targets
            .sorted { $0.searchPath.count > $1.searchPath.count }
            .map { ($0.id, $0, $0.searchPath) }
        var buckets: [UUID: [VideoRecord]] = [:]
        buckets.reserveCapacity(entries.count)
        for r in model.records {
            for e in entries {
                if r.fullPath.hasPrefix(e.prefix)
                    || (r.originalFullPath?.hasPrefix(e.prefix) ?? false) {
                    buckets[e.id, default: []].append(r)
                }
            }
        }
        var built: [UUID: VolumeAggregate] = [:]
        built.reserveCapacity(entries.count)
        for e in entries {
            let recs = buckets[e.id] ?? []
            let errCount = recs.reduce(into: 0) { acc, r in
                if r.streamType == .ffprobeFailed { acc += 1 }
            }
            let bytes = recs.reduce(into: Int64(0)) { $0 += $1.sizeBytes }
            built[e.id] = VolumeAggregate(
                files: recs.count,
                errors: errCount,
                mediaBytes: bytes,
                catalogStatusText: Self.buildCatalogInfo(records: recs, target: e.target)
            )
        }
        volumeAggregateCache = built
    }

    /// Look up the CatalogScanTarget for a VolumeRow ID.
    private func target(for id: UUID) -> CatalogScanTarget? {
        model.scanTargets.first { $0.id == id }
    }

    private func browsePath(for target: CatalogScanTarget) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a volume or folder to scan"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            target.searchPath = url.path
        }
    }

    /// Strict-catalog policy predicate. A target counts as "scanned" if either:
    ///   - it has a successful `lastScannedDate`, OR
    ///   - it isn't idle (currently scanning, paused mid-scan, waiting for the
    ///     volume to come back, etc. — i.e. real work in flight).
    /// Note: `CatalogTargetStatus.isIdle` is `true` for `.idle` and
    /// `.resumable`. A resumable target with no last-scan date is treated as
    /// unscanned here — that's intentional, it matches the cleanup predicate
    /// in `VideoScanModel.isUnscannedRemovable`.
    private func hasBeenScanned(_ t: CatalogScanTarget) -> Bool {
        if t.lastScannedDate != nil { return true }
        if !t.status.isIdle { return true }
        return false
    }

    /// Targets that pass the current Volume Options filters.
    /// Always hides the RAM disk (VideoScan_Temp). Also hides "never scanned"
    /// targets unless `showUnscannedTargets` is on — strict-catalog policy.
    private var filteredScanTargets: [CatalogScanTarget] {
        let base = model.scanTargets.filter {
            !$0.searchPath.contains("VideoScan_Temp")
        }

        // Strict-catalog default: hide targets that have never been scanned.
        // The user can flip the toggle to see the full list (useful right
        // after adding new targets that haven't been scanned yet).
        let scopedToScanned = showUnscannedTargets
            ? base
            : base.filter { hasBeenScanned($0) }

        // "All Ever Scanned" = show everything within the strict-catalog scope,
        // no further user-filter narrowing.
        if volumeFilters.contains(.allScanned) {
            return scopedToScanned
        }

        return scopedToScanned.filter { target in
            let path = target.searchPath
            let hasRecords = model.records.contains { $0.fullPath.hasPrefix(path) }
            let hasBadFiles = model.records.contains {
                $0.fullPath.hasPrefix(path) && $0.streamTypeRaw == StreamType.ffprobeFailed.rawValue
            }
            let isNetwork = VolumeReachability.isNetworkVolume(path: path)

            // Target passes if ANY active filter matches
            for filter in volumeFilters {
                switch filter {
                case .connected:
                    if target.isReachable { return true }
                case .network:
                    if isNetwork { return true }
                case .allScanned:
                    return true // handled above
                case .uncataloged:
                    if !hasRecords && target.isReachable { return true }
                case .withErrors:
                    if hasBadFiles { return true }
                }
            }
            return false
        }
    }

    // MARK: - Scan Targets Pane (matches PersonFinder's jobsSection pattern)

    private var scanTargetsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.title3).foregroundColor(.secondary)
                Text("Scan Volumes")
                    .font(.title3.weight(.semibold))
                    .padding(.trailing, 12)

                Button(action: { model.addScanTarget() }) {
                    Label("Local Volumes…", systemImage: "internaldrive")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: { showDiscoverVolumes = true }) {
                    Label("Network Volumes…", systemImage: "network")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Menu {
                    ForEach(VolumeFilter.allCases, id: \.self) { filter in
                        Button(action: { toggleVolumeFilter(filter) }) {
                            HStack {
                                if volumeFilters.contains(filter) {
                                    Image(systemName: "checkmark")
                                }
                                Label(filter.rawValue, systemImage: filter.icon)
                            }
                        }
                    }
                } label: {
                    Label("View", systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filter which volumes appear in the list")

                // Strict-catalog: hide-by-default + opt-in toggle. Pattern
                // mirrors TriageView's "Online volumes only" switch — small
                // control, AppStorage-backed, lives next to the table it
                // governs.
                Toggle(isOn: $showUnscannedTargets) {
                    Label("Show unscanned", systemImage: "eye")
                        .labelStyle(.titleAndIcon)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Show scan targets that haven't been scanned yet. Off by default — strict catalog view.")

                // One-time cleanup affordance for users whose target list got
                // polluted by the old auto-add-on-mount behavior. Only visible
                // when there's actually something to clean up — mirrors the
                // Delete Junk pattern that only surfaces when count > 0.
                if model.unscannedTargetCount > 0 {
                    Button(role: .destructive, action: {
                        showCleanupUnscannedConfirm = true
                    }) {
                        Label("Clean up unscanned… (\(model.unscannedTargetCount))",
                              systemImage: "trash.slash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Remove scan targets that have never been scanned and aren't currently active. Doesn't touch catalog records.")
                }

                Menu {
                    Section("Scan") {
                        Button(action: { model.startAllTargets() }) {
                            Label("Scan All Volumes", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.scanTargets.isEmpty)

                        ForEach(model.scanTargets.filter { $0.status.isIdle && $0.isReachable && !$0.searchPath.contains("VideoScan_Temp") && !$0.isRetired }) { target in
                            Button(action: {
                                if target.status == .resumable {
                                    model.resumeTarget(target)
                                } else {
                                    model.startTarget(target)
                                }
                            }) {
                                Label(VolumeReachability.displayLabel(forPath: target.searchPath),
                                      systemImage: target.status == .resumable ? "arrow.clockwise" : "play.fill")
                            }
                        }
                    }

                    Section("Delete") {
                        ForEach(model.scanTargets.filter { target in
                            model.records.contains { $0.fullPath.hasPrefix(target.searchPath) || ($0.originalFullPath?.hasPrefix(target.searchPath) ?? false) }
                        }) { target in
                            let count = model.records.filter { $0.fullPath.hasPrefix(target.searchPath) || ($0.originalFullPath?.hasPrefix(target.searchPath) ?? false) }.count
                            Button(role: .destructive, action: {
                                deleteVolumeCatalogTarget = target
                                showDeleteVolumeCatalogConfirm = true
                            }) {
                                Label("\(VolumeReachability.displayLabel(forPath: target.searchPath)) (\(count))",
                                      systemImage: "trash")
                            }
                        }

                        Divider()

                        Button(role: .destructive, action: {
                            showDeleteAllCatalogConfirm = true
                        }) {
                            Label("Delete All (\(model.records.count))", systemImage: "trash.fill")
                        }
                        .disabled(model.records.isEmpty)
                    }
                } label: {
                    Label("Catalog Options", systemImage: "doc.text.magnifyingglass")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Update or delete catalog data")

                ScanOptionsMenu(model: model)

                Button(action: { showVolumeCompare = true }) {
                    Label("Compare", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Compare two volumes — show what's unique to the source volume (would be lost if it died). Read-only audit; rescue/copy happens from inside the sheet.")

                Spacer().frame(minWidth: 20)

                backupStatusBadge

                Spacer().frame(minWidth: 8)

                Button(action: { model.startAllTargets() }) {
                    Label("Scan All", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.scanTargets.isEmpty || model.scanTargets.allSatisfy { $0.status.isActive })

                Button(action: {
                    if model.hasPausedTargets { model.resumeAllTargets() } else { model.pauseAllTargets() }
                }) {
                    Label(model.hasPausedTargets ? "Resume All" : "Pause All",
                          systemImage: model.hasPausedTargets ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!model.hasActiveTargets && !model.hasPausedTargets)

                Button(action: { model.stopAllTargets() }) {
                    Label("Stop All Scanning", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!model.hasActiveTargets)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if filteredScanTargets.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: model.scanTargets.isEmpty ? "externaldrive.badge.plus" : "line.3.horizontal.decrease.circle")
                        .font(.largeTitle).foregroundColor(.secondary)
                    Text(model.scanTargets.isEmpty ? "No scan volumes yet" : "No volumes match current filters")
                        .font(.headline).foregroundColor(.secondary)
                    Text(model.scanTargets.isEmpty
                         ? "Add volumes manually or use Discover to find mounted drives."
                         : "Try adjusting View filters to see more volumes.")
                        .font(.callout).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            } else {
                volumeTable
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .background(
            // Hidden button gives Cmd-I a global binding on the scan-volumes
            // pane — the context-menu Button's shortcut only fires when the
            // menu is actually open, so this mirrors it for the selected row.
            Button("") { showCatalogInfoForSelection() }
                .keyboardShortcut("i", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        // Per-volume aggregate cache refresh triggers. Keep these here on
        // the pane that consumes the cache so a hidden Catalog tab still
        // refreshes its cache on tab switch via `.onAppear`. Count-based
        // triggers cover the dominant change paths (scan completion,
        // record import, scan-target add/remove, purge). In-place
        // mutation paths that change `fullPath` without changing the
        // overall count (Bucket-D adoption) call
        // `notifyVolumeAggregatesStale()` directly — see below.
        .onAppear { recomputeVolumeAggregates() }
        .onChange(of: model.records.count) { recomputeVolumeAggregates() }
        .onChange(of: model.scanTargets.count) { recomputeVolumeAggregates() }
        .onChange(of: model.lastPurgedBatch) { recomputeVolumeAggregates() }
        .onChange(of: model.volumeAggregatesRevision) { recomputeVolumeAggregates() }
    }

    /// Auto-size the volume pane to fit all visible rows (header ~32 + ~30 per row),
    /// capped at 400 so it never swallows the entire window.
    private var scanTargetsPaneAutoHeight: CGFloat {
        let rowCount = CGFloat(volumeTableRows.count)
        return min(400, 32 + rowCount * 30)
    }

    // MARK: - Volume Table

    private var volumeTable: some View {
        Table(volumeTableRows, selection: $selectedVolumeIDs, sortOrder: $volumeTableSortOrder) {
            // Cells are now plain — no per-cell tap gestures. Double-
            // click to open the editor is handled by the Table's
            // `.contextMenu(forSelectionType:menu:primaryAction:)`
            // modifier below (canonical SwiftUI `Table` equivalent of
            // NSTableView.doubleAction, macOS 13+). Single-click
            // selection stays snappy because `primaryAction` is
            // dispatched independently of selection — no gesture-
            // arbiter tap-count window.
            TableColumn("Volume", value: \VolumeRow.name) { row in
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundColor(volumeNameColor(for: row))
                        .lineLimit(1)
                        .help(row.path)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 100, ideal: 150)

            TableColumn("Status") { row in
                // Pill + cycling spinner when a remediation pass is active.
                // See VolumeStatusView.swift / VolumeUIStatus.swift.
                VolumeStatusView(status: row.uiStatus)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 70, ideal: 110)

            TableColumn("Files", value: \VolumeRow.files) { row in
                Text(row.files > 0 ? "\(row.files)" : "—")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 50, ideal: 60)

            TableColumn("Errors") { row in
                Group {
                    if row.errors > 0 {
                        Text("\(row.errors)")
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundColor(.red)
                    } else {
                        Text("—")
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 50, ideal: 60)

            TableColumn("Media Size", value: \VolumeRow.mediaBytes) { row in
                Text(row.mediaBytes > 0 ? Self.formatBytesStatic(row.mediaBytes) : "—")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Scanned", value: \VolumeRow.lastScanned, comparator: OptionalDateComparator()) { row in
                Group {
                    if let date = row.lastScanned {
                        Text(Self.shortDateStatic(date))
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else {
                        Text("—")
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 75, ideal: 95)

            TableColumn("Phase") { row in
                HStack(spacing: 4) {
                    if row.status.isActive {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                        Text("In Progress")
                            .font(.system(size: 15, weight: .medium))
                    } else if let t = target(for: row.id), t.isRetired {
                        // §1B Retire — a retired volume still has its
                        // catalog (records carry the safe-witness
                        // dispositions or originVolume backfill); the
                        // underlying `phase` enum can stay at whatever
                        // it was, but the user-facing label should
                        // reflect retirement, not "NO CATALOG". A
                        // checkmark.seal reads as "completed/sealed",
                        // matching the lifecycle stage; system purple
                        // signals "preserved historical record" without
                        // the "warning" weight of orange or the "safe
                        // for active use" weight of green.
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 15))
                        Text("RETIRED")
                            .font(.system(size: 15, weight: .medium))
                    } else {
                        Image(systemName: row.phase.icon)
                            .font(.system(size: 15))
                        Text(row.phase.rawValue)
                            .font(.system(size: 15))
                    }
                }
                .foregroundColor(
                    row.status.isActive
                        ? .orange
                        : (target(for: row.id)?.isRetired == true
                           ? .purple
                           : row.phase.color)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 95, ideal: 115)

            // Role column — shows volume role (Original/Backup/Archive/
            // LTA/etc.) on its own when trust is .reliable or .unknown,
            // and "Role · Trust" when trust is degraded so the user can
            // spot drives that need attention without opening the
            // editor. Trust word inherits VolumeTrust.color so .aging is
            // yellow and .unreliable is red. Sortable on the role's
            // raw value.
            TableColumn("Role", value: \VolumeRow.role.rawValue) { row in
                roleTrustCell(role: row.role, trust: row.trust)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 90, ideal: 130)

            TableColumn("") { row in
                HStack(spacing: 6) {
                    if let t = target(for: row.id) {
                        if t.status.isActive {
                            Button(action: { model.togglePauseTarget(t) }) {
                                Image(systemName: t.status.isPaused ? "play.fill" : "pause.fill")
                                    .font(.system(size: 16))
                            }
                            .buttonStyle(.borderless)
                            .help(t.status.isPaused ? "Resume" : "Pause")

                            Button(action: { model.stopTarget(t) }) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 16))
                            }
                            .buttonStyle(.borderless)
                            .help("Stop Scanning")
                        } else if t.status == .resumable {
                            Button(action: { model.resumeTarget(t) }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 16))
                            }
                            .buttonStyle(.borderless)
                            .disabled(!t.isReachable)
                            .help(t.isReachable ? "Resume interrupted scan" : "Volume offline")
                        } else {
                            Button(action: { model.startTarget(t) }) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 16))
                            }
                            .buttonStyle(.borderless)
                            .disabled(t.searchPath.isEmpty || !t.isReachable)
                            .help(t.isReachable ? "Scan" : "Volume offline")
                        }
                    }
                }
            }
            .width(min: 55, ideal: 70)
        }
        // `primaryAction:` is SwiftUI's canonical equivalent of
        // NSTableView.doubleAction — fires on double-click OR Return
        // when a row is keyboard-focused. Dispatched independently of
        // the Table's selection binding, so single-click selection
        // stays snappy (no gesture-arbiter tap-count window). This
        // replaces the per-cell `.onTapGesture(count: 2)` /
        // `.simultaneousGesture(TapGesture(count: 2))` approaches that
        // both delayed single-click selection by ~250 ms.
        .contextMenu(forSelectionType: UUID.self) { ids in
            volumeContextMenu(for: ids)
        } primaryAction: { ids in
            if let id = ids.first { openVolumesEditor(for: id) }
        }
        .font(.system(size: 14))
    }

    /// Open the Volumes editor window with the given scan target pre-selected.
    /// Mirrors the Volume Roles & Archive… context-menu action (volumeContextVolumeSection)
    /// and the VolumeBadge double-click in ArchiveView. Safe if the id no longer
    /// resolves — VolumesWindow keeps whatever selection it had.
    /// (Swift's `private func` on a struct ≈ a C++ member function with file/class linkage.)
    private func openVolumesEditor(for targetID: UUID) {
        model.pendingVolumesSelectionID = targetID
        openWindow(id: "volumes")
    }

    @ViewBuilder
    private func volumeContextMenu(for ids: Set<UUID>) -> some View {
        let targets = ids.compactMap { id in target(for: id) }
        if let first = targets.first {
            let single = targets.count == 1
            volumeContextCatalogSection(targets: targets, first: first, single: single)
            Divider()
            volumeContextPhaseSection(targets: targets, first: first, single: single)
            Divider()
            volumeContextVolumeSection(targets: targets, first: first, single: single)
        }
    }

    @ViewBuilder
    private func volumeContextCatalogSection(
        targets: [CatalogScanTarget], first: CatalogScanTarget, single: Bool
    ) -> some View {
        Section("Catalog") {
            if single {
                Button(action: { showCatalogInfo(for: first) }) {
                    Label("Catalog Info", systemImage: "info.circle")
                }
                .keyboardShortcut("i", modifiers: .command)
            }
            Button(action: {
                for t in targets where t.status.isIdle && t.isReachable {
                    if t.status == .resumable {
                        model.resumeTarget(t)
                    } else {
                        model.startTarget(t)
                    }
                }
            }) {
                let hasResumable = targets.contains { $0.status == .resumable }
                Label(hasResumable ? "Resume Scan" : (single ? "Scan / Update Catalog" : "Scan Selected"),
                      systemImage: hasResumable ? "arrow.clockwise" : "arrow.clockwise")
            }
            if single {
                Button(action: { model.verifyCatalog(for: first) }) {
                    Label("Verify Catalog", systemImage: "checkmark.shield")
                }
                .disabled(!first.status.isIdle)
            }
            if single {
                // Caption Videos — sibling per-target action to "Find
                // Person" (which lives on the People tab). Runs the VLM
                // captioner over every cataloged video on this volume.
                // Disabled when there are no eligible videos so the
                // user gets a hint rather than a confusing no-op.
                let captionableCount = model.records.filter { r in
                    r.fullPath.hasPrefix(first.searchPath) &&
                    (r.streamType == .videoAndAudio || r.streamType == .videoOnly)
                }.count
                Button(action: {
                    showCaptionProgress = true
                    Task {
                        await captionOrchestrator.startCaptioning(target: first, model: model)
                    }
                }) {
                    Label(
                        captionableCount > 0
                            ? "Caption Videos (\(captionableCount))"
                            : "Caption Videos",
                        systemImage: "text.viewfinder"
                    )
                }
                .disabled(captionableCount == 0 || captionOrchestrator.currentStatus.isActive)
                .help(
                    captionableCount == 0
                        ? "No video files on this volume — nothing to caption"
                        : "Run the vision-language model on every video on this volume to generate scene captions"
                )
            }
            // Catalog-wide caption — sweeps every reachable volume in
            // one go. Idempotent: already-captioned records skip
            // through fast. Roadmap item #4.
            let reachableCaptionable = pfCatalogWideCaptionCandidates(
                pfCatalogWideMetadataCandidates(
                    records: model.records,
                    reachableVolumePaths: model.scanTargets.filter { $0.isReachable && !$0.searchPath.isEmpty }.map { $0.searchPath }
                )
            ).count
            Button(action: {
                showCaptionProgress = true
                Task {
                    await captionOrchestrator.startCatalogWideCaptioning(model: model)
                }
            }) {
                Label(
                    reachableCaptionable > 0
                        ? "Caption All Reachable Volumes (\(reachableCaptionable))"
                        : "Caption All Reachable Volumes",
                    systemImage: "text.viewfinder.rtl"
                )
            }
            .disabled(reachableCaptionable == 0 || captionOrchestrator.currentStatus.isActive)
            .help(
                reachableCaptionable == 0
                    ? "No eligible videos on any reachable volume"
                    : "Run the VLM across every reachable volume — idempotent, can be re-run to pick up new captures"
            )
            // Dossier sweep — three-prompt VLM (date / scene / text)
            // plus Whisper transcription per video, idempotent skip on
            // already-dossiered records. Populates the dossier schema
            // fields (ocrDateCandidates, ocrText, inferredRecordDate)
            // that single-prompt captioning leaves empty.
            Button(action: {
                showCaptionProgress = true
                Task {
                    await captionOrchestrator.startCatalogWideDossier(model: model)
                }
            }) {
                Label(
                    reachableCaptionable > 0
                        ? "Dossier All Reachable Volumes (\(reachableCaptionable))"
                        : "Dossier All Reachable Volumes",
                    systemImage: "doc.text.magnifyingglass"
                )
            }
            .disabled(reachableCaptionable == 0 || captionOrchestrator.currentStatus.isActive)
            .help(
                reachableCaptionable == 0
                    ? "No eligible videos on any reachable volume"
                    : "Run the full dossier (date/scene/text VLM prompts + Whisper transcript) across every reachable volume. ~3× slower than captioning but populates all dossier fields. Idempotent."
            )
            if targets.count > 1 || (single && model.records.contains(where: { $0.scanContext.volumeName.isEmpty })) {
                Button(action: { model.backfillAllProvenance() }) {
                    Label("Backfill All Volume Names", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            Button(role: .destructive, action: {
                if single {
                    deleteVolumeCatalogTarget = first
                    showDeleteVolumeCatalogConfirm = true
                } else {
                    for t in targets { model.deleteCatalogForTarget(t) }
                }
            }) {
                Label("Delete Catalog", systemImage: "trash")
            }
            if targets.contains(where: { $0.status == .complete || $0.status == .stopped || $0.status == .error }) {
                Button(action: {
                    for t in targets { model.resetTarget(t) }
                }) {
                    Label("Reset & Re-probe", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    @ViewBuilder
    private func volumeContextPhaseSection(
        targets: [CatalogScanTarget], first: CatalogScanTarget, single: Bool
    ) -> some View {
        Section("Phase") {
            ForEach(VolumePhase.allCases, id: \.self) { phase in
                Button(action: {
                    for t in targets { model.setPhase(phase, for: t) }
                }) {
                    HStack {
                        if single, first.phase == phase {
                            Image(systemName: "checkmark")
                        }
                        Label(phase.rawValue, systemImage: phase.icon)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func volumeContextVolumeSection(
        targets: [CatalogScanTarget], first: CatalogScanTarget, single: Bool
    ) -> some View {
        Section("Volume") {
            Button(action: {
                model.pendingVolumesSelectionID = first.id
                openWindow(id: "volumes")
            }) {
                Label("Volume Roles & Archive…", systemImage: "externaldrive.badge.checkmark")
            }
            if single {
                Button(action: { browsePath(for: first) }) {
                    Label("Browse…", systemImage: "folder")
                }
                .disabled(!first.status.isIdle)
            }
            if targets.contains(where: { !$0.isReachable }) {
                Button(action: {
                    for t in targets where !t.isReachable { model.wakeVolume(t) }
                }) {
                    Label("Wake Volume", systemImage: "bolt.fill")
                }
            }
            if targets.contains(where: { $0.isReachable && $0.searchPath.hasPrefix("/Volumes/") }) {
                Button(action: {
                    for t in targets where t.isReachable && t.searchPath.hasPrefix("/Volumes/") {
                        model.ejectVolume(t)
                    }
                }) {
                    Label("Eject", systemImage: "eject.fill")
                }
            }
            Button(role: .destructive, action: {
                for t in targets { model.removeScanTarget(t) }
            }) {
                Label(single ? "Remove from List" : "Remove Selected", systemImage: "minus.circle")
            }
        }
    }

    private func volumeNameColor(for row: VolumeRow) -> Color {
        switch row.status {
        case .scanning, .discovering:  return .green
        case .paused:                  return .cyan
        case .complete:                return .blue
        case .error:                   return .red
        case .stopped:                 return .orange
        case .resumable:               return .purple
        case .waitingForVolume:        return .yellow
        case .idle:                    return .primary
        }
    }

    private static func formatBytesStatic(_ bytes: Int64) -> String {
        let mb: Int64 = 1_048_576
        let gb: Int64 = 1_073_741_824
        let tb: Int64 = 1_099_511_627_776
        if bytes < gb {
            return String(format: "%.1f MB", Double(bytes) / Double(mb))
        } else if bytes < tb {
            return String(format: "%.1f GB", Double(bytes) / Double(gb))
        } else {
            return String(format: "%.2f TB", Double(bytes) / Double(tb))
        }
    }

    private static func shortDateStatic(_ date: Date) -> String {
        let fmt = DateFormatter()
        let cal = Calendar.current
        if cal.component(.year, from: date) == cal.component(.year, from: Date()) {
            fmt.dateFormat = "MMM d"
        } else {
            fmt.dateFormat = "MMM d, yyyy"
        }
        return fmt.string(from: date)
    }

    /// Backup-status pill rendered in the scan-targets header. Color
    /// hints at recency at a glance: green < 7 days, yellow 7–30,
    /// orange > 30, red when never. Click reveals the last bundle in
    /// Finder when present, or fires Export Everything when no backup
    /// has happened yet (cheaper one-click path than digging through
    /// the app menu).
    @ViewBuilder
    private var backupStatusBadge: some View {
        let now = Date()
        let last = model.lastBackupAt
        let path = model.lastBackupPath
        let dayCount = last.map { Int(now.timeIntervalSince($0) / 86_400) }
        let (label, color, icon): (String, Color, String) = {
            guard let last, let dayCount else {
                return ("Never backed up", .red, "externaldrive.badge.exclamationmark")
            }
            let where_ = path.map { Self.shortBackupDest($0) } ?? "?"
            if dayCount < 1 {
                let fmt = DateFormatter()
                fmt.timeStyle = .short
                fmt.dateStyle = .none
                return ("Backed up \(fmt.string(from: last)) → \(where_)",
                        .green, "externaldrive.badge.checkmark")
            } else if dayCount < 7 {
                return ("Backed up \(dayCount)d ago → \(where_)",
                        .green, "externaldrive.badge.checkmark")
            } else if dayCount < 30 {
                return ("Backed up \(dayCount)d ago → \(where_)",
                        .yellow, "externaldrive.badge.checkmark")
            } else {
                return ("Backed up \(dayCount)d ago → \(where_)",
                        .orange, "externaldrive.badge.exclamationmark")
            }
        }()
        Button(action: backupBadgeAction) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(color.opacity(0.4), lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(color.opacity(0.08))
                    )
            )
        }
        .buttonStyle(.plain)
        .help(backupBadgeTooltip())
    }

    private func backupBadgeAction() {
        if let p = model.lastBackupPath,
           FileManager.default.fileExists(atPath: p) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        } else {
            // No backup yet — kick off the export panel directly.
            model.exportBundleViaPanel()
        }
    }

    private func backupBadgeTooltip() -> String {
        guard let last = model.lastBackupAt else {
            return "No catalog backup yet. Click to run Export Everything…"
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        let where_ = model.lastBackupPath ?? "(unknown location)"
        return "Last Export Everything: \(fmt.string(from: last))\n\(where_)\n\nClick to reveal in Finder."
    }

    /// Shorten a bundle path to its containing folder name + ".../leaf",
    /// e.g. "/Users/rickb/iCloud Drive/Backups/VideoScan_…bundle" →
    /// "Backups / VideoScan_…bundle" — enough for the badge to convey
    /// "did this land in iCloud or somewhere else?".
    private static func shortBackupDest(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let leaf = url.lastPathComponent
        let parent = url.deletingLastPathComponent().lastPathComponent
        if parent.isEmpty || parent == "/" { return leaf }
        return "\(parent) / \(leaf)"
    }

    /// One-cell renderer for the Role column. Two flavors:
    ///   - quiet: just the role label in its own color (no trust word)
    ///   - degraded: "Role · Trust" with each word in its color, so a
    ///     glance at the table surfaces drives that need attention
    /// Unassigned + unknown trust renders as the universal "—" so empty
    /// rows don't shout for attention.
    @ViewBuilder
    private func roleTrustCell(role: VolumeRole, trust: VolumeTrust) -> some View {
        if role == .unassigned && (trust == .unknown || trust == .reliable) {
            Text("—")
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.secondary)
        } else {
            HStack(spacing: 4) {
                Text(role.rawValue)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(role.color)
                    .lineLimit(1)
                if trust == .aging || trust == .unreliable {
                    Text("·")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Text(trust.rawValue)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(trust.color)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// Payload for the Catalog Info window. Codable/Hashable so it can back a
/// `WindowGroup(for:)` scene — SwiftUI uses the value for window identity
/// and session restoration, so two different volumes produce two distinct
/// windows.
struct CatalogInfoItem: Identifiable, Codable, Hashable {
    /// Stable id — using the volume path means re-invoking Catalog Info on
    /// the same volume focuses the existing window instead of stacking
    /// duplicates. A fresh UUID would open a new window every click.
    var id: String { volumePath }
    let volumePath: String
    let title: String
    let message: String
}

/// Contents of the Catalog Info window. Independent resizable AppKit window
/// (not a sheet) so Rick can drag edges freely, keep it open while working,
/// or compare two volumes side by side.
struct CatalogInfoWindow: View {
    let item: CatalogInfoItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.title)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                Text(item.message)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }

            Divider()

            HStack {
                Spacer()
                Button("Copy") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(item.message, forType: .string)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

// MARK: - Catalog Sync Banner
//
// Two visual states for the viewer (read-only) Macs:
//
//   * Synced — subtle gray strip: the master is reachable, the catalog
//     was rsync'd in successfully, manifest verified. Quiet so it
//     doesn't compete with the rest of the UI.
//
//   * Fallback (master offline / sync failed) — amber strip with an
//     attention icon. Worded so the user can NEVER mistake stale data
//     for live data: "MASTER OFFLINE — showing snapshot from <ago>".
//
// On the master itself this view isn't rendered at all (see ContentView).

struct CatalogSyncBanner: View {
    @ObservedObject var sync: CatalogSync

    var body: some View {
        HStack(spacing: 10) {
            iconView
            VStack(alignment: .leading, spacing: 1) {
                Text(headlineText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(headlineColor)
                if let sub = subText {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(headlineColor.opacity(0.85))
                }
            }
            Spacer()
            Button(action: { Task { await sync.syncFromMaster() } }) {
                if case .syncing = sync.state.phase {
                    ProgressView().controlSize(.small)
                } else {
                    Text(isFallback ? "Retry" : "Refresh")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled({ if case .syncing = sync.state.phase { return true } else { return false } }())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
    }

    // MARK: - Visual state

    private var isFallback: Bool {
        switch sync.state.phase {
        case .failed, .idle: return true
        case .syncing, .synced: return false
        }
    }

    private var backgroundColor: Color {
        isFallback
            ? Color(red: 0.85, green: 0.45, blue: 0.10)   // amber — can't-miss
            : Color(NSColor.controlBackgroundColor)
    }

    private var headlineColor: Color {
        isFallback ? .white : .secondary
    }

    private var iconView: some View {
        Image(systemName: isFallback ? "exclamationmark.triangle.fill" : "checkmark.circle")
            .foregroundStyle(headlineColor)
            .font(.system(size: 14, weight: .semibold))
    }

    private var headlineText: String {
        switch sync.state.phase {
        case .idle:
            if let last = sync.state.lastSuccessfulSync {
                return "MASTER OFFLINE — showing snapshot from \(relative(last))"
            }
            return "MASTER OFFLINE — no previous snapshot available"
        case .syncing:
            return "Read-only · syncing from master…"
        case .synced(let at):
            return "Read-only · synced \(relative(at))"
        case .failed:
            if let last = sync.state.lastSuccessfulSync {
                return "MASTER OFFLINE — showing snapshot from \(relative(last))"
            }
            return "MASTER OFFLINE — no previous snapshot available"
        }
    }

    private var subText: String? {
        switch sync.state.phase {
        case .failed(let reason): return reason
        default: return nil
        }
    }

    private func relative(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}
