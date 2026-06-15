import Testing
import Foundation
@testable import VideoScan

// MARK: - Dossier propagation tests (Phase 0, Rick 2026-06-15)
//
// Same physical file gets cataloged once per volume it lives on; each
// scan ran its own Whisper / VLM / OCR pass on the same audio + frames
// but produced slightly different output (recognition non-determinism).
// Propagation picks the "best" result per partialMD5 group and applies
// it to every member, so a search hits the file via any copy.
//
// Tests cover both:
//   1. The pure "best wins" selectors (longest non-empty transcript,
//      largest count of captions, etc.) — testable without spinning up
//      a VideoScanModel.
//   2. The end-to-end propagation when applied to a group of records
//      sharing a partialMD5.

@MainActor
@Suite("DossierPropagation")
struct DossierPropagationTests {

    // MARK: - Helpers

    private func makeRecord(
        path: String,
        md5: String,
        transcript: String? = nil,
        transcriptModel: String? = nil,
        transcriptDate: Date? = nil,
        captions: [SceneCaption] = [],
        captionModel: String? = nil,
        captionDate: Date? = nil,
        ocrText: [SceneCaption] = [],
        ocrDates: [SceneCaption] = []
    ) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.partialMD5 = md5
        r.audioTranscript = transcript
        r.audioTranscriptModel = transcriptModel
        r.audioTranscriptDate = transcriptDate
        r.sceneCaptions = captions
        r.sceneCaptionModel = captionModel
        r.sceneCaptionDate = captionDate
        r.ocrText = ocrText
        r.ocrDateCandidates = ocrDates
        return r
    }

    // MARK: - 1. Pure "best wins" selectors

    /// regression: longest non-empty transcript wins. The elevator case:
    /// LaCie transcript ("elevated line of trees") was shorter than the
    /// Seagate transcript ("Is it in the elevator?..."). Longest wins =
    /// the elevator transcript propagates.
    @Test func bestAudioTranscript_longestNonEmptyWins() {
        let short = makeRecord(path: "/A", md5: "M",
                               transcript: "elevated line of trees. Bushes.")
        let long  = makeRecord(path: "/B", md5: "M",
                               transcript: "Is it in the elevator? It's in the elevator. Yes the elevator. Bushes.")
        let empty = makeRecord(path: "/C", md5: "M",
                               transcript: "")

        let best = VideoScanModel.bestAudioTranscript(in: [short, long, empty])
        #expect(best?.text == long.audioTranscript,
                "Longest non-empty transcript must win — proxy for 'most words recognized'")
    }

    /// regression: nil transcripts and empty strings are both skipped.
    /// Returns nil when nothing's worth propagating.
    @Test func bestAudioTranscript_allEmptyReturnsNil() {
        let a = makeRecord(path: "/A", md5: "M", transcript: nil)
        let b = makeRecord(path: "/B", md5: "M", transcript: "")
        #expect(VideoScanModel.bestAudioTranscript(in: [a, b]) == nil,
                "All-empty group must produce nil — no transcript worth propagating")
    }

    /// Captions: largest count wins, regardless of total text length.
    /// More scenes = more search signal.
    @Test func bestSceneCaptions_largestCountWins() {
        let oneScene = makeRecord(
            path: "/A", md5: "M",
            captions: [SceneCaption(timestamp: 0, text: "A very very very long single caption.")]
        )
        let fourScenes = makeRecord(
            path: "/B", md5: "M",
            captions: (0..<4).map { SceneCaption(timestamp: Double($0), text: "Short \($0)") }
        )
        let best = VideoScanModel.bestSceneCaptions(in: [oneScene, fourScenes])
        #expect(best?.captions.count == 4,
                "Larger caption count must win even when single-caption text is longer")
    }

    /// Captions: when counts tie, longer total text wins.
    @Test func bestSceneCaptions_textLengthTiebreaker() {
        let shortCaptions = makeRecord(
            path: "/A", md5: "M",
            captions: [
                SceneCaption(timestamp: 0, text: "Brief"),
                SceneCaption(timestamp: 1, text: "Also brief")
            ]
        )
        let richCaptions = makeRecord(
            path: "/B", md5: "M",
            captions: [
                SceneCaption(timestamp: 0, text: "A longer, more descriptive caption about a scene with people"),
                SceneCaption(timestamp: 1, text: "Another rich caption covering scene transitions and detail")
            ]
        )
        let best = VideoScanModel.bestSceneCaptions(in: [shortCaptions, richCaptions])
        #expect(best?.captions == richCaptions.sceneCaptions,
                "Same count, longer total text — richer captions must win")
    }

    // MARK: - 2. End-to-end propagation

    /// regression: the elevator-clip scenario. Three records sharing a
    /// partialMD5. One has the "good" transcript (longest), two have
    /// shorter / divergent ones. After propagation all three should
    /// hold the longest transcript verbatim, and their model + date
    /// should match the source record's.
    @Test func propagation_appliesBestTranscriptToAllSiblings() {
        let model = VideoScanModel()
        let elevatorDate = Date(timeIntervalSince1970: 1_700_000_000)

        let lacie = makeRecord(
            path: "/Volumes/LaCieWorkspace/Clip 05.dv",
            md5: "ABC123",
            transcript: "elevated line of trees. Bushes.",
            transcriptModel: "whisper-small",
            transcriptDate: Date(timeIntervalSince1970: 1_710_000_000)
        )
        let seagate = makeRecord(
            path: "/Volumes/Seagate2TB/Clip 05.dv",
            md5: "ABC123",
            transcript: "Is it in there or is it in the elevator? It's in the elevator. The elevator.",
            transcriptModel: "whisper-medium",
            transcriptDate: elevatorDate
        )
        let maxtor = makeRecord(
            path: "/Volumes/Maxtor750/Clip 05.dv",
            md5: "ABC123",
            transcript: nil
        )

        model.records = [lacie, seagate, maxtor]
        let mutated = model.propagateBestDossier(in: [lacie, seagate, maxtor])

        #expect(mutated == 2,
                "Two of three records had stale transcripts and should have been updated")
        #expect(lacie.audioTranscript == seagate.audioTranscript,
                "LaCie record must inherit Seagate's longer transcript so 'elevator' becomes findable on the online copy")
        #expect(maxtor.audioTranscript == seagate.audioTranscript,
                "Maxtor (nil before) must inherit Seagate's transcript")
        #expect(lacie.audioTranscriptModel == "whisper-medium",
                "Propagation must carry forward the source record's model attribution")
        #expect(lacie.audioTranscriptDate == elevatorDate,
                "Propagation must carry forward the source record's transcript date")
    }

    /// no-op when the group already agrees — mutated count is 0,
    /// records are untouched.
    @Test func propagation_noopWhenGroupAlreadyAgrees() {
        let model = VideoScanModel()
        let a = makeRecord(path: "/A", md5: "M",
                           transcript: "same text",
                           transcriptModel: "whisper-small")
        let b = makeRecord(path: "/B", md5: "M",
                           transcript: "same text",
                           transcriptModel: "whisper-small")
        model.records = [a, b]
        let mutated = model.propagateBestDossier(in: [a, b])
        #expect(mutated == 0,
                "Group with identical transcripts is already harmonized — no writes")
    }

    /// regression: a single-member group never propagates (there's no
    /// sibling to inherit from). Guards against accidentally mutating
    /// solo records when the MD5 only matches one row.
    @Test func propagation_singleMemberGroupNoops() {
        let model = VideoScanModel()
        let solo = makeRecord(path: "/A", md5: "SOLO",
                              transcript: "alone")
        model.records = [solo]
        let mutated = model.propagateBestDossier(in: [solo])
        #expect(mutated == 0,
                "Solo records have nothing to propagate to and must be left alone")
    }

    /// regression: records with empty partialMD5 must NEVER receive
    /// propagation — without a content hash we can't safely identify
    /// siblings. The `propagateDossierToMD5Duplicates(of:)` entry point
    /// must short-circuit.
    @Test func propagation_skipsEmptyMD5() {
        let model = VideoScanModel()
        let target = makeRecord(path: "/A", md5: "", transcript: "kept text")
        let candidateSibling = makeRecord(path: "/B", md5: "", transcript: "different text")
        model.records = [target, candidateSibling]
        model.propagateDossierToMD5Duplicates(of: target)
        #expect(target.audioTranscript == "kept text",
                "Empty-MD5 records must never be siblings — keep their own transcript")
        #expect(candidateSibling.audioTranscript == "different text",
                "Empty-MD5 sibling must also be untouched")
    }

    // MARK: - 3. Backfill — one-shot across the full catalog

    /// regression: backfill harmonizes ALL MD5 groups in one pass and
    /// returns the count of records updated. The elevator clip and an
    /// unrelated Christmas clip exist as separate groups; both should
    /// be harmonized in a single call.
    @Test func backfill_harmonizesEveryGroupOnce() {
        let model = VideoScanModel()

        // Group 1: elevator (LaCie + Seagate)
        let elevatorLacie = makeRecord(path: "/LaCie/e.dv", md5: "G1",
                                       transcript: "elevated")
        let elevatorSeagate = makeRecord(path: "/Seagate/e.dv", md5: "G1",
                                         transcript: "Is it in the elevator? Yes the elevator.")
        // Group 2: Christmas (two copies, captions diverge)
        let xmasA = makeRecord(path: "/A/x.mov", md5: "G2",
                               captions: [SceneCaption(timestamp: 0, text: "one")])
        let xmasB = makeRecord(path: "/B/x.mov", md5: "G2",
                               captions: [
                                SceneCaption(timestamp: 0, text: "scene 1"),
                                SceneCaption(timestamp: 1, text: "scene 2")
                               ])
        // Group 3: solo record, no siblings — should be left alone
        let solo = makeRecord(path: "/S/s.mov", md5: "G3",
                              transcript: "solo")
        // Empty-MD5 record — must never get touched
        let unhashed = makeRecord(path: "/U/u.mov", md5: "",
                                  transcript: "unhashed text")

        model.records = [elevatorLacie, elevatorSeagate, xmasA, xmasB, solo, unhashed]
        let updated = model.backfillDossierAcrossDuplicates()

        #expect(updated == 2,
                "Exactly 2 records (LaCie elevator + xmasA) had stale dossiers to update")
        #expect(elevatorLacie.audioTranscript == elevatorSeagate.audioTranscript)
        #expect(xmasA.sceneCaptions.count == 2,
                "xmasA must inherit xmasB's 2-scene caption set")
        #expect(solo.audioTranscript == "solo",
                "Solo record must be untouched")
        #expect(unhashed.audioTranscript == "unhashed text",
                "Empty-MD5 record must be untouched")
    }

    /// regression: re-running backfill on an already-harmonized catalog
    /// is a no-op. Important because backfill runs on every catalog
    /// load — must not generate spurious writes.
    @Test func backfill_idempotent() {
        let model = VideoScanModel()
        let a = makeRecord(path: "/A", md5: "M", transcript: "shared")
        let b = makeRecord(path: "/B", md5: "M", transcript: "shared")
        model.records = [a, b]
        let first = model.backfillDossierAcrossDuplicates()
        let second = model.backfillDossierAcrossDuplicates()
        #expect(first == 0,
                "Already-harmonized records — first pass should be a no-op")
        #expect(second == 0,
                "Second pass MUST be no-op — backfill is idempotent (runs every load)")
    }
}
