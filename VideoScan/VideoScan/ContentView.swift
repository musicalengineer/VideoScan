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
    @AppStorage("catalogShowUnscannedTargets") private var showUnscannedTargets: Bool = false
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
    @State private var volumeFilters: Set<VolumeFilter> = [.allScanned]
    @State private var showDeleteAllCatalogConfirm = false
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
    @State private var volumeAggregateCache: [UUID: VolumeAggregate] = [:]
    /// Memoized toolbar badge counts (video-only / audio-only). The
    /// toolbar used to run two full `records.filter{}.count` passes per
    /// body re-eval (~54K iterations per arrow-key step). Recomputed in
    /// recomputeVolumeAggregates(), which is already wired to every
    /// records-change trigger — same pattern as volumeAggregateCache.
    @State private var streamTypeCounts = CatalogStreamTypeCounts()
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
                searchText: searchText,
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
            }
            .onChange(of: model.pendingCatalogSelection) { handlePendingCatalogNavigation() }
            // Clear the ID filter and focus when user types in search or selects a volume
            .onChange(of: searchText) {
                if !searchText.isEmpty { filterByIDs = []; focusMatchScore = nil; model.focusedMediaIDs = [] }
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
    var volumeTableRows: [VolumeRow] {
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
        // Toolbar badge counts ride the same triggers — one extra O(n)
        // pass here instead of two per render.
        streamTypeCounts = CatalogStreamTypeCounts.compute(model.records)
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
    func target(for id: UUID) -> CatalogScanTarget? {
        model.scanTargets.first { $0.id == id }
    }

    func browsePath(for target: CatalogScanTarget) {
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

                // "Show unscanned" toggle and "Clean up unscanned" button
                // both removed from the toolbar 2026-06-07 per Rick's
                // 14" M5 cleanup pass — they were eating toolbar width
                // for actions Rick doesn't take daily. View → Online is
                // his preferred filter; the underlying `showUnscannedTargets`
                // AppStorage stays so the strict-catalog view persists
                // (off by default), and `cleanupUnscannedTargets()` on
                // the model is still callable from other surfaces if we
                // ever want a "Tools" menu entry.

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

                Button(action: { openWindow(id: "compare") }) {
                    Label("Compare", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Compare two volumes — show what's unique to the source volume (would be lost if it died). Opens in its own window so a multi-hour rescue copy doesn't block the main UI.")

                // Persistent rescue progress chip — only visible when
                // a copy is in flight (or just finished, awaiting ack).
                // Click opens the Compare window. Chip subscribes to
                // VolumeRescueOperation via @EnvironmentObject on its
                // own scope so a rescue tick doesn't re-render
                // ContentView's body.
                RescueToolbarChip()

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
}

