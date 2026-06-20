// CatalogHelpers.swift
// Catalog tab content: the table + preview pane (CatalogContent), its
// duplicate-disposition cell, and shared media-open helpers.
// (Toolbar → CatalogToolbar.swift, inspector → InspectorPanel.swift,
// sheets/menus → CatalogSheets.swift; 2026-06-11 file-split refactor.)

import SwiftUI
import AVKit

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

    func computeFiltered() -> [VideoRecord] {
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
            // Match records by CURRENT physical location only. A relocated file
            // shows under its destination volume, never its source — see
            // pfRecordOnSelectedVolume. (Previously this also matched
            // originalFullPath, so selecting RicksBackups surfaced files that
            // had moved to LaCie — confusing, and inconsistent with the Volume
            // column.)
            out = out.filter { pfRecordOnSelectedVolume($0, prefixes: prefixes) }
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
        // Workspace chip: keep only records the user has actively imported
        // into the triage workspace. Orthogonal to lifecycleStage — a
        // Cataloged record can also be workspace-active.
        if viewFilters.contains(.workspaceOnly) {
            out = out.filter { $0.workspaceActive }
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

