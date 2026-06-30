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
        ocrDates: [SceneCaption] = [],
        // A fresh VideoRecord has streamTypeRaw="" which maps to
        // `.ffprobeFailed` via the model's fallback — i.e. "unreadable".
        // The propagation playability guard (correctly) excludes those, so
        // legitimate-propagation cases must pin a readable stream type.
        // Default to Video+Audio so the existing "harmonize duplicates"
        // tests model READABLE duplicates, which is what they always meant.
        streamType: StreamType = .videoAndAudio,
        dossierProcessedAt: Date? = nil
    ) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.partialMD5 = md5
        r.streamTypeRaw = streamType.rawValue
        r.audioTranscript = transcript
        r.audioTranscriptModel = transcriptModel
        r.audioTranscriptDate = transcriptDate
        r.sceneCaptions = captions
        r.sceneCaptionModel = captionModel
        r.sceneCaptionDate = captionDate
        r.ocrText = ocrText
        r.ocrDateCandidates = ocrDates
        r.dossierProcessedAt = dossierProcessedAt
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

    // MARK: - 4. Playability guard (smear regression, fixed 2026-06-30)
    //
    // Bug: an unreadable / ffprobe-failed file that merely COLLIDES on
    // partialMD5 with a readable, analyzed sibling was inheriting that
    // sibling's transcript/captions — hallucinated content the junk file
    // never earned, written with NO dossierProcessedAt stamp. ~230 records
    // showed the signature. Propagation must exclude unreadable records as
    // BOTH donor and recipient, exactly as the direct dossier pipeline does.

    /// red→green: an unreadable (.ffprobeFailed) record sharing a
    /// partialMD5 with a readable donor must NOT receive the donor's
    /// transcript. Reproduces the core smear.
    @Test func propagation_unreadableRecipientRejectsSmear() {
        let model = VideoScanModel()
        let readableDonor = makeRecord(
            path: "/Volumes/LaCie/clip.mov", md5: "COLLIDE",
            transcript: "Happy birthday Matt, blow out the candles.",
            transcriptModel: "whisper-medium",
            streamType: .videoAndAudio
        )
        let junkRecipient = makeRecord(
            path: "/Volumes/Junk/0001.tmp", md5: "COLLIDE",
            transcript: nil,
            streamType: .ffprobeFailed
        )
        model.records = [readableDonor, junkRecipient]
        model.propagateBestDossier(in: [readableDonor, junkRecipient])

        #expect(junkRecipient.audioTranscript == nil,
                "Unreadable/ffprobe-failed record must NEVER inherit a sibling's transcript")
        #expect(junkRecipient.dossierProcessedAt == nil,
                "Guard must leave the junk record's provenance untouched")
    }

    /// red→green: an unreadable record must not act as a DONOR either —
    /// a readable sibling must not inherit content from junk.
    @Test func propagation_unreadableDonorIsIgnored() {
        let model = VideoScanModel()
        let junkDonor = makeRecord(
            path: "/Volumes/Junk/0002.tmp", md5: "COLLIDE2",
            transcript: "garbage transcript from an unreadable file",
            streamType: .ffprobeFailed
        )
        let readableRecipient = makeRecord(
            path: "/Volumes/LaCie/real.mov", md5: "COLLIDE2",
            transcript: nil,
            streamType: .videoAndAudio
        )
        model.records = [junkDonor, readableRecipient]
        let mutated = model.propagateBestDossier(in: [junkDonor, readableRecipient])

        #expect(mutated == 0,
                "Only one readable record in the group — nothing to propagate")
        #expect(readableRecipient.audioTranscript == nil,
                "Readable record must NOT inherit a transcript from an unreadable donor")
    }

    /// red→green: a degenerate donor transcript (single repeated character
    /// like "!!!!") must never propagate — it's a recognizer failure
    /// artifact, not speech. Both records are readable to isolate the
    /// degeneracy guard from the playability guard.
    @Test func propagation_degenerateDonorRejected() {
        let model = VideoScanModel()
        let degenerate = makeRecord(
            path: "/A/a.mov", md5: "DEGEN",
            transcript: "!!!!!!!!",
            streamType: .videoAndAudio
        )
        let recipient = makeRecord(
            path: "/B/b.mov", md5: "DEGEN",
            transcript: nil,
            streamType: .videoAndAudio
        )
        model.records = [degenerate, recipient]
        let mutated = model.propagateBestDossier(in: [degenerate, recipient])

        #expect(mutated == 0,
                "A degenerate '!!!!' transcript is the only candidate — nothing worth propagating")
        #expect(recipient.audioTranscript == nil,
                "Recipient must NOT inherit a single-repeated-character transcript")
        #expect(VideoScanModel.bestAudioTranscript(in: [degenerate, recipient]) == nil,
                "Degenerate text must be skipped by the donor selector outright")
    }

    /// positive: two READABLE duplicates still harmonize normally — the
    /// fix must not break the legitimate feature. (Mirrors the elevator
    /// case but asserts explicitly with pinned readable stream types.)
    @Test func propagation_betweenTwoReadableDuplicatesStillWorks() {
        let model = VideoScanModel()
        let online = makeRecord(
            path: "/Volumes/LaCie/e.dv", md5: "READABLE",
            transcript: "short", streamType: .videoAndAudio
        )
        let offline = makeRecord(
            path: "/Volumes/Seagate/e.dv", md5: "READABLE",
            transcript: "Is it in the elevator? Yes the elevator.",
            transcriptModel: "whisper-medium",
            streamType: .videoAndAudio
        )
        model.records = [online, offline]
        let mutated = model.propagateBestDossier(in: [online, offline])

        #expect(mutated == 1, "The shorter readable copy inherits the longer transcript")
        #expect(online.audioTranscript == offline.audioTranscript,
                "Legitimate propagation between two readable duplicates must still work")
    }

    // MARK: - 5. One-shot corruption cleanup

    /// The cleanup core clears ONLY records matching the exact corruption
    /// signature (unreadable + dossierProcessedAt==nil + has content) and
    /// leaves everything else — readable analyzed records, and legitimately
    /// stamped records — untouched. Idempotent on a second pass.
    @Test func cleanup_clearsOnlyCorruptedUnreadableRecords() {
        let model = VideoScanModel()

        // Corrupted: unreadable, smeared content, no stamp.
        let corrupted = makeRecord(
            path: "/Junk/x.tmp", md5: "M",
            transcript: "smeared birthday transcript",
            captions: [SceneCaption(timestamp: 0, text: "a cake")],
            streamType: .ffprobeFailed
        )
        // Legit readable analyzed record (the donor) — must survive.
        let healthy = makeRecord(
            path: "/Real/x.mov", md5: "M",
            transcript: "smeared birthday transcript",
            streamType: .videoAndAudio,
            dossierProcessedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        // Unreadable but legitimately stamped (e.g. audio-only edge) —
        // NOT corruption, must survive.
        let stampedUnreadable = makeRecord(
            path: "/Junk/y.tmp", md5: "N",
            transcript: "kept",
            streamType: .ffprobeFailed,
            dossierProcessedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        model.records = [corrupted, healthy, stampedUnreadable]
        let cleared = model.clearSmearedDossiers()

        #expect(cleared.count == 1, "Only the one corrupted record matches the signature")
        #expect(cleared.first?.audioTranscript == "smeared birthday transcript",
                "Snapshot must preserve the PRIOR content for the quarantine sidecar")
        #expect(corrupted.audioTranscript == nil && corrupted.sceneCaptions.isEmpty,
                "Live corrupted record must be blanked")
        #expect(healthy.audioTranscript == "smeared birthday transcript",
                "Readable analyzed record must be untouched")
        #expect(stampedUnreadable.audioTranscript == "kept",
                "Legitimately stamped record must be untouched even if unreadable")

        // Idempotent second pass finds nothing.
        let second = model.clearSmearedDossiers()
        #expect(second.isEmpty, "Cleanup is idempotent — corruption is gone after the first pass")
    }
}
