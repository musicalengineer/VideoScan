// CatalogContent+Table.swift
// The catalog results Table, its row context menus, and the per-column
// cell builders — extracted verbatim from CatalogContent's body in
// CatalogHelpers.swift (refactor 2026-06-11). A cross-file `extension`
// can't see `private` members, so the handful of CatalogContent stored
// properties/helpers this code touches were widened to internal in
// CatalogHelpers.swift (single-module app — same visibility in practice).
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state allowed, methods share the same `self`; `private` here
// means file-private to THIS file.)

import SwiftUI

extension CatalogContent {

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

    /// Right-click menu for set-aside rows (video-only catalog scope,
    /// 2026-07-15). Same minimal shape as the purged menu: Put Back +
    /// Reveal. Set-aside records are inert until restored — they must not
    /// be offered Combine/Correlate/Tag actions.
    @ViewBuilder
    private func setAsideRowContextMenu(rec: VideoRecord, selectedRecs: [VideoRecord]) -> some View {
        let setAsideSelection = selectedRecs.filter { $0.isSetAside }
        Button {
            _ = model.restoreSetAsideRecords(ids: Set(setAsideSelection.map(\.id)))
        } label: {
            Label(setAsideSelection.count > 1
                  ? "Put \(setAsideSelection.count) Back in Catalog"
                  : "Put Back in Catalog",
                  systemImage: "arrow.uturn.backward.circle")
        }
        if VolumeReachability.isReachable(path: rec.fullPath) {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(rec.fullPath, inFileViewerRootedAtPath: "")
            }
        }
    }

    /// Right-click menu for superseded rows (repair lifecycle, GH #132).
    /// Same minimal shape as the purged / set-aside menus: superseded
    /// originals are inert until restored — no Combine/Correlate/Tag.
    /// "Show Repaired Copy in Catalog" jumps to the record that replaced
    /// this one.
    @ViewBuilder
    private func supersededRowContextMenu(rec: VideoRecord, selectedRecs: [VideoRecord]) -> some View {
        let supersededSelection = selectedRecs.filter { $0.isSuperseded }
        if supersededSelection.count == 1, let repairID = rec.supersededByID,
           model.record(forID: repairID) != nil {
            Button {
                onShowRepairedCopy?(repairID)
            } label: {
                Label("Show Repaired Copy in Catalog",
                      systemImage: "arrow.triangle.swap")
            }
            .accessibilityIdentifier("catalog.row.showRepairedCopy")
        }
        Button {
            for r in supersededSelection { _ = model.unsupersede(id: r.id) }
        } label: {
            Label(supersededSelection.count > 1
                  ? "Restore \(supersededSelection.count) Originals (Un-supersede)"
                  : "Restore Original (Un-supersede)",
                  systemImage: "arrow.uturn.backward.circle")
        }
        .help("Bring this original back into the catalog's default view. The repaired copy stays too — nothing on disk changes.")
        .accessibilityIdentifier("catalog.row.unsupersede")
        if VolumeReachability.isReachable(path: rec.fullPath) {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(rec.fullPath, inFileViewerRootedAtPath: "")
            }
        }
    }

    /// Filename-cell tooltip: directory + state suffix, plus the pro-video
    /// bundle tag when the file lives inside a project bundle ("Look Inside
    /// Video Project Bundles", 2026-07-02). Kept as a helper so the bundle
    /// line composes with every existing state instead of another ternary.
    private func filenameTooltip(for rec: VideoRecord, offline: Bool, purged: Bool) -> String {
        var tip: String
        if purged {
            tip = "\(rec.directory) (removed from catalog)"
        } else if rec.isSetAside {
            let label = rec.setAsideReason
                .flatMap { CatalogScopePolicy.SetAsideReason(rawValue: $0)?.friendlyLabel }
                ?? "outside catalog scope"
            tip = "\(rec.directory) (set aside — \(label.lowercased()))"
        } else if rec.isSuperseded {
            // Repair lifecycle (GH #132): name the replacing file when we
            // can still resolve it — the "why is this row brown" answer.
            let replacement = rec.supersededByID
                .flatMap { model.record(forID: $0)?.filename }
            tip = replacement == nil
                ? "\(rec.directory) (superseded by its repaired copy)"
                : "\(rec.directory) (superseded by \(replacement ?? ""))"
        } else if let reason = rec.unanalyzableReason {
            tip = "\(rec.directory)\n\n⚠️ \(reason)"
        } else if offline {
            tip = "\(rec.directory) (offline)"
        } else {
            tip = rec.directory
        }
        if !rec.scanContext.bundleContainer.isEmpty {
            tip += "\n\n📦 Inside video project bundle: \(rec.scanContext.bundleContainer)"
        }
        // Verify Audio damaged verdict (GH #128) — composes with every
        // state above (the red filename tint needs its "why" visible).
        // The note self-describes since the "Damaged audio — <detail>"
        // standardization, so no extra label — a label would double up
        // as "Damaged audio: Damaged audio — …".
        if rec.audioVerifyStatus == "damaged" {
            tip += "\n\n⚠️ \(rec.audioVerifyNote.isEmpty ? "Damaged audio" : rec.audioVerifyNote)"
        }
        return tip
    }

    // MARK: - Results Table

    // Internal (not private): the view body in CatalogHelpers.swift embeds
    // this table in the left pane.
    //
    // Split (GH #132): the Table-with-columns expression and its long
    // modifier chain were ONE expression, and the chain's growth (extra
    // onChange keys) pushed the combined type-check past Xcode's budget.
    // `catalogTableBase` isolates the columns; this var owns the chain.
    var catalogTable: some View {
        tableWithMenus
        .onAppear { tableData = computeFiltered() }
        .onChange(of: records.count) { tableData = computeFiltered() }
        .onChange(of: searchText) { tableData = computeFiltered() }
        .onChange(of: filterTargetPaths) { tableData = computeFiltered() }
        .onChange(of: showPairsOnly) { tableData = computeFiltered() }
        .onChange(of: filterByIDs) { tableData = computeFiltered() }
        .onChange(of: viewFilters) { tableData = computeFiltered() }
        // Reachable-only baseline opt-out (2026-07-20).
        .onChange(of: showDisconnectedMedia) { tableData = computeFiltered() }
        // Media-kind facet chip flip (GH #124).
        .onChange(of: kindFacet) { tableData = computeFiltered() }
        .onChange(of: showRemoved) { tableData = computeFiltered() }
        .onChange(of: showSetAside) { tableData = computeFiltered() }
        // Superseded reveal toggle (GH #132).
        .onChange(of: showSuperseded) { tableData = computeFiltered() }
        .onChange(of: model.lastTidyBatch) { tableData = computeFiltered() }
        // Re-compute when purge state flips on any record (purge, undo, restore).
        // We key off lastPurgedBatch so mutations from the model are observed.
        .onChange(of: model.lastPurgedBatch) { tableData = computeFiltered() }
        // Confirm Repair supersedes originals (and undo restores them) —
        // same observation pattern as the purge batch (GH #132).
        .onChange(of: model.lastConfirmBatch) { tableData = computeFiltered() }
    }

    /// Sort + menus stage of the split — see `catalogTable`'s note.
    private var tableWithMenus: some View {
        catalogTableBase
        .onChange(of: sortOrder) {
            onSort(sortOrder)
            tableData.sort(using: sortOrder)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            rowContextMenu(ids: ids)
        } primaryAction: { ids in
            // Double-click / Return on row(s) → smart open (QuickTime when
            // the cataloged codecs guarantee picture+sound, else VLC).
            let recs = ids.compactMap { id in records.first { $0.id == id } }
            MediaOpener.open(recs)
        }
    }

    private var catalogTableBase: some View {
        Table(tableData, selection: $selectedIDs, sortOrder: $sortOrder) {
            TableColumn("Filename", value: \.filename) { rec in
                let offline = !VolumeReachability.isReachable(path: rec.fullPath)
                let purged = rec.isPurged
                let workspaceActive = rec.workspaceActive
                let setAside = rec.isSetAside
                let superseded = rec.isSuperseded
                HStack(spacing: 4) {
                    if purged {
                        // Trash-slash icon makes the "removed" state obvious
                        // at a glance — even if the user's row colors are
                        // partially overridden by a high-contrast theme.
                        Image(systemName: "trash.slash")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    } else if setAside {
                        // Archive-box = "set aside by catalog scope" (photo /
                        // music / audio with no matching video). Purple to
                        // stay distinct from purge-orange.
                        Image(systemName: "archivebox")
                            .font(.system(size: 10))
                            .foregroundColor(.purple)
                    } else if superseded {
                        // Swap arrows = "a confirmed repair replaced this
                        // original" (GH #132). Brown to stay distinct from
                        // purge-orange and set-aside-purple.
                        Image(systemName: "arrow.triangle.swap")
                            .font(.system(size: 10))
                            .foregroundColor(.brown)
                    } else if rec.isLikelyUnanalyzable {
                        // Red "!" — file's video / audio codec was
                        // deprecated by AVFoundation (svq3, qdm2,
                        // cinepak, etc.) so the analyzer can't decode
                        // it. Right-click → Reformat and Analyze to
                        // convert via ffmpeg. Rick 2026-06-14.
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                    } else if workspaceActive {
                        // Hammer = "being worked on with external tools."
                        // Turquoise (.mint adapts for dark mode) marks the
                        // record as triage-active. Pass A — Rick 2026-06-14.
                        Image(systemName: "hammer.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.mint)
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
                        // Workspace tint (.mint / turquoise) sits between
                        // purged-orange (highest priority) and the rest.
                        .italic(offline || purged || setAside || superseded)
                        .foregroundColor(purged ? .orange
                            : (setAside ? .purple
                                : (superseded ? .brown
                                    : (workspaceActive ? .mint
                                        : (offline ? .secondary
                                            : (showPairsOnly && rec.pairedWith != nil
                                               ? (rec.streamType == .videoOnly ? .blue : .green)
                                               : rec.filenameColor))))))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .help(filenameTooltip(for: rec, offline: offline, purged: purged))
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

            // GH #124 layer 4: audio-only rows always CAPTURED their codec
            // (ScanEngine maps codec_name for the first audio stream); the
            // column just never showed it, so 80k music rows read "—".
            // displayCodec = videoCodec, falling back to audioCodec when
            // there's no video stream. Sort key follows the displayed value.
            TableColumn("Codec", value: \.displayCodec) { rec in
                Text(rec.displayCodec.isEmpty ? "—" : rec.displayCodec)
                    .foregroundColor(rec.displayCodec.isEmpty ? .secondary : .primary)
                    .help("Video codec (e.g. h264, prores); for audio-only files, the audio codec (e.g. mp3, aac, pcm_s16le)")
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

            // Resolved best date (GH #117): Rick's hand-entered date —
            // either confidence — OUTRANKS the dossier's inferred date,
            // which outranks the filesystem creation date. Estimated
            // entries carry an " (est.)" suffix; the tooltip names the
            // source. Both accessors are O(1) per record (pure integer
            // math on the user-date path — VideoRecordUserDate.swift),
            // so the column stays safe at catalog scale.
            TableColumn("Date", value: \.resolvedDateSortKey) { rec in
                let display = rec.resolvedDateDisplay
                Text(display.isEmpty ? "—" : display)
                    .foregroundColor(display.isEmpty ? .secondary : .primary)
                    .font(.system(size: 11))
                    .help(rec.resolvedDateHelp)
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
    }

    /// The row context menu, extracted WHOLE from the Table's modifier
    /// chain (GH #132): the menu plus the grown onChange chain pushed the
    /// single `catalogTable` expression past Xcode's type-check budget.
    /// Same medicine as onlineCopyMenu / tagColumnCell — a dedicated
    /// function gives the compiler a small, isolated context.
    ///
    /// Lint note: this body is the SAME menu that previously lived
    /// inline in the `.contextMenu` closure (where the function-body
    /// rules couldn't see it) — the extraction is behavior-preserving,
    /// not new complexity. Decomposing the menu into per-section
    /// builders is real refactor work for reviewed daylight, not an
    /// overnight feature branch (refactor-scope rule).
    @ViewBuilder
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func rowContextMenu(ids: Set<UUID>) -> some View {
        let selectedRecs = ids.compactMap { id in records.first { $0.id == id } }
        // Mixed-selection split. Each predicate is computed once so the
        // Restore / Remove menu items use the same record set their
        // actions operate on (label counts == operated-on counts).
        // Swift's `.filter` ≈ C++ std::copy_if into a new vector.
        let activeRecs = selectedRecs.filter { !$0.isPurged && !$0.isSetAside && !$0.isSuperseded }
        let purgedRecs = selectedRecs.filter { $0.isPurged }
        let setAsideRecs = selectedRecs.filter { $0.isSetAside && !$0.isPurged }
        let supersededRecs = selectedRecs.filter { $0.isSuperseded && !$0.isPurged && !$0.isSetAside }
        if let id = ids.first,
           let rec = records.first(where: { $0.id == id }) {
            // Pure-purged selection: minimal menu (Restore + Reveal).
            // Pure set-aside selection: minimal menu (Put Back + Reveal).
            // Mixed selection: show the full active menu PLUS a Restore
            // item for the purged subset; row-targeted active actions
            // (Combine, Rename, Tag, etc.) are gated on
            // `purgedRecs.isEmpty` so a multi-select that pulled in any
            // purged row doesn't silently apply destructive ops to it.
            // Spec: "active-only row actions must be gated on
            // purgedRecs.isEmpty".
            if !activeRecs.isEmpty || rec.isPurged || rec.isSetAside || rec.isSuperseded {
                if rec.isPurged && activeRecs.isEmpty {
                    purgedRowContextMenu(rec: rec, selectedRecs: selectedRecs)
                } else if rec.isSetAside && activeRecs.isEmpty {
                    setAsideRowContextMenu(rec: rec, selectedRecs: selectedRecs)
                } else if rec.isSuperseded && activeRecs.isEmpty {
                    // Pure-superseded selection: minimal menu (Show
                    // Repaired Copy + Restore + Reveal) — GH #132.
                    supersededRowContextMenu(rec: rec, selectedRecs: selectedRecs)
                } else {
                    // Active or mixed selection — show the full menu,
                    // gating active-row actions on the selection being
                    // free of ALL inert states (purged / set-aside /
                    // superseded rows must never receive destructive ops).
                    let pureActive = purgedRecs.isEmpty && setAsideRecs.isEmpty
                        && supersededRecs.isEmpty
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
                    // Explicit manual override sibling of the QuickTime
                    // item above — forces VLC regardless of the smart
                    // double-click auto-decision. Falls back to the
                    // system default handler when VLC isn't installed.
                    Button("Open in VLC") {
                        MediaOpener.openInVLC([rec])
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

                    // Find Matching Audio — Rick 2026-06-14 (renamed
                    // from "Repair Audio" with GH #116, which freed
                    // the repair/fix verb space for Balance Audio).
                    // Video-only files only. Auto-finds the
                    // highest-confidence audio-only match (same
                    // scorer Find A/V Pair uses) and pre-fills the
                    // Combine sheet. Internal names + accessibility
                    // ids deliberately unchanged — visible strings
                    // only.
                    if rec.streamType == .videoOnly {
                        Button("Find Matching Audio…") {
                            repairAudio(for: rec)
                            openWindow(id: "combine")
                        }
                        .disabled(!VolumeReachability.isReachable(path: rec.fullPath))
                        .accessibilityIdentifier("catalog.row.repairAudio")
                    }

                    // Find Matching Video — symmetric verb for
                    // audio-only files (Rick 2026-06-15; renamed from
                    // "Repair Video" alongside the audio verb so the
                    // pair reads consistently). Same CorrelationScorer
                    // works both directions: given an audio-only
                    // record, it returns the best video-only match.
                    if rec.streamType == .audioOnly {
                        Button("Find Matching Video…") {
                            repairVideo(for: rec)
                            openWindow(id: "combine")
                        }
                        .disabled(!VolumeReachability.isReachable(path: rec.fullPath))
                        .accessibilityIdentifier("catalog.row.repairVideo")
                    }

                    // Analyze applies to the FULL selection (fix
                    // 2026-07-14 — it used only ids.first, so
                    // multi-selecting N files analyzed just one;
                    // the Tag menu below is the pattern). Jobs
                    // wait their turn behind a running batch, so
                    // the old currentStatus.isActive disable is
                    // gone — intent is never blocked, just queued.
                    Button(activeRecs.count > 1
                           ? "Analyze \(activeRecs.count) Files"
                           : "Analyze") {
                        requestAnalyze(forAll: activeRecs, stages: AnalyzeStage.all)
                    }
                    .disabled(!activeRecs.contains {
                        VolumeReachability.isReachable(path: $0.fullPath)
                    })
                    .accessibilityIdentifier("catalog.row.analyze")

                    // (The standalone "Balance Audio…" verb retired with
                    // the GH #137 consolidation — Verify Audio is the
                    // single audio-examination entry point, and its
                    // results sheet offers Balance as a treatment. The
                    // balance RENDER still runs as a BalanceAudioJob.)

                    // Transcode — opens a configuration sheet for format
                    // and destination instead of assuming the source disk.
                    // Disabled when the file is offline OR another
                    // transcode is already running for this same record
                    // (the per-file disable prevents the user from
                    // queueing two competing encodes against one input).
                    let transcodeRunning = fileOpsCenter.jobs.contains { job in
                        guard job.state.isActive, let t = job as? TranscodeJob else { return false }
                        return t.record.id == rec.id
                    }
                    let transcodeBlocked = !VolumeReachability.isReachable(path: rec.fullPath)
                        || transcodeRunning
                    Menu("Transcode") {
                        Button("For Editing…") {
                            configureTranscode(for: rec, preset: .editingLT)
                        }
                        .disabled(transcodeBlocked)
                        .accessibilityIdentifier("catalog.row.transcodeEditing")

                        // Archival splits into an "access copy"
                        // (HEVC, everyday viewing) and a verified
                        // lossless preservation master (FFV1 v3, for
                        // a possible LoC deposit). Nested so the menu
                        // doesn't grow flat and the two archival
                        // intents read as a pair.
                        Menu("For Archival…") {
                            Button("Access Copy (HEVC 10-bit)") {
                                configureTranscode(for: rec, preset: .archival)
                            }
                            .disabled(transcodeBlocked)
                            .accessibilityIdentifier("catalog.row.transcodeArchival")

                            Button("Preservation Master (FFV1 v3, verified)") {
                                configureTranscode(for: rec, preset: .preservation)
                            }
                            .disabled(transcodeBlocked)
                            .accessibilityIdentifier("catalog.row.transcodePreservation")
                        }
                    }

                    // Clean Up Video — named cleanup RECIPES (v1:
                    // "VHS Quick Clean"). Selecting one opens a
                    // friendly confirmation sheet; the render runs as
                    // a CleanupJob in the operations window. Needs a
                    // video stream, an online volume, and no cleanup
                    // already running against this same record.
                    // Registry is a tiny compile-time constant array —
                    // no O(records) work here.
                    let cleanupRunning = fileOpsCenter.jobs.contains { job in
                        guard job.state.isActive, let c = job as? CleanupJob else { return false }
                        return c.record.id == rec.id
                    }
                    let cleanupBlocked = !VolumeReachability.isReachable(path: rec.fullPath)
                        || cleanupRunning
                        || !(rec.streamType == .videoAndAudio || rec.streamType == .videoOnly)
                    Menu("Clean Up Video") {
                        ForEach(CleanupRecipeRegistry.builtIn) { recipe in
                            Button("\(recipe.displayName)…") {
                                cleanupRequest = CleanupRequest(record: rec, recipe: recipe)
                            }
                            .disabled(cleanupBlocked)
                            .accessibilityIdentifier("catalog.row.cleanup.\(recipe.id)")
                        }
                    }

                    // Trim Master — cut static/junk off the head and
                    // tail of an archival capture with a stream copy
                    // (no re-encode, no quality loss). Single-file
                    // operation in v1: disabled for multi-select.
                    // Needs a video stream, an online volume, and no
                    // trim already running against this record.
                    let trimRunning = fileOpsCenter.jobs.contains { job in
                        guard job.state.isActive, let t = job as? TrimJob else { return false }
                        return t.record.id == rec.id
                    }
                    let trimBlocked = !VolumeReachability.isReachable(path: rec.fullPath)
                        || trimRunning
                        || activeRecs.count > 1
                        || !(rec.streamType == .videoAndAudio || rec.streamType == .videoOnly)
                    Button("Trim Master…") {
                        trimRequest = TrimRequest(record: rec)
                    }
                    .disabled(trimBlocked)
                    .help(activeRecs.count > 1
                          ? "Trim Master works on one file at a time."
                          : "Cut static or junk off the start and end — a perfect copy with no quality loss. The original is never changed.")
                    .accessibilityIdentifier("catalog.row.trimMaster")

                    // Verify Audio / Verification Results / Repair
                    // Damaged Audio / Confirm Repair — extracted to
                    // a dedicated builder (GH #132/#135) so the
                    // context-menu expression stays inside Xcode's
                    // type-check budget (same fix as onlineCopyMenu).
                    audioLifecycleMenuItems(rec: rec,
                                            activeRecs: activeRecs,
                                            pureActive: pureActive)

                    // Rick 2026-06-14: grey out (don't hide) when
                    // the file lacks the relevant stream. More
                    // discoverable than absent — the user learns
                    // "Transcribe Audio exists but this file has
                    // no audio" instead of wondering where it went.
                    let hasAudio = (rec.streamType == .videoAndAudio || rec.streamType == .audioOnly)
                    // NOT raw streamType (QA F9): an mp3's cover art
                    // probes as a video stream — classify first so
                    // audio/photo files can't launch a captions job
                    // that runs with hasNoVideo and fails confusingly.
                    let hasVideo = pfCanGenerateSceneCaptions(
                        streamTypeRaw: rec.streamTypeRaw, filename: rec.filename)
                    Button("Transcribe Audio") {
                        requestAnalyze(for: rec, stages: [.transcript])
                    }
                    .disabled(!hasAudio
                              || !VolumeReachability.isReachable(path: rec.fullPath))
                    .help(hasAudio
                          ? "Run Whisper to produce a transcript of the audio track."
                          : "This file has no audio stream to transcribe.")
                    .accessibilityIdentifier("catalog.row.transcribeAudio")

                    Button("Generate Scene Captions") {
                        requestAnalyze(for: rec, stages: [.captions])
                    }
                    .disabled(!hasVideo
                              || !VolumeReachability.isReachable(path: rec.fullPath))
                    .help(hasVideo
                          ? "Run the VLM to extract scene descriptions + OCR text/dates from video frames."
                          : "This file has no video stream to caption.")
                    .accessibilityIdentifier("catalog.row.generateCaptions")

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

                        // Workflow tags (2026-07-23) — separate from the
                        // disposition "Tag" menu above: dispositions are
                        // one-of (keep/junk verdicts), these are any-of
                        // markers ("Follow Up", "Gold", your own words).
                        // Each quick-pick toggles across the WHOLE
                        // selection; a mixed selection applies to all.
                        Menu("Tags") {
                            ForEach(WorkflowTags.quickPicks, id: \.self) { tag in
                                let allHave = selectedRecs.allSatisfy {
                                    WorkflowTags.contains($0.tags, tag)
                                }
                                // Toggle in a menu renders as a checkmark
                                // item. Binding get/set ≈ a C++ property
                                // with custom getter/setter: get feeds the
                                // checkmark, set runs the toggle action.
                                Toggle(tag, isOn: Binding(
                                    get: { allHave },
                                    set: { model.setTag(tag, on: selectedRecs, present: $0) }
                                ))
                            }
                            Divider()
                            Button("Custom Tag\u{2026}") {
                                customTagTargetIDs = Set(selectedRecs.map(\.id))
                                customTagText = ""
                                showCustomTagAlert = true
                            }
                            if selectedRecs.contains(where: { !$0.tags.isEmpty }) {
                                Divider()
                                Button("Remove All Tags") {
                                    model.removeAllTags(from: selectedRecs)
                                }
                            }
                        }

                        // People (Rick 2026-08-01): confirmed person tags,
                        // POI-database names ONLY — controlled vocabulary
                        // keeps manual tags joined to the recognition
                        // gallery. Multi-select toggles across the whole
                        // selection, same semantics as the Tags menu.
                        Menu("People") {
                            // Family wildcard first: "lots of us are in
                            // this one" — surfaces for ANY person search.
                            let familyAllHave = selectedRecs.allSatisfy { rec in
                                rec.taggedPeople.contains { $0.lowercased() == "family" }
                            }
                            Toggle("Family (everyone)", isOn: Binding(
                                get: { familyAllHave },
                                set: { model.setPerson("Family", on: selectedRecs, present: $0) }
                            ))
                            Divider()
                            let poiNames = POIProfile.listAll().map(\.name).sorted()
                            if poiNames.isEmpty {
                                Text("No people in the People database yet")
                            } else {
                                ForEach(poiNames, id: \.self) { name in
                                    // Checkmark reflects the STRONG tier
                                    // (confirmed ∪ detected) — what the
                                    // People column shows — so toggling
                                    // off a wrong auto-detection reads
                                    // checked → unchecked, not phantom.
                                    let allHave = selectedRecs.allSatisfy { rec in
                                        rec.taggedPeople.contains {
                                            $0.compare(name, options: .caseInsensitive) == .orderedSame
                                        }
                                    }
                                    Toggle(name, isOn: Binding(
                                        get: { allHave },
                                        set: { model.setPerson(name, on: selectedRecs, present: $0) }
                                    ))
                                }
                            }
                            if selectedRecs.contains(where: {
                                !$0.taggedPeople.isEmpty || !$0.suspectedPeople.isEmpty
                                    || !$0.rejectedPeople.isEmpty
                            }) {
                                Divider()
                                Button("Clear People Tags") {
                                    model.removeAllPeople(from: selectedRecs)
                                }
                            }
                        }

                        Button("Notes\u{2026}") {
                            notesTarget = rec
                            // userNotes split (2026-07-23): the sheet
                            // edits YOUR note text; machine probe notes
                            // stay read-only in the inspector.
                            notesText = rec.userNotes
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

                    // Delete File — per-row parity with the triage window's
                    // batch path (Rick 2026-06-15). Move to Trash is
                    // recoverable; Delete Permanently shows a confirmation
                    // alert first. Both call deleteConfirmedJunk, which
                    // already handles offline-skip, already-missing, and
                    // per-file failures on a detached task. Distinct from
                    // Remove from Catalog (above) which only hides the row.
                    if !activeRecs.isEmpty {
                        Menu {
                            Button(role: .destructive) {
                                let targets = activeRecs
                                Task { @MainActor in
                                    let result = await model.deleteConfirmedJunk(targets, mode: .toTrash)
                                    reportDeleteResult(result, mode: .toTrash)
                                }
                            } label: {
                                Label("Move to Trash", systemImage: "trash")
                            }
                            .accessibilityIdentifier("catalog.row.deleteToTrash")

                            Button(role: .destructive) {
                                let targets = activeRecs
                                let count = targets.count
                                let alert = NSAlert()
                                alert.messageText = count == 1
                                    ? "Delete \u{201C}\(targets[0].filename)\u{201D} permanently?"
                                    : "Delete \(count) files permanently?"
                                alert.informativeText = "This cannot be undone \u{2014} the file\(count == 1 ? " is" : "s are") removed from disk immediately, not moved to Trash."
                                alert.alertStyle = .critical
                                alert.addButton(withTitle: "Delete Permanently")
                                alert.addButton(withTitle: "Cancel")
                                if alert.runModal() == .alertFirstButtonReturn {
                                    Task { @MainActor in
                                        let result = await model.deleteConfirmedJunk(targets, mode: .permanent)
                                        reportDeleteResult(result, mode: .permanent)
                                    }
                                }
                            } label: {
                                Label("Delete Permanently\u{2026}", systemImage: "trash.fill")
                            }
                            .accessibilityIdentifier("catalog.row.deletePermanently")
                        } label: {
                            Label(activeRecs.count > 1
                                  ? "Delete \(activeRecs.count) Files"
                                  : "Delete File",
                                  systemImage: "xmark.bin")
                        }
                        .help("Move the file(s) to Trash or remove them from disk permanently. Distinct from \u{201C}Remove from Catalog\u{201D} which only hides the row.")
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

                    // Put Back in Catalog — visible when the selection
                    // contains at least one set-aside row (mixed
                    // selection; pure set-aside gets the minimal menu).
                    if !setAsideRecs.isEmpty {
                        Button {
                            _ = model.restoreSetAsideRecords(ids: Set(setAsideRecs.map(\.id)))
                        } label: {
                            Label(setAsideRecs.count > 1
                                  ? "Put \(setAsideRecs.count) Back in Catalog"
                                  : "Put Back in Catalog",
                                  systemImage: "arrow.uturn.backward.circle")
                        }
                        .help("Clear the set-aside marker on the selected rows so they show up in lists and searches again.")
                    }

                    // Restore Original — visible when a mixed selection
                    // pulled in superseded rows (pure superseded gets
                    // the minimal menu above). GH #132.
                    if !supersededRecs.isEmpty {
                        Button {
                            for r in supersededRecs { _ = model.unsupersede(id: r.id) }
                        } label: {
                            Label(supersededRecs.count > 1
                                  ? "Restore \(supersededRecs.count) Originals (Un-supersede)"
                                  : "Restore Original (Un-supersede)",
                                  systemImage: "arrow.uturn.backward.circle")
                        }
                        .help("Bring these originals back into the catalog's default view. Their repaired copies stay too — nothing on disk changes.")
                    }
                }
            }
        }
    }


    /// Verify Audio + repair-lifecycle context-menu cluster (GH #128 /
    /// #132 / #135), extracted from the row context menu so the menu's
    /// ViewBuilder expression stays inside Xcode's type-check budget
    /// (the onlineCopyMenu precedent).
    ///
    ///   Verify Audio (N Files)      — dispatch VerifyAudioJob rows to
    ///     the MFO window for ANY selection size. The levels pass
    ///     decodes the whole track (minutes on long tapes), so it must
    ///     never block the catalog in a modal sheet (GH #135).
    ///   Verification Results…       — instant presentation of the
    ///     already-computed diagnosis; the sheet performs NO probe and
    ///     NO levels decode (its request type requires a diagnosis).
    ///   Repair Damaged Audio (N)    — re-verify each damaged row and
    ///     chain into Rebuild Audio Track when the damage is the
    ///     repairable codec class (GH #132 P1).
    ///   Sounds Good — Confirm Repair — the lifecycle heart (GH #132
    ///     P2): Confirm stamps both records, human metadata carries
    ///     over, the original is retired (hidden, never deleted). The
    ///     banner above the table offers one-tap undo.
    @ViewBuilder
    private func audioLifecycleMenuItems(rec: VideoRecord,
                                         activeRecs: [VideoRecord],
                                         pureActive: Bool) -> some View {
        let verifiableRecs = activeRecs.filter {
            VolumeReachability.isReachable(path: $0.fullPath)
        }
        Button(activeRecs.count > 1
               ? "Verify Audio (\(activeRecs.count) Files)"
               : "Verify Audio") {
            for r in verifiableRecs {
                fileOpsCenter.startVerifyAudio(record: r, model: model)
            }
            openWindow(id: "combine")
        }
        .disabled(verifiableRecs.isEmpty)
        .help("Check the sound track — levels, format, and whether the audio really belongs to the picture. Runs in the operations window; the catalog stays usable.")
        .accessibilityIdentifier("catalog.row.verifyAudio")

        if activeRecs.count == 1,
           let cached = fileOpsCenter.verifyDiagnosis(forRecordID: rec.id) {
            Button("Verification Results…") {
                verifyAudioRequest = VerifyAudioRequest(
                    record: rec,
                    diagnosis: cached,
                    onFindMatchingAudio: {
                        repairAudio(for: rec)
                        openWindow(id: "combine")
                    })
            }
            .help("Show what Verify Audio found for this file — instantly, without checking it again — plus any repair offer.")
            .accessibilityIdentifier("catalog.row.verifyResults")
        }

        let damagedRecs = verifiableRecs.filter {
            $0.audioVerifyStatus == "damaged"
        }
        if !damagedRecs.isEmpty {
            Button(damagedRecs.count > 1
                   ? "Repair Damaged Audio (\(damagedRecs.count) Files)"
                   : "Repair Damaged Audio") {
                for r in damagedRecs {
                    fileOpsCenter.startVerifyAudio(
                        record: r, model: model, autoRepair: true)
                }
                openWindow(id: "combine")
            }
            .help("Re-check each damaged file and, where the damage is fixable (an old sound format), rebuild a repaired copy next to the original. Originals are never changed.")
            .accessibilityIdentifier("catalog.row.repairDamagedAudio")
        }

        // Link Repaired Copy… (GH #132 P4) — Rick fixed the file
        // himself in another tool; adopt that file as this damaged
        // record's repaired copy (same two-way provenance the in-app
        // rebuild writes; enters the awaiting-confirmation state).
        if pureActive, activeRecs.count == 1,
           rec.audioVerifyStatus == "damaged" {
            Button("Link Repaired Copy…") {
                linkRepairedCopy(for: rec)
            }
            .help("Already repaired this file with another tool? Pick that repaired file and it joins the catalog as this one's repaired copy — then confirm it when it sounds right.")
            .accessibilityIdentifier("catalog.row.linkRepairedCopy")
        }

        let awaitingRecs = pureActive
            ? activeRecs.filter {
                $0.isAwaitingConfirmation
                    && $0.derivedFrom.flatMap { model.record(forID: $0) } != nil
            }
            : []
        if !awaitingRecs.isEmpty {
            Button(awaitingRecs.count > 1
                   ? "Sounds Good — Confirm \(awaitingRecs.count) Repairs"
                   : "Sounds Good — Confirm Repair") {
                _ = model.confirmRepairs(
                    repairIDs: Set(awaitingRecs.map(\.id)))
            }
            .help("You've listened and it sounds right: keep this repaired copy as the one to use. The original is hidden from the everyday view — never deleted — and your tags, notes, people, and ratings carry over.")
            .accessibilityIdentifier("catalog.row.confirmRepair")
        }
    }

    /// "Link Repaired Copy…" handler (GH #132 P4): pick the externally-
    /// repaired file, adopt it onto the damaged record, and select the
    /// new row. Failures (unreadable file, vanished original) alert with
    /// the model's family-language message and change nothing.
    private func linkRepairedCopy(for rec: VideoRecord) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the repaired copy of \(rec.filename)"
        panel.prompt = "Link Repaired Copy"
        panel.directoryURL = URL(fileURLWithPath: rec.directory, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                let newRec = try await model.adoptExternalRepair(
                    originalID: rec.id, fileURL: url)
                selectedIDs = [newRec.id]
                onSelect(newRec.id)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't Link the Repaired Copy"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
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
    /// Single entry point for the Analyze / Transcribe / Captions
    /// menu items. Inspects the record's codecs and routes:
    ///   - Modern codec (AVFoundation-decodable) → AnalyzeJob directly.
    ///   - Legacy codec (svq3/qdm2/cinepak/etc.) → one-shot confirm
    ///     alert offering Reformat-then-Analyze. The reformat's
    ///     existing auto-queue analyze hook takes over from there.
    ///
    /// Rick 2026-06-14 — collapses the prior "Reformat and Analyze"
    /// + "Analyze This File" pair into a single verb with intent
    /// captured in the stage set.
    /// Multi-selection Analyze (2026-07-14). Mirrors the Tag menu's
    /// apply-to-every-selected-row pattern:
    ///   - reachable modern-codec records each get an AnalyzeJob (the
    ///     jobs serialize themselves — each waits for the orchestrator
    ///     to free up, so N selected files means N banked dossiers,
    ///     not 1 success + N-1 "busy" failures)
    ///   - legacy-codec records get ONE combined confirm alert instead
    ///     of a modal alert per file
    ///   - offline records are silently skipped (same reachability
    ///     rule the single-file path enforces via menu disable)
    private func requestAnalyze(forAll recs: [VideoRecord], stages: Set<AnalyzeStage>) {
        let reachable = recs.filter { VolumeReachability.isReachable(path: $0.fullPath) }
        guard !reachable.isEmpty else { return }
        if reachable.count == 1 {
            // Single row — keep the richer per-file flow (its alert
            // names the file and the derived output).
            requestAnalyze(for: reachable[0], stages: stages)
            return
        }
        let needsReformat = reachable.filter {
            hasUnplayableLegacyCodec(videoCodec: $0.videoCodec, audioCodec: $0.audioCodec)
                || $0.needsReformat
        }
        let modern = reachable.filter { rec in !needsReformat.contains(where: { $0.id == rec.id }) }

        for rec in modern {
            fileOpsCenter.startAnalyzeOne(
                record: rec, model: model,
                orchestrator: captionOrchestrator,
                stages: stages
            )
        }
        if !modern.isEmpty { openWindow(id: "combine") }

        guard !needsReformat.isEmpty else { return }
        // One combined confirm for the legacy-codec subset.
        let alert = NSAlert()
        alert.messageText = "Reformat Required for \(needsReformat.count) File\(needsReformat.count == 1 ? "" : "s")"
        alert.informativeText = """
            \(needsReformat.count) of the selected files use old codecs the analyzer can't decode directly \
            (macOS dropped them in 2019).

            Convert them to HEVC first? New files will be created next to the originals, then analyzed.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Reformat and Analyze")
        alert.addButton(withTitle: needsReformat.count == reachable.count ? "Cancel" : "Skip These")
        if alert.runModal() == .alertFirstButtonReturn {
            for rec in needsReformat {
                fileOpsCenter.startReformat(
                    record: rec, model: model,
                    orchestrator: captionOrchestrator
                )
            }
            openWindow(id: "combine")
        }
    }

    private func requestAnalyze(for rec: VideoRecord, stages: Set<AnalyzeStage>) {
        if !hasUnplayableLegacyCodec(videoCodec: rec.videoCodec,
                                     audioCodec: rec.audioCodec)
            && !rec.needsReformat {
            // Modern codec — analyze directly.
            fileOpsCenter.startAnalyzeOne(
                record: rec, model: model,
                orchestrator: captionOrchestrator,
                stages: stages
            )
            openWindow(id: "combine")
            return
        }
        // Legacy codec — confirm reformat first.
        let alert = NSAlert()
        alert.messageText = "Reformat Required"
        let codecBits = [rec.videoCodec, rec.audioCodec]
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
        let derived = derivedFileURL(
            source: URL(fileURLWithPath: rec.fullPath),
            codec: "hevc",
            ext: "mp4"
        ).lastPathComponent
        alert.informativeText = """
            \(rec.filename) uses the \(codecBits) codec, which the analyzer can't decode directly. \
            macOS deprecated this codec in 2019.

            Convert to HEVC first? A new file \"\(derived)\" will be created next to the original, \
            then analyzed.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Reformat and Analyze")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            fileOpsCenter.startReformat(
                record: rec, model: model,
                orchestrator: captionOrchestrator
            )
            openWindow(id: "combine")
        }
    }

    /// Present the Transcode configuration sheet with a useful initial
    /// format. The sheet owns destination selection and starts the job.
    private func configureTranscode(for rec: VideoRecord, preset: TranscodePreset) {
        transcodeRequest = TranscodeRequest(record: rec, initialPreset: preset)
    }

    /// Surface a result alert ONLY when something interesting happened —
    /// skipped-offline, already-missing, or per-file failures. Pure
    /// success is silent, matching Finder's behavior on trash/delete.
    /// Called from the row context menu's Delete File submenu after the
    /// detached FileManager pass completes.
    private func reportDeleteResult(
        _ result: VideoScanModel.JunkDeletionResult,
        mode: VideoScanModel.JunkDeletionMode
    ) {
        let interesting = result.alreadyMissing > 0
            || result.skippedOffline > 0
            || !result.failed.isEmpty
        guard interesting else { return }

        var lines: [String] = []
        if result.succeeded > 0 {
            lines.append("\(result.succeeded) \(mode == .toTrash ? "moved to Trash" : "deleted permanently")")
        }
        if result.alreadyMissing > 0 {
            lines.append("\(result.alreadyMissing) already missing \u{2014} catalog updated")
        }
        if result.skippedOffline > 0 {
            lines.append("\(result.skippedOffline) skipped \u{2014} volume offline")
        }
        if !result.failed.isEmpty {
            lines.append("\(result.failed.count) failed (permissions or locked)")
        }
        let alert = NSAlert()
        alert.messageText = "Delete completed with notes"
        alert.informativeText = lines.joined(separator: "\n")
        alert.alertStyle = result.failed.isEmpty ? .informational : .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// "Find Matching Audio…" handler for video-only records (menu
    /// renamed from "Repair Audio" with GH #116; function name kept for
    /// history). Uses the same CorrelationScorer that Find A/V Pair
    /// does to identify the best audio-only match across all volumes,
    /// then opens the existing Combine sheet pre-filled with the pair.
    /// If no candidate clears the score≥3 floor, shows an alert telling
    /// the user how to proceed manually. Rick 2026-06-14.
    private func repairAudio(for rec: VideoRecord) {
        let durationTolerance: Double = 1.0
        let timestampTolerance: TimeInterval = 5.0
        guard let pair = CorrelationScorer.preferredPair(
            for: rec,
            in: model.records,
            durationTolerance: durationTolerance,
            timestampTolerance: timestampTolerance
        ) else {
            // GH #125 MINOR 2: distinguish "nothing structurally related"
            // from "a related file exists but its duration is unverifiable
            // or incompatible" — the latter must not blame the score.
            let durationRefused = CorrelationScorer.hasDurationRefusedStructuralCandidate(
                for: rec, in: model.records,
                durationTolerance: durationTolerance,
                timestampTolerance: timestampTolerance)
            let alert = NSAlert()
            alert.messageText = "No Audio Match Found"
            alert.informativeText = durationRefused
                ? """
                A related audio-only file was found for:

                \(rec.filename)

                …but its duration could not be verified or is incompatible \
                with the video, so it was not offered automatically (this \
                can indicate a truncated or mislabeled file). Verify the \
                source media or add a compatible full-length audio file.
                """
                : """
                No matching audio-only file scored highly enough against:

                \(rec.filename)

                Try "Find A/V Pair…" to explore correlation candidates, \
                or add the audio source to the catalog first.
                """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        // Pair found — open the existing Combine sheet pre-filled
        // with the high-confidence match.
        onCombinePair?(pair.video, pair.audio)
    }

    /// "Find Matching Video…" handler for audio-only records — mirror
    /// of repairAudio (menu renamed from "Repair Video" with GH #116).
    /// The CorrelationScorer is direction-agnostic; the
    /// returned pair is always (video, audio) regardless of which side
    /// was the input record, so the Combine-sheet call site stays
    /// identical. Rick 2026-06-15.
    private func repairVideo(for rec: VideoRecord) {
        let durationTolerance: Double = 1.0
        let timestampTolerance: TimeInterval = 5.0
        guard let pair = CorrelationScorer.preferredPair(
            for: rec,
            in: model.records,
            durationTolerance: durationTolerance,
            timestampTolerance: timestampTolerance
        ) else {
            // GH #125 MINOR 2: mirror of repairAudio — a related video may
            // exist but be duration-unverifiable/incompatible.
            let durationRefused = CorrelationScorer.hasDurationRefusedStructuralCandidate(
                for: rec, in: model.records,
                durationTolerance: durationTolerance,
                timestampTolerance: timestampTolerance)
            let alert = NSAlert()
            alert.messageText = "No Video Match Found"
            alert.informativeText = durationRefused
                ? """
                A related video-only file was found for:

                \(rec.filename)

                …but its duration could not be verified or is incompatible \
                with the audio, so it was not offered automatically (this \
                can indicate a truncated or mislabeled file). Verify the \
                source media or add a compatible full-length video file.
                """
                : """
                No matching video-only file scored highly enough against:

                \(rec.filename)

                Try "Find A/V Pair…" to explore correlation candidates, \
                or add the video source to the catalog first.
                """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        onCombinePair?(pair.video, pair.audio)
    }

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
            // Workflow tags (2026-07-23) — subtle teal chips, capped at
            // two + "+N" overflow so the column never balloons. Same
            // rounded-rect badge language as the inspector's stream-type
            // badge. Full list rides in the tooltip below.
            ForEach(Array(rec.tags.prefix(2)), id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.teal)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.teal.opacity(0.12))
                    )
                    .lineLimit(1)
            }
            if rec.tags.count > 2 {
                Text("+\(rec.tags.count - 2)")
                    .font(.system(size: 9))
                    .foregroundColor(.teal)
            }
            // Note icon covers YOUR notes and the machine probe notes —
            // both mean "there's something written on this row".
            if !rec.userNotes.isEmpty || !rec.notes.isEmpty {
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
        .help(tagColumnHelp(for: rec))
    }

    /// Tooltip for the Tag column: disposition, then workflow tags,
    /// then your note (machine probe notes stay in the inspector).
    private func tagColumnHelp(for rec: VideoRecord) -> String {
        var lines = [rec.mediaDisposition.rawValue]
        if !rec.tags.isEmpty {
            lines.append("Tags: \(rec.tags.joined(separator: ", "))")
        }
        if !rec.userNotes.isEmpty {
            lines.append(rec.userNotes)
        } else if !rec.notes.isEmpty {
            lines.append(rec.notes)
        }
        return lines.joined(separator: "\n")
    }

    /// Render the family-tag column for one record. Confirmed names blue,
    /// suspected names italic + secondary with a leading "?", joined by
    /// " · ". Em-dash when both arrays are empty (junk-triage signal).
    /// Tooltip lists names with tier annotations.
    @ViewBuilder
    private func peopleColumnCell(for rec: VideoRecord) -> some View {
        let strong = rec.taggedPeople   // confirmed ∪ detected (2026-08-01)
        if strong.isEmpty && rec.suspectedPeople.isEmpty {
            Text("—")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .help("No family tagged or detected — junk-triage candidate")
        } else {
            let strongText = Text(strong.joined(separator: ", "))
                .foregroundColor(.blue)
            let suspectedJoined = rec.suspectedPeople
                .map { "?\($0)" }
                .joined(separator: ", ")
            let suspectedText = Text(suspectedJoined)
                .italic()
                .foregroundColor(.secondary)
            let separator = (!strong.isEmpty
                             && !rec.suspectedPeople.isEmpty) ? " · " : ""
            (strongText + Text(separator) + suspectedText)
                .font(.system(size: 12))
                .lineLimit(1)
                .help(peopleColumnHelp(for: rec))
        }
    }

    private func peopleColumnHelp(for rec: VideoRecord) -> String {
        var lines: [String] = []
        let confirmed = rec.confirmedByUserPeople.map(\.name)
        if !confirmed.isEmpty {
            lines.append("Confirmed by you: \(confirmed.joined(separator: ", "))")
        }
        if !rec.detectedPeople.isEmpty {
            lines.append("Detected: \(rec.detectedPeople.joined(separator: ", "))")
        }
        if !rec.suspectedPeople.isEmpty {
            lines.append("Suspected (the leading ?): \(rec.suspectedPeople.joined(separator: ", "))")
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
