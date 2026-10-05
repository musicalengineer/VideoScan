// CatalogRowContextMenu.swift
// The Catalog files table's right-click menus — moved verbatim out of
// CatalogContent+Table.swift (R1 refactor, GH #281). The table itself,
// its columns and the ⌘⌫ / ⌘O handlers stay in that file.
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
    func rowContextMenu(ids: Set<UUID>) -> some View {
        let selectedRecs = ids.compactMap { id in records.first { $0.id == id } }
        // Mixed-selection split. Each predicate is computed once so the
        // Restore / Remove menu items use the same record set their
        // actions operate on (label counts == operated-on counts).
        // Swift's `.filter` ≈ C++ std::copy_if into a new vector.
        let activeRecs = selectedRecs.filter { !$0.isPurged && !$0.isSetAside && !$0.isSuperseded }
        let purgedRecs = selectedRecs.filter { $0.isPurged }
        let setAsideRecs = selectedRecs.filter { $0.isSetAside && !$0.isPurged }
        let supersededRecs = selectedRecs.filter { $0.isSuperseded && !$0.isPurged && !$0.isSetAside }
        // Delete File is never OFFERED for Master Archive files — the tree
        // or anywhere else on the archive's volume (Rick 2026-09-22). One
        // snapshot per menu open (right-click time, O(selection)); the
        // engine re-checks at the moment of the move regardless.
        let deletableRecs = model.recordsBulkVerbsMayRemove(activeRecs)
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
                            // Missing while mounted → "looks moved" banner
                            // (Update Catalog); Finder can't select it anyway.
                            if !model.noteMissingFileForUserAction(rec) {
                                NSWorkspace.shared.selectFile(rec.fullPath, inFileViewerRootedAtPath: "")
                            }
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
                        model.noteMissingFileForUserAction(rec)
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
                        model.noteMissingFileForUserAction(rec)
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
                            _ = fileOpsCenter.startedByUser {
                                $0.startCompare(recordA: fileA, recordB: fileB)
                            }
                            // The compare result lives in the job window — in front (codex #964).
                            MediaFileOperationsWindowOpener.openInFront(openWindow)
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
                            repairAudio(for: rec)   // Combine sheet or alert is the result; no job window (codex #964)
                        }
                        .disabled(!VolumeReachability.isReachable(path: rec.fullPath))
                        .accessibilityIdentifier("catalog.row.repairAudio")

                        // Find Missing Audio — GH #111 (Rick 2026-09-11).
                        // The aggressive hunt Tidy promised: set-aside /
                        // removed records, nearby folders, then every
                        // reachable scan root. Pair records the pair via
                        // the normal Correlate; nothing muxed or moved.
                        // Unpaired video-only rows only.
                        if rec.pairedWith == nil {
                            Button("Find Missing Audio…") {
                                missingAudioTarget = rec
                            }
                            .help("Search set-aside and removed records, this file's folder and its neighbours, then every reachable scan root for the audio half — even if it is not in the catalog. Pairing records the pair like Correlate; Combine stays a separate step.")
                            .accessibilityIdentifier("catalog.row.findMissingAudio")
                        }
                    }

                    // Find Matching Video — symmetric verb for
                    // audio-only files (Rick 2026-06-15; renamed from
                    // "Repair Video" alongside the audio verb so the
                    // pair reads consistently). Same CorrelationScorer
                    // works both directions: given an audio-only
                    // record, it returns the best video-only match.
                    if rec.streamType == .audioOnly {
                        Button("Find Matching Video…") {
                            repairVideo(for: rec)   // Combine sheet or alert is the result; no job window (codex #964)
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

                    // (The "Trim Master…" item was retired 2026-09-23 — Rick:
                    // "Let's remove Trim Master". TrimJob and startTrim stay
                    // (tested, and the .trim job kind still names old rows);
                    // only the menu entry and its now-unreachable sheet went.)

                    // Promote to Archive (Master Archive, 2026-08-15) —
                    // single + multi select; the model routes to the
                    // no-master alert or the confirmation sheet.
                    // "Which copy is the original?" is Archive Angel ▸
                    // Show Copies… since S4 (the Promote Helper is retired).
                    promoteToArchiveMenuItem(activeRecs: activeRecs, pureActive: pureActive)
                    ArchiveAngelMenuItems(model: model, center: fileOpsCenter, activeRecs: activeRecs, pureActive: pureActive,
                                          onTranscode: transcodeRunning ? nil : { rec, preset in configureTranscode(for: rec, preset: preset) })
                    removeFromCatalogMenuItem(activeRecs: activeRecs, pureActive: pureActive)

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
                        // Hand-pick for a person's People-tab page
                        // (Rick 2026-10-04, GH #272) — separate from
                        // tagging: a tag says "in it", this says "show it".
                        ShowInPeopleTabMenu(records: selectedRecs)
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
                                if selectedRecs.contains(where: {
                                    !$0.detectedPeople.isEmpty || !$0.suspectedPeople.isEmpty
                                }) {
                                    // Machine tiers only — your confirmed
                                    // tags and rejections survive.
                                    Button("Clear Machine Tags (*/?)") {
                                        model.clearMachinePeopleTags(from: selectedRecs)
                                    }
                                }
                                if selectedRecs.contains(where: { !$0.rejectedPeople.isEmpty }) {
                                    // Rejections block Find & Tag by design
                                    // ("not X" must stick) — this is the
                                    // explicit undo when one was a mistake.
                                    Button("Clear Rejections (let recipes re-judge)") {
                                        model.clearRejections(from: selectedRecs)
                                    }
                                }
                                Button("Clear People Tags") {
                                    model.removeAllPeople(from: selectedRecs)
                                }
                            }
                        }

                        // Family Music (Rick 2026-09-23): the ONLY way a file
                        // gets on the Archive tab's Music shelf — a human
                        // mark, never a rule, so bought music never shows.
                        // Mark opens a sheet (ellipsis); Unmark acts at once.
                        // Active rows only; multi-select: one sheet for all.
                        let markable = activeRecs.filter { $0.streamType != .noStreams && $0.streamType != .ffprobeFailed }
                        let markedRecs = activeRecs.filter { $0.familyMusic != nil }
                        Button {
                            familyMusicSheetRequest = FamilyMusicSheetRequest.make(for: markable)
                        } label: {
                            Label(FamilyMusicMenu.markTitle, systemImage: "music.note")
                        }
                        .disabled(markable.isEmpty || model.isReadOnly)
                        .help("Put this recording (or video of someone playing) on the Family Music shelf in the Archive tab. Only files you mark ever appear there.")
                        .accessibilityIdentifier("catalog.row.markFamilyMusic")
                        if !markedRecs.isEmpty {
                            Button {
                                model.unmarkFamilyMusic(markedRecs.map(\.id))
                            } label: {
                                Label(FamilyMusicMenu.unmarkTitle, systemImage: "music.note")
                            }
                            .disabled(model.isReadOnly)
                            .accessibilityIdentifier("catalog.row.unmarkFamilyMusic")
                        }

                        // Find & Tag (docs/find-and-tag-design.md): run a
                        // per-person recipe over the selection; results
                        // land in the machine tiers (Donna* / Donna?).
                        // v1: Donna is the only tuned recipe.
                        Menu("Find and Tag") {
                            Button("Donna") {
                                _ = fileOpsCenter.startedByUser {
                                    $0.startFindPerson(person: "Donna",
                                                       records: selectedRecs,
                                                       model: model)
                                }
                                MediaFileOperationsWindowOpener.openBehindMain(openWindow)   // MFO window (legacy id)
                            }
                            Divider()
                            // should not be hardwired rather lookup if recipes
                            Text("Only Donna has a tuned recipe so far")
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
                        // Find Similar Footage (2026-09-23): the group this
                        // file is in — likely original, roles, evidence —
                        // in a read-only sheet (ellipsis: a sheet opens).
                        Button {
                            footageSheetRequest = FootageSheetRequest(recordID: rec.id)
                        } label: {
                            Label("Find Similar Footage…", systemImage: "square.stack.3d.up")
                        }
                        .help("Show the files that are probably the same footage as this one — copies, re-encodes, transcodes, exports — and which is likely the original.")
                        .accessibilityIdentifier("catalog.row.findSimilarFootage")
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
                    if !deletableRecs.isEmpty {
                        Menu {
                            Button(role: .destructive) {
                                let targets = deletableRecs
                                Task { @MainActor in
                                    let result = await model.deleteConfirmedJunk(targets, mode: .toTrash)
                                    reportDeleteResult(result, mode: .toTrash)
                                }
                            } label: {
                                Label("Move to Trash", systemImage: "trash")
                            }
                            .accessibilityIdentifier("catalog.row.deleteToTrash")

                            Button(role: .destructive) {
                                let targets = deletableRecs
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
                            Label(deletableRecs.count > 1
                                  ? "Delete \(deletableRecs.count) Files"
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
}
