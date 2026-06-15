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

    // MARK: - Results Table

    // Internal (not private): the view body in CatalogHelpers.swift embeds
    // this table in the left pane.
    var catalogTable: some View {
        Table(tableData, selection: $selectedIDs, sortOrder: $sortOrder) {
            TableColumn("Filename", value: \.filename) { rec in
                let offline = !VolumeReachability.isReachable(path: rec.fullPath)
                let purged = rec.isPurged
                let workspaceActive = rec.workspaceActive
                HStack(spacing: 4) {
                    if purged {
                        // Trash-slash icon makes the "removed" state obvious
                        // at a glance — even if the user's row colors are
                        // partially overridden by a high-contrast theme.
                        Image(systemName: "trash.slash")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
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
                        .italic(offline || purged)
                        .foregroundColor(purged ? .orange
                            : (workspaceActive ? .mint
                                : (offline ? .secondary
                                    : (showPairsOnly && rec.pairedWith != nil
                                       ? (rec.streamType == .videoOnly ? .blue : .green)
                                       : rec.filenameColor))))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .help(purged ? "\(rec.directory) (removed from catalog)"
                      : (rec.unanalyzableReason.map { "\(rec.directory)\n\n⚠️ \($0)" }
                         ?? (offline ? "\(rec.directory) (offline)" : rec.directory)))
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

                        // Repair Audio — Rick 2026-06-14. Video-only
                        // files only. Auto-finds the highest-confidence
                        // audio-only match (same scorer Find A/V Pair
                        // uses) and pre-fills the Combine sheet.
                        if rec.streamType == .videoOnly {
                            Button("Repair Audio…") {
                                repairAudio(for: rec)
                                openWindow(id: "combine")
                            }
                            .disabled(!VolumeReachability.isReachable(path: rec.fullPath))
                            .accessibilityIdentifier("catalog.row.repairAudio")
                        }

                        Button("Analyze") {
                            requestAnalyze(for: rec, stages: AnalyzeStage.all)
                        }
                        .disabled(!VolumeReachability.isReachable(path: rec.fullPath)
                                  || captionOrchestrator.currentStatus.isActive)
                        .accessibilityIdentifier("catalog.row.analyze")

                        // Transcode — Pass C (Rick 2026-06-14). Two-preset
                        // faithful conversion: ProRes 422 HQ for FCP edit
                        // sessions, HEVC 10-bit for long-term archive.
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
                            Button("For Editing (ProRes 422 HQ)") {
                                requestTranscode(for: rec, preset: .editing)
                            }
                            .disabled(transcodeBlocked)
                            .accessibilityIdentifier("catalog.row.transcodeEditing")

                            Button("For Archival (HEVC 10-bit)") {
                                requestTranscode(for: rec, preset: .archival)
                            }
                            .disabled(transcodeBlocked)
                            .accessibilityIdentifier("catalog.row.transcodeArchival")
                        }

                        // Rick 2026-06-14: grey out (don't hide) when
                        // the file lacks the relevant stream. More
                        // discoverable than absent — the user learns
                        // "Transcribe Audio exists but this file has
                        // no audio" instead of wondering where it went.
                        let hasAudio = (rec.streamType == .videoAndAudio || rec.streamType == .audioOnly)
                        let hasVideo = (rec.streamType == .videoAndAudio || rec.streamType == .videoOnly)
                        Button("Transcribe Audio") {
                            requestAnalyze(for: rec, stages: [.transcript])
                        }
                        .disabled(!hasAudio
                                  || !VolumeReachability.isReachable(path: rec.fullPath)
                                  || captionOrchestrator.currentStatus.isActive)
                        .help(hasAudio
                              ? "Run Whisper to produce a transcript of the audio track."
                              : "This file has no audio stream to transcribe.")
                        .accessibilityIdentifier("catalog.row.transcribeAudio")

                        Button("Generate Scene Captions") {
                            requestAnalyze(for: rec, stages: [.captions])
                        }
                        .disabled(!hasVideo
                                  || !VolumeReachability.isReachable(path: rec.fullPath)
                                  || captionOrchestrator.currentStatus.isActive)
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

    /// "Transcode" handler — kicks off a TranscodeJob with the chosen
    /// preset and opens the Media File Operations window so the user
    /// can watch progress. Pass C (Rick 2026-06-14): no preset sheet —
    /// the menu's two entries ARE the UI. Lineage (`derivedFrom`) and
    /// the workspace tint (`workspaceActive = true`) are wired up by
    /// TranscodeJob.catalogTranscodeOutput.
    private func requestTranscode(for rec: VideoRecord, preset: TranscodePreset) {
        fileOpsCenter.startTranscode(record: rec, preset: preset, model: model)
        openWindow(id: "combine")
    }

    /// "Repair Audio…" handler for video-only records. Uses the same
    /// CorrelationScorer that Find A/V Pair does to identify the
    /// best audio-only match across all volumes, then opens the
    /// existing Combine sheet pre-filled with the pair. If no
    /// candidate clears the score≥3 floor, shows an alert telling the
    /// user how to proceed manually. Rick 2026-06-14.
    private func repairAudio(for rec: VideoRecord) {
        let durationTolerance: Double = 1.0
        let timestampTolerance: TimeInterval = 5.0
        guard let cand = CorrelationScorer.findBestPair(
            for: rec,
            in: model.records,
            durationTolerance: durationTolerance,
            timestampTolerance: timestampTolerance
        ) else {
            let alert = NSAlert()
            alert.messageText = "No Audio Match Found"
            alert.informativeText = """
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
        onCombinePair?(cand.video, cand.audio)
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

