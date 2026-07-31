// CatalogHelpers.swift
// Catalog tab content: the table + preview pane (CatalogContent), its
// duplicate-disposition cell, and shared media-open helpers.
// (Toolbar → CatalogToolbar.swift, inspector → InspectorPanel.swift,
// sheets/menus → CatalogSheets.swift; 2026-06-11 file-split refactor.)

import SwiftUI
import AVKit
import AppKit
import os.log

// MARK: - Table + Preview + Inspector

struct CatalogContent: View {
    @EnvironmentObject var model: VideoScanModel
    // Used in CatalogContent+Table.swift's "Reformat and Analyze…"
    // context-menu button (Rick 2026-06-14). The lint hook is per-file
    // so the use is invisible to it.
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject var captionOrchestrator: CaptionOrchestrator
    /// Media File Operations registry — "Compare These Two Files…" hands
    /// the pair to the center and opens the operations window; the job
    /// runs there (non-modal), not in a sheet.
    @EnvironmentObject var fileOpsCenter: MediaFileOperationsCenter
    @Environment(\.openWindow) var openWindow
    let records: [VideoRecord]
    @Binding var selectedIDs: Set<UUID>
    @Binding var sortOrder: [KeyPathComparator<VideoRecord>]
    let searchText: String
    /// Search-hit badge count, published UP to the parent as a
    /// by-product of `computeFiltered()`'s single scan (GH #123 PR B —
    /// the toolbar used to run its own duplicate full scan for this on
    /// every settled keystroke, doubling every search's main-thread
    /// cost). ContentView hands the value to CatalogToolbar. Semantics:
    /// hits over pfSearchBadgeBase; 0 when the search is empty. A
    /// `@Binding` here ≈ a C++ reference member — writes land in
    /// ContentView's @State storage, not in a local copy.
    @Binding var searchHitCount: Int
    let filterTargetPaths: Set<String>
    let showPairsOnly: Bool
    let viewFilters: Set<CatalogViewFilter>
    /// Reachable-only is the DEFAULT catalog baseline (2026-07-20): the table
    /// shows only media on currently-mounted volumes unless this opt-out is
    /// true. Persisted by the parent in @AppStorage("catalog.showDisconnectedMedia").
    /// NOT one of the additive `viewFilters` — it's a baseline preference, so
    /// "Clear All Filters" leaves it alone.
    let showDisconnectedMedia: Bool
    /// When true, purged rows are included in the table (rendered italic +
    /// orange, with a restricted context menu). When false (default), purged
    /// rows are hidden — they remain in catalog.json for recoverability.
    let showRemoved: Bool
    /// When true, set-aside rows (video-only catalog scope: photos / music /
    /// audio with no matching video) are included in the table so Rick can
    /// browse and put them back. When false (default), they are hidden —
    /// records and files are untouched. Independent of `showRemoved`.
    var showSetAside: Bool = false
    /// When true, superseded rows (originals retired by a confirmed
    /// repair, GH #132) are included in the table so Rick can inspect or
    /// restore them. When false (default), they are hidden — records and
    /// files untouched. Session-scoped in the parent (deliberately NOT
    /// persisted, unlike showRemoved/showSetAside).
    var showSuperseded: Bool = false
    /// Media-kind facet (GH #124): which stream shapes the table shows.
    /// Default `.videoBearing` — audio-only rows hidden until the user
    /// flips the toolbar facet chip. Applied in computeFiltered AFTER the
    /// purge/set-aside filters and BEFORE search, so the search working
    /// set shrinks with the view (the issue's ~4x win). Never affects
    /// correlate/combine — those source candidates from `model.records`.
    var kindFacet: CatalogKindFacet = .videoBearing
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
    /// Preview generation failed (or negative-cache hit) for the current
    /// selection — render the "NO PREVIEW" placeholder instead of leaving
    /// the ProgressView spinning forever (preview routing, 2026-07-26).
    /// `var` + default (same pattern as showSetAside) so existing
    /// callers/tests that don't care about the preview pane compile
    /// unchanged.
    var previewUnavailable: Bool = false
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
    /// "Show Repaired Copy in Catalog" on a superseded original (GH #132)
    /// — parent focuses the catalog on the repair record and selects it.
    var onShowRepairedCopy: ((_ repairID: UUID) -> Void)?

    @State private var player: AVPlayer?
    @State private var isPlaying = false

    /// "Preview follows selection" mode (live-preview, 2026-07-28).
    /// Spacebar (when the table owns focus) toggles it; while armed, an
    /// arrow-key selection change restarts the filmstrip for the newly
    /// highlighted row. The state machine itself is pure/testable
    /// (CatalogLivePreview.swift) — this @State just holds it and the
    /// event-monitor handle. A `struct` in @State ≈ a value member the
    /// framework owns; mutating it through a `mutating func` re-renders.
    @State private var livePreviewMode = LivePreviewMode()
    /// Local NSEvent keyDown monitor for the Space toggle. Installed when
    /// the catalog pane appears, removed on disappear (tab switch tears
    /// CatalogContent down). `Any?` because addLocalMonitor returns an
    /// opaque token. macOS 13-safe — `.onKeyPress` is 14+.
    @State private var spaceKeyMonitor: Any?

    @State var showRenameSheet = false
    @State var renameTarget: VideoRecord?
    @State var renameText: String = ""
    /// Non-nil drives an alert + keeps the rename sheet re-openable so the
    /// user sees *why* nothing happened. Original code silently caught the
    /// FileManager error and dismissed the sheet, leaving the user staring
    /// at the unchanged catalog wondering what went wrong.
    @State private var renameError: String?
    @State var showNotesSheet = false
    @State var notesTarget: VideoRecord?
    @State var notesText: String = ""

    // Workflow tags (2026-07-23): "Custom Tag…" alert backing. Targets
    // are captured as IDs when the menu item is clicked (the context
    // menu's record array is gone by the time the alert commits), then
    // resolved against `records` at commit.
    @State var showCustomTagAlert = false
    @State var customTagText: String = ""
    @State var customTagTargetIDs: Set<UUID> = []

    /// §2 Provenance & Audit Trail — File Journey sheet backing. Built
    /// fresh from the right-clicked record; the sheet binding drops the
    /// value on dismiss. Swift's `Identifiable?` ≈ a nullable handle that
    /// drives a sheet present/dismiss cycle.
    @State var fileJourneyPayload: FileJourney?

    /// Stable snapshot the Table reads from. Decoupled from `records` so the
    /// Table never sees the data array mutate mid-gesture (which races with
    /// AppKit's canDragRows / mouseDown handling and crashes inside
    /// ForEach.IDGenerator with an out-of-bounds subscript).
    @State var tableData: [VideoRecord] = []

    // "Extract Facial Frames…" (Rick 2026-06-09, Donna's birthday-
    // print project) runs as an ExtractFramesJob in the Media File
    // Operations window since phase 2 — no view-local ripper state.

    /// "Extract Frames…" (ffmpeg-only, verb split 2026-06-10) — the
    /// right-clicked record awaiting its sampling-options sheet.
    /// Non-nil drives the sheet; the job itself lives in the Media
    /// File Operations center once the user confirms.
    /// Internal (not private): set by the row context menu in
    /// CatalogContent+Table.swift.
    @State var ripAllFramesTarget: VideoRecord?
    /// Non-nil presents format + destination choices before a transcode.
    @State var transcodeRequest: TranscodeRequest?
    /// Non-nil presents the "Clean Up Video" recipe confirmation sheet.
    @State var cleanupRequest: CleanupRequest?
    /// Non-nil presents the "Trim Master…" in/out point sheet.
    @State var trimRequest: TrimRequest?
    /// Non-nil presents the "Verification Results" sheet (GH #128/#135;
    /// since the GH #137 consolidation it also carries the Balance
    /// Audio offer — the retired standalone Balance sheet's job).
    @State var verifyAudioRequest: VerifyAudioRequest?

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
    @State private var trimDerivativesMemo = RenderMemo<TrimDerivativesMemoKey, [VideoRecord]>()
    /// Music-triage candidate memo (GH #124 layer 2). The O(n) detection
    /// pass runs once per catalog change / purge / tidy event — NEVER per
    /// body re-eval (the no-O(records)-in-body rule). Keyed on the purge
    /// and tidy batches too because purging doesn't change records.count
    /// or the aggregates revision, yet must shrink the chip.
    @State private var musicTriageMemo = RenderMemo<MusicTriageMemoKey, [UUID]>()
    /// Non-nil presents the music-triage review sheet with a snapshot of
    /// the candidate IDs taken at click time (.sheet(item:) discipline —
    /// never chained isPresented).
    @State private var musicTriagePayload: MusicTriagePayload?
    /// The candidate count the user last dismissed the banner at.
    /// @SceneStorage so the dismissal survives tab switches (CatalogView
    /// is torn down per switch) but NOT app relaunch — nag semantics:
    /// the suggestion returns next session, or sooner if the count moves.
    @SceneStorage("musicTriageDismissedCount") private var musicTriageDismissedCount: Int = 0

    private struct DuplicateGroupMemoKey: Equatable {
        let selectedID: UUID
        let version: RecordsVersion
        let analyzing: Bool
    }

    private struct MusicTriageMemoKey: Equatable {
        let version: RecordsVersion
        let purge: VideoScanModel.LastPurgedBatch?
        let tidy: VideoScanModel.LastTidyBatch?
    }

    /// Identifiable payload for the review sheet — the candidate IDs
    /// frozen at banner-click time.
    struct MusicTriagePayload: Identifiable {
        let id = UUID()
        let candidateIDs: [UUID]
    }

    /// Memoized music-library candidate IDs. See MusicTriage.candidateIDs
    /// for the precision rules (MXF halves / paired / same-stem NEVER
    /// suggested — pinned by MusicTriageTests).
    private var musicTriageCandidateIDs: [UUID] {
        let key = MusicTriageMemoKey(
            version: recordsVersion,
            purge: model.lastPurgedBatch,
            tidy: model.lastTidyBatch
        )
        return musicTriageMemo.value(for: key) {
            MusicTriage.candidateIDs(in: records)
        }
    }

    private struct TrimDerivativesMemoKey: Equatable {
        let selectedID: UUID
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

    // MARK: - Live preview (follows selection)

    /// The previewable media path for the current selection, or nil when
    /// nothing previewable is selected. Delegates the decision to the pure
    /// resolver (CatalogLivePreview); the `.lazy` map means reachability is
    /// only probed up to the first selected row — NOT O(records). Called
    /// only from event handlers (Space / selection change), never `body`.
    private func livePreviewCandidatePath() -> String? {
        CatalogLivePreview.previewPath(
            orderedCandidates: tableData.lazy.map { rec in
                CatalogLivePreview.Candidate(
                    id: rec.id,
                    path: rec.fullPath,
                    isPreviewable: CatalogLivePreview.isPreviewable(
                        streamType: rec.streamType,
                        reachable: VolumeReachability.isReachable(path: rec.fullPath)))
            },
            selectedIDs: selectedIDs)
    }

    /// Perform the side effect the mode state machine asked for. Reuses the
    /// EXISTING filmstrip machinery — start always routes through the
    /// filmstrip surface (requestFilmstrip rips off-main and hits the disk
    /// cache first), so arrowing through already-swept rows is near-instant
    /// and never spins up a per-row AVPlayer.
    private func applyLivePreview(_ action: LivePreviewAction) {
        switch action {
        case .none:
            break
        case .stop:
            player?.pause()
            player = nil
            isPlaying = false
            model.stopFilmstrip()
        case .start(let path):
            // Tear down any AVPlayer, then hand the row to the filmstrip.
            player?.pause()
            player = nil
            isPlaying = false
            if let rec = tableData.first(where: { $0.fullPath == path }) {
                model.requestFilmstrip(for: rec)
            }
        }
    }

    /// Space pressed while the catalog table owns focus — toggle the mode.
    private func toggleLivePreview() {
        let action = livePreviewMode.toggle(candidatePath: livePreviewCandidatePath())
        applyLivePreview(action)
    }

    /// Whether a Space keyDown should drive the toggle. TRUE only when an
    /// NSTableView owns first-responder in the key window — so Space passes
    /// straight through to the search field, rename/inline-edit fields (any
    /// field editor is an NSText), and to buttons (which handle Space
    /// themselves). This is the text-field guard the feature promises.
    private func spaceShouldToggleLivePreview() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        // Field editors (search box, rename sheet, notes) are NSText —
        // never hijack Space from text entry.
        if responder is NSText { return false }
        guard let view = responder as? NSView else { return false }
        // Fire only when the catalog table (an NSTableView under the
        // SwiftUI Table) is focused. Walk the ancestor chain so a focused
        // cell subview still counts as "the table has focus".
        var node: NSView? = view
        while let current = node {
            if current is NSTableView { return true }
            node = current.superview
        }
        return false
    }

    /// Install the Space key monitor for the catalog pane's lifetime.
    /// Idempotent (guards on the existing handle). Local monitors run
    /// in-process for the key window only; returning nil consumes the
    /// event, returning it passes through untouched.
    private func installSpaceKeyMonitor() {
        guard spaceKeyMonitor == nil else { return }
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 49 = kVK_Space. Bare Space only — let ⌘/⌥/⌃-Space through to
            // their owners (menu shortcuts, input sources, etc.).
            let bareSpace = event.keyCode == 49
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    .isSubset(of: [.function, .numericPad])
            guard bareSpace, spaceShouldToggleLivePreview() else { return event }
            toggleLivePreview()
            return nil
        }
    }

    /// Remove the Space key monitor (tab switch / pane teardown). Also
    /// exits the mode so a re-entry starts clean.
    private func removeSpaceKeyMonitor() {
        if let monitor = spaceKeyMonitor {
            NSEvent.removeMonitor(monitor)
            spaceKeyMonitor = nil
        }
        _ = livePreviewMode.stop()
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

    /// Trimmed versions of the selected record (Trim Master provenance).
    /// Memoized on (selected id, records version) — same discipline as
    /// duplicateGroupMembers: the O(n) reverse scan runs once per
    /// selection/catalog change, never per body re-eval.
    private var trimDerivatives: [VideoRecord] {
        guard let rec = selectedRecord else { return [] }
        let key = TrimDerivativesMemoKey(selectedID: rec.id, version: recordsVersion)
        return trimDerivativesMemo.value(for: key) {
            records.filter { $0.derivedFrom == rec.id && $0.trimInSeconds != nil }
        }
    }

    /// The record the selected trim derivative was cut from — O(1) via
    /// the model's id index, so no memo needed.
    private var trimSource: VideoRecord? {
        guard let rec = selectedRecord,
              rec.trimInSeconds != nil,
              let sourceID = rec.derivedFrom else { return nil }
        return model.record(forID: sourceID)
    }

    /// The record the selected repair copy was made from (GH #132) —
    /// O(1) via the model's id index. Only resolves for repair-kind
    /// derivatives (rebuildAudio / externalRepair), so the inspector's
    /// Repair section never claims trim/balance outputs.
    private var repairSource: VideoRecord? {
        guard let rec = selectedRecord,
              VideoRecord.repairDerivationKinds.contains(rec.derivationKind ?? ""),
              let sourceID = rec.derivedFrom else { return nil }
        return model.record(forID: sourceID)
    }

    /// The repaired record that superseded the selected original
    /// (GH #132) — O(1) via the model's id index.
    private var repairCopy: VideoRecord? {
        guard let rec = selectedRecord,
              let copyID = rec.supersededByID else { return nil }
        return model.record(forID: copyID)
    }

    /// Compute the table's row set — and, as a by-product of the SAME
    /// scan, publish the toolbar's search-hit badge count through the
    /// `searchHitCount` binding (GH #123 PR B). Callers only ever run
    /// this from event handlers (onAppear/onChange), never from `body`,
    /// so the binding write is a legal state mutation.
    func computeFiltered() -> [VideoRecord] {
        // Explicit-IDs ask always wins, including over Show-Removed. The
        // filterByIDs path is driven by user navigation ("Show in Catalog",
        // "Show Pair in Catalog") — they asked for those specific records,
        // so surface them whether or not the row happens to be purged or
        // the Show-Removed toggle is on.
        if !filterByIDs.isEmpty {
            // Focus mode is mutually exclusive with a live search
            // (ContentView clears one when the other activates); zero the
            // badge so a stale count can't outlive its query.
            searchHitCount = 0
            return records.filter { filterByIDs.contains($0.id) }
        }
        // Default: hide soft-deleted (purged) records. Composes with all the
        // filters below — purge filter applied FIRST so each downstream filter
        // sees a smaller input. Toggling Show Removed is a pure inclusion (it
        // adds purged rows back; it doesn't change online/View semantics).
        var out = pfApplyPurgeFilter(records, showRemoved: showRemoved)
        // Catalog-scope set-aside filter (2026-07-15) — composes with the
        // purge filter above; applied BEFORE search so set-aside rows can
        // never match a default search (Rick: cruft is "only bothersome if
        // it shows up in a list or in a search").
        out = pfApplySetAsideFilter(out, showSetAside: showSetAside)
        // Superseded filter (GH #132) — third sibling of the two above.
        // Originals retired by a confirmed repair stay out of the default
        // view (their repaired copy represents the footage now) until the
        // "Show superseded" toggle reveals them.
        out = pfApplySupersededFilter(out, showSuperseded: showSuperseded)
        // Media-kind facet (GH #124) — the default Videos facet drops the
        // ~80k audio-only rows here, BEFORE search/pairs/View filters, so
        // every downstream pass (and the table itself) works the small
        // set. `.everything` is an identity short-circuit. Note the
        // Show-Pairs-Only flatten below re-appends each video's audio
        // partner by reference, so correlated pairs stay whole even under
        // the default facet.
        out = pfApplyKindFacet(out, facet: kindFacet)
        if !searchText.isEmpty {
            // Search routes through the model's CatalogSearchIndex so the
            // per-keystroke cost is haystack.contains() per record — no
            // re-lowercasing or re-concatenation of every audio transcript
            // and OCR field. Correctness is identical to the canonical
            // pfRecordFilenameOrPersonMatch (pinned by index unit tests).
            // Rick 2026-06-09: this is the fast path that made search
            // feel instant on 15k-record catalogs.
            //
            // GH #123 PR B: ONE scan per settled query. The search runs
            // over the badge base (purge → set-aside → kind facet, the
            // #124-era pfSearchBadgeBase, BEFORE the volume filter) so
            // its hit count IS the toolbar badge; the volume filter then
            // narrows the survivors. Filters are independent per-record
            // predicates, so search-then-volume yields exactly the same
            // rows as volume-then-search.
            out = model.searchIndex.filter(records: out, query: searchText)
            // Badge honors the reachable-only baseline (2026-07-20, Rick): in the
            // default connected-only view the hit count matches the media you can
            // actually see, instead of #123's cross-catalog count that included
            // matches on disconnected drives. The "Show disconnected media" opt-out
            // restores the full #123 count. Reversible — revert to `out.count`.
            searchHitCount = showDisconnectedMedia
                ? out.count
                : out.filter { VolumeReachability.isReachable(path: $0.fullPath) }.count
        } else {
            searchHitCount = 0
        }
        if !filterTargetPaths.isEmpty {
            let prefixes = Array(filterTargetPaths)
            // Match records by CURRENT physical location only. A relocated file
            // shows under its destination volume, never its source — see
            // pfRecordOnSelectedVolume. (Previously this also matched
            // originalFullPath, so selecting RicksBackups surfaced files that
            // had moved to LaCie — confusing, and inconsistent with the Volume
            // column.)
            out = out.filter { pfRecordOnSelectedVolume($0, prefixes: prefixes) }
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
        // Reachable-only baseline (2026-07-20): by default the catalog shows
        // ONLY media on currently-mounted volumes. The "Show disconnected
        // media" toggle lifts this baseline. Uses the SAME
        // VolumeReachability.isReachable the Volumes view uses so the two
        // stay consistent. Applied here (after the additive filters would
        // start) but gated on its OWN flag, not `viewFilters` — Clear All
        // Filters must not disturb it.
        if !showDisconnectedMedia {
            out = out.filter { VolumeReachability.isReachable(path: $0.fullPath) }
        }
        // View menu filters (additive — each active filter narrows further)
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
        // Workspace chip: keep only records the user has actively imported
        // into the triage workspace. Orthogonal to lifecycleStage — a
        // Cataloged record can also be workspace-active.
        if viewFilters.contains(.workspaceOnly) {
            out = out.filter { $0.workspaceActive }
        }
        if viewFilters.contains(.untaggedOnly) {
            out = out.filter(pfRecordIsUntagged)
        }
        // Repair-lifecycle worklist (GH #132 P3): only repair copies
        // still waiting for Rick's confirmation.
        if viewFilters.contains(.awaitingConfirmation) {
            out = out.filter(pfAwaitingConfirmation)
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
                    // Same affordance for the most recent Tidy Catalog apply.
                    tidyUndoBanner
                    // …and for the most recent Confirm Repair (GH #132).
                    confirmUndoBanner
                    // Music-triage suggestion (GH #124 layer 2, nag-button
                    // pattern). Reads the memoized candidate list — no
                    // O(records) work per body eval.
                    musicTriageBanner
                    // Empty-state overlay: when a search is active and
                    // yields zero rows, surface that explicitly instead
                    // of leaving the user staring at a blank table area.
                    // The Table widget itself just shows headers + empty,
                    // which is ambiguous (Rick 2026-06-16).
                    ZStack {
                        catalogTable
                        if tableData.isEmpty && !searchText.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 28))
                                    .foregroundColor(.secondary)
                                Text("No matches")
                                    .font(.title3.weight(.medium))
                                    .foregroundColor(.secondary)
                                Text("Try removing a term, or check that the records you expect have transcripts (Transcribe Audio) and captions (Generate Captions) populated.")
                                    .font(.callout)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 420)
                                    .padding(.horizontal, 16)
                            }
                            .padding(40)
                        }
                    }
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
                    },
                    trimSource: trimSource,
                    trimDerivatives: trimDerivatives,
                    repairSource: repairSource,
                    repairCopy: repairCopy,
                    onConfirmRepair: { id in
                        _ = model.confirmRepair(repairID: id)
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
            // Live-preview follow (2026-07-28): when the mode is armed,
            // drive the filmstrip to the newly highlighted row. When it's
            // OFF this is a pure no-op, so ordinary arrow navigation is
            // unchanged. Runs AFTER onSelect so the model's per-row
            // resetFilmstrip has already keyed to this path — requestFilmstrip
            // for the same path is then kept, not cancelled.
            let action = livePreviewMode.selectionChanged(candidatePath: livePreviewCandidatePath())
            applyLivePreview(action)
        }
        // Space-toggle monitor lives for the catalog pane's on-screen
        // lifetime — installed here, torn down (and the mode reset) on
        // disappear so it can't fire from another tab.
        .onAppear { installSpaceKeyMonitor() }
        .onDisappear { removeSpaceKeyMonitor() }
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
                    // userNotes split (2026-07-23): the sheet edits YOUR
                    // note field; machine probe notes are untouched. The
                    // model helper also refreshes the search index so a
                    // note: search reflects the edit immediately.
                    if let target = notesTarget {
                        model.setUserNotes(notesText, for: target)
                    }
                    showNotesSheet = false
                },
                onCancel: { showNotesSheet = false }
            )
        }
        // "Custom Tag…" free-form entry (workflow tags, 2026-07-23).
        // TextField-in-alert is the lightest chrome for one line of
        // input; quick-picks stay in the Tags submenu / inspector ⊕.
        .alert("Add a Tag", isPresented: $showCustomTagAlert) {
            TextField("Your tag (like \u{201C}Fix Color\u{201D})", text: $customTagText)
            Button("Add Tag") {
                let targets = records.filter { customTagTargetIDs.contains($0.id) }
                model.addTag(customTagText, to: targets)
                customTagText = ""
                customTagTargetIDs = []
            }
            Button("Cancel", role: .cancel) {
                customTagText = ""
                customTagTargetIDs = []
            }
        } message: {
            Text("Tag the selected files with your own word or phrase. You can search for it later with tag:.")
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
        .sheet(item: $transcodeRequest) { request in
            TranscodeSheet(request: request)
        }
        // "Clean Up Video" recipe confirmation. Same .sheet(item:) shape
        // as the transcode sheet above (never chained isPresented).
        .sheet(item: $cleanupRequest) { request in
            CleanupSheet(request: request)
        }
        // "Trim Master…" in/out point picker. Same .sheet(item:) shape.
        .sheet(item: $trimRequest) { request in
            TrimSheet(request: request)
        }
        // "Verification Results" (GH #128/#135) — presentation-only;
        // carries the Balance Audio offer since the GH #137
        // consolidation. Same .sheet(item:) shape.
        .sheet(item: $verifyAudioRequest) { request in
            VerifyAudioSheet(request: request)
        }
        // Music-triage review list (GH #124). Same .sheet(item:) shape.
        .sheet(item: $musicTriagePayload) { payload in
            MusicTriageSheet(candidateIDs: payload.candidateIDs)
                .environmentObject(model)
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
    /// Internal (not private): invoked by the row context menu in
    /// CatalogContent+Table.swift.
    func findOnlineVersion(for rec: VideoRecord) {
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
    /// Internal (not private): invoked by the row context menu in
    /// CatalogContent+Table.swift.
    func startFrameRip(for rec: VideoRecord) {
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

    // Inline undo affordance for the most recent "Tidy Catalog" apply —
    // purple to match the set-aside palette, otherwise the same layout and
    // dismissal rules as the purge banner (no auto-dismiss timer).
    @ViewBuilder
    private var tidyUndoBanner: some View {
        if let batch = model.lastTidyBatch {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.purple)
                let n = batch.ids.count
                Text("Set aside \(n) file\(n == 1 ? "" : "s") — nothing was deleted.")
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                Button("Undo") {
                    _ = model.undoLastTidyCatalog()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()

                Button {
                    model.dismissTidyUndoBanner()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.secondary, Color.secondary.opacity(0.2))
                }
                .buttonStyle(.plain)
                .help("Dismiss — set-aside files stay hidden until you flip “Show set-aside files” and right-click → Put Back in Catalog")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.purple.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.purple.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // Inline undo affordance for the most recent "Sounds Good — Confirm
    // Repair" (GH #132) — brown to match the superseded palette,
    // otherwise the same layout and dismissal rules as its siblings
    // above (no auto-dismiss timer; Rick wants to take his time).
    @ViewBuilder
    private var confirmUndoBanner: some View {
        if let batch = model.lastConfirmBatch {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.brown)
                let n = batch.snapshots.count
                Text("Confirmed \(n) repair\(n == 1 ? "" : "s") — the original\(n == 1 ? " is" : "s are") hidden, never deleted.")
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                Button("Undo") {
                    _ = model.undoConfirmRepair()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()

                Button {
                    model.dismissConfirmUndoBanner()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.secondary, Color.secondary.opacity(0.2))
                }
                .buttonStyle(.plain)
                .help("Dismiss — superseded originals stay hidden until you flip “Show superseded” and right-click → Restore Original")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.brown.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.brown.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Music Triage Banner (GH #124 layer 2)
    //
    // Suggestion chip in the banner stack. Hidden while a focus filter is
    // active (the user is mid-navigation), when there are no candidates,
    // or when the user dismissed it at exactly this count. Clicking
    // "Review & Remove…" freezes the candidate IDs into the sheet payload
    // so the reviewed list can't shift under the user.
    @ViewBuilder
    private var musicTriageBanner: some View {
        if filterByIDs.isEmpty {
            let ids = musicTriageCandidateIDs
            if !ids.isEmpty && ids.count != musicTriageDismissedCount {
                MusicTriageBanner(
                    count: ids.count,
                    onReview: { musicTriagePayload = MusicTriagePayload(candidateIDs: ids) },
                    onDismiss: { musicTriageDismissedCount = ids.count }
                )
            }
        }
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
                            // Full path + codecs (replaced Volume Size /
                            // Media Cataloged, Rick 2026-07-31: show what
                            // the selected file IS, not where it lives).
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rec.fullPath)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(3)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                if !rec.videoCodec.isEmpty {
                                    Text("Video: \(rec.videoCodec)")
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                if !rec.audioCodec.isEmpty {
                                    Text("Audio: \(rec.audioCodec)")
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                            if isPlaying || model.filmstripState.isActive(forPath: rec.fullPath) {
                                Button {
                                    // Symmetric teardown for BOTH preview
                                    // modes: the AVPlayer path and the
                                    // filmstrip path (stopFilmstrip also
                                    // cancels an in-flight interactive
                                    // generation; a background prewarm
                                    // keeps running for the disk cache).
                                    player?.pause()
                                    player = nil
                                    isPlaying = false
                                    model.stopFilmstrip()
                                    // Stop also EXITS preview-follows-selection
                                    // mode (live-preview, 2026-07-28) — Space
                                    // and Stop are the two symmetric off-switches.
                                    _ = livePreviewMode.stop()
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
                        } else if case .ready(let stripPath, let stripFrames) = model.filmstripState,
                                  stripPath == selectedRecord?.fullPath {
                            // Filmstrip mode (filmstrip preview, 2026-07-27):
                            // the play-button path for records AVKit can't
                            // decode (MKV/FFV1 — PreviewFrameRouter said
                            // .ffmpegDirect). Sits exactly where VideoPlayer
                            // renders for playable files. `.id` ties the
                            // view's playback state (frame index) to the
                            // row — a row switch rebuilds from frame 0.
                            FilmstripPreviewView(frames: stripFrames,
                                                 videoCodec: selectedRecord?.videoCodec ?? "",
                                                 container: selectedRecord?.container ?? "")
                                .id(stripPath)
                        } else if case .loading(let stripPath, let done, let total) = model.filmstripState,
                                  stripPath == selectedRecord?.fullPath {
                            // Interactive strip generation in flight —
                            // honest progress, same placeholder family as
                            // MEDIA OFFLINE / NO PREVIEW.
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.black)
                                VStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Extracting frame \(min(done + 1, max(total, 1))) of \(max(total, 1))…")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .monospacedDigit()
                                }
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
                                        // ROUTED (filmstrip preview,
                                        // 2026-07-27): consult the same pure
                                        // route decision every other preview
                                        // path uses BEFORE constructing any
                                        // AVFoundation object. An MKV/FFV1
                                        // record must never instantiate
                                        // AVPlayer — AVKit just shows the
                                        // crossed-out play glyph. O(1) per
                                        // click, no I/O.
                                        // The route→surface mapping is the
                                        // pure PreviewPlayAction seam so the
                                        // FilmstripRouteGateSensor can pin it
                                        // (testing agent, 2026-07-27).
                                        let route = PreviewFrameRouter.previewRoute(
                                            container: rec.container,
                                            videoCodec: rec.videoCodec,
                                            likelyUnanalyzable: rec.isLikelyUnanalyzable)
                                        switch PreviewPlayAction.forRoute(route) {
                                        case .filmstrip:
                                            model.requestFilmstrip(for: rec)
                                        case .avPlayer:
                                            let url = URL(fileURLWithPath: rec.fullPath)
                                            player = AVPlayer(url: url)
                                            isPlaying = true
                                            player?.play()
                                        }
                                    } label: {
                                        Image(systemName: "play.circle.fill")
                                            .font(.system(size: 48))
                                            .foregroundColor(.white.opacity(0.85))
                                            .shadow(radius: 4)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } else if previewUnavailable {
                            // Preview generation failed (AVF + ffmpeg both
                            // struck out, or the negative cache remembered
                            // it). Same placeholder family as MEDIA OFFLINE /
                            // AUDIO ONLY — the spinner below is reserved for
                            // genuinely in-flight generation.
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.black)
                                VStack(spacing: 6) {
                                    Image(systemName: "film.slash")
                                        .font(.system(size: 36))
                                        .foregroundColor(.gray.opacity(0.8))
                                    Text("NO PREVIEW")
                                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                                        .foregroundColor(.gray)
                                }
                            }
                            .frame(maxWidth: 480, maxHeight: 180)
                            .aspectRatio(16.0/9.0, contentMode: .fit)
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

// MARK: - Shared media open helpers

private let mediaOpenLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "mediaOpen")

/// Which player VideoScan should hand a file to.
enum MediaPlayerChoice: Equatable {
    /// QuickTime Player — chosen ONLY when the cataloged codecs guarantee
    /// both picture AND sound play (Rick's preferred player when it works).
    case quickTime
    /// VLC — the "opens anything" fallback for codecs QuickTime can't
    /// decode, or would open silently (ac3/dts/opus/…), or files we have
    /// no metadata for. Used when /Applications/VLC.app exists.
    case vlc
    /// The system default handler — last resort when VLC isn't installed.
    case systemDefault
}

enum MediaOpener {

    // MARK: Player decision (pure, unit-testable)
    //
    // Decided entirely from already-cataloged ffprobe metadata — zero
    // runtime probing. Conservative by design: QuickTime is returned ONLY
    // on a positive three-way match (container + video codec + audio
    // codec all known-good). ANY uncertainty — an empty/unknown field, an
    // off-list audio codec that QT would open silently — routes to VLC.

    /// File extensions whose container QuickTime opens natively. Matched
    /// against `VideoRecord.ext` (the scanner stores the UPPERCASED
    /// pathExtension there; our `norm()` lowercases before comparing).
    /// We deliberately key off the extension, NOT `record.container`,
    /// because the scanner fills `container` with ffprobe's
    /// `format_long_name` ("QuickTime / MOV"), not a short token.
    private static let qtContainers: Set<String> = ["mov", "mp4", "m4v", "qt"]

    /// Video codecs QuickTime can decode. These are compared against
    /// `VideoRecord.videoCodec`, which the scanner fills from ffprobe's
    /// `codec_name` — so only codec_name spellings appear here (no fourccs
    /// like avc1/hvc1/apcn, which codec_name never emits).
    private static let qtVideoCodecs: Set<String> = [
        "h264", "hevc", "prores", "mjpeg"
    ]

    /// Audio codecs QuickTime plays WITH SOUND, as ffprobe `codec_name`
    /// spells them. The empty string means "no audio track" — video-only
    /// files are fine in QT. Anything NOT on this list (ac3, eac3, dts,
    /// opus, vorbis, flac, truehd, …) makes QT open-but-silent, so it is
    /// deliberately excluded → routes to VLC.
    private static let qtAudioCodecs: Set<String> = [
        "aac", "alac", "mp3",
        "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le",
        "pcm_s8", "pcm_u8", ""
    ]

    /// Pure decision function. Inputs are normalized (trimmed, lowercased)
    /// before matching. See the allow-lists above for the exact policy.
    static func preferredPlayer(container: String,
                                videoCodec: String,
                                audioCodec: String,
                                hasVLC: Bool) -> MediaPlayerChoice {
        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let c = norm(container)
        let v = norm(videoCodec)
        let a = norm(audioCodec)

        // Positive-match only. Missing container or videoCodec fails the
        // Set.contains check on its own, so uncataloged files fall through
        // to VLC/systemDefault without a special case.
        let qtOK = qtContainers.contains(c)
            && qtVideoCodecs.contains(v)
            && qtAudioCodecs.contains(a)

        if qtOK { return .quickTime }
        return hasVLC ? .vlc : .systemDefault
    }

    /// Convenience overload reading the fields off a catalog record.
    ///
    /// NOTE: we pass `record.ext` ("MOV") as the container token — NOT
    /// `record.container`, which the scanner fills with ffprobe's
    /// `format_long_name` ("QuickTime / MOV") and would never match the
    /// short tokens in `qtContainers`. (Blocker fix 2026-07-20.)
    static func preferredPlayer(for record: VideoRecord,
                                hasVLC: Bool) -> MediaPlayerChoice {
        preferredPlayer(container: record.ext,
                        videoCodec: record.videoCodec,
                        audioCodec: record.audioCodec,
                        hasVLC: hasVLC)
    }

    // MARK: VLC availability
    //
    // `static let` is computed lazily exactly once on first access and is
    // thread-safe — the Swift analog of a function-local `static` in C++
    // (Meyers singleton). We only probe the filesystem once per launch.
    private static let vlcAppPath = "/Applications/VLC.app"
    private static let vlcInstalled: Bool =
        FileManager.default.fileExists(atPath: vlcAppPath)

    /// Whether /Applications/VLC.app is present (cached for the process).
    static var hasVLC: Bool { vlcInstalled }

    // MARK: Smart launch

    /// The unified double-click entry point: pick the right player per
    /// record from cataloged metadata, then launch — batching by player
    /// so a multi-selection opens in as few app launches as possible.
    /// Records on unreachable volumes are skipped (and logged), never
    /// blocked on.
    ///
    /// `@MainActor` ≈ "this must run on the UI thread": NSWorkspace launch
    /// APIs expect the main thread, and every caller is a SwiftUI
    /// primaryAction/button closure already on the main actor.
    @MainActor
    static func open(_ records: [VideoRecord]) {
        let reachable = records.filter { rec in
            if VolumeReachability.isReachable(path: rec.fullPath) { return true }
            mediaOpenLog.info("Skipping unreachable file: \(rec.fullPath, privacy: .public)")
            return false
        }
        guard !reachable.isEmpty else { return }

        var qtURLs: [URL] = []
        var vlcURLs: [URL] = []
        var defaultURLs: [URL] = []
        for rec in reachable {
            let url = URL(fileURLWithPath: rec.fullPath)
            switch preferredPlayer(for: rec, hasVLC: hasVLC) {
            case .quickTime:     qtURLs.append(url)
            case .vlc:           vlcURLs.append(url)
            case .systemDefault: defaultURLs.append(url)
            }
        }

        if !qtURLs.isEmpty { launchQuickTime(qtURLs) }
        if !vlcURLs.isEmpty { launchVLC(vlcURLs) }
        for url in defaultURLs {
            mediaOpenLog.info("Opening in system default handler: \(url.path, privacy: .public)")
            NSWorkspace.shared.open(url)
        }
    }

    /// Open one or more catalog records in QuickTime Player, unconditionally.
    /// Kept for the explicit "Open in QuickTime Player" menu item — the
    /// smart path is `open(_:)`. Silently skips records on offline volumes.
    @MainActor
    static func openInQuickTime(_ records: [VideoRecord]) {
        let urls = records
            .filter { VolumeReachability.isReachable(path: $0.fullPath) }
            .map { URL(fileURLWithPath: $0.fullPath) }
        launchQuickTime(urls)
    }

    /// Open one or more catalog records in VLC, unconditionally. Kept for
    /// the explicit "Open in VLC" menu item (the manual-override sibling of
    /// "Open in QuickTime Player") — the smart auto-decision path is
    /// `open(_:)`. Skips records on offline volumes, same filter as `open`.
    /// If /Applications/VLC.app isn't present, falls back to the system
    /// default handler so the menu item never silently no-ops.
    @MainActor
    static func openInVLC(_ records: [VideoRecord]) {
        let urls = records
            .filter { VolumeReachability.isReachable(path: $0.fullPath) }
            .map { URL(fileURLWithPath: $0.fullPath) }
        guard !urls.isEmpty else { return }
        if hasVLC {
            launchVLC(urls)   // shared private launcher — no duplicated launch code
        } else {
            for url in urls {
                mediaOpenLog.info("VLC absent; opening in system default handler: \(url.path, privacy: .public)")
                NSWorkspace.shared.open(url)
            }
        }
    }

    @MainActor
    private static func launchQuickTime(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let qtURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.QuickTimePlayerX"
        ) else {
            mediaOpenLog.error("QuickTime Player not found; \(urls.count) file(s) not opened")
            return
        }
        mediaOpenLog.info("Opening \(urls.count) file(s) in QuickTime")
        NSWorkspace.shared.open(urls,
                                withApplicationAt: qtURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Launch the VLC application BUNDLE (LaunchServices resolves the
    /// correct arm64 binary — never hardcode Contents/MacOS/VLC).
    @MainActor
    private static func launchVLC(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        mediaOpenLog.info("Opening \(urls.count) file(s) in VLC")
        NSWorkspace.shared.open(urls,
                                withApplicationAt: URL(fileURLWithPath: vlcAppPath),
                                configuration: NSWorkspace.OpenConfiguration())
    }
}
