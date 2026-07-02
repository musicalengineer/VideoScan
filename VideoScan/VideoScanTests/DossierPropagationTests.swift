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

    // MARK: - 6. Quarantine sidecar is a genuine undo record
    //
    // The live cleanup pass BLANKS dossier fields on ~230 records; the
    // sidecar JSON is the only place the prior content survives. The log
    // line promises "Prior content quarantined … for audit/undo", so the
    // sidecar must carry the FULL content of every quarantined field —
    // counts alone cannot restore anything.

    /// Test-local mirror of the sidecar entry schema. Decoding the real
    /// payload into this proves the on-disk JSON carries full content
    /// (a counts-only sidecar fails decode with keyNotFound).
    private struct SidecarEntry: Decodable {
        let id: String
        let fullPath: String
        let partialMD5: String
        let audioTranscript: String?
        let audioTranscriptModel: String?
        let audioTranscriptDate: Date?
        let sceneCaptions: [SceneCaption]
        let sceneCaptionModel: String?
        let sceneCaptionDate: Date?
        let ocrText: [SceneCaption]
        let ocrDateCandidates: [SceneCaption]
    }

    /// red→green: every quarantined dossier field must round-trip out of
    /// the sidecar payload byte-for-byte equal to the original values —
    /// multi-entry captions with timestamps, OCR text, OCR date
    /// candidates, and the transcript.
    @Test func quarantineSidecar_roundTripsFullDossierContent() throws {
        let captions = [
            SceneCaption(timestamp: 0.0, text: "a birthday cake with lit candles"),
            SceneCaption(timestamp: 12.5, text: "kids around the kitchen table"),
            SceneCaption(timestamp: 47.25, text: "a woman laughing near the window")
        ]
        let ocr = [
            SceneCaption(timestamp: 3.0, text: "JUL 4 1997"),
            SceneCaption(timestamp: 9.0, text: "CAPE COD")
        ]
        let ocrDates = [
            SceneCaption(timestamp: 3.0, text: "1997-07-04")
        ]
        // Whole-second dates: the sidecar encodes ISO-8601 (human-
        // reviewable), which drops sub-second precision.
        let transcriptDate = Date(timeIntervalSince1970: 1_700_000_000)
        let captionDate = Date(timeIntervalSince1970: 1_710_000_000)
        let smeared = makeRecord(
            path: "/Volumes/Junk/0001.tmp", md5: "SMEAR-RT",
            transcript: "Happy birthday, blow out the candles.",
            transcriptModel: "whisper-medium",
            transcriptDate: transcriptDate,
            captions: captions,
            captionModel: "fastvlm",
            captionDate: captionDate,
            ocrText: ocr,
            ocrDates: ocrDates,
            streamType: .ffprobeFailed
        )

        // Same shape as the live/dry-run paths: the sidecar is written
        // from pre-clear snapshots.
        let data = try VideoScanModel.smearQuarantinePayloadData([smeared.snapshotClone()])

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode([SidecarEntry].self, from: data)
        #expect(decoded.count == 1)
        let entry = try #require(decoded.first)
        #expect(entry.id == smeared.id.uuidString)
        #expect(entry.fullPath == "/Volumes/Junk/0001.tmp")
        #expect(entry.partialMD5 == "SMEAR-RT")
        #expect(entry.audioTranscript == "Happy birthday, blow out the candles.",
                "Full transcript must be recoverable from the sidecar")
        #expect(entry.sceneCaptions == captions,
                "Full caption array (timestamps + text, in order) must be recoverable from the sidecar")
        #expect(entry.ocrText == ocr,
                "Full OCR text entries must be recoverable from the sidecar")
        #expect(entry.ocrDateCandidates == ocrDates,
                "Full OCR date candidates must be recoverable from the sidecar")
        // Attribution fields the cleanup also blanks — part of the undo.
        #expect(entry.audioTranscriptModel == "whisper-medium")
        #expect(entry.audioTranscriptDate == transcriptDate)
        #expect(entry.sceneCaptionModel == "fastvlm")
        #expect(entry.sceneCaptionDate == captionDate)
    }

    /// The sidecar stays human-reviewable: pretty-printed JSON, and the
    /// per-field counts survive as summary fields alongside the content.
    @Test func quarantineSidecar_staysHumanReviewableWithCounts() throws {
        let smeared = makeRecord(
            path: "/Volumes/Junk/0002.tmp", md5: "SMEAR-HR",
            transcript: "smeared",
            captions: [SceneCaption(timestamp: 0, text: "a cake"),
                       SceneCaption(timestamp: 5, text: "a dog")],
            ocrText: [SceneCaption(timestamp: 1, text: "JUN 1991")],
            ocrDates: [SceneCaption(timestamp: 1, text: "1991-06-21")],
            streamType: .ffprobeFailed
        )
        let data = try VideoScanModel.smearQuarantinePayloadData([smeared])
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\n"), "Sidecar must stay pretty-printed for Rick's review")

        struct CountsEntry: Decodable {
            let sceneCaptionCount: Int
            let ocrTextCount: Int
            let ocrDateCount: Int
        }
        let counts = try JSONDecoder().decode([CountsEntry].self, from: data)
        let entry = try #require(counts.first)
        #expect(entry.sceneCaptionCount == 2)
        #expect(entry.ocrTextCount == 1)
        #expect(entry.ocrDateCount == 1)
    }

    // MARK: - 7. Direct transcript writeback carries provenance (latent bug, 2026-07-01)
    //
    // The smear-cleanup signature is "unreadable + has dossier content +
    // dossierProcessedAt == nil". A record with an unplayable legacy VIDEO
    // codec (svq3 etc. → isLikelyUnanalyzable) can still have a perfectly
    // legitimate Whisper AUDIO transcript — ffmpeg decodes the audio fine.
    // If a caller writes that transcript via the applyAudioTranscript
    // family (which historically never stamped dossierProcessedAt), the
    // cleanup would classify the legit transcript as smear and blank it.
    // Every apply variant must stamp provenance so directly-applied
    // transcripts are excluded from the signature.

    /// Realistic at-risk record: Sorenson video (AVFoundation can't decode
    /// → isLikelyUnanalyzable → excluded-from-propagation / smear-signature
    /// candidate) but ordinary PCM audio that Whisper CAN transcribe.
    private func makeLegacyVideoCodecRecord(path: String, md5: String) -> VideoRecord {
        let r = makeRecord(path: path, md5: md5, streamType: .videoAndAudio)
        r.videoCodec = "svq3"       // unplayable legacy video
        r.audioCodec = "pcm_s16le"  // fine audio — transcribable
        return r
    }

    @Test func applyAudioTranscript_direct_stampsProvenance_survivesSmearCleanup() {
        let model = VideoScanModel()
        let rec = makeLegacyVideoCodecRecord(path: "/Vols/T/thanksgiving.mov", md5: "LGC1")
        model.records = [rec]
        #expect(VideoScanModel.isExcludedFromPropagation(rec),
                "Precondition: legacy-codec record must be in the at-risk class")

        model.applyAudioTranscript("pass the gravy please",
                                   modelID: "whisper-medium-mlx-q4",
                                   to: rec)

        #expect(rec.dossierProcessedAt != nil,
                "Direct transcript writeback must stamp dossierProcessedAt provenance")

        let cleared = model.clearSmearedDossiers()
        #expect(cleared.isEmpty,
                "A directly-applied transcript is legitimate content, not smear")
        #expect(rec.audioTranscript == "pass the gravy please",
                "Legit Whisper transcript on an unplayable-video record must survive cleanup")
    }

    @Test func applyAudioTranscript_byPath_stampsProvenance_survivesSmearCleanup() {
        let model = VideoScanModel()
        let rec = makeLegacyVideoCodecRecord(path: "/Vols/T/parade.mov", md5: "LGC2")
        model.records = [rec]

        let matched = model.applyAudioTranscript(
            "look at that balloon", to: "/Vols/T/parade.mov",
            model: "whisper-medium-mlx-q4")
        #expect(matched)

        #expect(rec.dossierProcessedAt != nil,
                "Path-keyed transcript writeback must stamp dossierProcessedAt provenance")

        let cleared = model.clearSmearedDossiers()
        #expect(cleared.isEmpty)
        #expect(rec.audioTranscript == "look at that balloon")
    }

    @Test func applyAudioTranscripts_bulk_stampsProvenance_survivesSmearCleanup() {
        let model = VideoScanModel()
        let a = makeLegacyVideoCodecRecord(path: "/Vols/T/a.mov", md5: "LGC3")
        let b = makeLegacyVideoCodecRecord(path: "/Vols/T/b.mov", md5: "LGC4")
        model.records = [a, b]

        let updated = model.applyAudioTranscripts(
            ["/Vols/T/a.mov": "happy birthday donna",
             "/Vols/T/b.mov": "blow out the candles"],
            model: "whisper-medium-mlx-q4")
        #expect(updated == 2)

        #expect(a.dossierProcessedAt != nil && b.dossierProcessedAt != nil,
                "Bulk transcript writeback must stamp dossierProcessedAt on every updated record")

        let cleared = model.clearSmearedDossiers()
        #expect(cleared.isEmpty)
        #expect(a.audioTranscript == "happy birthday donna")
        #expect(b.audioTranscript == "blow out the candles")
    }

    /// Re-transcribing a record that already carries a FULL dossier stamp
    /// must not overwrite that provenance — dossierProcessedAt/By record
    /// when/which stack produced the whole dossier (VLM + Whisper), and
    /// the audio channel's own provenance lives in audioTranscriptModel/
    /// Date. The stamp is only backfilled when missing.
    @Test func applyAudioTranscript_preservesExistingFullDossierProvenance() {
        let model = VideoScanModel()
        let fullDossierAt = Date(timeIntervalSince1970: 1_700_000_000)
        let rec = makeRecord(path: "/Vols/T/dossiered.mov", md5: "LGC5",
                             transcript: "old transcript",
                             streamType: .videoAndAudio,
                             dossierProcessedAt: fullDossierAt)
        rec.dossierProcessedBy = "qwen2.5-vl-3b-4bit+whisper-medium-mlx-q4"
        model.records = [rec]

        model.applyAudioTranscript("new re-run transcript",
                                   modelID: "whisper-large-v3",
                                   to: rec)

        #expect(rec.audioTranscript == "new re-run transcript")
        #expect(rec.audioTranscriptModel == "whisper-large-v3")
        #expect(rec.dossierProcessedAt == fullDossierAt,
                "Existing full-dossier timestamp must not be overwritten by a re-transcribe")
        #expect(rec.dossierProcessedBy == "qwen2.5-vl-3b-4bit+whisper-medium-mlx-q4",
                "Existing full-dossier stack attribution must not be overwritten by a re-transcribe")
    }

    /// Negative control: the fix must NOT weaken smear detection. Content
    /// that arrived WITHOUT a provenance stamp (the pre-2026-06-30 ungated
    /// MD5 propagation) on an unreadable record is still corruption and is
    /// still cleared — even when a legitimately-transcribed record sits in
    /// the same catalog.
    @Test func smearCleanup_stillDetectsGenuineSmear_alongsideDirectTranscript() {
        let model = VideoScanModel()

        // Legit: transcript arrives via the apply path → stamped → kept.
        let legit = makeLegacyVideoCodecRecord(path: "/Vols/T/legit.mov", md5: "LGC6")
        // Smeared: content field-assigned the way the old propagation did
        // (copies text + model + date but never a dossierProcessedAt).
        let smeared = makeLegacyVideoCodecRecord(path: "/Vols/T/smeared.mov", md5: "LGC7")
        smeared.audioTranscript = "hallucinated inherited transcript"
        smeared.audioTranscriptModel = "whisper-medium-mlx-q4"
        smeared.audioTranscriptDate = Date(timeIntervalSince1970: 1_700_000_000)

        model.records = [legit, smeared]
        model.applyAudioTranscript("real speech", modelID: "whisper-medium-mlx-q4", to: legit)

        let cleared = model.clearSmearedDossiers()
        #expect(cleared.count == 1, "Exactly the unstamped record matches the smear signature")
        #expect(cleared.first?.fullPath == "/Vols/T/smeared.mov")
        #expect(smeared.audioTranscript == nil, "Genuine smear must still be blanked")
        #expect(legit.audioTranscript == "real speech", "Stamped direct transcript must survive")
    }

    // MARK: - 8. Direct caption writeback carries provenance (twin of section 7, 2026-07-01)
    //
    // Identical exposure to the transcript bug above, on the caption
    // channel: applyCaptions historically wrote sceneCaptions /
    // sceneCaptionModel / sceneCaptionDate without stamping
    // dossierProcessedAt. A caption-only run onto an isLikelyUnanalyzable
    // record (VLM captioning a legacy-codec file via the ffmpeg frame-rip
    // path, which decodes fine even when AVFoundation can't) therefore
    // matched the smear-cleanup corruption signature and the one-shot
    // cleanup would blank the legitimate captions.

    @Test func applyCaptions_byPath_stampsProvenance_survivesSmearCleanup() {
        let model = VideoScanModel()
        let rec = makeLegacyVideoCodecRecord(path: "/Vols/T/beachday.mov", md5: "LGC8")
        model.records = [rec]
        #expect(VideoScanModel.isExcludedFromPropagation(rec),
                "Precondition: legacy-codec record must be in the at-risk class")

        let matched = model.applyCaptions(
            [SceneCaption(timestamp: 0, text: "Kids building a sandcastle")],
            to: "/Vols/T/beachday.mov",
            model: "qwen2.5-vl-3b-4bit")
        #expect(matched)

        #expect(rec.dossierProcessedAt != nil,
                "Path-keyed caption writeback must stamp dossierProcessedAt provenance")

        let cleared = model.clearSmearedDossiers()
        #expect(cleared.isEmpty,
                "Directly-applied captions are legitimate content, not smear")
        #expect(rec.sceneCaptions.count == 1,
                "Legit VLM captions on an unplayable-video record must survive cleanup")
    }

    @Test func applyCaptions_bulk_stampsProvenance_survivesSmearCleanup() {
        let model = VideoScanModel()
        let a = makeLegacyVideoCodecRecord(path: "/Vols/T/c.mov", md5: "LGC9")
        let b = makeLegacyVideoCodecRecord(path: "/Vols/T/d.mov", md5: "LGCA")
        model.records = [a, b]

        let updated = model.applyCaptions(
            ["/Vols/T/c.mov": [SceneCaption(timestamp: 0, text: "A birthday cake with candles")],
             "/Vols/T/d.mov": [SceneCaption(timestamp: 5, text: "A dog running across the yard")]],
            model: "qwen2.5-vl-3b-4bit")
        #expect(updated == 2)

        #expect(a.dossierProcessedAt != nil && b.dossierProcessedAt != nil,
                "Bulk caption writeback must stamp dossierProcessedAt on every updated record")

        let cleared = model.clearSmearedDossiers()
        #expect(cleared.isEmpty)
        #expect(a.sceneCaptions.first?.text == "A birthday cake with candles")
        #expect(b.sceneCaptions.first?.text == "A dog running across the yard")
    }

    /// Re-captioning a record that already carries a FULL dossier stamp
    /// must not overwrite that provenance — same backfill-only rule as
    /// the transcript twin. The caption channel's own provenance lives
    /// in sceneCaptionModel/Date.
    @Test func applyCaptions_preservesExistingFullDossierProvenance() {
        let model = VideoScanModel()
        let fullDossierAt = Date(timeIntervalSince1970: 1_700_000_000)
        let rec = makeRecord(path: "/Vols/T/dossiered2.mov", md5: "LGCB",
                             captions: [SceneCaption(timestamp: 0, text: "old caption")],
                             streamType: .videoAndAudio,
                             dossierProcessedAt: fullDossierAt)
        rec.dossierProcessedBy = "qwen2.5-vl-3b-4bit+whisper-medium-mlx-q4"
        model.records = [rec]

        let matched = model.applyCaptions(
            [SceneCaption(timestamp: 0, text: "new re-run caption")],
            to: "/Vols/T/dossiered2.mov",
            model: "qwen2.5-vl-7b-8bit")
        #expect(matched)

        #expect(rec.sceneCaptions.first?.text == "new re-run caption")
        #expect(rec.sceneCaptionModel == "qwen2.5-vl-7b-8bit")
        #expect(rec.dossierProcessedAt == fullDossierAt,
                "Existing full-dossier timestamp must not be overwritten by a re-caption")
        #expect(rec.dossierProcessedBy == "qwen2.5-vl-3b-4bit+whisper-medium-mlx-q4",
                "Existing full-dossier stack attribution must not be overwritten by a re-caption")
    }

    /// Negative control (caption flavor): the fix must NOT weaken smear
    /// detection. Caption content that arrived WITHOUT a provenance stamp
    /// (the pre-2026-06-30 ungated MD5 propagation) on an unreadable
    /// record is still corruption and is still cleared — even when a
    /// legitimately-captioned record sits in the same catalog.
    @Test func smearCleanup_stillDetectsGenuineCaptionSmear_alongsideDirectCaptions() {
        let model = VideoScanModel()

        // Legit: captions arrive via the apply path → stamped → kept.
        let legit = makeLegacyVideoCodecRecord(path: "/Vols/T/legitcap.mov", md5: "LGCC")
        // Smeared: content field-assigned the way the old propagation did
        // (copies captions + model + date but never a dossierProcessedAt).
        let smeared = makeLegacyVideoCodecRecord(path: "/Vols/T/smearedcap.mov", md5: "LGCD")
        smeared.sceneCaptions = [SceneCaption(timestamp: 0, text: "hallucinated inherited caption")]
        smeared.sceneCaptionModel = "qwen2.5-vl-3b-4bit"
        smeared.sceneCaptionDate = Date(timeIntervalSince1970: 1_700_000_000)

        model.records = [legit, smeared]
        _ = model.applyCaptions(
            [SceneCaption(timestamp: 0, text: "real scene description")],
            to: "/Vols/T/legitcap.mov",
            model: "qwen2.5-vl-3b-4bit")

        let cleared = model.clearSmearedDossiers()
        #expect(cleared.count == 1, "Exactly the unstamped record matches the smear signature")
        #expect(cleared.first?.fullPath == "/Vols/T/smearedcap.mov")
        #expect(smeared.sceneCaptions.isEmpty, "Genuine caption smear must still be blanked")
        #expect(legit.sceneCaptions.first?.text == "real scene description",
                "Stamped direct captions must survive")
    }
}
