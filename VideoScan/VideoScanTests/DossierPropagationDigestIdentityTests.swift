// DossierPropagationDigestIdentityTests.swift
// REGRESSION GH #413: dossier propagation grouped records by `partialMD5`
// (a head+tail SAMPLE) and wrote the best transcript, scene captions, OCR
// text AND OCR date candidates to every member. OCR dates feed
// DateInference and, through it, Promote's decade folder. On Rick's catalog
// 11 partialMD5 groups held more than one whole-file digest (same size and
// head/tail, different interior bytes). Rule 6: identity is the whole-file
// SHA-256, never a sample.
//
// Fix: group by the digest the commit stores (CatalogRecordDTO.resolveDigest);
// a record with no whole-file digest propagates nothing.
//
// Red/green (before the fix → after):
//   sameSampleDifferentDigest_backfillCopiesNoOCRDates ......... RED → green
//   sameSampleDifferentDigest_writebackCopiesNoTranscript ...... RED → green
//   sameSampleNoDigest_propagatesNothing ....................... RED → green
//   disagreeingFixities_propagateNothing ....................... RED → green
//   sameDigest_propagatesAsBefore .............................. green → green
//   sameDigestDifferentSample_propagates ....................... RED → green
//   archiveFixityIsAWholeFileDigestToo ......................... RED → green

import Testing
import CryptoKit
import Foundation
import VideoScanCore
@testable import VideoScan

@MainActor
@Suite("Dossier propagation — whole-file digest identity (GH #413)")
struct DossierPropagationDigestIdentityTests {

    /// 64 lowercase hex — a well-formed whole-file digest named by `seed`.
    private static func digest(_ seed: String) -> String {
        SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func fixity(_ seed: String, size: Int64) -> ContentFixity {
        ContentFixity(digest: digest(seed), byteCount: size,
                      stamp: FileIdentityStamp(device: 1, inode: 1, size: size, mtimeNs: 1, ctimeNs: 1,
                                               volumeUUID: "11111111-2222-3333-4444-555555555555"),
                      computedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private static func record(_ path: String, md5: String, digestSeed: String?, size: Int64 = 4_000_000,
                               transcript: String? = nil, ocrDates: [SceneCaption] = []) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.partialMD5 = md5
        r.sizeBytes = size
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.audioTranscript = transcript
        r.ocrDateCandidates = ocrDates
        r.contentFixity = digestSeed.map { fixity($0, size: size) }
        return r
    }

    private static let christmas1987 = [SceneCaption(timestamp: 2, text: "DEC 25 1987")]

    @Test("same partialMD5, different whole-file digests: the backfill copies no OCR date across")
    func sameSampleDifferentDigest_backfillCopiesNoOCRDates() {
        let model = VideoScanModel()
        let dated = Self.record("/A/clip.dv", md5: "HEADTAIL", digestSeed: "intact", ocrDates: Self.christmas1987)
        let other = Self.record("/B/clip.dv", md5: "HEADTAIL", digestSeed: "damaged")
        model.records = [dated, other]

        let updated = model.backfillDossierAcrossDuplicates()

        #expect(updated == 0, "two different contents are not copies of one file")
        #expect(other.ocrDateCandidates.isEmpty,
                "an OCR date crossed to a file with different bytes: \(other.ocrDateCandidates.map(\.text))")
    }

    @Test("same partialMD5, different digests: a transcript writeback reaches no other content")
    func sameSampleDifferentDigest_writebackCopiesNoTranscript() {
        let model = VideoScanModel()
        let target = Self.record("/A/clip.dv", md5: "HEADTAIL", digestSeed: "intact")
        let other = Self.record("/B/clip.dv", md5: "HEADTAIL", digestSeed: "damaged", transcript: "")
        model.records = [target, other]

        model.applyAudioTranscript("happy birthday grandma", modelID: "whisper-test", to: target)

        #expect(other.audioTranscript ?? "" == "", "a transcript crossed to different bytes")
    }

    @Test("same partialMD5, neither hashed in full: nothing propagates")
    func sameSampleNoDigest_propagatesNothing() {
        let model = VideoScanModel()
        let dated = Self.record("/A/clip.dv", md5: "HEADTAIL", digestSeed: nil, ocrDates: Self.christmas1987)
        let other = Self.record("/B/clip.dv", md5: "HEADTAIL", digestSeed: nil)
        model.records = [dated, other]

        #expect(model.backfillDossierAcrossDuplicates() == 0)
        #expect(other.ocrDateCandidates.isEmpty, "no whole-file digest is no proof of same content")
    }

    @Test("a row whose content and archive fixities disagree names no identity")
    func disagreeingFixities_propagateNothing() {
        let model = VideoScanModel()
        let dated = Self.record("/A/clip.dv", md5: "HEADTAIL", digestSeed: "x", ocrDates: Self.christmas1987)
        let other = Self.record("/B/clip.dv", md5: "HEADTAIL", digestSeed: "x")
        other.archiveFixity = ArchiveFixity(digest: Self.digest("y"), verifiedAt: Date(), sizeBytes: other.sizeBytes)
        model.records = [dated, other]

        #expect(model.backfillDossierAcrossDuplicates() == 0)
        #expect(other.ocrDateCandidates.isEmpty, "two full hashes that disagree are not trusted (§f row 2)")
    }

    @Test("equivalence: one whole-file digest, one partialMD5 — propagation is unchanged")
    func sameDigest_propagatesAsBefore() {
        let model = VideoScanModel()
        let dated = Self.record("/A/clip.dv", md5: "HEADTAIL", digestSeed: "same", ocrDates: Self.christmas1987)
        let other = Self.record("/B/clip.dv", md5: "HEADTAIL", digestSeed: "same")
        model.records = [dated, other]

        #expect(model.backfillDossierAcrossDuplicates() == 1)
        #expect(other.ocrDateCandidates.map(\.text) == ["DEC 25 1987"])
    }

    @Test("the digest is the identity: copies with no partialMD5 still share")
    func sameDigestDifferentSample_propagates() {
        let model = VideoScanModel()
        let dated = Self.record("/A/clip.dv", md5: "", digestSeed: "same", ocrDates: Self.christmas1987)
        let other = Self.record("/B/clip.dv", md5: "", digestSeed: "same")
        model.records = [dated, other]

        #expect(model.backfillDossierAcrossDuplicates() == 1)
        #expect(other.ocrDateCandidates.map(\.text) == ["DEC 25 1987"])
    }

    @Test("an archive copy's fixity is its whole-file digest (it carries no content fixity)")
    func archiveFixityIsAWholeFileDigestToo() {
        let model = VideoScanModel()
        let archived = Self.record("/Archive/clip.dv", md5: "", digestSeed: nil, ocrDates: Self.christmas1987)
        archived.archiveFixity = ArchiveFixity(digest: Self.digest("same"), verifiedAt: Date(),
                                               sizeBytes: archived.sizeBytes)
        let copy = Self.record("/A/clip.dv", md5: "", digestSeed: "same")
        model.records = [archived, copy]

        #expect(model.backfillDossierAcrossDuplicates() == 1)
        #expect(copy.ocrDateCandidates.map(\.text) == ["DEC 25 1987"])
    }
}
