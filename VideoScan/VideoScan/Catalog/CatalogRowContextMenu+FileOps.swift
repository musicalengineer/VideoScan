// CatalogRowContextMenu+FileOps.swift
// File-operation items of the Catalog row menu, cut out of the single
// rowContextMenu builder section by section (R1 refactor, GH #281):
// the `.process` and `.archive` groups, plus the Find Matching verbs the
// `.find` group opens with (regrouped 2026-10-08, CatalogRowMenuGroup).
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state allowed, methods share the same `self`; `private` here
// means file-private to THIS file.)

import SwiftUI

extension CatalogContent {

    /// The `.process` group (Rick 2026-10-08): the pair verbs (when they
    /// apply), Analyze ▸, Transcode ▸, Clean Up Video ▸ — the verbs that
    /// make or study media, not fixes (fixes are Repair…).
    @ViewBuilder
    func processItems(rec: VideoRecord, selection: CatalogRowMenuSelection,
                      transcodeRunning: Bool) -> some View {
        pairItems(rec: rec, selectedRecs: selection.selected, pureActive: selection.pureActive)
        analyzeMenu(rec: rec, activeRecs: selection.active)
        transcodeAndCleanupMenus(rec: rec, transcodeRunning: transcodeRunning)
    }

    /// Combine This Pair… and Compare These Two Files….
    @ViewBuilder
    private func pairItems(rec: VideoRecord, selectedRecs: [VideoRecord], pureActive: Bool) -> some View {
        // File operations — every verb that runs as a job
        // in the Media File Operations window lives in this
        // ONE section (Rick 2026-06-10).
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
                    // GH #293: a fingerprint the visual tier computes is
                    // kept on the record and saved with the catalog.
                    $0.startCompare(recordA: fileA, recordB: fileB,
                                    onFingerprintKept: { [weak model] in model?.saveCatalogDebounced() })
                }
                // The compare result lives in the job window — in front (codex #964).
                MediaFileOperationsWindowOpener.openInFront(openWindow)
            }
            .disabled(!VolumeReachability.isReachable(path: fileA.fullPath)
                      || !VolumeReachability.isReachable(path: fileB.fullPath))
            .help("Check whether these two files are exact copies, the same movie in a different wrapper, or genuinely different.")
            .accessibilityIdentifier("catalog.row.compareTwoFiles")
        }
    }

    /// Find Matching Audio… / Find Missing Audio… / Find Matching Video…
    /// — the head of the `.find` group since 2026-10-08.
    /// ("Extract Facial Frames…" and "Extract Frames…" were retired
    /// 2026-10-07 — Rick: deprecated and unverified; VLC exports frames.
    /// Their code is in the repo's .trash/ and in git history.)
    @ViewBuilder
    func matchItems(rec: VideoRecord) -> some View {
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
    }

    /// Analyze ▸ — Analyze (whole selection), Transcribe Audio, Generate
    /// Scene Captions (grouped 2026-10-07).
    @ViewBuilder
    private func analyzeMenu(rec: VideoRecord, activeRecs: [VideoRecord]) -> some View {
        Menu("Analyze") {
            // Analyze applies to the FULL selection (fix
            // 2026-07-14 — it used only ids.first, so
            // multi-selecting N files analyzed just one).
            // Jobs wait their turn behind a running batch,
            // so intent is never blocked, just queued.
            Button(CatalogRowMenuText.analyze(count: activeRecs.count)) {
                requestAnalyze(forAll: activeRecs, stages: AnalyzeStage.all)
            }
            .disabled(!activeRecs.contains {
                VolumeReachability.isReachable(path: $0.fullPath)
            })
            .accessibilityIdentifier("catalog.row.analyze")

            transcriptionItems(rec: rec)
        }
    }

    /// Transcode ▸ and Clean Up Video ▸ submenus.
    @ViewBuilder
    private func transcodeAndCleanupMenus(rec: VideoRecord, transcodeRunning: Bool) -> some View {
        // Transcode — opens a configuration sheet for format
        // and destination instead of assuming the source disk.
        // Disabled when the file is offline OR another
        // transcode is already running for this same record
        // (the per-file disable prevents the user from
        // queueing two competing encodes against one input).
        let transcodeBlocked = CatalogRowMenuRules.transcodeBlocked(
            reachable: VolumeReachability.isReachable(path: rec.fullPath),
            running: transcodeRunning)
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
        let cleanupBlocked = CatalogRowMenuRules.cleanupBlocked(
            reachable: VolumeReachability.isReachable(path: rec.fullPath),
            running: cleanupRunning,
            streamType: rec.streamType)
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
    }

    /// The `.archive` group: Promote to Archive, the Archive Angel items.
    /// (Remove from Catalog (keep files) moved to the bottom group,
    /// 2026-10-08.)
    @ViewBuilder
    func archiveItems(activeRecs: [VideoRecord],
                      pureActive: Bool, transcodeRunning: Bool) -> some View {
        // Promote to Archive (Master Archive, 2026-08-15) —
        // single + multi select; the model routes to the
        // no-master alert or the confirmation sheet.
        // "Which copy is the original?" is Archive Angel ▸
        // Show Copies… since S4 (the Promote Helper is retired).
        promoteToArchiveMenuItem(activeRecs: activeRecs, pureActive: pureActive)
        ArchiveAngelMenuItems(model: model, center: fileOpsCenter, activeRecs: activeRecs, pureActive: pureActive,
                              onTranscode: transcodeRunning ? nil : { rec, preset in configureTranscode(for: rec, preset: preset) })
    }

    /// Transcribe Audio / Generate Scene Captions (inside Analyze ▸).
    @ViewBuilder
    private func transcriptionItems(rec: VideoRecord) -> some View {
        // Rick 2026-06-14: grey out (don't hide) when
        // the file lacks the relevant stream. More
        // discoverable than absent — the user learns
        // "Transcribe Audio exists but this file has
        // no audio" instead of wondering where it went.
        let hasAudio = CatalogRowMenuRules.hasAudio(rec.streamType)
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
    }
}
