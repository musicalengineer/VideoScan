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
        // Storage (2026-08-19): the Volumes editor promoted to a top-tier
        // tab — drives, roles, tiers, migrations are peers of the catalog
        // (MAM convention). Tag 6 so saved `selectedTab` values keep their
        // meaning; the ⌘⇧V window still exists for badge click-through.
        ("Storage", "externaldrive.fill", 6),
        // Workbench merged into Triage as the "Under Construction" filter
        // (Rick 2026-08-19); tag 3 falls through to Triage below.
        ("Triage", "checklist", 2),
        ("Archive", "archivebox.fill", 4),
        ("Family Tree", "person.3.fill", 5)
    ]
    @Environment(\.openWindow) private var openWindow

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
                    // Family Archivist — the door to Hallie Mae's window,
                    // after Family Tree, twinkling (Rick 2026-08-16). Not
                    // a content tab: the conversation stays in its own
                    // always-on-top window so the catalog remains the
                    // display surface.
                    ArchivistTabButton(fontSize: tabFontSize) {
                        openWindow(id: "archivist")
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
                    TriageView()   // legacy Workbench selection
                case 4:
                    ArchiveView()
                case 5:
                    FamilyTreeDemoView()
                case 6:
                    VolumesWindow(embedded: true)
                default:
                    PeopleTabView()
                        .environmentObject(personFinderModel)
                        .environmentObject(identifyFamilyModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 900, minHeight: 600)
        // Master Archive (docs/archive_promotion_workflow.md). All three
        // are MODEL-driven so the Volumes-window right-click, the catalog
        // right-click, the Archive tab and the File ▸ Archive menu share ONE
        // sheet each (.sheet(item:) per the chained-sheet antipattern memo).
        // Attached at the ROOT, not CatalogView: Rick 2026-08-16 pressed
        // Initialize from the Archive tab and nothing appeared — CatalogView
        // is not in the hierarchy on other tabs, so its sheets can't present.
        .sheet(item: $model.pendingMasterArchiveInitOffer) { offer in
            MasterArchiveInitSheet(offer: offer)
                .environmentObject(model)
        }
        .sheet(item: $model.pendingPromoteRequest) { request in
            // fileOpsCenter reaches the sheet through the environment the
            // app injects at the window (VideoScanApp) — no re-injection,
            // and no root subscription to MFO progress churn.
            PromoteToArchiveSheet(request: request)
                .environmentObject(model)
        }
        .alert(item: $model.pendingPromoteWithoutMaster) { pending in
            Alert(
                title: Text("You need to designate a volume as the master archive."),
                message: Text("Promote copies files into one Master Archive tree. Pick the volume that will hold it (the RAID, for example) — Initialize creates the folders and index files, then the promotion continues."),
                primaryButton: .default(Text("Initialize Master Archive…")) {
                    // Hop a turn: never present the next sheet from inside
                    // an alert's dismissal (chained-sheet antipattern).
                    let ids = pending.recordIDs
                    Task { @MainActor in
                        model.chooseAndOfferInitializeMasterArchive(promoteAfterwards: ids)
                    }
                },
                secondaryButton: .cancel()
            )
        }
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

            // Bridge the catalog's dossier evidence (inferred record date +
            // VLM scene captions) into PersonFinder's identity-narrowing
            // pass. Batch shape: one O(records) walk per annotate call,
            // NOT per result row. Assigning this closure also fires its
            // didSet, which annotates any jobs already restored from disk.
            personFinderModel.identityEvidenceProvider = { [weak model] paths in
                guard let model, !paths.isEmpty else { return [:] }
                var out: [String: PFIdentityEvidence] = [:]
                out.reserveCapacity(paths.count)
                for rec in model.records where paths.contains(rec.fullPath) {
                    out[rec.fullPath] = PFIdentityEvidence(
                        recordDate: rec.inferredRecordDate,
                        sceneDescriptions: rec.sceneCaptions.map(\.text)
                    )
                }
                return out
            }
        }
    }
}

// MARK: - Catalog View Filter

enum CatalogViewFilter: String, CaseIterable, Hashable {
    // .onlineOnly retired 2026-07-20: reachable-only is now the DEFAULT
    // catalog baseline (opt-out via "Show disconnected media"), not an
    // opt-in additive filter. See CatalogContent.showDisconnectedMedia.
    case videoAndAudioOnly = "Video+Audio Only"
    case unpairedOnly     = "Unpaired Only"
    case ratedOnly        = "Rated Only"
    case hasFamily        = "Has Family"
    case workspaceOnly    = "In Workspace"
    case untaggedOnly     = "Untagged (junk candidate)"
    /// Repair-lifecycle worklist (GH #132 P3): repair copies waiting
    /// for Rick's one-click "Sounds Good" — the listen-then-confirm
    /// queue. Backed by pfAwaitingConfirmation.
    case awaitingConfirmation = "Repaired — Awaiting Confirmation"
    /// Master Archive (2026-08-15): live sources without a promoted copy
    /// (the "what still needs promoting" worklist). Backed by
    /// pfNotYetArchived (memoized reverse index — O(1) per record).
    case notYetArchived = "Not Yet Archived"
    /// Master Archive: sources that HAVE a promoted copy.
    case hasMasterCopy = "Has Master Copy"

    var icon: String {
        switch self {
        case .videoAndAudioOnly:    return "film"
        case .unpairedOnly:         return "exclamationmark.triangle"
        case .ratedOnly:            return "star.fill"
        case .hasFamily:            return "person.2.fill"
        case .workspaceOnly:        return "hammer.fill"
        case .untaggedOnly:         return "questionmark.folder"
        case .awaitingConfirmation: return "checkmark.seal"
        case .notYetArchived:       return "archivebox"
        case .hasMasterCopy:        return "archivebox.fill"
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
    /// COLUMN visibility, not a row filter (Rick 2026-08-14: "let's NOT
    /// show Errors from Scan unless Show includes 'Show Errors' — cleaner
    /// display"). Lives in VolumeFilter so it rides the existing Show
    /// menu + persistence; the row-matching switch treats it as neutral.
    case showErrorsColumn = "Show Errors Column"

    var icon: String {
        switch self {
        case .connected:   return "externaldrive.fill"
        case .network:     return "network"
        case .allScanned:  return "clock.arrow.circlepath"
        case .uncataloged: return "questionmark.folder"
        case .withErrors:  return "exclamationmark.triangle"
        case .showErrorsColumn: return "tablecells.badge.ellipsis"
        }
    }
}

// MARK: - Catalog Tab

struct CatalogView: View {
    @EnvironmentObject var model: VideoScanModel
    @AppStorage("selectedTab") private var selectedTab: Int = 0
    @State private var selectedIDs: Set<UUID> = []
    @State private var showCombineSheet = false
    /// Migrate sheet. Internal (not private): the Volume Scanner pane in
    /// CatalogView+ScanTargetsPane.swift presents it now that Migrate
    /// lives beside Compare (2026-08-11).
    @State var showRelocateSheet = false
    /// Tidy Catalog dry-run sheet. Moved here from CatalogToolbar on
    /// 2026-08-11 when the button moved up to the Volume Scanner row.
    @State var showTidySheet = false
    /// Cached content-hash backfill plan for the Catalog Options menu.
    /// Same discipline as `storageTotals`: the computation is O(records)
    /// and must never run from a view body.
    @State var hashBackfillPlan = VideoScanModel.ContentHashBackfillPlan()
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
    /// edge of typing. Rick 2026-06-16. GH #123 PR B (2026-07-19): this
    /// is now the ONLY search debouncer — CatalogToolbar's private twin
    /// is gone. The toolbar reads this value (for its "Searching…"
    /// indicator) and the hit count below, both passed down as plain
    /// values.
    @State private var debouncedSearchText: String = ""
    /// Cancellable task that fires 250 ms after the last keystroke and
    /// propagates `searchText` → `debouncedSearchText`. Reset on every
    /// keystroke so only the trailing edge lands.
    @State private var searchDebounceTask: Task<Void, Never>? = nil
    /// Search-hit badge count for the toolbar. WRITTEN by CatalogContent
    /// as a by-product of the table filter pass (GH #123 PR B: the badge
    /// used to run its own duplicate full scan per settled keystroke —
    /// 2× the main-thread cost of every search). READ by CatalogToolbar.
    /// Semantics unchanged: hits over pfSearchBadgeBase (purge +
    /// set-aside pre-filter, BEFORE volume/View-chip narrowing);
    /// 0 when the search is empty.
    @State private var searchHitCount: Int = 0
    @State private var showDeleteDuplicatesConfirm = false
    /// Analysis-ledger (2026-07-05): Correlate All is incremental; the
    /// from-scratch redo is destructive to manual pairs, so it confirms.
    @State private var showClearRecorrelateConfirm = false
    @State private var deleteTargetVolume: String = ""
    @State private var deleteTargetCount: Int = 0
    /// Confirmation body built once at click time from
    /// `duplicateDeletionSelection` (2026-08-18, "Also clean up working
    /// copies" mode) — see WorkingCopyCleanupText.confirmation.
    @State private var deleteTargetSummary: String = ""
    @State private var deleteTargetCrossMode: Bool = false
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
    /// Baseline reachability opt-out (2026-07-20). Reachable-only is the
    /// DEFAULT — the catalog table shows only media on currently-mounted
    /// volumes. Flipping this ON lifts that baseline and shows disconnected
    /// media too. Persisted across launches; default OFF. NOT one of the
    /// additive `catalogViewFilters`, so "Clear All Filters" leaves it alone.
    /// `@AppStorage` ≈ a persisted-in-NSUserDefaults bool.
    @AppStorage("catalog.showDisconnectedMedia") private var showDisconnectedMedia = false
    /// Whether purged ("removed from catalog") rows are included in the table.
    /// Persisted across launches like other catalog UI prefs.
    /// Default OFF — purged rows hidden until the user opts in.
    @AppStorage("catalogShowRemoved") private var showRemoved: Bool = false
    /// Whether set-aside rows (video-only catalog scope: photos / music /
    /// audio with no matching video) are included in the table. Default
    /// OFF — set-aside rows hidden until the user opts in. Independent of
    /// `showRemoved` (distinct states, distinct toggles).
    @AppStorage("catalogShowSetAside") private var showSetAside: Bool = false
    /// Whether superseded rows (originals retired by a confirmed repair,
    /// GH #132) are included in the table. Session-scoped `@State` —
    /// deliberately NOT persisted (Manager decision 2026-07-24): the
    /// default view should always come back clean on relaunch.
    @State private var showSuperseded: Bool = false
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
    /// Catalog-wide storage totals for the "TOTAL MEDIA" footer pinned
    /// under the volume table (Rick 2026-08-09). Same cache discipline
    /// as `volumeAggregateCache` above and recomputed on the same
    /// triggers: the calculation is O(records), so it must never run
    /// from a view body.
    @State var storageTotals = CatalogStorageTotals()
    /// In-flight existence probe for the footer's "marked deleted, still
    /// on disk" caption (Rick 2026-08-18). Held so a newer recompute can
    /// cancel a stale sweep before it publishes into `storageTotals`.
    @State var manuallyDeletedProbeTask: Task<Void, Never>? = nil
    /// Measured frames of the volume table's Media Size / Scanned /
    /// Phase columns, reported by the cells themselves via
    /// VolumeColumnFramesKey. The TOTAL MEDIA footer puts one figure on
    /// each instead of assuming fixed column widths — see
    /// VolumeTableMetrics for why measuring won.
    @State var volumeColumnFrames: [String: CGRect] = [:]
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
    /// Handed to the Promote confirmation sheet (Master Archive) so its
    /// Confirm can enqueue the MFO job — intentional forwarding only.
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject var fileOpsCenter: MediaFileOperationsCenter
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
                hasCorrelatedPairs: model.hasAnyPairs,
                outputCSVPath: model.outputCSVPath,
                selectedIDs: selectedIDs,
                showCombineSheet: $showCombineSheet,
                showRelocateSheet: $showRelocateSheet,
                showDashboard: $showDashboard,
                searchText: $searchText,
                debouncedSearchText: debouncedSearchText,
                searchHitCount: searchHitCount,
                showInspector: $showInspector,
                cacheCount: model.cacheCount,
                dashboard: model.dashboard,
                onStopCombine: { model.stopCombine() },
                onCorrelateAll: {
                    model.log("\nCorrelating all audio-only and video-only files...")
                    Task { await model.correlate() }
                },
                onCorrelateSelected: {
                    model.log("\nCorrelating \(selectedIDs.count) selected files...")
                    Task { await model.correlate(selectedIDs: selectedIDs) }
                },
                onCorrelateAcrossVolumes: {
                    model.log("\n━━ Finding Avid A/V pairs across all volumes ━━")
                    Task { await model.correlateAcrossVolumes() }
                },
                onClearAndRecorrelateAll: {
                    showClearRecorrelateConfirm = true
                },
                onAnalyzeDuplicatesAll: {
                    model.log("\nAnalyzing duplicate candidates across all scanned media...")
                    Task { await model.analyzeDuplicates() }
                },
                onAnalyzeDuplicatesSelected: {
                    model.log("\nAnalyzing duplicate candidates in \(selectedIDs.count) selected files...")
                    Task { await model.analyzeDuplicates(selectedIDs: selectedIDs) }
                },
                volumesWithDeletableDups: model.deletableDupVolumes,
                onDeleteDuplicates: { path, count in
                    deleteTargetVolume = path
                    deleteTargetCount = count
                    // One O(records) pass at click time (not in a body) so
                    // the alert can state the mode and the split honestly.
                    let selection = model.duplicateDeletionSelection(onVolume: path)
                    deleteTargetSummary = selection.confirmationText(
                        volumeName: URL(fileURLWithPath: path).lastPathComponent)
                    deleteTargetCrossMode = selection.crossVolumeMode
                    showDeleteDuplicatesConfirm = true
                },
                onClearResults: { model.clearResults() },
                onClearCache: { _ = model.clearCache() },
                onScanAvidBins: { model.scanAvidBins() },
                avidBinCount: model.avidBinResults.reduce(0) { $0 + $1.clips.count },
                avidBinFiles: model.avidBinResults.count,
                showPairsOnly: $showPairsOnly,
                viewFilters: $catalogViewFilters,
                showDisconnectedMedia: $showDisconnectedMedia,
                showRemoved: $showRemoved,
                showSetAside: $showSetAside,
                showSuperseded: $showSuperseded,
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

            // Background preview sweep (2026-07-27): unobtrusive one-line
            // status while the sweep works/pauses. Self-observing subview
            // — progress re-renders ONLY this line, never the table.
            PreviewSweepStatusLine(sweep: model.previewSweep)

            // MARK: Split — Table + Player left, Inspector right
            CatalogContent(
                records: model.records,
                selectedIDs: $selectedIDs,
                sortOrder: $sortOrder,
                searchText: debouncedSearchText,
                searchHitCount: $searchHitCount,
                filterTargetPaths: filterTargetPaths,
                showPairsOnly: showPairsOnly,
                viewFilters: catalogViewFilters,
                showDisconnectedMedia: showDisconnectedMedia,
                showRemoved: showRemoved,
                showSetAside: showSetAside,
                showSuperseded: showSuperseded,
                // Media-kind facet (GH #124) — persisted on the model,
                // flipped by the toolbar facet chip.
                kindFacet: model.kindFacetSetting.facet,
                filterByIDs: filterByIDs,
                focusMatchScore: focusMatchScore,
                focusLabel: focusLabel,
                previewImage: model.previewImage,
                previewFilename: model.previewFilename,
                previewOfflineVolumeName: model.previewOfflineVolumeName,
                previewUnavailable: model.previewUnavailable,
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
                },
                onShowRepairedCopy: { repairID in
                    // GH #132 — jump from a superseded original to the
                    // repair that replaced it. Same focus mechanics as
                    // Online copies.
                    searchText = ""
                    selectedVolumeIDs = []
                    showPairsOnly = false
                    filterByIDs = [repairID]
                    selectedIDs = [repairID]
                    focusMatchScore = nil
                    focusLabel = "Repaired copy"
                }
            )
            .onChange(of: selectedIDs) {
                model.hallieCurrentSelectionID = selectedIDs.count == 1
                    ? selectedIDs.first
                    : nil
                // Mirror for the File ▸ Archive ▸ Promote Selected menu
                // command (plain var — no publish, no re-render).
                model.catalogSelectedIDs = selectedIDs
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
                model.hallieCurrentSelectionID = selectedIDs.count == 1
                    ? selectedIDs.first
                    : nil
                // Re-seed the debounced filter from the restored search term.
                // `searchText` is SceneStorage so it survives a tab switch,
                // but `debouncedSearchText` is plain @State and resets to ""
                // on view recreation. `.onChange(of: searchText)` won't fire
                // on reappear (the value didn't change), so without this the
                // field would show the term but the table would be unfiltered.
                if debouncedSearchText != searchText {
                    debouncedSearchText = searchText
                }
                // A query the Family Archivist window published while the
                // catalog view didn't exist (tab switched away) still
                // applies on reappear.
                if let request = model.archivistSearchRequest {
                    searchText = request
                    debouncedSearchText = request
                    model.archivistSearchRequest = nil
                }
            }
            .onDisappear {
                // CatalogView's @State selection ceases to be a visible
                // current row when this tab leaves the hierarchy.
                model.hallieCurrentSelectionID = nil
            }
            .onChange(of: model.archivistSearchRequest) {
                // Family Archivist chat window → catalog search field
                // (2026-08-07). Applied undebounced: the archivist
                // speaks in complete queries, not keystrokes.
                guard let request = model.archivistSearchRequest else { return }
                searchText = request
                debouncedSearchText = request
                model.archivistSearchRequest = nil
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
        // Tidy Catalog — dry-run summary first, applies on confirm.
        .sheet(isPresented: $showTidySheet) {
            TidyCatalogSheet(model: model)
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
        // Volume-rename dialogs (auto-migrated / ask / manual refusal) —
        // see VideoScanModel+VolumeRenameMigration.swift. The binding's
        // setter routes stray dismissals (Esc, click-away) through the
        // model's dismiss handler so a "Not Now" on the ask tier sticks
        // for the session instead of re-nagging on the next rebuild.
        .alert(
            volumeRenameNoticeTitle(model.pendingVolumeRenameNotice),
            isPresented: Binding(
                get: { model.pendingVolumeRenameNotice != nil },
                set: { shown in
                    if !shown, let n = model.pendingVolumeRenameNotice {
                        model.dismissVolumeRenameNotice(n)
                    }
                }
            ),
            presenting: model.pendingVolumeRenameNotice
        ) { notice in
            volumeRenameNoticeButtons(notice)
        } message: { notice in
            Text(volumeRenameNoticeMessage(notice))
        }
        .alert("Delete Duplicates", isPresented: $showDeleteDuplicatesConfirm) {
            Button("Delete \(deleteTargetCount) Files", role: .destructive) {
                Task { await model.deleteDuplicates(onVolume: deleteTargetVolume) }
            }
            .disabled(model.isReadOnly || model.isDeletingDuplicates)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(deleteDuplicatesConfirmMessage)
        }
        .alert("Clear & Re-correlate All", isPresented: $showClearRecorrelateConfirm) {
            Button("Clear All Pairs & Re-correlate", role: .destructive) {
                model.log("\nClearing ALL pairs and re-correlating from scratch...")
                Task { await model.clearAndRecorrelateAll() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This wipes EVERY A/V pairing — including pairs you made by hand — and re-derives them all from file evidence.\n\nNormal \"Correlate All\" already handles new files and never touches existing pairs. Only use this if the pairings themselves are wrong.")
        }
        // Catalog maintenance: the unified "Purge Non-Video Media…" dialog
        // (replaces the former cover-art + unrelated-audio sheets). Opened
        // from the Catalog menu (VideoScanApp) with all volumes selected; it
        // does one O(N) classification pass on appear and removes only on
        // explicit Purge. The volume right-click entry point (VolumesWindow)
        // drives its own copy of this dialog with a volume pre-selected.
        .sheet(isPresented: $model.showNonVideoMediaPurgeSheet) {
            NonVideoMediaPurgeSheet(preselectedVolumeKey: nil)
                .environmentObject(model)
        }
        // Update Catalog (2026-08-17): the ONE door for "files were moved /
        // renamed outside the app". Opened from the Catalog menu, the
        // volume-rename badge, the "looks moved" banner and the target
        // context menus. Dismissing (× / Esc) routes through the model so
        // parked-but-unapplied rescan results are discarded, never
        // committed. See VideoScanModel+UpdateCatalog.swift.
        .sheet(isPresented: Binding(
            get: { model.showUpdateCatalogSheet },
            set: { if !$0 { model.closeUpdateCatalog() } }
        )) {
            UpdateCatalogSheet()
                .environmentObject(model)
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

        let selection = CorrelationScorer.preferredPair(
            for: rec,
            in: model.records,
            durationTolerance: durationTolerance,
            timestampTolerance: timestampTolerance
        )
        let partner = selection.map {
            rec.streamType == .videoOnly ? $0.audio : $0.video
        }
        let score = selection?.score

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

        // Rick 2026-08-18: decimal via the shared formatter (was base-1024 "GB").
        let catSize = MediaBytes.display(Int64(records.count) * 2048)
        let mediaSize = MediaBytes.display(totalBytes)

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

        // File signatures — coverage AND currency. Rick 2026-08-12:
        // "catalog info for a volume should also show file sigs
        // date-time." Coverage alone answers "did it run"; the dates
        // answer the question that actually matters before a migration
        // — "are these signatures describing the volume as it is NOW, or
        // as it was months ago?"
        let signable = records.filter { $0.purgedAt == nil && $0.sizeBytes > 0 }
        let signed = signable.filter { !$0.contentHash.isEmpty }
        lines.append("")
        lines.append("— File Signatures —")
        if signable.isEmpty {
            lines.append("No signable files")
        } else {
            let pct = Int((Double(signed.count) / Double(signable.count) * 100).rounded())
            lines.append("Signed: \(signed.count) of \(signable.count) (\(pct)%)")
            if signed.count < signable.count {
                lines.append("Missing: \(signable.count - signed.count) "
                             + "— Catalog Options ▸ File Signatures")
            }
            let stamps = signed.compactMap { $0.contentHashAt }
            if let first = stamps.min(), let last = stamps.max() {
                let fmt = DateFormatter()
                fmt.dateStyle = .medium
                fmt.timeStyle = .short
                if Calendar.current.isDate(first, inSameDayAs: last) {
                    lines.append("Computed: \(fmt.string(from: last))")
                } else {
                    lines.append("First computed: \(fmt.string(from: first))")
                    lines.append("Last computed:  \(fmt.string(from: last))")
                }
            }
            if !stamps.isEmpty && stamps.count < signed.count {
                // Signatures written before the timestamp existed, or
                // restored from a cache that predates it.
                lines.append("(\(signed.count - stamps.count) signed before dates were recorded)")
            }
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


// MARK: - Delete Duplicates confirmation copy (2026-08-18)

extension CatalogView {
    /// The alert body states the MODE ("Also clean up working copies"
    /// on/off) and the split so nobody is surprised by a cross-drive
    /// removal. Off = the pre-existing same-drive-only wording.
    var deleteDuplicatesConfirmMessage: String {
        let volume = URL(fileURLWithPath: deleteTargetVolume).lastPathComponent
        var text = "This will permanently delete \(deleteTargetCount) high-confidence duplicate(s) on:\n\n\(deleteTargetVolume)\n\n"
        if deleteTargetCrossMode {
            text += "\(deleteTargetSummary)\n\n"
            text += WorkingCopyCleanupText.confirmationOn + "\n\n"
        } else {
            text += WorkingCopyCleanupText.confirmationOff(volume: volume) + "\n\n"
        }
        text += "Are you sure? Do you have backups and/or are these really junk or duplicates?"
        return text
    }
}
