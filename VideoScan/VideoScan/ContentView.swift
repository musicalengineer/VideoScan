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
    case workspaceOnly    = "In Workspace"
    case untaggedOnly     = "Untagged (junk candidate)"

    var icon: String {
        switch self {
        case .onlineOnly:        return "externaldrive.fill.badge.checkmark"
        case .videoAndAudioOnly: return "film"
        case .unpairedOnly:      return "exclamationmark.triangle"
        case .ratedOnly:         return "star.fill"
        case .hasFamily:         return "person.2.fill"
        case .workspaceOnly:     return "hammer.fill"
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
    /// Catalog search term. `@SceneStorage` (not `@State`) so a search —
    /// especially a complex one — survives leaving and returning to the
    /// Catalog tab. The tab content is rendered via `switch selectedTab`,
    /// which fully removes `CatalogView` from the hierarchy on tab switch
    /// and would otherwise reset every `@State` to its default. SceneStorage
    /// is scoped to the running scene (session), so it persists across tab
    /// switches but does NOT carry a stale search across full app relaunches
    /// the way `@AppStorage` would. The toolbar's search field keeps its
    /// built-in "x" to clear. Rick 2026-06-24. On reappear we re-seed
    /// `debouncedSearchText` in `.onAppear` (see below) because the debounce
    /// only fires on `.onChange`, which does not run on view recreation.
    @SceneStorage("catalogSearchText") private var searchText: String = ""
    /// Debounced mirror of `searchText` driving the CatalogContent
    /// table filter. Updated 250 ms after the last keystroke so
    /// computeFiltered (~10 ms × 15K records) only runs on the trailing
    /// edge of typing. Rick 2026-06-16. Parallels CatalogToolbar's own
    /// private debouncer (which feeds the hit-count badge) — type
    /// checker couldn't absorb a Binding through the toolbar's already-
    /// huge initializer, so we run two independent debouncers on the
    /// same source. They produce identical output in practice.
    @State private var debouncedSearchText: String = ""
    /// Cancellable task that fires 250 ms after the last keystroke and
    /// propagates `searchText` → `debouncedSearchText`. Reset on every
    /// keystroke so only the trailing edge lands.
    @State private var searchDebounceTask: Task<Void, Never>? = nil
    @State private var showDeleteDuplicatesConfirm = false
    @State private var deleteTargetVolume: String = ""
    @State private var deleteTargetCount: Int = 0
    @State var showDiscoverVolumes = false
    // showVolumeCompare retired 2026-06-07 — Compare moved from a
    // modal sheet to its own Window scene (id: "compare") to eliminate
    // beachballing during multi-hour rescue copies. Button now calls
    // openWindow(id: "compare").
    //
    // No `@EnvironmentObject volumeRescue` here — ContentView never
    // reads from it, so a subscription would force a full ContentView
    // body re-eval on every rescue tick. RescueToolbarChip subscribes
    // at its own (much smaller) view scope via @EnvironmentObject.
    // See project_bug_prevention_strategy: the
    // env-object-subscribed-but-unread antipattern.
    /// Set by Archive tab navigation — filters catalog to specific record IDs.
    @State private var filterByIDs: Set<UUID> = []
    /// When `filterByIDs` was populated by Find A/V Pair, the candidate's score
    /// (0–14) so the focus banner can show a Best/Better/Good/Maybe label.
    @State private var focusMatchScore: Int?
    /// Focus-banner caption — set alongside filterByIDs by whichever
    /// verb created the focus ("A/V Pair focus", "Online copies",
    /// "Not migrated from <volume>").
    @State private var focusLabel = "A/V Pair focus"
    /// punch-list #5: non-nil drives a brief alert when an Archive→Catalog
    /// navigation resolves to no live records (stale id after live-reload
    /// identity churn). We clear the filter (leaving the full catalog
    /// visible) rather than blanking the table, and explain why.
    @State private var catalogNavigationNotice: String?
    /// Non-nil presents the volume migration report sheet
    /// ("Show Migrated…" on an offline/retired volume).
    /// Internal (not private): set by showMigrationReport(for:) in
    /// CatalogView+VolumeTable.swift (the volume context menu's file).
    @State var migrationReportItem: VolumeMigrationItem?
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
    @AppStorage("catalogShowUnscannedTargets") var showUnscannedTargets: Bool = false
    // showCleanupUnscannedConfirm removed 2026-06-07 along with the
    // toolbar button; the alert handler at .alert(...) is gone too.
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
    /// Default is Connected so the table shows only volumes MFO can act on.
    @State var volumeFilters: Set<VolumeFilter> = [.connected]
    @State var showDeleteAllCatalogConfirm = false
    @State var showDeleteVolumeCatalogConfirm = false
    @State var deleteVolumeCatalogTarget: CatalogScanTarget?
    /// Selected volume IDs in the scan volumes table.
    @State var selectedVolumeIDs: Set<UUID> = []
    /// Per-volume aggregate cache (file count, error count, byte sum,
    /// pre-built Cmd+I popover text). Recomputed once per records or
    /// scan-target change via the `.onChange` modifiers below. Without
    /// this cache, `volumeTableRows` triple-walked the full ~13K record
    /// catalog for every visible target on every SwiftUI body re-eval —
    /// every click of a volume row caused ~620K iterations on the main
    /// thread, racing NSTableView's selection visuals and producing
    /// the "highlight sometimes appears, sometimes doesn't" lag.
    @State var volumeAggregateCache: [UUID: VolumeAggregate] = [:]
    /// Memoized toolbar badge counts (video-only / audio-only). The
    /// toolbar used to run two full `records.filter{}.count` passes per
    /// body re-eval (~54K iterations per arrow-key step). Recomputed in
    /// recomputeVolumeAggregates(), which is already wired to every
    /// records-change trigger — same pattern as volumeAggregateCache.
    @State var streamTypeCounts = CatalogStreamTypeCounts()
    /// Sort order for the Scan Volumes table. Defaults to volume-name
    /// ascending, which matches the historical implicit ordering. Bound
    /// to the Table via `Table(_:selection:sortOrder:)` so column-header
    /// clicks rotate through ascending → descending → none.
    @State var volumeTableSortOrder: [KeyPathComparator<VolumeRow>] = [
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
    /// Dereferenced in CatalogView+VolumeTable.swift (context-menu caption
    /// actions) — the file-scoped lint can't see across the extension split.
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject var captionOrchestrator: CaptionOrchestrator
    @State var showCaptionProgress = false
    /// Opens an independent resizable window keyed by CatalogInfoItem value.
    /// Defined as a `WindowGroup(for:)` scene in VideoScanApp.
    @Environment(\.openWindow) var openWindow

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
                videoOnlyCount: streamTypeCounts.videoOnly,
                audioOnlyCount: streamTypeCounts.audioOnly,
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
                searchText: debouncedSearchText,
                filterTargetPaths: filterTargetPaths,
                showPairsOnly: showPairsOnly,
                viewFilters: catalogViewFilters,
                showRemoved: showRemoved,
                filterByIDs: filterByIDs,
                focusMatchScore: focusMatchScore,
                focusLabel: focusLabel,
                previewImage: model.previewImage,
                previewFilename: model.previewFilename,
                previewOfflineVolumeName: model.previewOfflineVolumeName,
                showInspector: $showInspector,
                onSort: { model.records.sort(using: $0) },
                onSelect: { id in
                    // record(forID:) is the O(1) index lookup — this fires
                    // on EVERY arrow-key step, so no linear scans here.
                    if let id, let rec = model.record(forID: id),
                       rec.streamType == .videoOnly || rec.streamType == .videoAndAudio {
                        // Debounced (200 ms): holding an arrow key no longer
                        // opens one media file per traversed row. Cache hits
                        // still swap instantly inside the model.
                        model.requestThumbnailDebounced(for: rec)
                    } else {
                        // clearPreview also cancels any pending debounce so
                        // a stale generation can't repopulate the pane.
                        model.clearPreview()
                    }
                },
                onClearPreview: {
                    model.clearPreview()
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
                    focusLabel = "A/V Pair focus"
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
                },
                onShowOnlineCopies: { focusIDs, selectID in
                    searchText = ""
                    selectedVolumeIDs = []
                    showPairsOnly = false
                    filterByIDs = focusIDs
                    selectedIDs = [selectID]
                    focusMatchScore = nil
                    focusLabel = "Online copies"
                }
            )
            .onChange(of: selectedIDs) {
                // Update volume highlight when table selection changes.
                // O(1) index lookup — runs per arrow-key step.
                if let id = selectedIDs.first,
                   let rec = model.record(forID: id) {
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
                // Re-seed the debounced filter from the restored search term.
                // `searchText` is SceneStorage so it survives a tab switch,
                // but `debouncedSearchText` is plain @State and resets to ""
                // on view recreation. `.onChange(of: searchText)` won't fire
                // on reappear (the value didn't change), so without this the
                // field would show the term but the table would be unfiltered.
                if debouncedSearchText != searchText {
                    debouncedSearchText = searchText
                }
            }
            .onChange(of: model.pendingCatalogSelection) { handlePendingCatalogNavigation() }
            // Clear the ID filter and focus when user types in search or selects a volume
            .onChange(of: searchText) {
                if !searchText.isEmpty { filterByIDs = []; focusMatchScore = nil; model.focusedMediaIDs = [] }
                // Debounce the CatalogContent filter: cancel any
                // pending propagation and schedule a new 250 ms one.
                // Empty-clears are instant — no debounce needed when
                // the user is BACKSPACING the field empty.
                searchDebounceTask?.cancel()
                if searchText.isEmpty {
                    debouncedSearchText = ""
                } else {
                    let pending = searchText
                    searchDebounceTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        if !Task.isCancelled {
                            debouncedSearchText = pending
                        }
                    }
                }
            }
            .onChange(of: selectedVolumeIDs) {
                if !selectedVolumeIDs.isEmpty { filterByIDs = []; focusMatchScore = nil; model.focusedMediaIDs = [] }
                // Part 3 (perf batch 2026-06-10): prewarm the thumbnail
                // cache for the clicked volume's rows in the background.
                startThumbnailPrecache()
            }
            // A scan competes for the same disks — stop any prewarm the
            // moment one starts. (Prewarm resumes on the next volume click.)
            .onChange(of: model.isScanning) {
                if model.isScanning {
                    model.thumbnailPrecacher.cancel(reason: "scan started")
                }
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
        // "Show Migrated…" on an offline/retired volume — per-volume
        // migration report (which files have copies elsewhere, where,
        // and which don't).
        .sheet(item: $migrationReportItem) { item in
            VolumeMigrationSheet(item: item) { unmigratedIDs in
                migrationReportItem = nil
                searchText = ""
                selectedVolumeIDs = []
                showPairsOnly = false
                filterByIDs = Set(unmigratedIDs)
                selectedIDs = Set(unmigratedIDs)
                focusMatchScore = nil
                focusLabel = "Not migrated from \(item.volumeName)"
            }
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
        // .sheet for Compare retired 2026-06-07 — Compare is now its own
        // Window scene (defined in VideoScanApp.swift, id: "compare").
        // The Compare button uses openWindow(id: "compare") instead.
        .sheet(isPresented: $showCaptionProgress) {
            CaptionProgressSheet(
                orchestrator: captionOrchestrator,
                isPresented: $showCaptionProgress
            )
        }
        .alert(
            "Show in Catalog",
            isPresented: Binding(
                get: { catalogNavigationNotice != nil },
                set: { if !$0 { catalogNavigationNotice = nil } }
            ),
            presenting: catalogNavigationNotice
        ) { _ in
            Button("OK", role: .cancel) { catalogNavigationNotice = nil }
        } message: { msg in
            Text(msg)
        }
        .alert("Delete Catalog", isPresented: $showDeleteAllCatalogConfirm) {
            Button("Delete All", role: .destructive) {
                model.deleteAllCatalog()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will delete all \(model.records.count) catalog records across every volume. The probe cache is unaffected.\n\nAre you sure?")
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
        focusLabel = "A/V Pair focus"
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
        // punch-list #5: empty means the record is no longer in the catalog
        // (stale id after live-reload identity churn). Clear the filter so the
        // full catalog stays visible — do NOT filter to nothing (blank table).
        guard !ids.isEmpty else {
            filterByIDs = []
            focusMatchScore = nil
            focusLabel = "A/V Pair focus"
            selectedIDs = []
            model.focusedMediaIDs = []
            catalogNavigationNotice = "That file is no longer in the catalog — it may have been removed or replaced by a re-scan. Showing the full catalog."
            return
        }
        filterByIDs = ids
        focusMatchScore = nil
        focusLabel = "A/V Pair focus"
        selectedIDs = ids
        model.focusedMediaIDs = model.focusSet(for: id)
        // Generate thumbnail — deliberate one-shot navigation, so the
        // immediate (non-debounced) path is correct here.
        if let rec = model.record(forID: id),
           rec.streamType == .videoOnly || rec.streamType == .videoAndAudio {
            model.generateThumbnail(for: rec)
        }
    }

    // MARK: - Thumbnail Prewarm (Part 3, perf batch 2026-06-10)

    /// Kick a background thumbnail prewarm for the currently selected
    /// volume(s). Candidate building is the pure
    /// `ThumbnailPrecachePlanner.orderedCandidates` (dossier-complete
    /// rows first, then current table-sort order; cached/unreachable
    /// rows excluded). Empty selection or an active scan cancels instead.
    private func startThumbnailPrecache() {
        let targets = selectedVolumeIDs.compactMap { target(for: $0) }
            .filter { !$0.searchPath.isEmpty }
        guard !targets.isEmpty, !model.isScanning else {
            model.thumbnailPrecacher.cancel(reason: targets.isEmpty
                ? "volume selection cleared"
                : "scan in progress")
            return
        }

        let prefixes = targets.map(\.searchPath)
        let volumeRecords = model.records.filter { rec in
            prefixes.contains(where: { rec.fullPath.hasPrefix($0) })
        }

        let cache = model.thumbnailCache
        let candidates = ThumbnailPrecachePlanner.orderedCandidates(
            records: volumeRecords,
            sortOrder: sortOrder,
            isCached: { cache.object(forKey: $0 as NSString) != nil },
            // Non-blocking since the SWR fix in 109cc36 — safe per record.
            isReachable: { VolumeReachability.isReachable(path: $0) }
        )

        // Per-disk pacing (HDD=1, SSD=4, internal=8) from the target's
        // mediaTech classification; multi-volume selections take the most
        // conservative bound so a lone HDD in the set isn't hammered.
        let bound = targets.map { t in
            ThumbnailPrecachePlanner.concurrencyBound(
                mediaTech: t.mediaTech,
                isInternalPath: !t.searchPath.hasPrefix("/Volumes/")
            )
        }.min() ?? 4

        let label = targets
            .map { VolumeReachability.displayLabel(forPath: $0.searchPath) }
            .joined(separator: ", ")

        model.thumbnailPrecacher.start(
            volumeLabel: label,
            candidates: candidates,
            concurrency: bound,
            model: model
        )
    }

    private func restoreFocusedMedia() {
        guard model.pendingCatalogSelection == nil,
              !model.focusedMediaIDs.isEmpty else { return }
        selectedVolumeIDs = []
        searchText = ""
        showPairsOnly = false
        filterByIDs = model.focusedMediaIDs
        focusMatchScore = nil
        focusLabel = "A/V Pair focus"
        selectedIDs = model.focusedMediaIDs
    }

    // MARK: - Volume Filter Helpers

    func toggleVolumeFilter(_ filter: VolumeFilter) {
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
        // If nothing is checked, snap back to Connected — the safe baseline
        // (volumes MFO can actually act on).
        if volumeFilters.isEmpty {
            volumeFilters = [.connected]
        }
    }

    /// Open the Catalog Info window for a given target. Shared by the
    /// right-click menu Button and the Cmd-I global shortcut. Window identity
    /// is the volume path, so repeat invocations focus the existing window
    /// rather than stacking duplicates.
    func showCatalogInfo(for target: CatalogScanTarget) {
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
    func showCatalogInfoForSelection() {
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
}

