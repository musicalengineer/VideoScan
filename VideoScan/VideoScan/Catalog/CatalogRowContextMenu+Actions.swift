// CatalogRowContextMenu+Actions.swift
// Handlers the Catalog row menu calls: Analyze (with the legacy-codec
// reformat offer), Transcode, Find Matching Audio / Video — moved
// verbatim out of CatalogContent+Table.swift (R1 refactor, GH #281).
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state allowed, methods share the same `self`; `private` here
// means file-private to THIS file.)

import SwiftUI

extension CatalogContent {

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
    func requestAnalyze(forAll recs: [VideoRecord], stages: Set<AnalyzeStage>) {
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

        _ = fileOpsCenter.startedByUser { center in
            for rec in modern {
                center.startAnalyzeOne(record: rec, model: model,
                                       orchestrator: captionOrchestrator,
                                       stages: stages)
            }
        }
        guard !needsReformat.isEmpty else {
            if !modern.isEmpty { MediaFileOperationsWindowOpener.openBehindMain(openWindow) }
            return
        }
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
        let reformat = alert.runModal() == .alertFirstButtonReturn
        if reformat {
            _ = fileOpsCenter.startedByUser { center in
                for rec in needsReformat {
                    center.startReformat(record: rec, model: model,
                                         orchestrator: captionOrchestrator)
                }
            }
        }
        // Opened only AFTER the modal returns, whichever button was chosen:
        // an open before runModal had every retry skipped by the modal
        // guard and nothing rescheduled afterwards (codex #969).
        if reformat || !modern.isEmpty {
            MediaFileOperationsWindowOpener.openBehindMain(openWindow)
        }
    }

    func requestAnalyze(for rec: VideoRecord, stages: Set<AnalyzeStage>) {
        if !hasUnplayableLegacyCodec(videoCodec: rec.videoCodec,
                                     audioCodec: rec.audioCodec)
            && !rec.needsReformat {
            // Modern codec — analyze directly.
            _ = fileOpsCenter.startedByUser {
                $0.startAnalyzeOne(record: rec, model: model,
                                   orchestrator: captionOrchestrator,
                                   stages: stages)
            }
            MediaFileOperationsWindowOpener.openBehindMain(openWindow)
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
            _ = fileOpsCenter.startedByUser {
                $0.startReformat(record: rec, model: model,
                                 orchestrator: captionOrchestrator)
            }
            MediaFileOperationsWindowOpener.openBehindMain(openWindow)
        }
    }

    /// Present the Transcode configuration sheet with a useful initial
    /// format. The sheet owns destination selection and starts the job.
    func configureTranscode(for rec: VideoRecord, preset: TranscodePreset) {
        transcodeRequest = TranscodeRequest(record: rec, initialPreset: preset)
    }

    /// "Find Matching Audio…" handler for video-only records (menu
    /// renamed from "Repair Audio" with GH #116; function name kept for
    /// history). Uses the same CorrelationScorer that Find A/V Pair
    /// does to identify the best audio-only match across all volumes,
    /// then opens the existing Combine sheet pre-filled with the pair.
    /// If no candidate clears the score≥3 floor, shows an alert telling
    /// the user how to proceed manually. Rick 2026-06-14.
    func repairAudio(for rec: VideoRecord) {
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
    func repairVideo(for rec: VideoRecord) {
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
}
