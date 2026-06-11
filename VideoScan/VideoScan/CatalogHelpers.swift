// CatalogHelpers.swift
// Catalog tab helper views: toolbar, content table, inspector, rename sheet,
// discover-volumes sheet.

import SwiftUI
import AVKit

// MARK: - Toolbar (post-scan actions: correlate, combine, search, export)

struct CatalogToolbar<Dashboard: View>: View {
    @EnvironmentObject var model: VideoScanModel
    let isScanning: Bool
    let isCombining: Bool
    let isCorrelating: Bool
    let isAnalyzingDuplicates: Bool
    let correlateStatus: String
    let duplicateStatus: String
    let videoOnlyCount: Int
    let audioOnlyCount: Int
    let hasRecords: Bool
    let hasCorrelatedPairs: Bool
    let outputCSVPath: String
    let selectedIDs: Set<UUID>
    @Binding var showCombineSheet: Bool
    @Binding var showRelocateSheet: Bool
    @Binding var showDashboard: Bool
    @Binding var searchText: String
    @Binding var showInspector: Bool
    let cacheCount: Int
    let dashboard: DashboardState
    let onStopCombine: () -> Void
    let onCorrelateAll: () -> Void
    let onCorrelateSelected: () -> Void
    let onCorrelateAcrossVolumes: () -> Void
    let onAnalyzeDuplicatesAll: () -> Void
    let onAnalyzeDuplicatesSelected: () -> Void
    let volumesWithDeletableDups: [(path: String, count: Int)]
    let onDeleteDuplicates: (String, Int) -> Void
    let onClearResults: () -> Void
    let onClearCache: () -> Void
    let onScanAvidBins: () -> Void
    let avidBinCount: Int
    let avidBinFiles: Int
    @Binding var showPairsOnly: Bool
    @Binding var viewFilters: Set<CatalogViewFilter>
    /// When on, purged rows render alongside active rows (italic + orange).
    /// Persisted in @AppStorage("catalogShowRemoved") by the parent.
    @Binding var showRemoved: Bool
    @ViewBuilder let dashboardContent: () -> Dashboard

    // MARK: Delete-Confirmed-Junk sheet state
    //
    // Owned by the toolbar so the entry point and the two sheets live in
    // one file — the parent doesn't need to know about either sheet. The
    // workflow is:
    //   1. user clicks "Delete Confirmed Junk… (N)" → showConfirmSheet=true
    //   2. confirm sheet's "Move to Trash" or "Delete Permanently" → run
    //      model.deleteConfirmedJunk, stash result + mode, dismiss confirm,
    //      open result sheet
    //   3. result sheet's OK → dismiss result.
    //
    // SwiftUI `@State` here ≈ a C++ member variable that triggers a view
    // re-render when written. The struct is a value type but @State boxes
    // its storage so mutations persist across re-renders.
    @State private var showJunkConfirmSheet = false
    @State private var showJunkResultSheet = false
    @State private var junkResult: VideoScanModel.JunkDeletionResult?
    @State private var junkResultMode: VideoScanModel.JunkDeletionMode = .toTrash
    @State private var junkResultBytesSucceeded: Int64 = 0
    /// Search-syntax help popover toggled by the `?` button next to
    /// the catalog search field. Local UI state — no need to persist.
    @State private var showSearchHelp = false
    /// Debounced mirror of `searchText`. Updated 250ms after the last
    /// keystroke so the toolbar hit-count badge doesn't recompute on
    /// every character typed. Rick 2026-06-09: this + the CatalogSearch-
    /// Index were the two-part fix for sluggish search typing.
    @State private var debouncedSearchText: String = ""
    /// Cancellable task that fires 250ms after the last keystroke and
    /// propagates `searchText` → `debouncedSearchText`. Reset each
    /// keystroke so only the trailing edge ever lands.
    @State private var searchDebounceTask: Task<Void, Never>? = nil

    /// Active (non-purged) records currently marked .confirmedJunk. This is
    /// the same query the model exposes via `confirmedJunkRecords`; we read
    /// it directly off the published `records` array so the button label
    /// updates live as the user tags more rows.
    private var confirmedJunk: [VideoRecord] {
        model.records.filter {
            $0.mediaDisposition == .confirmedJunk && $0.purgedAt == nil
        }
    }

    /// Memoized badge count for the catalog search bar. A @State cache,
    /// NOT a computed property: this toolbar sits in a nested hosting
    /// view whose constraint passes re-evaluate `body` constantly, and
    /// post-dossier haystacks are multi-KB transcripts. Computing the
    /// scan in `body` (twice — text + color) was 87% of main-thread
    /// time in the 2026-06-10 beachball. Recomputed only when the
    /// debounced query or the record set changes.
    @State private var searchHitCount: Int = 0

    private func recomputeSearchHitCount() {
        guard !debouncedSearchText.isEmpty else {
            searchHitCount = 0
            return
        }
        searchHitCount = model.searchIndex.count(records: model.records,
                                                 query: debouncedSearchText)
    }

    private var canCombine: Bool {
        guard !isScanning && !isCombining else { return false }
        return hasCorrelatedPairs
    }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Clear Results") { onClearResults() }
                    .disabled(!hasRecords)
                Divider()
                Button("Clear All Cache — All Volumes (\(cacheCount) entries)") { onClearCache() }
                    .disabled(cacheCount == 0)
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 80)
            .disabled(isScanning)
            .help("Clear catalog results or cached probe data")

            Divider().frame(height: 22)

            VStack(spacing: 2) {
                Menu {
                    Button("Correlate All", action: onCorrelateAll)
                    Button("Correlate Selected", action: onCorrelateSelected)
                        .disabled(selectedIDs.isEmpty)
                    Divider()
                    Button("Find A/V Pairs Across Volumes", action: onCorrelateAcrossVolumes)
                        .accessibilityIdentifier("catalog.correlate.findPairsAcrossVolumes")
                    Divider()
                    Toggle("Show Pairs Only", isOn: $showPairsOnly)
                        .disabled(!hasCorrelatedPairs)
                } label: {
                    if isCorrelating {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("Correlating…")
                        }
                    } else {
                        Label("Correlate", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .menuStyle(.borderlessButton)
                .disabled(isScanning || isCorrelating || !hasRecords)
                .accessibilityIdentifier("catalog.correlate.menu")
                .help("Match video-only files with their corresponding audio-only files (e.g. Avid MXF pairs)")

                if !correlateStatus.isEmpty {
                    Text(correlateStatus)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(isCorrelating ? .secondary : .green)
                        .lineLimit(1)
                } else if videoOnlyCount > 0 || audioOnlyCount > 0 {
                    Text("\(videoOnlyCount)V + \(audioOnlyCount)A candidates")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 120)

            VStack(spacing: 2) {
                Menu {
                    Button("Analyze All", action: onAnalyzeDuplicatesAll)
                    Button("Analyze Selected", action: onAnalyzeDuplicatesSelected)
                        .disabled(selectedIDs.isEmpty)

                    if !volumesWithDeletableDups.isEmpty {
                        Divider()
                        Menu("Delete Duplicates on Volume…") {
                            ForEach(volumesWithDeletableDups, id: \.path) { vol in
                                Button("\(URL(fileURLWithPath: vol.path).lastPathComponent) — \(vol.count) file\(vol.count == 1 ? "" : "s")") {
                                    onDeleteDuplicates(vol.path, vol.count)
                                }
                            }
                        }
                    }
                } label: {
                    if isAnalyzingDuplicates {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("Analyzing…")
                        }
                    } else {
                        Label("Duplicates", systemImage: "doc.on.doc")
                    }
                }
                .menuStyle(.borderlessButton)
                .disabled(isScanning || isAnalyzingDuplicates || !hasRecords)
                .help("Find duplicate files by comparing hash, duration, filename, resolution, and other signals")

                if !duplicateStatus.isEmpty {
                    Text(duplicateStatus)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(isAnalyzingDuplicates ? .secondary : .yellow)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 120)

            VStack(spacing: 2) {
                Button(action: onScanAvidBins) {
                    HStack(spacing: 4) {
                        Label("Avid Bins", systemImage: "film.stack")
                        if avidBinCount > 0 {
                            Text("\(avidBinCount) clips")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isScanning)
                .help("Scan for Avid .avb bin files and extract clip metadata — badge shows total clips found across all bins")

                if avidBinFiles > 0 {
                    Text("\(avidBinFiles) bins · \(avidBinCount) clips")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.cyan)
                        .lineLimit(1)
                }
            }

            Button(action: { showCombineSheet = true }) {
                Label("Combine", systemImage: "rectangle.stack.badge.plus")
            }
            .buttonStyle(.bordered)
            .disabled(!canCombine && !isCombining)
            .accessibilityIdentifier("catalog.combine.openSheet")
            .help("Mux correlated video + audio pairs into combined files using ffmpeg (no re-encode)")

            Button(action: { showRelocateSheet = true }) {
                Label("Migrate…", systemImage: "externaldrive.badge.checkmark")
            }
            .buttonStyle(.bordered)
            .disabled(!hasRecords)
            .accessibilityIdentifier("catalog.relocate.openSheet")
            .help("Copy catalogued files from a flaky source volume onto a healthier destination and rewrite catalog paths.")

            if isCombining {
                Button(action: onStopCombine) {
                    Label("Stop Combine", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            // Delete Confirmed Junk lives in the Triage toolbar (which has
            // the dispositions + analyze + filters in one place). The
            // confirm/result sheets stay attached below for sheet plumbing
            // — they're presented from this view when invoked from any
            // future entry point in the catalog row context menu.

            Button {
                CatalogScanWindowController.shared.show(dashboard: dashboard, model: model)
            } label: {
                Label("Realtime Scan", systemImage: "waveform.path.ecg.rectangle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)

            if !outputCSVPath.isEmpty {
                Button(action: {
                    NSWorkspace.shared.selectFile(outputCSVPath, inFileViewerRootedAtPath: "")
                }) {
                    Label("Show CSV", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)
            }

            Divider().frame(height: 22)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Try: donna 1990s · mark dan grampa · cape cod beach",
                          text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 320)
                    .accessibilityIdentifier("catalog.searchField")
                    .onChange(of: searchText) { _, newValue in
                        // Cancel any pending debounce so only the trailing
                        // edge of typing lands on debouncedSearchText.
                        searchDebounceTask?.cancel()
                        if newValue.isEmpty {
                            // Empty-clear is instant — no point waiting.
                            debouncedSearchText = ""
                            return
                        }
                        searchDebounceTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            if !Task.isCancelled {
                                debouncedSearchText = newValue
                            }
                        }
                    }
                    .onChange(of: debouncedSearchText) { _, _ in
                        recomputeSearchHitCount()
                    }
                    .onChange(of: model.records.count) { _, _ in
                        recomputeSearchHitCount()
                    }
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        debouncedSearchText = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(6)
            // Match count badge — visible only while there's a query.
            // Counts against the full record set so the badge reflects
            // pre-filter results (i.e. before View-menu filters like
            // Online/Has Family further narrow). Reads the memoized
            // searchHitCount — never scan records inside body.
            if !searchText.isEmpty {
                Text("\(searchHitCount) of \(model.records.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(searchHitCount == 0 ? .red : .secondary)
                    .help("Search hits across filename, people tags, captions, transcripts, and OCR text. Each whitespace-separated word must match somewhere on the record (AND). Year shorthand: 1990s · 199x.")
            }

            // Help popover — surfaces the field-prefix grammar so users
            // don't have to read a docs file to discover `people:donna`
            // / `year:1989..1995` / `caption:beach`. Added 2026-06-08
            // alongside the field-prefix feature itself; without this
            // the feature is invisible.
            Button {
                showSearchHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Search syntax reference")
            .popover(isPresented: $showSearchHelp, arrowEdge: .bottom) {
                CatalogSearchHelpPopover()
            }

            // Persistent dossier progress chip — small ring + N/M label.
            // Click opens the full Dossier Dashboard (⌘⇧O). Always
            // visible while in the catalog tab so Rick can monitor
            // fleet progress without keeping the dashboard window open.
            DossierToolbarChip(model: model)

            Menu {
                ForEach(CatalogViewFilter.allCases, id: \.self) { filter in
                    Toggle(isOn: Binding(
                        get: { viewFilters.contains(filter) },
                        set: { on in
                            if on { viewFilters.insert(filter) }
                            else  { viewFilters.remove(filter) }
                        }
                    )) {
                        Label(filter.rawValue, systemImage: filter.icon)
                    }
                }
                if !viewFilters.isEmpty {
                    Divider()
                    Button("Clear All Filters") { viewFilters.removeAll() }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "line.3.horizontal.decrease.circle\(viewFilters.isEmpty ? "" : ".fill")")
                    Text("View")
                }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 70)
            .help("Filter catalog results")

            // Show-removed toggle — composes with online/View filters above.
            // Purged rows render italic + orange in the table when on.
            // Persisted in @AppStorage by CatalogView.
            Toggle(isOn: $showRemoved) {
                Label("Show removed", systemImage: showRemoved
                      ? "eye.trianglebadge.exclamationmark"
                      : "eye.slash")
                    .labelStyle(.titleAndIcon)
                    .foregroundColor(showRemoved ? .orange : .secondary)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(showRemoved
                  ? "Removed (purged) records are visible — italic + orange. Click to hide."
                  : "Click to show removed records alongside active ones.")

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showInspector.toggle()
                }
            } label: {
                Image(systemName: showInspector ? "sidebar.right" : "sidebar.right")
                    .font(.system(size: 14))
                    .foregroundColor(showInspector ? .accentColor : .secondary)
            }
            .buttonStyle(.bordered)
            .help(showInspector ? "Hide Inspector" : "Show Inspector")

            dashboardContent()
        }
        .padding(10)
        .background(Color(NSColor.windowBackgroundColor))
        // Confirmation sheet — picks Move to Trash vs Delete Permanently.
        .sheet(isPresented: $showJunkConfirmSheet) {
            let snapshot = confirmedJunk
            DeleteConfirmedJunkConfirmSheet(
                records: snapshot,
                onCancel: { /* dismiss is automatic */ },
                onAct: JunkDeleteAction.makeOnAct(model: model) { result, mode, bytesSucceeded in
                    junkResult = result
                    junkResultMode = mode
                    junkResultBytesSucceeded = bytesSucceeded
                    // Chained .sheet trap: flipping the result-sheet
                    // flag synchronously collides with the confirm
                    // sheet's dismiss animation — SwiftUI only allows
                    // one sheet per view at a time. Defer just past
                    // the dismiss animation window.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showJunkResultSheet = true
                    }
                }
            )
        }
        // Result sheet — shows succeeded/missing/failed breakdown.
        .sheet(isPresented: $showJunkResultSheet) {
            if let r = junkResult {
                DeleteConfirmedJunkResultSheet(
                    mode: junkResultMode,
                    result: r,
                    bytesSucceeded: junkResultBytesSucceeded
                )
            }
        }
    }

}

// MARK: - Table + Preview + Inspector

struct CatalogContent: View {
    @EnvironmentObject var model: VideoScanModel
    /// Media File Operations registry — "Compare These Two Files…" hands
    /// the pair to the center and opens the operations window; the job
    /// runs there (non-modal), not in a sheet.
    @EnvironmentObject var fileOpsCenter: MediaFileOperationsCenter
    @Environment(\.openWindow) private var openWindow
    let records: [VideoRecord]
    @Binding var selectedIDs: Set<UUID>
    @Binding var sortOrder: [KeyPathComparator<VideoRecord>]
    let searchText: String
    let filterTargetPaths: Set<String>
    let showPairsOnly: Bool
    let viewFilters: Set<CatalogViewFilter>
    /// When true, purged rows are included in the table (rendered italic +
    /// orange, with a restricted context menu). When false (default), purged
    /// rows are hidden — they remain in catalog.json for recoverability.
    let showRemoved: Bool
    /// When non-empty, show only these specific records (overrides all other filters).
    /// Used by Archive tab's "Show in Catalog" / "Show Pair in Catalog".
    var filterByIDs: Set<UUID> = []
    /// When `filterByIDs` was populated by an on-demand "Find A/V Pair", carries
    /// the score so the focus banner can show a Best/Better/Good/Maybe label.
    /// nil for filters from other sources (Archive, already-paired).
    var focusMatchScore: Int?
    /// Focus-banner caption — what put the table into filterByIDs mode.
    /// Default preserves the historical wording; "Find Online Version"
    /// passes "Online copies" so the banner doesn't claim a pair focus.
    var focusLabel: String = "A/V Pair focus"
    let previewImage: NSImage?
    let previewFilename: String
    let previewOfflineVolumeName: String?
    @Binding var showInspector: Bool
    let onSort: ([KeyPathComparator<VideoRecord>]) -> Void
    let onSelect: (UUID?) -> Void
    let onClearPreview: () -> Void
    var onCombinePair: ((VideoRecord, VideoRecord) -> Void)?
    var onShowPair: ((UUID, UUID) -> Void)?
    var onFindAVPair: ((VideoRecord) -> Void)?
    var onClearFilter: (() -> Void)?
    var onShowInArchive: ((VideoRecord) -> Void)?
    /// "Find Online Version" found mounted copies — parent focuses the
    /// catalog on (originalID + online copy IDs) and selects the best
    /// copy. Mirrors onShowPair's contract.
    var onShowOnlineCopies: ((_ focusIDs: Set<UUID>, _ selectID: UUID) -> Void)?

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var showRenameSheet = false
    @State private var renameTarget: VideoRecord?
    @State private var renameText: String = ""
    /// Non-nil drives an alert + keeps the rename sheet re-openable so the
    /// user sees *why* nothing happened. Original code silently caught the
    /// FileManager error and dismissed the sheet, leaving the user staring
    /// at the unchanged catalog wondering what went wrong.
    @State private var renameError: String?
    @State private var showNotesSheet = false
    @State private var notesTarget: VideoRecord?
    @State private var notesText: String = ""

    /// §2 Provenance & Audit Trail — File Journey sheet backing. Built
    /// fresh from the right-clicked record; the sheet binding drops the
    /// value on dismiss. Swift's `Identifiable?` ≈ a nullable handle that
    /// drives a sheet present/dismiss cycle.
    @State private var fileJourneyPayload: FileJourney?

    /// Stable snapshot the Table reads from. Decoupled from `records` so the
    /// Table never sees the data array mutate mid-gesture (which races with
    /// AppKit's canDragRows / mouseDown handling and crashes inside
    /// ForEach.IDGenerator with an out-of-bounds subscript).
    @State private var tableData: [VideoRecord] = []

    // "Extract Facial Frames…" (Rick 2026-06-09, Donna's birthday-
    // print project) runs as an ExtractFramesJob in the Media File
    // Operations window since phase 2 — no view-local ripper state.

    /// "Extract Frames…" (ffmpeg-only, verb split 2026-06-10) — the
    /// right-clicked record awaiting its sampling-options sheet.
    /// Non-nil drives the sheet; the job itself lives in the Media
    /// File Operations center once the user confirms.
    @State private var ripAllFramesTarget: VideoRecord?

    /// "Find Online Version" came up empty — non-nil drives an alert
    /// explaining where copies exist (all offline) or that this is the
    /// only cataloged copy. The success path never touches this; it
    /// goes straight to onShowOnlineCopies.
    @State private var findOnlineNotice: String?

    /// Memo boxes for per-render derivations (perf batch 2026-06-10).
    /// RenderMemo is a CLASS held by @State — mutating it during body
    /// does not trigger a view update, which is exactly what a render-
    /// time memo needs. See CatalogPerfMemo.swift.
    @State private var duplicateGroupMemo = RenderMemo<DuplicateGroupMemoKey, [VideoRecord]>()
    @State private var mediaOnVolumeMemo = RenderMemo<MediaOnVolumeMemoKey, Int64>()

    private struct DuplicateGroupMemoKey: Equatable {
        let selectedID: UUID
        let version: RecordsVersion
        let analyzing: Bool
    }

    private struct MediaOnVolumeMemoKey: Equatable {
        let path: String
        let version: RecordsVersion
    }

    /// Composite records "version" — count catches add/remove, the model's
    /// volumeAggregatesRevision catches bulk in-place mutations.
    private var recordsVersion: RecordsVersion {
        RecordsVersion(count: records.count, revision: model.volumeAggregatesRevision)
    }

    private var selectedRecord: VideoRecord? {
        guard let id = selectedIDs.first else { return nil }
        // O(1) via the model's id index — this is evaluated several times
        // per body, and the old linear scan was ~27K iterations each.
        return model.record(forID: id)
    }

    /// All records sharing the selected record's duplicate group (excluding the selected record itself).
    /// Memoized on (selected id, records version, analysis-active flag) — the
    /// O(n) filter used to run on every body re-eval while the inspector was open.
    private var duplicateGroupMembers: [VideoRecord] {
        guard let rec = selectedRecord,
              let groupID = rec.duplicateGroupID else { return [] }
        let key = DuplicateGroupMemoKey(
            selectedID: rec.id,
            version: recordsVersion,
            analyzing: model.isAnalyzingDuplicates   // flip → recompute once analysis lands
        )
        return duplicateGroupMemo.value(for: key) {
            records.filter { $0.duplicateGroupID == groupID && $0.id != rec.id }
        }
    }

    private func volumeRoot(for path: String) -> String {
        if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/", maxSplits: 3)
            if parts.count >= 2 { return "/Volumes/" + String(parts[1]) }
        }
        return "/"
    }

    private func volumeDiskSize(path: String) -> String {
        // Was a statfs PER RENDER (blocking syscall — beachballs on
        // sleeping HDDs). Now stale-while-revalidate via VolumeStatsCache,
        // same engine as the VolumeReachability fix in 109cc36; mount/
        // unmount events invalidate it. First-ever query renders "" for
        // one frame while the background probe fills in.
        guard let total = VolumeStatsCache.diskSizeBytes.value(forKey: path, missDefault: nil)
        else { return "" }
        return formatBytes(total)
    }

    private func mediaOnVolume(path: String) -> String {
        // O(n) reduce memoized per (volume root, records version) — was
        // re-walking the full catalog on every body re-eval.
        let key = MediaOnVolumeMemoKey(path: path, version: recordsVersion)
        let bytes = mediaOnVolumeMemo.value(for: key) {
            records.filter { $0.fullPath.hasPrefix(path) }
                .reduce(into: Int64(0)) { $0 += $1.sizeBytes }
        }
        guard bytes > 0 else { return "0 MB" }
        return formatBytes(bytes)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let kb: Int64 = 1_024
        let mb: Int64 = 1_048_576
        let gb: Int64 = 1_073_741_824
        let tb: Int64 = 1_099_511_627_776
        if bytes < mb {
            return String(format: "%.0f KB", Double(bytes) / Double(kb))
        } else if bytes < gb {
            return String(format: "%.1f MB", Double(bytes) / Double(mb))
        } else if bytes < tb {
            return String(format: "%.1f GB", Double(bytes) / Double(gb))
        } else {
            return String(format: "%.2f TB", Double(bytes) / Double(tb))
        }
    }

    private func computeFiltered() -> [VideoRecord] {
        // Explicit-IDs ask always wins, including over Show-Removed. The
        // filterByIDs path is driven by user navigation ("Show in Catalog",
        // "Show Pair in Catalog") — they asked for those specific records,
        // so surface them whether or not the row happens to be purged or
        // the Show-Removed toggle is on.
        if !filterByIDs.isEmpty {
            return records.filter { filterByIDs.contains($0.id) }
        }
        // Default: hide soft-deleted (purged) records. Composes with all the
        // filters below — purge filter applied FIRST so each downstream filter
        // sees a smaller input. Toggling Show Removed is a pure inclusion (it
        // adds purged rows back; it doesn't change online/View semantics).
        var out = pfApplyPurgeFilter(records, showRemoved: showRemoved)
        if !filterTargetPaths.isEmpty {
            let prefixes = Array(filterTargetPaths)
            // Match records currently at this volume OR records that originated
            // here and were relocated elsewhere (Bucket-A copy, Bucket-D adoption).
            // Without the originalFullPath check, clicking a source volume after a
            // Relocate run shows 0 records — the records still exist but live
            // under the destination volume now.
            out = out.filter { rec in
                prefixes.contains(where: { prefix in
                    rec.fullPath.hasPrefix(prefix)
                    || (rec.originalFullPath?.hasPrefix(prefix) ?? false)
                })
            }
        }
        if !searchText.isEmpty {
            // Search routes through the model's CatalogSearchIndex so the
            // per-keystroke cost is haystack.contains() per record — no
            // re-lowercasing or re-concatenation of every audio transcript
            // and OCR field. Correctness is identical to the canonical
            // pfRecordFilenameOrPersonMatch (pinned by index unit tests).
            // Rick 2026-06-09: this is the fast path that made search
            // feel instant on 15k-record catalogs.
            out = model.searchIndex.filter(records: out, query: searchText)
        }
        if showPairsOnly {
            // Only show records that have a correlated partner
            let pairedIDs = Set(out.compactMap { $0.pairedWith != nil ? $0.id : nil })
            let partnerIDs = Set(out.compactMap { $0.pairedWith?.id })
            let allPairIDs = pairedIDs.union(partnerIDs)
            out = out.filter { allPairIDs.contains($0.id) }

            // Collect video records (one per pair), sort by current table sort
            var videos = out.filter { $0.streamType == .videoOnly && $0.pairedWith != nil }
            videos.sort(using: sortOrder)

            // Flatten: video then its audio partner, in sort order
            var result: [VideoRecord] = []
            for v in videos {
                result.append(v)
                if let a = v.pairedWith { result.append(a) }
            }
            out = result
        }
        // View menu filters (additive — each active filter narrows further)
        if viewFilters.contains(.onlineOnly) {
            out = out.filter { VolumeReachability.isReachable(path: $0.fullPath) }
        }
        if viewFilters.contains(.videoAndAudioOnly) {
            out = out.filter { $0.streamType == .videoAndAudio }
        }
        if viewFilters.contains(.unpairedOnly) {
            out = out.filter {
                ($0.streamType == .videoOnly || $0.streamType == .audioOnly) && $0.pairedWith == nil
            }
        }
        if viewFilters.contains(.ratedOnly) {
            out = out.filter { $0.starRating > 0 }
        }
        if viewFilters.contains(.hasFamily) {
            out = out.filter(pfRecordHasAnyPerson)
        }
        if viewFilters.contains(.untaggedOnly) {
            out = out.filter(pfRecordIsUntagged)
        }
        return out
    }

    var body: some View {
        HSplitView {
            // MARK: Left side — Table + Player
            VSplitView {
                VStack(spacing: 0) {
                    if !filterByIDs.isEmpty {
                        pairFilterBanner
                    }
                    // Inline undo affordance for the most recent purge. Sits
                    // above the table so it never reflows the grid below —
                    // the VStack just gets one more row when armed.
                    purgeUndoBanner
                    catalogTable
                }
                    .frame(minHeight: 250)

                previewPlayer
                    .frame(minHeight: 140, idealHeight: 220)
                    .background(Color(NSColor.controlBackgroundColor))
            }
            .frame(minWidth: 500)

            // MARK: Right side — Inspector
            if showInspector {
                InspectorPanel(
                    record: selectedRecord,
                    duplicateGroupMembers: duplicateGroupMembers,
                    previewImage: previewImage,
                    previewOfflineVolumeName: previewOfflineVolumeName,
                    onSelectRecord: { id in
                        selectedIDs = [id]
                        onSelect(id)
                    }
                )
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 400)
            }
        }
        .onChange(of: selectedIDs) {
            if isPlaying {
                player?.pause()
                player = nil
                isPlaying = false
            }
            if let id = selectedIDs.first {
                onSelect(id)
            } else {
                onClearPreview()
            }
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameSheet(
                filename: $renameText,
                originalExt: (renameTarget?.filename as NSString?)?.pathExtension ?? "",
                onConfirm: { performRename() },
                onCancel: { showRenameSheet = false }
            )
        }
        // Surface rename failures (silent fail was the original bug).
        // `Binding(get:set:)` lets us treat the optional string as the
        // alert's isPresented trigger; setting to false clears the error.
        .alert(
            "Couldn't Rename File",
            isPresented: Binding(
                get: { renameError != nil },
                set: { if !$0 { renameError = nil } }
            ),
            presenting: renameError
        ) { _ in
            Button("Try Again") {
                renameError = nil
                // Re-open the sheet so the user can adjust the name. The
                // sheet state retains `renameTarget` and `renameText` so
                // the user picks up exactly where they were.
                if renameTarget != nil { showRenameSheet = true }
            }
            Button("Cancel", role: .cancel) {
                renameError = nil
                renameTarget = nil
                renameText = ""
            }
        } message: { msg in
            Text(msg)
        }
        .sheet(isPresented: $showNotesSheet) {
            NotesSheet(
                notes: $notesText,
                filename: notesTarget?.filename ?? "",
                onConfirm: {
                    notesTarget?.notes = notesText
                    model.saveCatalogDebounced()
                    showNotesSheet = false
                },
                onCancel: { showNotesSheet = false }
            )
        }
        // §2 Provenance & Audit Trail — File Journey sheet.
        .sheet(item: $fileJourneyPayload) { payload in
            FileJourneySheet(journey: payload)
        }
        // "Extract Frames…" options sheet (sampling + disk estimate).
        // .sheet(item:) per the chained-sheet antipattern memo —
        // VideoRecord is Identifiable, so the binding drives the
        // present/dismiss cycle directly.
        .sheet(item: $ripAllFramesTarget) { rec in
            RipAllFramesSheet(record: rec)
        }
        .alert(
            "Find Online Version",
            isPresented: Binding(
                get: { findOnlineNotice != nil },
                set: { if !$0 { findOnlineNotice = nil } }
            ),
            presenting: findOnlineNotice
        ) { _ in
            Button("OK", role: .cancel) { findOnlineNotice = nil }
        } message: { msg in
            Text(msg)
        }
    }

    /// User picked "Find Online Version" on an offline record. Strict
    /// same-content match (hash+size / UMID / dup-group — see
    /// OnlineCopyFinder), then: mounted copy found → focus the catalog
    /// on the copy group via onShowOnlineCopies; copies exist but all
    /// offline → alert naming their volumes; no copies → alert saying
    /// this is the only cataloged one.
    private func findOnlineVersion(for rec: VideoRecord) {
        let copies = OnlineCopyFinder(records: records).sameContentCopies(of: rec)
        let online = copies.filter { VolumeReachability.isReachable(path: $0.fullPath) }
        if let best = online.first {
            onShowOnlineCopies?(Set([rec.id] + online.map(\.id)), best.id)
        } else if copies.isEmpty {
            findOnlineNotice = """
                No other copy of “\(rec.filename)” is in the catalog. \
                The only known copy is on \(VolumeReachability.displayLabel(forPath: rec.fullPath)) (offline).
                """
        } else {
            let vols = Set(copies.map { VolumeReachability.displayLabel(forPath: $0.fullPath) })
                .sorted()
            findOnlineNotice = """
                \(copies.count) cop\(copies.count == 1 ? "y" : "ies") of “\(rec.filename)” \
                exist\(copies.count == 1 ? "s" : "") — on \(vols.joined(separator: ", ")) — \
                but none of those volumes is mounted right now.
                """
        }
    }

    /// User picked "Extract Facial Frames…" — show a folder picker,
    /// then hand the rip to the Media File Operations center and open
    /// its window (same pattern as "Compare These Two Files…"). The
    /// job owns the run Task, so it survives this view and the window
    /// closing. (The ffmpeg-only "Extract Frames…" verb goes through
    /// RipAllFramesSheet instead — it needs sampling options and a
    /// disk-usage estimate before start.)
    private func startFrameRip(for rec: VideoRecord) {
        let panel = NSOpenPanel()
        panel.title = "Save extracted facial frames into…"
        panel.message = "Pick the parent folder. A subfolder named \"<video>-frames\" will be created inside."
        panel.canCreateDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        fileOpsCenter.startExtract(record: rec, destinationParent: dest)
        openWindow(id: "combine")
    }

    private func performRename() {
        guard let rec = renameTarget else { return }

        // Close the sheet first; if the rename fails we re-open via the
        // alert's "Try Again" button. Dismissing here keeps the UI from
        // double-stacking sheet+alert when the alert appears.
        showRenameSheet = false

        do {
            try model.renameRecord(rec, toBaseName: renameText)
            // Success: refresh the cached table snapshot so the row
            // re-renders with the new name. saveCatalogDebounced() is
            // already invoked inside renameRecord.
            tableData = computeFiltered()
            renameTarget = nil
            renameText = ""
        } catch VideoScanModel.RenameError.nameUnchanged,
                VideoScanModel.RenameError.emptyName {
            // Treat "user opened sheet and clicked OK with no change"
            // and "user cleared the field" as no-ops, not errors. Matches
            // the original behavior and avoids alert spam.
            renameTarget = nil
            renameText = ""
        } catch let err as VideoScanModel.RenameError {
            renameError = err.errorDescription ?? "Unknown rename error."
        } catch {
            renameError = error.localizedDescription
        }
    }

    private var pairFilterBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.horizontal.3.decrease.circle.fill")
                .foregroundColor(.accentColor)
            Text("\(focusLabel) (\(filterByIDs.count) file\(filterByIDs.count == 1 ? "" : "s"))")
                .font(.system(size: 12, weight: .medium))

            if let score = focusMatchScore {
                let q = CorrelationScorer.MatchQuality.bucket(forScore: score)
                Text("\(q.rawValue) match")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(matchQualityColor(q).opacity(0.18),
                                in: RoundedRectangle(cornerRadius: 4))
                    .foregroundColor(matchQualityColor(q))
                    .help("Score \(score)/14 — Best ≥10, Better 7–9, Good 4–6, Maybe 3")
            }

            Spacer()

            if let rec = records.first(where: { filterByIDs.contains($0.id) }),
               let partner = rec.pairedWith, filterByIDs.contains(partner.id) {
                Button("Combine This Pair…") {
                    let video = rec.streamType == .videoOnly ? rec : partner
                    let audio = rec.streamType == .audioOnly ? rec : partner
                    onCombinePair?(video, audio)
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11))
            }

            Button("Show All") {
                onClearFilter?()
            }
            .buttonStyle(.bordered)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }

    private func matchQualityColor(_ q: CorrelationScorer.MatchQuality) -> Color {
        switch q {
        case .best:   return .green
        case .better: return .blue
        case .good:   return .orange
        case .maybe:  return .secondary
        }
    }

    // MARK: - Purge Undo Banner
    //
    // Inline undo affordance for the most recent "Remove from Catalog"
    // action. Mirrors the POI undo banner exactly — same orange palette,
    // same layout, same dismissal rules (Undo / × / superseded by next
    // purge / app relaunch). No auto-dismiss timer; Rick wants to take
    // his time.
    @ViewBuilder
    private var purgeUndoBanner: some View {
        if let batch = model.lastPurgedBatch {
            HStack(spacing: 10) {
                Image(systemName: "trash.slash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.orange)
                if let err = model.lastPurgeUndoError {
                    Text(err)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.red)
                } else {
                    let n = batch.ids.count
                    Text("Removed \(n) item\(n == 1 ? "" : "s").")
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                }
                Button("Undo") {
                    _ = model.undoLastPurge()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut("z", modifiers: .command)

                Spacer()

                Button {
                    model.dismissPurgeUndoBanner()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.secondary, Color.secondary.opacity(0.2))
                }
                .buttonStyle(.plain)
                .help("Dismiss — purged records stay hidden until you flip Show Removed and right-click → Restore")
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
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Right-click menu shown when one or more purged rows is selected.
    /// Per spec, this is intentionally minimal: Restore + Reveal in Finder.
    /// Everything else (Combine, Correlate, Tag, Notes, ...) is suppressed —
    /// purged records are inert until restored.
    @ViewBuilder
    private func purgedRowContextMenu(rec: VideoRecord, selectedRecs: [VideoRecord]) -> some View {
        let purgedSelection = selectedRecs.filter { $0.isPurged }
        Button {
            for r in purgedSelection {
                _ = model.restoreRecord(id: r.id)
            }
        } label: {
            Label(purgedSelection.count > 1
                  ? "Restore \(purgedSelection.count) to Catalog"
                  : "Restore to Catalog",
                  systemImage: "arrow.uturn.backward.circle")
        }
        if VolumeReachability.isReachable(path: rec.fullPath) {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(rec.fullPath, inFileViewerRootedAtPath: "")
            }
        }
    }

    // MARK: - Results Table

    private var catalogTable: some View {
        Table(tableData, selection: $selectedIDs, sortOrder: $sortOrder) {
            TableColumn("Filename", value: \.filename) { rec in
                let offline = !VolumeReachability.isReachable(path: rec.fullPath)
                let purged = rec.isPurged
                HStack(spacing: 4) {
                    if purged {
                        // Trash-slash icon makes the "removed" state obvious
                        // at a glance — even if the user's row colors are
                        // partially overridden by a high-contrast theme.
                        Image(systemName: "trash.slash")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    } else if showPairsOnly && rec.pairedWith != nil {
                        Image(systemName: rec.streamType == .videoOnly ? "film" : "waveform")
                            .font(.system(size: 10))
                            .foregroundColor(rec.streamType == .videoOnly ? .blue : .green)
                    }
                    Text(rec.filename)
                        .font(.system(.body, design: .monospaced))
                        // Italic when offline OR purged — both signal "not the
                        // active default state". Purge color (orange) wins over
                        // both offline-secondary and pair-blue/green when set.
                        .italic(offline || purged)
                        .foregroundColor(purged ? .orange
                            : (offline ? .secondary
                                : (showPairsOnly && rec.pairedWith != nil
                                   ? (rec.streamType == .videoOnly ? .blue : .green)
                                   : rec.filenameColor)))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .help(purged ? "\(rec.directory) (removed from catalog)"
                      : (offline ? "\(rec.directory) (offline)" : rec.directory))
            }
            .width(min: 180, ideal: 260)

            // Sort by `displayVolumeLabel` so folder-scoped scans of the same
            // folder name (e.g. multiple "Movies" subfolders across volumes)
            // sort together under their owning volume. The label embeds the
            // volume name as the prefix, so this preserves volume grouping.
            TableColumn("Volume", value: \.displayVolumeLabel) { rec in
                Text(rec.displayVolumeLabel)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .help(rec.fullPath)
            }
            .width(min: 80, ideal: 160)

            TableColumn("Stream", value: \.streamTypeRaw) { rec in
                let unpaired = rec.streamType.needsCorrelation && rec.pairedWith == nil
                let display = rec.streamType == .ffprobeFailed
                    ? rec.isPlayable
                    : rec.streamTypeRaw
                Text(display)
                    .foregroundColor(unpaired ? .orange : streamTypeColor(rec.streamType))
                    .bold(rec.streamType.needsCorrelation)
                    .help(unpaired
                          ? (rec.streamType == .videoOnly ? "No audio pair found" : "No video pair found")
                          : "V+A = video and audio, V-only/A-only = single stream, or file status if damaged")
            }
            .width(min: 90, ideal: 130)

            TableColumn("Duration", value: \.durationSeconds) { rec in
                Text(rec.duration)
                    .help("Playback duration (HH:MM:SS)")
            }
            .width(min: 65, ideal: 75)

            TableColumn("Resolution", value: \.pixelCount) { rec in
                Text(rec.resolution)
                    .help("Video frame size (width x height)")
            }
            .width(min: 80, ideal: 95)

            TableColumn("Codec", value: \.videoCodec) { rec in
                Text(rec.videoCodec.isEmpty ? "—" : rec.videoCodec)
                    .foregroundColor(rec.videoCodec.isEmpty ? .secondary : .primary)
                    .help("Video codec (e.g. h264, prores, mpeg2video)")
            }
            .width(min: 60, ideal: 80)

            // Dossier channel-dots column — at-a-glance richness per
            // record. Four dots = scene captions / audio transcript /
            // OCR text / OCR dates. Sorts by total channel count so
            // ascending → emptiest-first ("what's left to do") and
            // descending → richest-first ("what's been captured").
            TableColumn("Dossier", value: \.dossierChannelCount) { rec in
                DossierChannelDots(record: rec)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .width(min: 64, ideal: 72)

            TableColumn("Size", value: \.sizeBytes) { rec in
                Text(rec.size)
                    .help("File size on disk")
            }
            .width(min: 60, ideal: 75)

            TableColumn("Created", value: \.dateCreatedSortKey) { rec in
                Text(rec.dateCreated.isEmpty ? "—" : rec.dateCreated)
                    .foregroundColor(rec.dateCreated.isEmpty ? .secondary : .primary)
                    .font(.system(size: 11))
                    .help("File creation date from filesystem metadata")
            }
            .width(min: 80, ideal: 100)

            // Last three columns wrapped in Group to stay under the 10-child
            // limit of Swift's @TableColumnBuilder. The People column (Step 5)
            // is the 11th, so we group People + Tag + Duplicate.
            //
            // People column: confirmed names in blue, suspected (borderline)
            // names italic + secondary with a leading "?". Em-dash when both
            // arrays are empty — the "junk candidate" signal the user filters
            // on with .untaggedOnly. Sortable via peopleSortKey: confirmed
            // alphabetical first, suspected after (~ prefix), untagged last.
            Group {
                TableColumn("People", value: \.peopleSortKey) { rec in
                    peopleColumnCell(for: rec)
                }
                .width(min: 90, ideal: 140)

                TableColumn("Tag") { rec in
                    tagColumnCell(for: rec)
                }
                .width(min: 70, ideal: 120)

                TableColumn("Duplicate") { rec in
                    DuplicateDispositionCell(record: rec)
                        .help(rec.duplicateDisposition == .none
                              ? "Run Duplicates analysis to check for copies"
                              : "Total copies across catalog. Color: green = Keep (best copy), orange = Review (check manually), red = Extra copy (safe to remove)")
                }
                .width(min: 80, ideal: 95)
            }
        }
        .onChange(of: sortOrder) {
            onSort(sortOrder)
            tableData.sort(using: sortOrder)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            let selectedRecs = ids.compactMap { id in records.first { $0.id == id } }
            // Mixed-selection split. Each predicate is computed once so the
            // Restore / Remove menu items use the same record set their
            // actions operate on (label counts == operated-on counts).
            // Swift's `.filter` ≈ C++ std::copy_if into a new vector.
            let activeRecs = selectedRecs.filter { !$0.isPurged }
            let purgedRecs = selectedRecs.filter { $0.isPurged }
            if let id = ids.first,
               let rec = records.first(where: { $0.id == id }) {
                // Pure-purged selection: minimal menu (Restore + Reveal).
                // Mixed selection: show the full active menu PLUS a Restore
                // item for the purged subset; row-targeted active actions
                // (Combine, Rename, Tag, etc.) are gated on
                // `purgedRecs.isEmpty` so a multi-select that pulled in any
                // purged row doesn't silently apply destructive ops to it.
                // Spec: "active-only row actions must be gated on
                // purgedRecs.isEmpty".
                if !activeRecs.isEmpty || rec.isPurged {
                    if rec.isPurged && activeRecs.isEmpty {
                        purgedRowContextMenu(rec: rec, selectedRecs: selectedRecs)
                    } else {
                        // Active or mixed selection — show the full menu,
                        // gating active-row actions on purgedRecs.isEmpty.
                        let pureActive = purgedRecs.isEmpty
                        Button(VolumeReachability.isReachable(path: rec.fullPath)
                               ? "Reveal in Finder"
                               : "Reveal in Finder (offline)") {
                            if VolumeReachability.isReachable(path: rec.fullPath) {
                                NSWorkspace.shared.selectFile(rec.fullPath, inFileViewerRootedAtPath: "")
                            } else {
                                let alert = NSAlert()
                                alert.messageText = "File Offline"
                                alert.informativeText = "The volume containing this file is not mounted.\n\n\(rec.fullPath)"
                                alert.alertStyle = .informational
                                alert.addButton(withTitle: "OK")
                                alert.runModal()
                            }
                        }
                        Button("Open in QuickTime Player") {
                            if let qtURL = NSWorkspace.shared.urlForApplication(
                                withBundleIdentifier: "com.apple.QuickTimePlayerX"
                            ) {
                                NSWorkspace.shared.open(
                                    [URL(fileURLWithPath: rec.fullPath)],
                                    withApplicationAt: qtURL,
                                    configuration: NSWorkspace.OpenConfiguration()
                                )
                            }
                        }

                        Divider()

                        // File operations — every verb that runs as a job
                        // in the Media File Operations window lives in this
                        // ONE section, alphabetized (Rick 2026-06-10). New
                        // verbs (merge, analyze, …) join here, in order.
                        if pureActive, let partner = rec.pairedWith {
                            Button("Combine This Pair…") {
                                let video = rec.streamType == .videoOnly ? rec : partner
                                let audio = rec.streamType == .audioOnly ? rec : partner
                                onCombinePair?(video, audio)
                            }
                            .accessibilityIdentifier("catalog.row.combineThisPair")
                        }
                        if pureActive, selectedRecs.count == 2,
                           let fileA = selectedRecs.first,
                           let fileB = selectedRecs.last {
                            // Quick two-file check — exact copies, same
                            // movie in a different wrapper, or genuinely
                            // different? Only with exactly two rows
                            // selected. Distinct from the volume-level
                            // Compare & Rescue feature.
                            Button("Compare These Two Files…") {
                                fileOpsCenter.startCompare(
                                    recordA: fileA, recordB: fileB)
                                openWindow(id: "combine")
                            }
                            .disabled(!VolumeReachability.isReachable(path: fileA.fullPath)
                                      || !VolumeReachability.isReachable(path: fileB.fullPath))
                            .help("Check whether these two files are exact copies, the same movie in a different wrapper, or genuinely different.")
                            .accessibilityIdentifier("catalog.row.compareTwoFiles")
                        }
                        // Extract Facial Frames — best portrait frames as
                        // lossless PNGs, Vision face-quality ranked (Donna's
                        // Aug 4 birthday print). Disabled when the file is
                        // offline. (Renamed from "Extract Frames…" when the
                        // ffmpeg-only verb below was added, 2026-06-10.)
                        Button("Extract Facial Frames…") {
                            startFrameRip(for: rec)
                        }
                        .disabled(!VolumeReachability.isReachable(path: rec.fullPath))
                        .accessibilityIdentifier("catalog.row.extractFacialFrames")
                        // Extract Frames — ffmpeg-only frame export (every
                        // frame / every Nth / N per second), no Vision.
                        // Opens an options sheet first: this verb can write
                        // tens of thousands of PNGs, so the user sees the
                        // frame-count + disk estimate before anything runs.
                        Button("Extract Frames…") {
                            ripAllFramesTarget = rec
                        }
                        .disabled(!VolumeReachability.isReachable(path: rec.fullPath))
                        .accessibilityIdentifier("catalog.row.extractFrames")

                        if pureActive {
                            Divider()

                            Button("Rename…") {
                                renameTarget = rec
                                renameText = (rec.filename as NSString).deletingPathExtension
                                showRenameSheet = true
                            }

                            Divider()

                            Menu("Tag") {
                                Button {
                                    for r in selectedRecs { r.mediaDisposition = .important }
                                    model.saveCatalogDebounced()
                                } label: {
                                    Label("Important", systemImage: "star.fill")
                                }
                                Button {
                                    for r in selectedRecs { r.mediaDisposition = .recoverable }
                                    model.saveCatalogDebounced()
                                } label: {
                                    Label("Recoverable", systemImage: "wrench.and.screwdriver.fill")
                                }

                                Divider()

                                Button {
                                    for r in selectedRecs { r.mediaDisposition = .suspectedJunk }
                                    model.saveCatalogDebounced()
                                } label: {
                                    Label("Suspected Junk", systemImage: "exclamationmark.triangle")
                                }
                                Button {
                                    for r in selectedRecs { r.mediaDisposition = .confirmedJunk }
                                    model.saveCatalogDebounced()
                                } label: {
                                    Label("Junk", systemImage: "xmark.circle.fill")
                                }

                                Divider()

                                Button {
                                    for r in selectedRecs { r.mediaDisposition = .unreviewed }
                                    model.saveCatalogDebounced()
                                } label: {
                                    Label("Clear Tag", systemImage: "arrow.counterclockwise")
                                }
                            }

                            Button("Notes\u{2026}") {
                                notesTarget = rec
                                notesText = rec.notes
                                showNotesSheet = true
                            }

                            // Show duplicate group matches
                            let groupMatches = records.filter {
                                $0.id != rec.id && $0.duplicateGroupID != nil && $0.duplicateGroupID == rec.duplicateGroupID
                            }
                            if !groupMatches.isEmpty {
                                let onlineMatches = groupMatches.filter {
                                    VolumeReachability.isReachable(path: $0.fullPath)
                                }

                                if !onlineMatches.isEmpty {
                                    // Extracted to a dedicated method so Xcode 16.4 has a tiny,
                                    // isolated type-check context for the Menu→ForEach→Section→
                                    // ForEach chain. Inline, the compiler was leaking
                                    // ChartContentBuilder candidates into overload resolution.
                                    onlineCopyMenu(onlineMatches: onlineMatches)
                                }

                                Menu("All Matches (\(groupMatches.count))") {
                                    ForEach(groupMatches) { dup in
                                        let online = VolumeReachability.isReachable(path: dup.fullPath)
                                        Button {
                                            selectedIDs = [dup.id]
                                            onSelect(dup.id)
                                        } label: {
                                            let vol = VolumeReachability.displayLabel(forPath: dup.fullPath)
                                            Text("\(dup.filename) — \(vol)\(online ? "" : " (offline)")")
                                        }
                                    }
                                }
                            }

                            // ("Compare These Two Files…" moved to the
                            // file-operations section near the top of this
                            // menu — Rick 2026-06-10: all fileops verbs
                            // grouped + alphabetized.)

                            if rec.streamType.needsCorrelation {
                                Divider()
                                Button("Find A/V Pair") {
                                    onFindAVPair?(rec)
                                }
                                .help("Show this file's best matching pair in the catalog, including any online duplicates of either side.")
                            }
                            // ("Combine This Pair…" likewise lives in the
                            // file-operations section now.)

                            // Find Online Version — only offered when the
                            // file itself is unreachable (the verb answers
                            // "this one's offline, what CAN I use?").
                            // Strict identity match, never the fuzzy
                            // duplicate scorer — see OnlineCopyFinder.
                            if !VolumeReachability.isReachable(path: rec.fullPath) {
                                Divider()
                                Button {
                                    findOnlineVersion(for: rec)
                                } label: {
                                    Label("Find Online Version",
                                          systemImage: "externaldrive.badge.checkmark")
                                }
                                .help("Locate a copy of this file on a volume that is mounted right now and show it in the catalog.")
                                .accessibilityIdentifier("catalog.row.findOnlineVersion")
                            }
                            Divider()
                            Button {
                                onShowInArchive?(rec)
                            } label: {
                                Label("Show in Archive", systemImage: "archivebox")
                            }
                            // §2 Provenance & Audit Trail — surface the
                            // File Journey timeline for this record. Works
                            // on every active row, including ones with no
                            // relocate history (the timeline just shows
                            // Origin → Current). Active-only — purged
                            // rows don't need it.
                            Button {
                                fileJourneyPayload = model.makeFileJourney(for: rec)
                            } label: {
                                Label("Show this file's journey",
                                      systemImage: "mappin.and.ellipse")
                            }
                            .accessibilityIdentifier("catalog.row.showJourney")
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(rec.fullPath, forType: .string)
                            }
                        } // end pureActive

                        Divider()

                        // Remove from Catalog — visible when the selection
                        // contains at least one active row. The label and the
                        // action both operate on `activeRecs` exclusively, so
                        // a mixed selection's purged rows are never
                        // double-stamped and the count in the label matches
                        // the count actually mutated.
                        if !activeRecs.isEmpty {
                            Button(role: .destructive) {
                                let targetIDs = Set(activeRecs.map { $0.id })
                                _ = model.purgeRecords(ids: targetIDs)
                            } label: {
                                Label(activeRecs.count > 1
                                      ? "Remove \(activeRecs.count) from Catalog"
                                      : "Remove from Catalog",
                                      systemImage: "trash.slash")
                            }
                            .help("Hide these records from the default view. The files on disk are not deleted; toggle Show Removed in the toolbar to recover.")
                        }

                        // Restore to Catalog — visible when the selection
                        // contains at least one purged row. Symmetric with
                        // Remove: label count == operated-on count.
                        if !purgedRecs.isEmpty {
                            Button {
                                for r in purgedRecs { _ = model.restoreRecord(id: r.id) }
                            } label: {
                                Label(purgedRecs.count > 1
                                      ? "Restore \(purgedRecs.count) to Catalog"
                                      : "Restore to Catalog",
                                      systemImage: "arrow.uturn.backward.circle")
                            }
                            .help("Clear the removed marker on the selected rows.")
                        }
                    }
                }
            }
        } primaryAction: { ids in
            // Double-click / Return on row(s) → open in QuickTime.
            let recs = ids.compactMap { id in records.first { $0.id == id } }
            MediaOpener.openInQuickTime(recs)
        }
        .onAppear { tableData = computeFiltered() }
        .onChange(of: records.count) { tableData = computeFiltered() }
        .onChange(of: searchText) { tableData = computeFiltered() }
        .onChange(of: filterTargetPaths) { tableData = computeFiltered() }
        .onChange(of: showPairsOnly) { tableData = computeFiltered() }
        .onChange(of: filterByIDs) { tableData = computeFiltered() }
        .onChange(of: viewFilters) { tableData = computeFiltered() }
        .onChange(of: showRemoved) { tableData = computeFiltered() }
        // Re-compute when purge state flips on any record (purge, undo, restore).
        // We key off lastPurgedBatch so mutations from the model are observed.
        .onChange(of: model.lastPurgedBatch) { tableData = computeFiltered() }
    }

    // MARK: - Preview / Player

    private var previewPlayer: some View {
        Group {
            if selectedRecord != nil {
                HStack(spacing: 0) {
                    // Volume info — lower left
                    if let rec = selectedRecord {
                        VStack(alignment: .leading, spacing: 4) {
                            // Finder-like selection count, above volume name
                            if !selectedIDs.isEmpty {
                                Text("\(selectedIDs.count) selected")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(.primary)
                                    .monospacedDigit()
                            }
                            HStack(spacing: 5) {
                                Image(systemName: "externaldrive.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.accentColor)
                                Text(VolumeReachability.displayLabel(forPath: rec.fullPath))
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                if !VolumeReachability.isReachable(path: rec.fullPath) {
                                    Text("OFFLINE")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(.orange)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                                }
                            }
                            // Volume size + media cataloged
                            VStack(alignment: .leading, spacing: 2) {
                                let volPath = volumeRoot(for: rec.fullPath)
                                let volSize = volumeDiskSize(path: volPath)
                                if !volSize.isEmpty {
                                    Text("Volume Size: \(volSize)")
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                let mediaSize = mediaOnVolume(path: volPath)
                                Text("Media Cataloged: \(mediaSize)")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            if isPlaying {
                                Button {
                                    player?.pause()
                                    player = nil
                                    isPlaying = false
                                } label: {
                                    Label("Stop", systemImage: "stop.fill")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .padding(.top, 4)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Media preview — center
                    VStack(spacing: 0) {
                        if previewOfflineVolumeName != nil
                            || (selectedRecord.map { !VolumeReachability.isReachable(path: $0.fullPath) } ?? false) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.black)
                                Text("MEDIA OFFLINE")
                                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                                    .foregroundColor(.orange)
                                    .tracking(2)
                            }
                            .frame(maxWidth: 480, maxHeight: 180)
                            .aspectRatio(16.0/9.0, contentMode: .fit)
                        } else if isPlaying, let player = player {
                            VideoPlayer(player: player)
                                .cornerRadius(6)
                                .shadow(radius: 3)
                        } else if let img = previewImage {
                            ZStack {
                                Image(nsImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .cornerRadius(6)
                                    .shadow(radius: 3)

                                if let rec = selectedRecord,
                                   rec.streamType == .videoAndAudio || rec.streamType == .videoOnly {
                                    Button {
                                        let url = URL(fileURLWithPath: rec.fullPath)
                                        player = AVPlayer(url: url)
                                        isPlaying = true
                                        player?.play()
                                    } label: {
                                        Image(systemName: "play.circle.fill")
                                            .font(.system(size: 48))
                                            .foregroundColor(.white.opacity(0.85))
                                            .shadow(radius: 4)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } else if selectedRecord?.streamType == .audioOnly {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.black)
                                VStack(spacing: 6) {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 36))
                                        .foregroundColor(.yellow.opacity(0.7))
                                    Text("AUDIO ONLY")
                                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                                        .foregroundColor(.yellow)
                                }
                            }
                            .frame(maxWidth: 480, maxHeight: 180)
                            .aspectRatio(16.0/9.0, contentMode: .fit)
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.gray.opacity(0.1))
                                    .frame(width: 240, height: 135)
                                ProgressView()
                            }
                        }
                    }

                    // Balance — right side
                    Spacer()
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("Select a file to preview")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(height: 140)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Extracted "Find Online Copy" submenu for the active-row context
    /// menu. Inlining `Menu { ForEach { Section { ForEach { Button } } } }`
    /// inside the row's context menu confused Xcode 16.4's overload
    /// resolution — Charts' `ChartContentBuilder` was leaking into the
    /// candidate set for the nested Section/ForEach combinations,
    /// producing "result builder 'ChartContentBuilder' does not implement
    /// any 'buildBlock'" errors. Encapsulating the menu in a dedicated
    /// `@ViewBuilder` function gives the compiler a small, isolated
    /// type-check context where the SwiftUI ViewBuilder candidates win.
    /// Same root cause as `tagColumnCell` below — see commit history.
    @ViewBuilder
    private func onlineCopyMenu(onlineMatches: [VideoRecord]) -> some View {
        // Flatten to a single (label, match) list and prefix the volume name
        // onto each button. We previously grouped with Section, but on
        // Xcode 16.4 Charts contributes a `Section`/`ForEach` overload
        // pair whose result-builder context (ChartContentBuilder) wins
        // overload resolution and breaks the build. Flattening sidesteps
        // the whole problem — one ForEach, one Button per row, no Section.
        // UX cost is small: instead of grouped submenu sections we get
        // "Volume — filename" labels in a single list.
        let byVolume = Dictionary(grouping: onlineMatches) {
            VolumeReachability.displayLabel(forPath: $0.fullPath)
        }
        let flat: [(id: UUID, label: String, path: String)] =
            byVolume.keys.sorted().flatMap { vol -> [(UUID, String, String)] in
                (byVolume[vol] ?? []).map { match in
                    (match.id, "\(vol) — \(match.filename)", match.fullPath)
                }
            }
        Menu("Find Online Copy (\(onlineMatches.count))") {
            ForEach(flat, id: \.id) { entry in
                Button(entry.label) {
                    NSWorkspace.shared.selectFile(
                        entry.path,
                        inFileViewerRootedAtPath: ""
                    )
                }
            }
        }
    }

    /// Extracted Tag-column cell. Moved out of the Table body to keep
    /// the @TableColumnBuilder's type inference manageable — when the
    /// People column pushed this Table from 10 → 11 columns, type-check
    /// timed out on the larger expression.
    @ViewBuilder
    private func tagColumnCell(for rec: VideoRecord) -> some View {
        HStack(spacing: 3) {
            Image(systemName: rec.mediaDisposition.icon)
                .foregroundColor(rec.mediaDisposition.color)
            if rec.mediaDisposition != .unreviewed {
                Text(rec.mediaDisposition.rawValue)
                    .font(.system(size: 11))
                    .foregroundColor(rec.mediaDisposition.color)
            }
            if !rec.notes.isEmpty {
                Image(systemName: "note.text")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            if rec.archiveHealth != .notApplicable {
                Image(systemName: rec.archiveHealth.icon)
                    .font(.system(size: 9))
                    .foregroundColor(rec.archiveHealth.color)
            }
        }
        .help(rec.notes.isEmpty
              ? rec.mediaDisposition.rawValue
              : "\(rec.mediaDisposition.rawValue) — \(rec.notes)")
    }

    /// Render the family-tag column for one record. Confirmed names blue,
    /// suspected names italic + secondary with a leading "?", joined by
    /// " · ". Em-dash when both arrays are empty (junk-triage signal).
    /// Tooltip lists names with tier annotations.
    @ViewBuilder
    private func peopleColumnCell(for rec: VideoRecord) -> some View {
        if rec.detectedPeople.isEmpty && rec.suspectedPeople.isEmpty {
            Text("—")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .help("No family detected — junk-triage candidate")
        } else {
            let confirmedText = Text(rec.detectedPeople.joined(separator: ", "))
                .foregroundColor(.blue)
            let suspectedJoined = rec.suspectedPeople
                .map { "?\($0)" }
                .joined(separator: ", ")
            let suspectedText = Text(suspectedJoined)
                .italic()
                .foregroundColor(.secondary)
            let separator = (!rec.detectedPeople.isEmpty
                             && !rec.suspectedPeople.isEmpty) ? " · " : ""
            (confirmedText + Text(separator) + suspectedText)
                .font(.system(size: 12))
                .lineLimit(1)
                .help(peopleColumnHelp(for: rec))
        }
    }

    private func peopleColumnHelp(for rec: VideoRecord) -> String {
        var lines: [String] = []
        if !rec.detectedPeople.isEmpty {
            lines.append("Detected: \(rec.detectedPeople.joined(separator: ", "))")
        }
        if !rec.suspectedPeople.isEmpty {
            lines.append("Suspected: \(rec.suspectedPeople.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private func streamTypeColor(_ st: StreamType) -> Color {
        switch st {
        case .videoOnly:     return .orange
        case .audioOnly:     return .yellow
        case .ffprobeFailed: return .red
        default:             return .primary
        }
    }
}

// MARK: - Rename Sheet

struct RenameSheet: View {
    @Binding var filename: String
    let originalExt: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename File")
                .font(.headline)
            HStack {
                TextField("New name", text: $filename)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text(".\(originalExt)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(filename.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

// MARK: - Notes Sheet

struct NotesSheet: View {
    @Binding var notes: String
    let filename: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notes")
                .font(.headline)
            Text(filename)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
            TextEditor(text: $notes)
                .font(.system(.body))
                .frame(minHeight: 80)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 220)
    }
}

// MARK: - Inspector Panel

struct InspectorPanel: View {
    let record: VideoRecord?
    let duplicateGroupMembers: [VideoRecord]
    let previewImage: NSImage?
    let previewOfflineVolumeName: String?
    var onSelectRecord: ((UUID) -> Void)?

    var body: some View {
        if let rec = record {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Filename header
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rec.filename)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .padding(.top, 12)
                        HStack(spacing: 8) {
                            Text(rec.streamType == .ffprobeFailed ? rec.isPlayable : rec.streamTypeRaw)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(streamTypeColor(rec.streamType))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(streamTypeColor(rec.streamType).opacity(0.12))
                                )
                            if rec.streamType == .videoOnly && rec.pairedWith == nil {
                                Text("NO AUDIO")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.orange.opacity(0.12))
                                    )
                            }
                            if rec.streamType == .audioOnly && rec.pairedWith == nil {
                                Text("NO VIDEO")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.orange.opacity(0.12))
                                    )
                            }
                        }
                        // Star rating
                        HStack(spacing: 6) {
                            Text("Rating")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            StarRatingView(rating: Binding(
                                get: { rec.starRating },
                                set: { rec.starRating = $0 }
                            ))
                        }
                        // Volume name — prominent.
                        // Use `displayVolumeLabel` so folder scans show as
                        // "Volume > Folder" (e.g. "M4drive > rickb"), matching
                        // the catalog table's Volume column. The old
                        // VolumeReachability.volumeName(forPath:) helper
                        // collapses any "/Users/<X>/..." path to "<X>",
                        // hiding the actual volume — see catalog with 125
                        // records under /Users/rickb that all appeared as
                        // just "rickb" in this inspector.
                        HStack(spacing: 4) {
                            Image(systemName: "externaldrive.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.accentColor)
                            Text(rec.displayVolumeLabel)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                        }
                        .padding(.top, 2)
                        // Avid identity — tape and clip name at a glance
                        if rec.hasAvidMetadata && (!rec.avidTapeName.isEmpty || !rec.avidClipName.isEmpty) {
                            VStack(alignment: .leading, spacing: 3) {
                                if !rec.avidTapeName.isEmpty {
                                    HStack(spacing: 4) {
                                        Image(systemName: "recordingtape")
                                            .font(.system(size: 10))
                                        Text(rec.avidTapeName)
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                }
                                if !rec.avidClipName.isEmpty {
                                    HStack(spacing: 4) {
                                        Image(systemName: "film.stack")
                                            .font(.system(size: 10))
                                        Text(rec.avidClipName)
                                            .font(.system(size: 11))
                                    }
                                }
                            }
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.cyan.opacity(0.08))
                            )
                            .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                    Divider().padding(.horizontal, 16)

                    // Sections
                    inspectorSection("General", systemImage: "doc") {
                        inspectorRow("Size", rec.size)
                        inspectorRow("Duration", rec.duration)
                        inspectorRow("Container", rec.container)
                        inspectorRow("Extension", rec.ext)
                    }

                    inspectorSection("Video", systemImage: "film") {
                        inspectorRow("Resolution", rec.resolution)
                        inspectorRow("Codec", rec.videoCodec)
                        inspectorRow("Frame Rate", rec.frameRate)
                        inspectorRow("Bitrate", rec.videoBitrate)
                        inspectorRow("Total Bitrate", rec.totalBitrate)
                        inspectorRow("Color Space", rec.colorSpace)
                        inspectorRow("Bit Depth", rec.bitDepth)
                        inspectorRow("Scan Type", rec.scanType)
                    }

                    inspectorSection("Audio", systemImage: "speaker.wave.2") {
                        inspectorRow("Codec", rec.audioCodec)
                        inspectorRow("Channels", rec.audioChannels)
                        inspectorRow("Sample Rate", rec.audioSampleRate)
                    }

                    inspectorSection("Family Tags", systemImage: "person.crop.circle") {
                        InspectorFamilyTagsView(record: rec)
                    }

                    // Dossier — captions, transcript, OCR text, OCR dates,
                    // inferred date. Only shown when the record has been
                    // processed by the dossier pipeline so empty rows don't
                    // clutter the inspector for un-dossiered records.
                    if rec.dossierProcessedAt != nil {
                        inspectorSection("Dossier", systemImage: "doc.text.magnifyingglass") {
                            InspectorDossierView(record: rec)
                        }
                    }

                    inspectorSection("Timestamps", systemImage: "calendar") {
                        inspectorRow("Created", rec.dateCreated)
                        inspectorRow("Modified", rec.dateModified)
                        inspectorRow("Timecode", rec.timecode)
                        inspectorRow("Tape Name", rec.tapeName)
                    }

                    if rec.pairedWith != nil || rec.pairConfidence != nil {
                        inspectorSection("Correlation", systemImage: "arrow.triangle.2.circlepath") {
                            if let paired = rec.pairedWith {
                                HStack(alignment: .top, spacing: 6) {
                                    Text("Paired With")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .frame(width: 80, alignment: .trailing)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Button {
                                            onSelectRecord?(paired.id)
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: paired.streamType == .audioOnly
                                                      ? "waveform" : "film")
                                                    .font(.system(size: 9))
                                                Text(paired.filename)
                                                    .font(.system(size: 11, weight: .medium))
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                            .foregroundColor(.accentColor)
                                        }
                                        .buttonStyle(.plain)
                                        .onHover { hovering in
                                            if hovering {
                                                NSCursor.pointingHand.push()
                                            } else {
                                                NSCursor.pop()
                                            }
                                        }
                                        Text(paired.directory)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                    }
                                    Spacer()
                                }
                            }
                            if let conf = rec.pairConfidence {
                                HStack(spacing: 6) {
                                    Text("Confidence")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .frame(width: 80, alignment: .trailing)
                                    Circle()
                                        .fill(conf.textColor)
                                        .frame(width: 8, height: 8)
                                    Text(conf.rawValue)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(conf.textColor)
                                    Spacer()
                                }
                            }
                        }
                    }

                    if rec.duplicateDisposition != .none || !rec.duplicateBestMatchFilename.isEmpty {
                        inspectorSection("Duplicates", systemImage: "doc.on.doc") {
                            if rec.duplicateDisposition != .none {
                                HStack(spacing: 6) {
                                    Text("Status")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .frame(width: 80, alignment: .trailing)
                                    Circle()
                                        .fill(rec.duplicateDisposition.textColor)
                                        .frame(width: 8, height: 8)
                                    Text(
                                        rec.duplicateGroupCount >= 2
                                        ? "\(rec.duplicateDisposition.rawValue) · \(rec.duplicateGroupCount) matches"
                                        : rec.duplicateDisposition.rawValue
                                    )
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(rec.duplicateDisposition.textColor)
                                    Spacer()
                                }
                            }
                            inspectorRow("Reasons", rec.duplicateReasons)
                            if let conf = rec.duplicateConfidence {
                                HStack(spacing: 6) {
                                    Text("Confidence")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .frame(width: 80, alignment: .trailing)
                                    Circle()
                                        .fill(conf.textColor)
                                        .frame(width: 8, height: 8)
                                    Text(conf.rawValue)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(conf.textColor)
                                    Spacer()
                                }
                            }

                            // Show all copies in this duplicate group
                            if !duplicateGroupMembers.isEmpty {
                                let thisVolume = VolumeReachability.volumeName(forPath: rec.fullPath)

                                Divider().padding(.vertical, 4)

                                Text("Duplicate Group (\(duplicateGroupMembers.count + 1) total)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .padding(.leading, 4)

                                // This record (selected)
                                duplicateCopyRow(
                                    filename: rec.filename,
                                    volumeName: thisVolume,
                                    directory: (rec.fullPath as NSString).deletingLastPathComponent,
                                    disposition: rec.duplicateDisposition,
                                    isSameVolume: true,
                                    isSelected: true
                                )

                                // Other group members
                                ForEach(duplicateGroupMembers, id: \.id) { member in
                                    let memberVolume = VolumeReachability.volumeName(forPath: member.fullPath)
                                    let sameVolume = (memberVolume == thisVolume)
                                    duplicateCopyRow(
                                        filename: member.filename,
                                        volumeName: memberVolume,
                                        directory: (member.fullPath as NSString).deletingLastPathComponent,
                                        disposition: member.duplicateDisposition,
                                        isSameVolume: sameVolume,
                                        isSelected: false
                                    )
                                }
                            }
                        }
                    }

                    if rec.hasAvidMetadata {
                        inspectorSection("Avid Project", systemImage: "film.stack") {
                            inspectorRow("Clip Name", rec.avidClipName)
                            inspectorRow("Mob Type", rec.avidMobType)
                            inspectorRow("Bin File", rec.avidBinFile)
                            inspectorRow("Tape", rec.avidTapeName)
                            inspectorRow("Tracks", rec.avidTracks)
                            inspectorRow("Edit Rate", rec.avidEditRate > 0 ? String(format: "%.2f fps", rec.avidEditRate) : "")
                            inspectorCopyableRow("Mob ID", rec.avidMobID)
                            inspectorCopyableRow("Material UUID", rec.avidMaterialUUID)
                            inspectorCopyableRow("Original Path", rec.avidMediaPath)
                        }
                    }

                    if !rec.notes.isEmpty {
                        inspectorSection("Notes", systemImage: "exclamationmark.bubble") {
                            Text(rec.notes)
                                .font(.system(size: 12))
                                .foregroundColor(rec.streamType == .ffprobeFailed ? .red : .secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    inspectorSection("Location", systemImage: "folder") {
                        inspectorCopyableRow("Path", rec.fullPath)
                        inspectorRow("Directory", rec.directory)
                        inspectorRow("MD5 (partial)", rec.partialMD5)
                    }

                    Spacer(minLength: 16)
                }
            }
            .contextMenu {
                Button("Copy All Metadata") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(formatAllMetadata(rec), forType: .string)
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.4))
                Text("No Selection")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Text("Select a file to view details")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    // MARK: - Copy Metadata

    func formatAllMetadata(_ rec: VideoRecord) -> String {
        var lines: [String] = []
        func add(_ label: String, _ value: String) {
            guard !value.isEmpty else { return }
            lines.append("  \(label): \(value)")
        }
        func section(_ title: String) {
            if !lines.isEmpty { lines.append("") }
            lines.append("[\(title)]")
        }
        // Local copy of InspectorDossierView's formatter — keeps the
        // m:ss formatting consistent between the inspector panel and
        // the copied metadata text.
        func formatTimestamp(_ seconds: Double) -> String {
            let s = max(0, Int(seconds))
            return String(format: "%d:%02d", s / 60, s % 60)
        }

        // Header
        lines.append(rec.filename)
        lines.append("  Stream Type: \(rec.streamTypeRaw)")
        lines.append("  Volume: \(VolumeReachability.displayLabel(forPath: rec.fullPath))")
        if rec.starRating > 0 {
            lines.append("  Rating: \(String(repeating: "★", count: rec.starRating))")
        }
        if rec.hasAvidMetadata {
            if !rec.avidTapeName.isEmpty { add("Tape", rec.avidTapeName) }
            if !rec.avidClipName.isEmpty { add("Clip", rec.avidClipName) }
        }

        // General
        section("General")
        add("Size", rec.size)
        add("Duration", rec.duration)
        add("Container", rec.container)
        add("Extension", rec.ext)

        // Video
        section("Video")
        add("Resolution", rec.resolution)
        add("Codec", rec.videoCodec)
        add("Frame Rate", rec.frameRate)
        add("Bitrate", rec.videoBitrate)
        add("Total Bitrate", rec.totalBitrate)
        add("Color Space", rec.colorSpace)
        add("Bit Depth", rec.bitDepth)
        add("Scan Type", rec.scanType)

        // Audio
        section("Audio")
        add("Codec", rec.audioCodec)
        add("Channels", rec.audioChannels)
        add("Sample Rate", rec.audioSampleRate)

        // Timestamps
        section("Timestamps")
        add("Created", rec.dateCreated)
        add("Modified", rec.dateModified)
        add("Timecode", rec.timecode)
        add("Tape Name", rec.tapeName)

        // Correlation
        if rec.pairedWith != nil || rec.pairConfidence != nil {
            section("Correlation")
            if let paired = rec.pairedWith {
                add("Paired With", paired.filename)
                add("Pair Volume", VolumeReachability.displayLabel(forPath: paired.fullPath))
                add("Pair Path", paired.fullPath)
            }
            if let conf = rec.pairConfidence {
                add("Confidence", conf.rawValue)
            }
        }

        formatDuplicateSection(rec, add: add, section: section, appendLine: { lines.append($0) })
        formatAvidSection(rec, add: add, section: section)

        // Notes
        if !rec.notes.isEmpty {
            section("Notes")
            lines.append("  \(rec.notes)")
        }

        // Dossier — scene captions, audio transcript, OCR. Rick 2026-06-09:
        // these are the most copy-worthy fields once the record is dossier'd
        // (handy for sharing a clip's content with someone else, or for
        // pasting into a notes app). Section is omitted when there's nothing
        // worth showing to keep the output tight for non-dossier'd records.
        let hasDossierContent =
            !rec.sceneCaptions.isEmpty
            || !(rec.audioTranscript ?? "").isEmpty
            || !rec.ocrText.isEmpty
            || !rec.ocrDateCandidates.isEmpty
            || rec.inferredRecordDate != nil
        if hasDossierContent {
            section("Dossier")
            if let inferred = rec.inferredRecordDate {
                let fmt = DateFormatter()
                fmt.dateStyle = .medium
                fmt.timeStyle = .none
                var line = "  Inferred Record Date: \(fmt.string(from: inferred))"
                if let conf = rec.inferredDateConfidence {
                    line += " (confidence \(String(format: "%.2f", conf)))"
                }
                lines.append(line)
            }
            if let by = rec.dossierProcessedBy, !by.isEmpty,
               let at = rec.dossierProcessedAt {
                let fmt = DateFormatter()
                fmt.dateStyle = .short
                fmt.timeStyle = .short
                lines.append("  Processed: \(by) on \(fmt.string(from: at))")
            }
            if !rec.sceneCaptions.isEmpty {
                lines.append("")
                lines.append("  Scene Captions (\(rec.sceneCaptions.count)):")
                for cap in rec.sceneCaptions {
                    let ts = formatTimestamp(cap.timestamp)
                    lines.append("    [\(ts)] \(cap.text)")
                }
            }
            if let transcript = rec.audioTranscript, !transcript.isEmpty {
                lines.append("")
                lines.append("  Audio Transcript:")
                // Preserve as a single block — keeps the natural flow for
                // pasting elsewhere. Indent with 4 spaces.
                for textLine in transcript.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("    \(textLine)")
                }
            }
            if !rec.ocrText.isEmpty {
                lines.append("")
                lines.append("  OCR Text (\(rec.ocrText.count)):")
                for hit in rec.ocrText {
                    let ts = formatTimestamp(hit.timestamp)
                    lines.append("    [\(ts)] \(hit.text)")
                }
            }
            if !rec.ocrDateCandidates.isEmpty {
                lines.append("")
                lines.append("  OCR Date Candidates (\(rec.ocrDateCandidates.count)):")
                for hit in rec.ocrDateCandidates {
                    let ts = formatTimestamp(hit.timestamp)
                    lines.append("    [\(ts)] \(hit.text)")
                }
            }
        }

        // Location
        section("Location")
        add("Path", rec.fullPath)
        add("Directory", rec.directory)
        add("MD5 (partial)", rec.partialMD5)

        return lines.joined(separator: "\n")
    }

    func formatDuplicateSection(
        _ rec: VideoRecord,
        add: (String, String) -> Void, section: (String) -> Void,
        appendLine: (String) -> Void
    ) {
        guard rec.duplicateDisposition != .none || !rec.duplicateBestMatchFilename.isEmpty else { return }
        section("Duplicates")
        if rec.duplicateDisposition != .none {
            let status = rec.duplicateGroupCount >= 2
                ? "\(rec.duplicateDisposition.rawValue) · \(rec.duplicateGroupCount) matches"
                : rec.duplicateDisposition.rawValue
            add("Status", status)
        }
        add("Reasons", rec.duplicateReasons)
        if let conf = rec.duplicateConfidence { add("Confidence", conf.rawValue) }
        if !duplicateGroupMembers.isEmpty {
            appendLine("")
            appendLine("  Duplicate Group (\(duplicateGroupMembers.count + 1) total):")
            let thisVol = VolumeReachability.volumeName(forPath: rec.fullPath)
            appendLine("    ★ \(rec.filename)  [\(thisVol)]  \(rec.duplicateDisposition.rawValue)")
            for member in duplicateGroupMembers {
                let vol = VolumeReachability.volumeName(forPath: member.fullPath)
                let online = VolumeReachability.isReachable(path: member.fullPath)
                appendLine("    · \(member.filename)  [\(vol)]\(online ? "" : " (offline)")  \(member.duplicateDisposition.rawValue)")
            }
        }
    }

    func formatAvidSection(
        _ rec: VideoRecord,
        add: (String, String) -> Void, section: (String) -> Void
    ) {
        guard rec.hasAvidMetadata else { return }
        section("Avid Project")
        add("Clip Name", rec.avidClipName)
        add("Mob Type", rec.avidMobType)
        add("Bin File", rec.avidBinFile)
        add("Tape", rec.avidTapeName)
        add("Tracks", rec.avidTracks)
        if rec.avidEditRate > 0 { add("Edit Rate", String(format: "%.2f fps", rec.avidEditRate)) }
        add("Mob ID", rec.avidMobID)
        add("Material UUID", rec.avidMaterialUUID)
        add("Original Path", rec.avidMediaPath)
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private func inspectorThumbnail(for rec: VideoRecord) -> some View {
        if previewOfflineVolumeName != nil {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black)
                Text("OFFLINE")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.orange)
            }
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .padding(16)
        } else if let img = previewImage {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .cornerRadius(6)
                .shadow(radius: 2)
                .frame(maxWidth: .infinity)
                .padding(16)
        } else if rec.streamType == .audioOnly {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
                Image(systemName: "waveform")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .frame(height: 80)
            .frame(maxWidth: .infinity)
            .padding(16)
        } else {
            EmptyView()
        }
    }

    // MARK: - Section Builder

    @ViewBuilder
    private func inspectorSection(_ title: String, systemImage: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            content()
                .padding(.horizontal, 16)
        }
    }

    // MARK: - Row Helpers

    @ViewBuilder
    private func inspectorRow(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .trailing)
                Text(value)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func inspectorCopyableRow(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .trailing)
                Text(value)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
            }
        }
    }

    private func streamTypeColor(_ st: StreamType) -> Color {
        switch st {
        case .videoOnly:     return .orange
        case .audioOnly:     return .yellow
        case .ffprobeFailed: return .red
        default:             return .primary
        }
    }

    // MARK: - Duplicate Copy Row

    @ViewBuilder
    private func duplicateCopyRow(
        filename: String,
        volumeName: String,
        directory: String,
        disposition: DuplicateDisposition,
        isSameVolume: Bool,
        isSelected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle()
                    .fill(disposition.textColor)
                    .frame(width: 6, height: 6)
                Text(filename)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isSelected {
                    Text("(selected)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 4) {
                Image(systemName: isSameVolume ? "internaldrive" : "externaldrive")
                    .font(.system(size: 9))
                    .foregroundColor(isSameVolume ? .secondary : .orange)
                Text(volumeName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isSameVolume ? .secondary : .orange)
                if !isSameVolume {
                    Text("(different volume)")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                }
            }
            Text(directory)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
                .textSelection(.enabled)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        )
    }
}

// MARK: - Table Cell Views

struct DuplicateDispositionCell: View {
    let record: VideoRecord

    var body: some View {
        HStack(spacing: 4) {
            if let conf = record.duplicateConfidence {
                Circle()
                    .fill(conf.textColor)
                    .frame(width: 8, height: 8)
            }
            Text(duplicateDisplayLabel(for: record))
                .foregroundColor(record.duplicateDisposition.textColor)
        }
    }
}

func duplicateDisplayLabel(for record: VideoRecord) -> String {
    if record.duplicateDisposition == .none { return "—" }
    let n = record.duplicateGroupCount
    if n >= 2 { return "\(n) matches" }
    return record.duplicateDisposition.rawValue
}

// MARK: - Discover Volumes Sheet

struct DiscoverVolumesSheet: View {
    @ObservedObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    @State private var volumes: [DiscoveredVolume] = []
    @State private var selected: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "network")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Discover Volumes")
                        .font(.headline)
                    Text("Mounted local and network volumes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            if volumes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No volumes found")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Mount a drive or network share and click Refresh.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(volumes, selection: $selected) { vol in
                    HStack(spacing: 10) {
                        Image(systemName: vol.isNetwork ? "network" : "internaldrive")
                            .font(.title3)
                            .foregroundColor(vol.isNetwork ? .blue : .secondary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(vol.name)
                                    .font(.system(size: 13, weight: .semibold))
                                if vol.isNetwork {
                                    Text("Network")
                                        .font(.system(size: 9, weight: .medium))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.blue.opacity(0.15))
                                        .cornerRadius(3)
                                        .foregroundColor(.blue)
                                }
                                if vol.alreadyAdded {
                                    Text("Already added")
                                        .font(.system(size: 9, weight: .medium))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.green.opacity(0.15))
                                        .cornerRadius(3)
                                        .foregroundColor(.green)
                                }
                            }
                            Text(vol.path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            if vol.totalBytes > 0 {
                                Text("\(vol.usedFormatted) used of \(vol.totalFormatted)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .tag(vol.id)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            Divider()

            // Footer
            HStack {
                Text("\(volumes.count) volume(s) found")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Selected (\(selected.count))") {
                    let toAdd = volumes.filter { selected.contains($0.id) && !$0.alreadyAdded }
                    model.addDiscoveredVolumes(toAdd)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 550, height: 420)
        .onAppear { refresh() }
    }

    private func refresh() {
        volumes = model.discoverVolumes()
        selected = []
    }
}

// MARK: - Scan Options Menu

/// Toolbar menu for toggling what the walker descends into and two perf
/// shortcuts. All toggles are applied at scan start (not mid-scan), so the
/// next "Scan All" reflects the new policy. Defaults = aggressive skip
/// (only descend where family media plausibly lives).
struct ScanOptionsMenu: View {
    @ObservedObject var model: VideoScanModel

    /// Binding wrapper that saves to UserDefaults on every toggle, so the
    /// user's preference survives relaunch without an explicit "Save" step.
    private func toggle(_ keyPath: WritableKeyPath<ScanOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.scanOptions[keyPath: keyPath] },
            set: { newVal in
                model.scanOptions[keyPath: keyPath] = newVal
                model.scanOptions.save()
            }
        )
    }

    var body: some View {
        Menu {
            Toggle("Skip System Files", isOn: toggle(\.skipSystemFiles))
            Toggle("Skip Media Bundles", isOn: toggle(\.skipMediaBundles))
            Toggle("Skip Small Files", isOn: toggle(\.skipSmallFiles))
            Toggle("Skip Checksums", isOn: toggle(\.skipChecksums))

            Divider()

            Button("Fast Defaults") {
                model.scanOptions = .fastDefaults
                model.scanOptions.save()
            }
            .disabled(model.scanOptions == .fastDefaults)

            Button("Scan Everything (Slower)") {
                model.scanOptions = .thorough
                model.scanOptions.save()
            }
            .disabled(model.scanOptions == .thorough)
        } label: {
            HStack(spacing: 4) {
                Label("Scan Options", systemImage: "slider.horizontal.3")
                // Accent-colored dot when the user has deviated from the
                // fast-path defaults — visible at a glance.
                if model.scanOptions.isCustomized {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(model.scanOptions.isCustomized
              ? "Non-default scan policy (applies on next scan)"
              : "What to skip during scan (applies on next scan)")
    }
}

// MARK: - Star Rating View

struct StarRatingView: View {
    @Binding var rating: Int
    let maxStars: Int = 3

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...maxStars, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.system(size: 14))
                    .foregroundColor(star <= rating ? .yellow : .secondary.opacity(0.4))
                    .onTapGesture {
                        rating = (rating == star) ? 0 : star
                    }
            }
        }
    }
}

// MARK: - Shared media open helpers

enum MediaOpener {
    /// Open one or more catalog records in QuickTime Player.
    /// Silently skips records on offline volumes (the table's row context
    /// menu shows a clearer "Reveal" option for those).
    static func openInQuickTime(_ records: [VideoRecord]) {
        let urls = records
            .filter { VolumeReachability.isReachable(path: $0.fullPath) }
            .map { URL(fileURLWithPath: $0.fullPath) }
        guard !urls.isEmpty,
              let qtURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.QuickTimePlayerX"
              )
        else { return }
        NSWorkspace.shared.open(urls,
                                withApplicationAt: qtURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Catalog search help popover
//
// Added 2026-06-08 alongside the field-prefix grammar (Phase B of the
// Google-like search). The grammar is useless if users can't discover
// it — a `?` button next to the search field shows this card with
// concrete examples. Keep examples narrow and copy-paste-ready;
// no big tables, no theory.

private struct CatalogSearchHelpPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tint)
                Text("Search syntax")
                    .font(.headline)
            }

            Group {
                Text("Plain words — match anywhere on the record")
                    .font(.subheadline.weight(.medium))
                CatalogSearchExampleRow(query: "donna",
                                        meaning: "any record mentioning donna")
                CatalogSearchExampleRow(query: "mark dan grampa",
                                        meaning: "all three names somewhere on the record (AND)")
                CatalogSearchExampleRow(query: "cape cod 1990s",
                                        meaning: "cape, cod, and a 1990s year signal")
            }

            Divider()

            Group {
                Text("Year shorthand")
                    .font(.subheadline.weight(.medium))
                CatalogSearchExampleRow(query: "1990s",
                                        meaning: "decade 1990–1999")
                CatalogSearchExampleRow(query: "199x",
                                        meaning: "same — decade wildcard")
            }

            Divider()

            Group {
                Text("Field-prefix grammar")
                    .font(.subheadline.weight(.medium))
                CatalogSearchExampleRow(query: "people:donna",
                                        meaning: "donna in the people tags only (not paths/captions)")
                CatalogSearchExampleRow(query: "transcript:birthday",
                                        meaning: "birthday in the audio transcript")
                CatalogSearchExampleRow(query: "caption:guitar",
                                        meaning: "guitar in scene captions")
                CatalogSearchExampleRow(query: "ocr:1991",
                                        meaning: "1991 in burned-in text / OCR")
                CatalogSearchExampleRow(query: "name:cape",
                                        meaning: "cape in the filename (not path)")
                CatalogSearchExampleRow(query: "notes:keeper",
                                        meaning: "your notes (otherwise excluded)")
                CatalogSearchExampleRow(query: "year:1991",
                                        meaning: "single year")
                CatalogSearchExampleRow(query: "year:1989..1995",
                                        meaning: "year range")
                CatalogSearchExampleRow(query: "decade:1990s",
                                        meaning: "decade")
            }

            Divider()

            Text("Field-prefix tokens compose with plain words. Every token must match (AND).")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: 360, alignment: .leading)
        }
        .padding(16)
        .frame(width: 420)
    }
}

private struct CatalogSearchExampleRow: View {
    let query: String
    let meaning: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(query)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.12))
                )
                .frame(minWidth: 140, alignment: .leading)
            Text(meaning)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
    }
}
