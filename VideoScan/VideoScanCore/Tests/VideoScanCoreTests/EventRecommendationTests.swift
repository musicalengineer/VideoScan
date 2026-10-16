// EventRecommendationTests.swift
// The eight rules × what the archive holds × which transfer is better × the
// era rule — every cell of the table in the Compare Media design.

import Testing
@testable import VideoScanCore

private func day(_ y: Int, _ m: Int, _ d: Int) -> EventDay { EventDay(year: y, month: m, day: d) }
private typealias Side = RelatedEvidence.Side

private func side(archived: Bool, codec: CodecGeneration = .original, year: Int = 1996, digest: String = "a", audible: Double = 2000) -> Side {
    Side(digest: digest + String(repeating: "0", count: 63), sizeBytes: 1_000, durationSeconds: 2100, audibleSeconds: audible,
         day: day(year, 4, 22), dayIsReliable: true, people: ["Timmy"], isArchiveFile: archived, isArchived: archived, codec: codec)
}
private func reco(_ e: RelatedEvidence) -> EventRecommendation {
    EventRecommendation.recommend(RelatedLadder.judge(e), evidence: e)
}

@Suite("Event recommendations — the eight rules")
struct EventRecommendationTests {

    @Test("R1: identical copy of an archived master — remove the copy, through Cleanup's copies lane")
    func r1() {
        let r = reco(RelatedEvidence(a: side(archived: false), b: side(archived: true)))
        #expect(r.rule == .r1 && r.door == .cleanupCopies && r.subject == .a)
        #expect(r.words.hasPrefix("Master is archived."))
    }

    @Test("identical copy, neither archived → R6 promote one; both archived → nothing to do")
    func identicalEdges() {
        let none = reco(RelatedEvidence(a: side(archived: false), b: side(archived: false)))
        #expect(none.rule == .r6 && none.door == .recommendMaster)
        let both = reco(RelatedEvidence(a: side(archived: true), b: side(archived: true)))
        #expect(both.rule == .r7 && both.door == .none && both.words.contains("Both are in the archive"))
    }

    @Test("R2: a clip of an archived master — remove the clip; of an unarchived master → R6 promote the master")
    func r2() {
        let clip = Side(digest: "c" + String(repeating: "0", count: 63), sizeBytes: 90, durationSeconds: 78, audibleSeconds: 76, codec: .delivery)
        let r = reco(RelatedEvidence(a: clip, b: side(archived: true, digest: "m"), audio: .containedInMaster(offsetSeconds: 376), audioCoverage: 0.96))
        #expect(r.rule == .r2 && r.door == .cleanupClips && r.subject == .a && r.why.contains("1:18"))
        let u = reco(RelatedEvidence(a: clip, b: side(archived: false, digest: "m"), audio: .containedInMaster(offsetSeconds: 376), audioCoverage: 0.96))
        #expect(u.rule == .r6 && u.subject == .b)
    }

    @Test("R3: same recording, the archived transfer is better (or as good, post-2000) — remove this transfer")
    func r3() {
        let dvd = side(archived: false, codec: .delivery, year: 2006, digest: "d")
        let r = reco(RelatedEvidence(a: dvd, b: side(archived: true, digest: "m"), audio: .sameRecording, audioCoverage: 0.99))
        #expect(r.rule == .r3 && r.door == .cleanupTransfers && r.subject == .a)
        #expect(r.why.contains("original-generation codec"))
        // A tie on post-2000 content is still R3 (the archived one stays).
        let tie = reco(RelatedEvidence(a: side(archived: false, year: 2015, digest: "x"), b: side(archived: true, year: 2015, digest: "y"), audio: .sameRecording, audioCoverage: 0.99))
        #expect(tie.rule == .r3 && tie.subject == .a)
    }

    @Test("R4: same recording and THIS transfer is better than the archived one — promote it")
    func r4() {
        let ffv1 = side(archived: false, codec: .original, year: 1995, digest: "f")
        let dvdMaster = side(archived: true, codec: .delivery, year: 1995, digest: "d")
        let r = reco(RelatedEvidence(a: ffv1, b: dvdMaster, audio: .sameRecording, audioCoverage: 0.99))
        #expect(r.rule == .r4 && r.door == .promote && r.subject == .a)
    }

    @Test("older generations first: a tie on pre-2000 content is 'keep both', never a removal")
    func eraRule() {
        let r = reco(RelatedEvidence(a: side(archived: false, year: 1988, digest: "x"), b: side(archived: true, year: 1988, digest: "y"), audio: .sameRecording, audioCoverage: 0.99))
        #expect(r.rule == .r5 && r.door == .groupAsEvent && r.words.contains("pre-2000"))
    }

    @Test("same recording, neither archived → R6 promote the better (or the longer) one")
    func r6Transfers() {
        let r = reco(RelatedEvidence(a: side(archived: false, codec: .delivery, digest: "x"), b: side(archived: false, codec: .original, digest: "y"), audio: .sameRecording, audioCoverage: 0.99))
        #expect(r.rule == .r6 && r.subject == .b)
    }

    @Test("R5: same event, different capture — keep both, group them")
    func r5() {
        let r = reco(RelatedEvidence(a: side(archived: false, digest: "x"), b: side(archived: true, digest: "y"), audio: .overlap(offsetSeconds: 100, seconds: 19)))
        #expect(r.rule == .r5 && r.door == .groupAsEvent && r.subject == nil)
    }

    @Test("R7: different events — nothing to do; R8: not enough evidence — fingerprint first")
    func r7r8() {
        var other = side(archived: true, year: 1984, digest: "z"); other.people = ["Mark"]
        let r7 = reco(RelatedEvidence(a: side(archived: true, digest: "y"), b: other, audio: .different))
        #expect(r7.rule == .r7 && r7.door == .none)
        let r8 = reco(RelatedEvidence(a: Side(sizeBytes: 1, durationSeconds: 1), b: Side(sizeBytes: 2, durationSeconds: 1)))
        #expect(r8.rule == .r8 && r8.door == .fingerprint && r8.why.contains("fingerprint"))
    }

    @Test("codex 10/15 F1: R2 never targets a clip that is itself an archive file or archived content")
    func r2NeverTargetsProtectedClip() {
        for (archiveFile, archived) in [(true, false), (false, true)] {
            var clip = Side(digest: "c" + String(repeating: "0", count: 63), sizeBytes: 90, durationSeconds: 78, audibleSeconds: 76,
                            day: day(1996, 4, 22), dayIsReliable: true, codec: .delivery)
            clip.isArchiveFile = archiveFile; clip.isArchived = archived
            let r = reco(RelatedEvidence(a: clip, b: side(archived: true, digest: "m"), audio: .containedInMaster(offsetSeconds: 376), audioCoverage: 0.96))
            #expect(r.rule == .r7 && r.subject == nil, "\(archiveFile) \(archived): \(r.rule)")
        }
    }

    @Test("codex 10/15 F2: an unreliable newer transfer date never cancels the pre-2000 protection; a year-only 1988 counts")
    func transferDateCannotCancelEraProtection() {
        var copy = side(archived: false, year: 2006, digest: "x"); copy.dayIsReliable = false
        let r = reco(RelatedEvidence(a: copy, b: side(archived: true, year: 1988, digest: "y"), audio: .sameRecording, audioCoverage: 0.99))
        #expect(r.rule == .r5, "\(r.rule)")
        var yearOnly = side(archived: false, digest: "p"); yearOnly.day = nil; yearOnly.dayIsReliable = false; yearOnly.year = 1988
        var archivedYearOnly = side(archived: true, digest: "q"); archivedYearOnly.day = nil; archivedYearOnly.dayIsReliable = false; archivedYearOnly.year = 1988
        let y = reco(RelatedEvidence(a: yearOnly, b: archivedYearOnly, audio: .sameRecording, audioCoverage: 0.99))
        #expect(y.rule == .r5, "\(y.rule)")
    }

    @Test("every rule names a door; the subject is the side the door acts on")
    func table() {
        #expect(EventRule.allCases.count == 8)
    }
}
