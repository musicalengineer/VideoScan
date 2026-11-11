// PromoteSoundGateTests.swift
// LOGIC + SCALE for the Promote sound gate (Rick 2026-11-10): "Promote
// measures a video's sound itself when no current measurement exists, and
// refuses a video whose sound is missing, silent or damaged unless the owner
// has marked that file as acceptable without sound."
//
// Pure: PromoteSoundGate's three functions over canned values — what a
// measurement means (`finding`), when the owner's tag speaks for these bytes
// (`mark`) and the decision with its words (`decide`). There is no fourth:
// a stored check is never reused (PromoteSoundGateSensorTests 2b). No file is read, no model built.
// The call site is PromoteSoundGateJobTests; real media is
// PromoteSoundGateMediaMatrixTests.
//
// (For Rick: `#expect` ≈ EXPECT_*, records and carries on; `#require` ≈
// ASSERT_*, stops the test.)

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Promote sound gate — the rule (pure)")
@MainActor
struct PromoteSoundGateTests {

    typealias G = PromoteSoundGate
    typealias S = MasterArchiveTestSupport

    static let digest = String(repeating: "a", count: 64)
    static let other = String(repeating: "b", count: 64)

    static func fixity(_ digest: String = PromoteSoundGateTests.digest, bytes: Int64 = 4_096,
                       at: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> ContentFixity {
        ContentFixity(digest: digest, byteCount: bytes,
                      stamp: FileIdentityStamp(device: 1, inode: 2, size: bytes, mtimeNs: 3, ctimeNs: 4),
                      computedAt: at)
    }

    static func decide(_ finding: G.Finding, mark: G.Mark = .absent, partner: String? = nil,
                       year: Int? = nil) -> G.Decision {
        G.decide(finding: finding, mark: mark, soundPartnerName: partner,
                 recordedYear: year, digestPrefix: "aaaaaaaaaaaa")
    }

    static func refusal(_ d: G.Decision) -> (code: G.Code, detail: String, log: String)? {
        if case .refuse(let code, let detail, let log) = d { return (code, detail, log) }
        return nil
    }

    static func pass(_ d: G.Decision) -> (note: String?, log: String)? {
        if case .promote(let note, let log) = d { return (note, log) }
        return nil
    }

    // MARK: finding(from:) — what a measurement means

    @Test("sound on at least one channel is PRESENT: stereo, dual mono, mono, surround with one live channel, two live tracks")
    func presentShapes() {
        #expect(G.finding(from: S.soundDiagnosis(channels: [-18, -20])) == .present(oneSided: nil, levels: "2 ch: L -18.0, R -20.0 dBFS RMS"))
        #expect(G.finding(from: S.soundDiagnosis(channels: [-25])) == .present(oneSided: nil, levels: "1 ch: mono -25.0 dBFS RMS"))
        if case .present(let side, _) = G.finding(from: S.soundDiagnosis(channels: [-70, -70, -22, -70, -70, -70])) {
            #expect(side == nil)
        } else { Issue.record("surround with one live channel must be present") }
        if case .present(let side, _) = G.finding(from: S.soundDiagnosis(channels: [-18, -.infinity], audioStreams: 2,
                                                                         programStreamCount: 2)) {
            #expect(side == nil, "two live tracks is not 'one side'")
        } else { Issue.record("two live tracks must be present") }
    }

    @Test("one side only: left or right, both channels measured, one stream")
    func oneSided() {
        #expect(G.finding(from: S.soundDiagnosis(channels: [-18, -.infinity]))
                == .present(oneSided: .left, levels: "2 ch: L -18.0, R -inf dBFS RMS"))
        #expect(G.finding(from: S.soundDiagnosis(channels: [-91, -18]))
                == .present(oneSided: .right, levels: "2 ch: L -91.0, R -18.0 dBFS RMS"))
    }

    @Test("Codex #280 F5: a live channel does not excuse an incomplete measurement — one unread channel, or a pass that did not cover every stream, is COULD NOT CHECK")
    func liveChannelDoesNotExcuseAnIncompletePass() {
        func unchecked(_ d: AudioVerifyDiagnosis) -> Bool {
            if case .unchecked = G.finding(from: d) { return true }
            return false
        }
        #expect(unchecked(S.soundDiagnosis(channels: [-18, nil])), "left live, right never read: \(G.finding(from: S.soundDiagnosis(channels: [-18, nil])))")
        #expect(unchecked(S.soundDiagnosis(channels: [-18, -20], levelsComplete: false)), "stereo, but the pass did not cover every stream")
        #expect(unchecked(S.soundDiagnosis(channels: [-18, -.infinity], levelsComplete: false)))
    }

    @Test("the −60 dBFS line: the real archived title (both channels at −68) is SILENT; exactly −60.0 is silent; −59.9 has sound; digital silence is silent")
    func theLine() {
        #expect(G.floorDBFS == -60.0)
        #expect(G.finding(from: S.soundDiagnosis(channels: [-68, -68]))
                == .silent(levels: "2 ch: L -68.0, R -68.0 dBFS RMS", loudestDBFS: -68))
        #expect(G.finding(from: S.soundDiagnosis(channels: [-60, -60]))
                == .silent(levels: "2 ch: L -60.0, R -60.0 dBFS RMS", loudestDBFS: -60))
        if case .present = G.finding(from: S.soundDiagnosis(channels: [-59.9, -80])) {} else {
            Issue.record("−59.9 dBFS is above the line")
        }
        #expect(G.finding(from: S.soundDiagnosis(channels: [-.infinity, -.infinity]))
                == .silent(levels: "2 ch: L -inf, R -inf dBFS RMS", loudestDBFS: -.infinity))
    }

    @Test("a silent SURROUND track is silent — the classifier calls it 'surround' without reading levels; the gate reads them")
    func silentSurround() {
        let d = S.soundDiagnosis(channels: [-70, -72, -.infinity, -90, -75, -80])
        #expect(d.balanceAnalysis?.classification == .multichannel)
        #expect(d.persistedStatus == "ok" && d.persistedNote.hasPrefix("surround audio"),
                "fixture: Verify Audio stores this as ok / surround: \(d.persistedNote)")
        if case .silent(_, let loudest) = G.finding(from: d) { #expect(loudest == -70) } else {
            Issue.record("six channels under the line are silent: \(G.finding(from: d))")
        }
    }

    @Test("no audio stream is NO TRACK; damage outranks everything the levels say")
    func noTrackAndDamage() {
        #expect(G.finding(from: S.soundDiagnosis(channels: [], audioStreams: 0)) == .noTrack)
        let short = S.soundDiagnosis(channels: [-18, -20],
                                     extraFindings: [.durationMismatch(audioSeconds: 2, videoSeconds: 10)])
        #expect(G.finding(from: short) == .damaged("audio shorter than video (2s vs 10s)"))
        let badCodec = S.soundDiagnosis(channels: [-18, -20], extraFindings: [.unsupportedCodec(codec: "qdm2", decodable: true)])
        #expect(G.finding(from: badCodec) == .damaged("invalid codec (qdm2)"))
        var reference = S.soundDiagnosis(channels: [], audioStreams: 0)
        reference.findings = [.referenceMovie(referencedPaths: ["/Avid MediaFiles/x"])]
        #expect(G.finding(from: reference) == .damaged("reference movie, media missing"),
                "a reference movie is damage, and its paths stay out of the words")
    }

    @Test("Codex #281 F1: a levels pass that FAILED (the probe's 'undecodable') is could-not-check, not 'damaged' — a failed read is not a decoded-and-bad result")
    func failedLevelsPassIsUncheckedNotDamaged() {
        let failed = S.soundDiagnosis(channels: [-18, -20], extraFindings: [.unsupportedCodec(codec: "aac", decodable: false)])
        guard case .unchecked(let why) = G.finding(from: failed) else {
            Issue.record("a failed levels pass must be could-not-check: \(G.finding(from: failed))"); return
        }
        #expect(why.contains("could not be decoded (aac)"), "\(why)")
        // Real, decoded evidence of damage still says damaged — alone or beside a failed pass.
        let both = S.soundDiagnosis(channels: [-18, -20], extraFindings: [.unsupportedCodec(codec: "aac", decodable: false),
                                                                           .durationMismatch(audioSeconds: 2, videoSeconds: 10)])
        #expect(G.finding(from: both) == .damaged("audio shorter than video (2s vs 10s)"))
        let legacy = S.soundDiagnosis(channels: [-18, -20], extraFindings: [.unsupportedCodec(codec: "qdm2", decodable: true)])
        #expect(G.finding(from: legacy) == .damaged("invalid codec (qdm2)"))
    }

    @Test("an incomplete measurement is COULD NOT CHECK, never silent and never a pass")
    func incompleteIsUnchecked() {
        func unchecked(_ d: AudioVerifyDiagnosis) -> Bool {
            if case .unchecked = G.finding(from: d) { return true }
            return false
        }
        #expect(unchecked(S.soundDiagnosis(channels: [nil, nil])), "no channel was read")
        #expect(unchecked(S.soundDiagnosis(channels: [-.infinity, nil])), "one channel silent, one not read")
        #expect(unchecked(S.soundDiagnosis(channels: [-70, -70], levelsComplete: false)), "the pass did not cover every stream")
        var noAnalysis = S.soundDiagnosis(channels: [-18, -20])
        noAnalysis.balanceAnalysis = nil
        noAnalysis.findings = []
        #expect(unchecked(noAnalysis), "a sound track nobody decoded")
    }

    // MARK: decide — the outcomes and their words

    @Test("present promotes with no note; one-sided promotes and says which side")
    func presentDecisions() throws {
        let plain = try #require(Self.pass(Self.decide(.present(oneSided: nil, levels: "2 ch: L -18.0, R -20.0 dBFS RMS"))))
        #expect(plain.note == nil)
        #expect(plain.log == "present — 2 ch: L -18.0, R -20.0 dBFS RMS, floor -60.0, sha256 aaaaaaaaaaaa…")
        let left = try #require(Self.pass(Self.decide(.present(oneSided: .left, levels: "2 ch: L -18.0, R -inf dBFS RMS"))))
        #expect(left.note == "sound on the left side only")
        #expect(left.log == "present, left only — 2 ch: L -18.0, R -inf dBFS RMS, floor -60.0, sha256 aaaaaaaaaaaa…")
        let right = try #require(Self.pass(Self.decide(.present(oneSided: .right, levels: "2 ch: L -inf, R -18.0 dBFS RMS"))))
        #expect(right.note == "sound on the right side only")
    }

    @Test("no track: refused in plain words that name the exact tag; nothing about a partner in the log")
    func noTrackRefusal() throws {
        let r = try #require(Self.refusal(Self.decide(.noTrack)))
        #expect(r.code == .noTrack && r.code.rawValue == "sound-none")
        #expect(r.detail == "Not promoted — this file has no sound track. If that is right for this file, tag it “Silent — checked” and promote again. Nothing was copied.")
        #expect(r.log == "no audio stream, no owner tag; nothing written")
    }

    @Test("before 1980 the file needs the mark like any other; the words add a hint and nothing more")
    func before1980() throws {
        let old = try #require(Self.refusal(Self.decide(.noTrack, year: 1962)))
        #expect(old.code == .noTrack)
        #expect(old.detail.contains("(film before 1980 is often silent)"))
        let silentOld = try #require(Self.refusal(Self.decide(.silent(levels: "x", loudestDBFS: -70), year: 1979)))
        #expect(silentOld.code == .silent && silentOld.detail.contains("film before 1980 is often silent"))
        #expect(Self.refusal(Self.decide(.noTrack, year: 1980))?.detail.contains("1980") == false)
        #expect(Self.refusal(Self.decide(.noTrack, year: nil))?.detail.contains("1980") == false)
    }

    @Test("silent: refused with the measured number; digital silence says so")
    func silentRefusal() throws {
        let r = try #require(Self.refusal(Self.decide(.silent(levels: "2 ch: L -68.1, R -70.0 dBFS RMS", loudestDBFS: -68.1))))
        #expect(r.code == .silent && r.code.rawValue == "sound-silent")
        #expect(r.detail.hasPrefix("Not promoted — the sound track is silent: every channel is under -60.0 dBFS (loudest -68.1)."))
        #expect(r.detail.contains("tag it “Silent — checked”") && r.detail.hasSuffix("Nothing was copied."))
        #expect(r.log == "every channel under -60.0 dBFS RMS (2 ch: L -68.1, R -70.0 dBFS RMS), no owner tag; nothing written")
        let digital = try #require(Self.refusal(Self.decide(.silent(levels: "x", loudestDBFS: -.infinity))))
        #expect(digital.detail.contains("(digital silence)"))
    }

    @Test("the picture half of a pair: refused, names the partner and points at Combine This Pair…; the log names no file")
    func pairHalf() throws {
        let r = try #require(Self.refusal(Self.decide(.noTrack, partner: "Christmas 1994.A01.mxf")))
        #expect(r.code == .pairHalf && r.code.rawValue == "sound-pair-half")
        #expect(r.detail == "Not promoted — this is the picture half of a pair; its sound is in Christmas 1994.A01.mxf. Use Combine This Pair…, then promote the combined file. Nothing was copied.")
        #expect(!r.log.contains("Christmas"), "persistent lines carry no names: \(r.log)")
        #expect(r.log.contains("a sound partner is catalogued"))
    }

    @Test("the owner's tag accepts no-track and silent — and a tagged pair half promotes alone, the partner recorded")
    func tagAccepts() throws {
        let none = try #require(Self.pass(Self.decide(.noTrack, mark: .accepted)))
        #expect(none.note == "no sound track — you tagged this file “Silent — checked”")
        #expect(none.log == "no audio stream, accepted — owner tag \"Silent — checked\", sha256 aaaaaaaaaaaa…")
        let silent = try #require(Self.pass(Self.decide(.silent(levels: "2 ch: L -68.0, R -68.0 dBFS RMS", loudestDBFS: -68), mark: .accepted)))
        #expect(silent.note == "silent sound track — you tagged this file “Silent — checked”")
        #expect(silent.log.contains("owner tag \"Silent — checked\", sha256 aaaaaaaaaaaa…") && silent.log.contains("L -68.0"))
        let half = try #require(Self.pass(Self.decide(.noTrack, mark: .accepted, partner: "sound.mxf")))
        #expect(half.log.hasSuffix("; a sound partner is catalogued") && !half.log.contains("sound.mxf"))
    }

    @Test("the tag NEVER lifts damaged sound or could-not-check, and a tag not tied to these bytes accepts nothing")
    func tagLimits() throws {
        for mark in [G.Mark.absent, .accepted, .notTiedToTheseBytes] {
            let damaged = try #require(Self.refusal(Self.decide(.damaged("audio shorter than video (2s vs 10s)"), mark: mark)))
            #expect(damaged.code == .damaged && damaged.code.rawValue == "sound-damaged")
            #expect(damaged.detail == "Not promoted — the sound is damaged: audio shorter than video (2s vs 10s). Right-click ▸ Repair… shows the fix. Nothing was copied.")
            let unchecked = try #require(Self.refusal(Self.decide(.unchecked("ffprobe exited with status 1"), mark: mark)))
            #expect(unchecked.code == .unchecked && unchecked.code.rawValue == "sound-unchecked")
            #expect(unchecked.detail.contains("Could not check is not a pass") && unchecked.detail.contains("ffprobe exited with status 1"))
        }
        let stale = try #require(Self.refusal(Self.decide(.noTrack, mark: .notTiedToTheseBytes)))
        #expect(stale.code == .noTrack)
        #expect(stale.detail.hasSuffix("The “Silent — checked” tag on it was given to an earlier version of this file — tag it again if it still applies."))
        #expect(stale.log.contains("owner tag not tied to these bytes"))
        let staleSilent = try #require(Self.refusal(Self.decide(.silent(levels: "x", loudestDBFS: -70), mark: .notTiedToTheseBytes)))
        #expect(staleSilent.code == .silent && staleSilent.detail.contains("earlier version"))
    }

    @Test("the owner's “Archive anyway” tick accepts ONE thing — a sound that could not be checked — and never a measured refusal")
    func theTickAcceptsOnlyCouldNotCheck() throws {
        func ticked(_ finding: G.Finding, mark: G.Mark = .absent) -> G.Decision {
            G.decide(finding: finding, mark: mark, soundPartnerName: nil, recordedYear: nil, digestPrefix: "aaaaaaaaaaaa",
                     ownerAcceptsUnchecked: true)
        }
        let accepted = try #require(Self.pass(ticked(.unchecked("ffprobe exited with status 1"))))
        #expect(accepted.note == "sound not checked — archived on your “Archive anyway” tick")
        #expect(accepted.log == "not checked (ffprobe exited with status 1), accepted — owner's \"Archive anyway\" tick, sha256 aaaaaaaaaaaa…")
        #expect(Self.refusal(ticked(.silent(levels: "x", loudestDBFS: -70)))?.code == .silent)
        #expect(Self.refusal(ticked(.noTrack))?.code == .noTrack)
        #expect(Self.refusal(G.decide(finding: .noTrack, mark: .absent, soundPartnerName: "s.mxf", recordedYear: nil,
                                      digestPrefix: "", ownerAcceptsUnchecked: true))?.code == .pairHalf)
        #expect(Self.refusal(ticked(.damaged("x")))?.code == .damaged)
        #expect(!ticked(.present(oneSided: nil, levels: "x")).isRefusal)
        // Without the tick, could-not-check is refused whatever the tag says.
        #expect(Self.refusal(Self.decide(.unchecked("x"), mark: .accepted))?.code == .unchecked)
    }

    @Test("precedence: could not check, then damaged, then no track / silent, then present")
    func precedence() {
        // finding(from:) already orders damage over levels; decide never turns a refusal into a pass.
        for finding in [G.Finding.unchecked("x"), .damaged("x"), .noTrack, .silent(levels: "x", loudestDBFS: -70)] {
            #expect(Self.decide(finding).isRefusal)
        }
        #expect(!Self.decide(.present(oneSided: nil, levels: "")).isRefusal)
    }

    // MARK: mark — when the owner's tag speaks for these bytes

    @Test("the tag binds to the digest it is stored under; a never-fingerprinted record binds by size")
    func markBinding() {
        func mark(_ tags: [String], fixity: ContentFixity? = Self.fixity(), proven: String = Self.digest,
                  recordSize: Int64 = 4_096, provenSize: Int64 = 4_096) -> G.Mark {
            G.mark(tags: tags, storedFixity: fixity, provenDigest: proven, recordSizeBytes: recordSize, provenSizeBytes: provenSize)
        }
        #expect(G.ownerTag == "Silent — checked")
        #expect(mark([]) == .absent)
        #expect(mark(["Gold"]) == .absent)
        #expect(mark(["Silent - checked"]) == .absent, "a near-miss spelling (hyphen) is not the tag")
        #expect(mark(["Silent OK"]) == .absent)
        #expect(mark(["Gold", "Silent — checked"]) == .accepted)
        #expect(mark(["SILENT — CHECKED"]) == .accepted, "matched case-insensitively, like every tag")
        #expect(mark(["Silent — checked"], proven: Self.digest.uppercased()) == .accepted)
        #expect(mark(["Silent — checked"], proven: Self.other) == .notTiedToTheseBytes,
                "the record's fingerprint names other bytes: the tag does not cross")
        #expect(mark(["Silent — checked"], proven: "") == .notTiedToTheseBytes)
        #expect(mark(["Silent — checked"], fixity: nil) == .accepted, "never fingerprinted, same size")
        #expect(mark(["Silent — checked"], fixity: nil, recordSize: 4_096, provenSize: 4_097) == .notTiedToTheseBytes)
        #expect(mark(["Silent — checked"], fixity: nil, recordSize: 0, provenSize: 0) == .notTiedToTheseBytes)
    }

    // MARK: Words at the edges

    @Test("could-not-check reasons name no file; Archive Angel's words follow the code; the finished row shows the first refusal")
    func edgeWords() {
        #expect(G.uncheckedReason(AudioVerifyProbeError.toolUnavailable("x")) == "the audio tools (ffmpeg / ffprobe) are not available")
        #expect(G.uncheckedReason(AudioVerifyProbeError.probeFailed("ffprobe exited with status 1")) == "ffprobe exited with status 1")
        #expect(G.uncheckedReason(AudioBalanceProbeError.timedOut(afterSeconds: 300)) == "the check ran out of time after 300 seconds")
        #expect(G.uncheckedReason(CocoaError(.fileReadNoSuchFile)) == "the check failed to run")

        #expect(ArchiveAngelPromoter.soundRefusalWords(code: "sound-none", detail: "d") == "Needs your OK: no sound — d")
        #expect(ArchiveAngelPromoter.soundRefusalWords(code: "sound-silent", detail: "d") == "Needs your OK: no sound — d")
        #expect(ArchiveAngelPromoter.soundRefusalWords(code: "sound-pair-half", detail: "d") == "Needs your OK: no sound — d")
        #expect(ArchiveAngelPromoter.soundRefusalWords(code: "sound-damaged", detail: "d") == "Needs repair: sound damaged — d")
        #expect(ArchiveAngelPromoter.soundRefusalWords(code: "sound-unchecked", detail: "d") == "Could not check the sound — d")
        #expect(ArchiveAngelPromoter.soundRefusalWords(code: "duplicate", detail: "d") == nil)
        #expect(ArchiveAngelPromoter.soundRefusalWords(code: nil, detail: "d") == nil)

        // The job's codes and the gate's are one list.
        for code in G.Code.allCases {
            #expect(PromoteToArchiveJob.Refusal.Code(rawValue: code.rawValue)?.isSound == true, "\(code.rawValue)")
        }
        #expect(!PromoteToArchiveJob.Refusal.Code.duplicate.isSound)

        #expect(PromoteToArchiveJob.soundRefusalSubtitle(summary: "Promoted 0 · skipped 0 · failed 1", rows: []) == nil)
        #expect(PromoteToArchiveJob.soundRefusalSubtitle(summary: "S", rows: ["a.mov: why"]) == "S — a.mov: why")
        #expect(PromoteToArchiveJob.soundRefusalSubtitle(summary: "S", rows: ["a.mov: why", "b", "c"])
                == "S — a.mov: why (and 2 more refused for their sound)")
    }

    // MARK: Scale

    @Test("SCALE: 100,000 files through finding + mark + decide in under a second", .timeLimit(.minutes(1)))
    func scale() {
        let fixity = Self.fixity()
        let diagnoses = [S.soundDiagnosis(channels: [-18, -20]), S.soundDiagnosis(channels: [-18, -.infinity]),
                         S.soundDiagnosis(channels: [-68, -68]), S.soundDiagnosis(channels: [], audioStreams: 0),
                         S.soundDiagnosis(channels: [-70, -72, -.infinity, -90, -75, -80]), S.soundDiagnosis(channels: [-18, nil])]
        let start = Date()
        var promoted = 0, refused = 0
        for i in 0..<100_000 {
            let finding = G.finding(from: diagnoses[i % diagnoses.count])
            let mark = G.mark(tags: i % 11 == 0 ? ["Silent — checked"] : ["Gold"], storedFixity: fixity,
                              provenDigest: Self.digest, recordSizeBytes: 4_096, provenSizeBytes: 4_096)
            if G.decide(finding: finding, mark: mark, soundPartnerName: nil, recordedYear: 1994,
                        digestPrefix: "aaaaaaaaaaaa").isRefusal { refused += 1 } else { promoted += 1 }
        }
        let elapsed = -start.timeIntervalSinceNow
        #expect(promoted + refused == 100_000 && promoted > 0 && refused > 0)
        #expect(elapsed < 1.0, "100k decisions took \(String(format: "%.2f", elapsed))s")
    }
}
