// RelatedLadderTests.swift
// The ladder of evidence, as a truth table: every rung, every band, every
// contradiction and non-clue, the "not enough evidence" floor, the better
// transfer — on the Timmy's 10th shapes from the 2026-10-14 match run.

import Testing
@testable import VideoScanCore

private func day(_ y: Int, _ m: Int, _ d: Int) -> EventDay { EventDay(year: y, month: m, day: d) }
private typealias Side = RelatedEvidence.Side

private let master = Side(digest: "4f1d" + String(repeating: "0", count: 56) + "b2a8", sizeBytes: 4_300_000_000, durationSeconds: 2280,
                          audibleSeconds: 2150, day: day(1996, 4, 22), dayIsReliable: true,
                          people: ["Timmy", "Donna", "Dan", "Matt"], namesSaid: ["Timmy", "Donna"], occasionWords: ["happy birthday", "cake"],
                          folderLabel: "Timmy 10th Bday", isArchiveFile: true, isArchived: true, codec: .original, frameHeight: 480, bitRate: 40_000_000)
private let part1 = Side(digest: "a7c3" + String(repeating: "1", count: 56) + "91e0", sizeBytes: 92_000_000, durationSeconds: 78,
                         audibleSeconds: 76, day: day(1996, 4, 22), dayIsReliable: false,
                         people: ["Timmy", "Donna"], namesSaid: ["Timmy"], occasionWords: ["happy birthday"],
                         folderLabel: "iMovie Events", codec: .delivery, frameHeight: 480, bitRate: 9_000_000)
private let vob = Side(digest: "0c88" + String(repeating: "2", count: 56) + "7e31", sizeBytes: 1_000_000_000, durationSeconds: 2250,
                       audibleSeconds: 2120, day: day(2006, 1, 9), dayIsReliable: false,
                       people: ["Timmy", "Donna", "Dan", "Matt"], namesSaid: ["Timmy", "Donna"], occasionWords: ["happy birthday", "cake"],
                       folderLabel: "Timmy 10th Bday Restored", codec: .delivery, frameHeight: 480, bitRate: 6_000_000)
private let mark84 = Side(digest: "9b21" + String(repeating: "3", count: 56) + "c4d7", sizeBytes: 2_800_000_000, durationSeconds: 1500,
                          audibleSeconds: 1400, day: day(1984, 6, 10), dayIsReliable: true,
                          people: ["Mark", "Donna", "Rick"], namesSaid: ["Mark"], occasionWords: ["happy birthday", "candles"],
                          folderLabel: "Mark Bday 1984", isArchiveFile: true, isArchived: true, codec: .original)

private func kinds(_ v: RelatedVerdict) -> [RelatedLine.Kind] { v.lines.map(\.kind) }
private func has(_ v: RelatedVerdict, _ kind: RelatedLine.Kind, _ text: String) -> Bool {
    v.lines.contains { $0.kind == kind && $0.words.contains(text) }
}

@Suite("Related ladder — rungs and bands")
struct RelatedLadderTests {

    @Test("no whole-file hash on a side: the ladder says so instead of staying silent (Rick 2026-10-16)")
    func missingFullHashIsSaid() {
        let a = RelatedEvidence.Side(sizeBytes: 100, durationSeconds: 60, audibleSeconds: 50)
        let b = RelatedEvidence.Side(digest: String(repeating: "b", count: 64), sizeBytes: 100, durationSeconds: 60, audibleSeconds: 50)
        let v = RelatedLadder.judge(RelatedEvidence(a: a, b: b, audio: .sameRecording, audioCoverage: 0.99))
        #expect(v.rung == .sameRecording && !v.isIdenticalCopy)
        #expect(has(v, .missing, "No whole-file SHA-256 for the first file"))
        let both = RelatedLadder.judge(RelatedEvidence(a: a, b: RelatedEvidence.Side(sizeBytes: 100, durationSeconds: 60, audibleSeconds: 50), audio: .sameRecording, audioCoverage: 0.99))
        #expect(has(both, .missing, "for either file"))
    }

    @Test("rung 6: the same SHA-256 and size is an identical copy, whatever the sound says")
    func identicalCopy() {
        var copy = master; copy.isArchiveFile = false; copy.isArchived = true; copy.folderLabel = "Mirror"
        let v = RelatedLadder.judge(RelatedEvidence(a: master, b: copy, audio: .different))
        #expect(v.rung == .identicalCopy && v.band == .sameEvent && v.isIdenticalCopy)
        #expect(has(v, .supports, "SHA-256 equal") && has(v, .supports, "seen in both"))
        #expect(v.headline == "The same recording, byte for byte.")
    }

    @Test("rung 5: the clip is contained in the master — light green, with its length and offset")
    func clipOfMaster() {
        let v = RelatedLadder.judge(RelatedEvidence(a: part1, b: master, audio: .containedInMaster(offsetSeconds: 376), audioCoverage: 0.96))
        #expect(v.rung == .sameRecording)
        #expect(v.band == .clipFromSameEvent(clip: .a, seconds: 78, offsetSeconds: 376))
        #expect(v.headline == "A 1:18 clip cut from the other at 6:16.")
        #expect(has(v, .supports, "96 %") && has(v, .differs, "SHA-256 differs") && has(v, .differs, "Codecs differ"))
        #expect(has(v, .nonClue, "one date is not reliable"), "\(v.lines)")
        #expect(has(v, .nonClue, "happy birthday"))
        #expect(v.better == nil)
    }

    @Test("rung 5 the other way round: the master is the query, the clip the master")
    func masterContainsClip() {
        let v = RelatedLadder.judge(RelatedEvidence(a: master, b: part1, audio: .masterContainedInQuery(offsetSeconds: 376), audioCoverage: 0.96))
        #expect(v.band == .clipFromSameEvent(clip: .b, seconds: 78, offsetSeconds: 376))
    }

    @Test("rung 5: two transfers of one recording — the unreliable DVD date is a non-clue, the master is the better transfer")
    func sameRecordingOtherTransfer() {
        let v = RelatedLadder.judge(RelatedEvidence(a: vob, b: master, audio: .sameRecording, audioCoverage: 0.99))
        #expect(v.rung == .sameRecording && v.band == .sameEvent)
        #expect(has(v, .supports, "99 %") && has(v, .nonClue, "File dates differ"))
        #expect(!has(v, .contradicts, "Dates disagree"), "an unreliable date never contradicts")
        #expect(v.better == .b(why: "an original-generation codec; the other is a delivery re-encode"), "\(String(describing: v.better))")
    }

    @Test("better transfer: audible length first (by more than 5 %), then codec generation, frame size, bit rate; else a tie")
    func betterTransferOrder() {
        var longer = vob; longer.audibleSeconds = 2400; longer.durationSeconds = 2500
        var lines: [RelatedLine] = []
        #expect(RelatedLadder.betterTransfer(RelatedEvidence(a: longer, b: master), into: &lines) == .a(why: "longer: 40:00 vs 35:50"))
        var sameCodec = vob; sameCodec.codec = .original; sameCodec.frameHeight = 576
        #expect(RelatedLadder.betterTransfer(RelatedEvidence(a: sameCodec, b: master), into: &lines) == .a(why: "larger frame: 576 vs 480 lines"))
        sameCodec.frameHeight = 480; sameCodec.bitRate = 50_000_000
        #expect(RelatedLadder.betterTransfer(RelatedEvidence(a: sameCodec, b: master), into: &lines) == .a(why: "higher bit rate"))
        sameCodec.bitRate = 40_000_000
        #expect(RelatedLadder.betterTransfer(RelatedEvidence(a: sameCodec, b: master), into: &lines) == .tie)
    }

    @Test("rung 4: a short overlap at one offset is two cameras at one moment — yellow, with the shared seconds")
    func sameMoment() {
        var cam2 = Side(digest: "e5a0" + String(repeating: "4", count: 56) + "3c19", sizeBytes: 860_000_000, durationSeconds: 240, audibleSeconds: 230,
                        day: day(1996, 4, 22), dayIsReliable: true, people: ["Timmy", "Donna", "Rick"], occasionWords: ["happy birthday"], codec: .original)
        let v = RelatedLadder.judge(RelatedEvidence(a: cam2, b: master, audio: .overlap(offsetSeconds: 1180, seconds: 19)))
        #expect(v.rung == .sameMoment && v.band == .differentCapture(sharedSeconds: 19))
        #expect(has(v, .supports, "19 s shared at 19:40") && has(v, .supports, "Same day") && has(v, .supports, "Donna, Timmy seen in both"))
        cam2.day = day(1997, 4, 22)
        let conflict = RelatedLadder.judge(RelatedEvidence(a: cam2, b: master, audio: .overlap(offsetSeconds: 1180, seconds: 19)))
        #expect(conflict.rung == .related, "a reliable date conflict blocks rung 4; the people keep it related — \(conflict.rung as Any)")
        #expect(has(conflict, .contradicts, "reliable dates disagree"))
    }

    @Test("rung 4 needs at least the minimum shared seconds; less is 'nothing in common'")
    func overlapTooShort() {
        let v = RelatedLadder.judge(RelatedEvidence(a: part1, b: mark84, audio: .overlap(offsetSeconds: 10, seconds: 2)))
        #expect(v.rung != .sameMoment && has(v, .contradicts, "nothing in common"))
    }

    @Test("rung 3: no shared sound, but the same reliable day and people in common — yellow, zero shared seconds")
    func sameOccasion() {
        var still = Side(sizeBytes: 50_000_000, durationSeconds: 60, audibleSeconds: 0, day: day(1996, 4, 22), dayIsReliable: true,
                         people: ["Timmy"], folderLabel: "Timmy 10th Bday")
        let v = RelatedLadder.judge(RelatedEvidence(a: still, b: master, audio: nil))
        #expect(v.rung == .sameOccasion && v.band == .differentCapture(sharedSeconds: 0))
        #expect(has(v, .nonClue, "No sound in the first file") && has(v, .supports, "Same folder label"))
        still.day = day(1996, 4, 23)
        #expect(RelatedLadder.judge(RelatedEvidence(a: still, b: master)).rung == .sameOccasion, "the day after counts as the same day")
    }

    @Test("rung 2: people in common on a different day is related, red band; rung 1: nothing in common at all")
    func relatedAndNone() {
        let v = RelatedLadder.judge(RelatedEvidence(a: mark84, b: master, audio: .different))
        #expect(v.rung == .related && v.band == .differentEvents)
        #expect(has(v, .contradicts, "Dates disagree: Jun 10, 1984 vs Apr 22, 1996") && has(v, .supports, "Donna seen in both"))
        #expect(has(v, .nonClue, "happy birthday"))
        var stranger = mark84; stranger.people = ["Uncle Terry"]; stranger.namesSaid = []; stranger.folderLabel = "Reels"
        let n = RelatedLadder.judge(RelatedEvidence(a: stranger, b: master, audio: .different))
        #expect(n.rung == RelatedRung.none && n.band == .differentEvents)
        #expect(n.headline == "These files do not represent the same event in any way.")
        #expect(has(n, .contradicts, "Different people"))
    }

    @Test("silent footage: the video barcode stands in for the sound — whole or clip")
    func silentFootageByFrames() {
        var silentMaster = master; silentMaster.audibleSeconds = 0
        var silentClip = part1; silentClip.audibleSeconds = 0
        let clip = RelatedLadder.judge(RelatedEvidence(a: silentClip, b: silentMaster, video: .aligned(coverage: 0.9, offsetSeconds: 376)))
        #expect(clip.rung == .sameRecording && clip.band == .clipFromSameEvent(clip: .a, seconds: 78, offsetSeconds: 376))
        var silentCopy = silentMaster; silentCopy.digest = "ffff"; silentCopy.isArchived = false; silentCopy.isArchiveFile = false
        let whole = RelatedLadder.judge(RelatedEvidence(a: silentCopy, b: silentMaster, video: .aligned(coverage: 0.99, offsetSeconds: 0)))
        #expect(whole.band == .sameEvent && whole.better != nil)
        let none = RelatedLadder.judge(RelatedEvidence(a: silentClip, b: silentMaster, video: .noRunInCommon))
        #expect(has(none, .contradicts, "no run in common") && none.rung != .sameRecording)
    }

    @Test("not enough evidence: no fingerprints, no reliable dates, no people — grey, with the missing lines")
    func notEnoughEvidence() {
        let a = Side(sizeBytes: 10, durationSeconds: 60), b = Side(sizeBytes: 20, durationSeconds: 60, day: day(1990, 1, 1))
        let v = RelatedLadder.judge(RelatedEvidence(a: a, b: b))
        #expect(v.rung == nil && v.band == .notEnoughEvidence)
        #expect(has(v, .missing, "No sound fingerprint yet for either file"))
        let inc = RelatedLadder.judge(RelatedEvidence(a: a, b: b, audio: .inconclusive(reason: .bothIncomplete)))
        #expect(inc.band == .notEnoughEvidence && has(inc, .missing, "both fingerprints are partial"))
    }

    @Test("a different-sound verdict with evidence present is never 'not enough': it is a real answer")
    func differentIsAnAnswer() {
        let a = Side(sizeBytes: 10, durationSeconds: 60, audibleSeconds: 50), b = Side(sizeBytes: 20, durationSeconds: 60, audibleSeconds: 50)
        let v = RelatedLadder.judge(RelatedEvidence(a: a, b: b, audio: .different))
        #expect(v.rung == RelatedRung.none && v.band == .differentEvents)
    }

    @Test("a file that is not on disk gets no verdict — even when the catalog's stored hashes say identical (Rick 2026-10-15)")
    func notOnDisk() {
        var gone = master; gone.isOnDisk = false
        var here = master; here.isOnDisk = true; here.isArchiveFile = false
        let v = RelatedLadder.judge(RelatedEvidence(a: gone, b: here, audio: .sameRecording, audioCoverage: 1))
        #expect(v.rung == nil && v.band == .notEnoughEvidence)
        #expect(v.headline == "One file is not on disk — nothing can be verified.")
        #expect(has(v, .missing, "The first file is not at its path") && has(v, .nonClue, "stored SHA-256s match"))
        let r = EventRecommendation.recommend(v, evidence: RelatedEvidence(a: gone, b: here))
        #expect(r.rule == .r8 && r.subject == .a && r.words.hasPrefix("Rescan the drive"))
        // Not asked (drive off) is not gone: the ladder runs.
        var unknown = master; unknown.isOnDisk = nil
        #expect(RelatedLadder.judge(RelatedEvidence(a: unknown, b: here)).rung == .identicalCopy)
    }

    @Test("codex 10/15 F3: empty digests never establish identity, so no R1 against an archived counterpart")
    func emptyDigestsCannotAuthorizeCopyRemoval() {
        var archived = master; archived.digest = ""
        var copy = archived; copy.isArchiveFile = false; copy.isArchived = false
        let e = RelatedEvidence(a: copy, b: archived)
        let v = RelatedLadder.judge(e)
        #expect(!v.isIdenticalCopy && copy.digest == nil)
        #expect(EventRecommendation.recommend(v, evidence: e).rule != .r1)
    }

    @Test("codex 10/15 F4: identical bytes with a 'different' sound verdict keep rung 6 AND show the contradiction")
    func identicalCopyStillShowsSoundContradiction() {
        let v = RelatedLadder.judge(RelatedEvidence(a: master, b: master, audio: .different))
        #expect(v.rung == .identicalCopy && has(v, .contradicts, "Sound: nothing in common"))
    }

    @Test("codex r2 F5: an overlap on identical bytes is described as partial, never as 'nothing in common'")
    func identicalCopyOverlapWording() {
        let v = RelatedLadder.judge(RelatedEvidence(a: master, b: master, audio: .overlap(offsetSeconds: 0, seconds: 2000)))
        #expect(v.rung == .identicalCopy && has(v, .contradicts, "only 2000 s matched") && !has(v, .contradicts, "nothing in common"))
    }

    @Test("a year-only date carries its year for the era rule")
    func yearOnly() {
        let s = Side(sizeBytes: 1, durationSeconds: 1, year: 1988)
        #expect(s.year == 1988 && s.day == nil)
        let d = Side(sizeBytes: 1, durationSeconds: 1, day: day(1996, 4, 22))
        #expect(d.year == 1996)
    }

    @Test("words: mm:ss and h:mm:ss, the band words")
    func words() {
        #expect(RelatedLadder.mmss(376) == "6:16" && RelatedLadder.mmss(3725) == "1:02:05" && RelatedLadder.mmss(-3) == "0:00")
        #expect(RelatedBand.clipFromSameEvent(clip: .a, seconds: 1, offsetSeconds: 0).word == "Clip from same event")
        #expect(RelatedBand.differentCapture(sharedSeconds: 0).word == "Same event · different capture")
    }
}
