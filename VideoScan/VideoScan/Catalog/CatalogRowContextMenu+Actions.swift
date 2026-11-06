// CatalogRowContextMenu+Actions.swift
// Handlers the Catalog row menu calls: Analyze, Transcode, Find Matching
// Audio / Video — moved verbatim out of CatalogContent+Table.swift (R1
// refactor, GH #281).
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state allowed, methods share the same `self`; `private` here
// means file-private to THIS file.)

import SwiftUI

extension CatalogContent {

    /// Analyze / Transcribe Audio / Generate Scene Captions on the selected
    /// rows: one AnalyzeJob per reachable row through the one Analyze verb
    /// (MediaFileOperationsCenter.startAnalyze), then the operations window.
    ///
    /// No codec gate and no Reformat-first alert (DECISIONS 2026-11-06,
    /// Rick: "a pipeline that sucks the file in, converts as needed, does
    /// the analysis, then remembers this analysis is for this file"). The
    /// analyzers read legacy codecs through ffmpeg in place; a file nothing
    /// can decode fails its own row with the decoder's reason. Reformat is
    /// its own verb (Transcode ▸ Reformat Old Codec…).
    func requestAnalyze(forAll recs: [VideoRecord], stages: Set<AnalyzeStage>) {
        let started = fileOpsCenter.startedByUser {
            $0.startAnalyze(records: recs, model: model,
                            orchestrator: captionOrchestrator, stages: stages)
        }
        if !started.isEmpty { MediaFileOperationsWindowOpener.openBehindMain(openWindow) }
    }

    func requestAnalyze(for rec: VideoRecord, stages: Set<AnalyzeStage>) {
        requestAnalyze(forAll: [rec], stages: stages)
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
            // Elementary / demuxed streams Correlate cannot pair (an .m2v
            // records no length; GH #125 refuses unknown lengths): list the
            // sound files beside it with their reasons; the person chooses
            // (Rick 2026-10-10). Falls through when there are none.
            if SoundPairAlert.offer(for: rec, model: model, combine: { v, a in onCombinePair?(v, a) }) { return }
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
