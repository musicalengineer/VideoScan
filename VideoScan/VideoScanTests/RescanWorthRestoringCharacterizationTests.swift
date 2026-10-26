import Foundation
import Testing
@testable import VideoScan

// MARK: - RescanPreservedFields.isWorthRestoring — characterization
//
// Written 2026-10-25 BEFORE the predicate was split into named rule groups
// (complexity refactor: CCN 36 in one 38-line disjunction). The truth table
// below pins every field that, ALONE, keeps a record in the rescan snapshot
// map, and every field that does NOT (scan-derived, comparison-only, or
// carried by a sibling predicate). The refactor must leave every row green.
//
// Red/green record (deliberate mutations on the UNCHANGED predicate, each
// reverted before the refactor):
//
//   mutation                                            | red test
//   ----------------------------------------------------|---------------------------------------------
//   remove `|| userPlace != nil`                        | eachCuratedFieldAloneIsWorthRestoring[userPlace]
//   `starRating != 0` → `starRating > 1`                | eachCuratedFieldAloneIsWorthRestoring[starRating]
//   add `|| inferredDateConfidence != nil`              | scanDerivedOrSiblingFieldsAloneAreNotWorthRestoring[inferredDateConfidence]
//
// Green on the unchanged code, green after the refactor.

/// One row of the truth table: a name for the report and the single field
/// write that turns a blank record into the case under test.
/// (For Rick: a struct of a label plus a function pointer — the closure is
/// `@MainActor` because VideoRecord is written on the main actor.)
struct WorthRestoringCase: Sendable, CustomTestStringConvertible {
    let name: String
    let write: @MainActor @Sendable (VideoRecord) -> Void
    var testDescription: String { name }

    private static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    /// Every field that ALONE makes the snapshot worth restoring — one per
    /// term of the predicate, in the predicate's order.
    static let positives: [WorthRestoringCase] = [
        // Dossier channels
        .init(name: "sceneCaptions") { $0.sceneCaptions = [SceneCaption(timestamp: 1, text: "cake")] },
        .init(name: "audioTranscript") { $0.audioTranscript = "happy birthday" },
        .init(name: "ocrDateCandidates") { $0.ocrDateCandidates = [SceneCaption(timestamp: 0.5, text: "JUN 21 1991")] },
        .init(name: "ocrText") { $0.ocrText = [SceneCaption(timestamp: 2, text: "HAPPY BIRTHDAY")] },
        .init(name: "dossierProcessedAt") { $0.dossierProcessedAt = stamp },
        .init(name: "inferredRecordDate") { $0.inferredRecordDate = stamp },
        // People tags
        .init(name: "detectedPeople") { $0.detectedPeople = ["Matt"] },
        .init(name: "suspectedPeople") { $0.suspectedPeople = ["Tim"] },
        .init(name: "confirmedByUserPeople") { $0.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: stamp)] },
        .init(name: "rejectedPeople") { $0.rejectedPeople = ["Anna"] },
        // Curation
        .init(name: "mediaDisposition") { $0.mediaDisposition = .important },
        .init(name: "lifecycleStage") { $0.lifecycleStage = .reviewing },
        .init(name: "archiveStage") { $0.archiveStage = .healthy },
        .init(name: "starRating") { $0.starRating = 1 },
        .init(name: "junkScore") { $0.junkScore = 1 },
        .init(name: "notes") { $0.notes = "Matt's 4th birthday" },
        .init(name: "tags") { $0.tags = ["birthday"] },
        .init(name: "userNotes") { $0.userNotes = "keep" },
        // Lifecycle / removal state
        .init(name: "purgedAt (removal marker)") { $0.purgedAt = stamp },
        .init(name: "setAsideReason") { $0.setAsideReason = "editor cache" },
        .init(name: "supersededByID") { $0.supersededByID = UUID() },
        .init(name: "repairConfirmedDate") { $0.repairConfirmedDate = stamp },
        .init(name: "derivedFrom") { $0.derivedFrom = UUID() },
        .init(name: "derivationKind") { $0.derivationKind = "repair" },
        // Archive provenance
        .init(name: "archiveFixity") { $0.archiveFixity = ArchiveFixity(digest: "00", verifiedAt: stamp, sizeBytes: 1) },
        .init(name: "originalFullPath") { $0.originalFullPath = "/Volumes/LaCie/x.mov" },
        .init(name: "originVolume") { $0.originVolume = "LaCie" },
        .init(name: "masterLocation") { $0.masterLocation = "/Volumes/FamilyArchive" },
        // Rick's answers
        .init(name: "userDate") { $0.userDate = "1992" },
        .init(name: "userDateConfidence") { $0.userDateConfidence = "estimated" },
        .init(name: "userPlace") { $0.userPlace = "Cape Cod" },
        .init(name: "userPlaceConfidence") { $0.userPlaceConfidence = "known" },
        .init(name: "backupAttestations") { $0.backupAttestations = [BackupAttestation(kind: .offsite, answer: .no)] },
        // Footage + music
        .init(name: "footageDecisions") { $0.setFootageDecision(FootageDecision(otherID: UUID(), verdict: .notSame)) },
        .init(name: "footage") {
            $0.footage = FootageMembership(groupID: UUID(), groupSize: 2, confidence: .likely, role: .copy,
                                           rank: 1, likelyOriginalID: UUID(), originalInCatalog: true,
                                           evidence: [], scannedAt: stamp, algorithmVersion: 1)
        },
        .init(name: "familyMusic") { $0.familyMusic = FamilyMusicInfo(performer: "Tim", title: "Blackbird") },
    ]

    /// Fields that do NOT, alone, make the snapshot worth restoring: scan-
    /// derived values the fresh probe re-reads, comparison-only evidence,
    /// fields a sibling predicate (`carriesKeptFingerprint`,
    /// `carriesRemovalHistory`) owns, and dossier SIDE fields whose presence
    /// without their channel means nothing. This is the predicate as it IS.
    static let negatives: [WorthRestoringCase] = [
        .init(name: "blank record") { _ in },
        .init(name: "partialMD5 (comparison only)") { $0.partialMD5 = "0123456789abcdef0123456789abcdef" },
        .init(name: "sizeBytes / codec / resolution (scan-derived)") {
            $0.sizeBytes = 12_345; $0.videoCodec = "h264"; $0.resolution = "1920x1080"
        },
        .init(name: "perceptualFingerprint (sibling: carriesKeptFingerprint)") {
            $0.perceptualFingerprint = StoredPerceptualFingerprint(hashes: [1, 2, 3], sizeBytes: 10, durationSeconds: 1)
        },
        .init(name: "removalRevision (sibling: carriesRemovalHistory)") { $0.removalRevision = 2 },
        .init(name: "auditSeenOn (sibling: carriesRemovalHistory)") {
            $0.auditSeenOn = AuditSeenOn(volumeUUID: "ABC", mountFrom: nil, seenAt: stamp)
        },
        .init(name: "audioTranscript empty string") { $0.audioTranscript = "" },
        .init(name: "sceneCaptionModel alone") { $0.sceneCaptionModel = "qwen" },
        .init(name: "sceneCaptionDate alone") { $0.sceneCaptionDate = stamp },
        .init(name: "audioTranscriptModel alone") { $0.audioTranscriptModel = "whisper" },
        .init(name: "audioTranscriptDate alone") { $0.audioTranscriptDate = stamp },
        .init(name: "inferredDateConfidence alone") { $0.inferredDateConfidence = 0.9 },
        .init(name: "inferredDateSource alone") { $0.inferredDateSource = "ocr" },
        .init(name: "inferredDateReason alone") { $0.inferredDateReason = "sibling folder" },
        .init(name: "dossierProcessedBy alone") { $0.dossierProcessedBy = "qwen+whisper" },
        .init(name: "defaults restated (unreviewed / cataloged / none / 0 / \"\")") {
            $0.mediaDisposition = .unreviewed; $0.lifecycleStage = .cataloged; $0.archiveStage = .none
            $0.starRating = 0; $0.junkScore = 0; $0.notes = ""; $0.tags = []; $0.userNotes = ""
            $0.masterLocation = ""
        },
    ]
}

@MainActor
@Suite("Rescan preservation — isWorthRestoring characterization")
struct RescanWorthRestoringCharacterizationTests {

    private func blank() -> VideoRecord {
        let r = VideoRecord()
        r.filename = "clip.mov"
        r.fullPath = "/Volumes/Test/clip.mov"
        return r
    }

    @Test(arguments: WorthRestoringCase.positives)
    func eachCuratedFieldAloneIsWorthRestoring(_ row: WorthRestoringCase) {
        let r = blank()
        row.write(r)
        #expect(RescanPreservedFields(from: r).isWorthRestoring, "\(row.name) alone must keep the record in the snapshot map")
    }

    @Test(arguments: WorthRestoringCase.negatives)
    func scanDerivedOrSiblingFieldsAloneAreNotWorthRestoring(_ row: WorthRestoringCase) {
        let r = blank()
        row.write(r)
        #expect(!RescanPreservedFields(from: r).isWorthRestoring, "\(row.name) alone must NOT keep the record in the snapshot map")
    }

    /// The table covers the predicate exactly once per term: 36 disjuncts
    /// in the original (CCN 36 = 1 + 35 `||`). A new preserved field must
    /// add a row here, or this count says the table fell behind.
    @Test func truthTableCoversEveryTermOnce() {
        #expect(WorthRestoringCase.positives.count == 36)
        #expect(Set(WorthRestoringCase.positives.map(\.name)).count == 36, "no duplicate rows")
    }

    /// Any two positive fields together are still worth restoring (the
    /// predicate is a pure OR — no field can veto another).
    @Test func positivesNeverVetoEachOther() {
        let rows = WorthRestoringCase.positives
        for i in stride(from: 0, to: rows.count - 1, by: 2) {
            let r = blank()
            rows[i].write(r)
            rows[i + 1].write(r)
            #expect(RescanPreservedFields(from: r).isWorthRestoring, "\(rows[i].name) + \(rows[i + 1].name)")
        }
    }

    /// The three snapshot-map predicates are disjoint in what they claim:
    /// a fingerprint-only or history-only row is admitted by its sibling,
    /// never by `isWorthRestoring`. Pins the division the refactor keeps.
    @Test func siblingPredicatesStayOutsideIsWorthRestoring() {
        let fp = blank()
        fp.perceptualFingerprint = StoredPerceptualFingerprint(hashes: [7], sizeBytes: 10, durationSeconds: 1)
        let fpSnap = RescanPreservedFields(from: fp)
        #expect(!fpSnap.isWorthRestoring && fpSnap.carriesKeptFingerprint && !fpSnap.carriesRemovalHistory)

        let hist = blank()
        hist.removalRevision = 2
        let histSnap = RescanPreservedFields(from: hist)
        #expect(!histSnap.isWorthRestoring && histSnap.carriesRemovalHistory && !histSnap.carriesKeptFingerprint)
    }
}
