// VerifyAudioVerdictConsumerTests.swift
// Review round 1 on GH #467 / #468 (2026-11-11): the readers of a "not
// checked" sound verdict. Each finding is pinned here, seen red first.
//
//   F1  a full check whose sound could not be checked never headlines
//       "Looks healthy"; the headline says the sound was not checked and why.
//   F2  Repair… opens for a sound track that could not be decoded — from the
//       session's diagnosis, or after a relaunch from the card's Sound row.
//   F3  Balance Audio refuses an analysis that is not a complete measurement
//       (an unread channel parses as −inf and would classify one-sided).
//   F4  the Angel's "Already verified" skip never reuses a not-checked
//       diagnosis behind an earlier stored "ok".
//   F5  a stored damaged note never says "undecodable" on the evidence of a
//       failed read.
//
// Pure: values in, values out. No file, no subprocess, no job, no model.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private typealias S = MasterArchiveTestSupport

private func failedPassDiagnosis(codec: String = "aac") -> AudioVerifyDiagnosis {
    var shape = AudioVerifyShape()
    shape.audioStreams = 1
    shape.audioCodec = codec
    return AudioVerifyDiagnosis(findings: [.unsupportedCodec(codec: codec, decodable: false)],
                                shape: shape, balanceAnalysis: nil)
}

/// The Sound row Check Media writes for `d` (a file with a sound track).
private func soundRow(for d: AudioVerifyDiagnosis) throws -> MediaCheck {
    CheckMediaRules.checkSound(.success(d), facts: try CheckMediaFixtures.healthy().facts)
}

private func fullCard(_ rows: [MediaCheck]) -> MediaReportCard {
    MediaReportCard(tier: .full, checkedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    fileSizeBytes: 1000, headline: "", checks: rows)
}

// MARK: - F1

@Suite("Verify Audio verdict consumers — F1 the full-check headline")
struct VerifyAudioVerdictHeadlineTests {

    private let decodeOK = MediaCheck(kind: .decode, verdict: .ok, sentence: "Every frame decoded cleanly.", evidence: [])

    @Test func soundNotCheckedIsNeverLooksHealthy() throws {
        let quick = try CheckMediaFixtures.healthy()
        let checks = [decodeOK,
                      MediaCheck(kind: .sound, verdict: .notRun(reason: "the sound track could not be decoded (aac)"),
                                 sentence: "Not checked.", evidence: [])]
        let headline = CheckMediaRules.headline(checks: checks, quick: quick, tier: .full)
        #expect(headline != CheckMediaRules.fullPassHeadline)
        #expect(!headline.lowercased().contains("healthy") && !headline.contains("nothing wrong"), "\(headline)")
        #expect(headline.hasPrefix("Sound not checked — the sound track could not be decoded (aac)"), "\(headline)")
    }

    @Test("the rows Check Media really writes: a failed pass and a partial pass both name the reason in the headline")
    func theRealRowsHeadline() throws {
        let quick = try CheckMediaFixtures.healthy()
        for (d, words) in [(failedPassDiagnosis(), "could not be decoded (aac)"),
                           (S.soundDiagnosis(channels: [-18, -20], levelsComplete: false), "only partly measured")] {
            let headline = CheckMediaRules.headline(checks: [decodeOK, try soundRow(for: d)], quick: quick, tier: .full)
            #expect(headline.hasPrefix("Sound not checked — ") && headline.contains(words), "\(headline)")
        }
    }

    @Test("a sound pass that threw (the drive stopped answering) is not Looks healthy either")
    func aThrownSoundPassIsNotHealthy() throws {
        let quick = try CheckMediaFixtures.healthy()
        let row = CheckMediaRules.checkSound(.failure(CheckMediaSkip(reason: "the drive went away")), facts: quick.facts)
        let headline = CheckMediaRules.headline(checks: [decodeOK, row], quick: quick, tier: .full)
        #expect(headline.hasPrefix("Sound not checked — the drive went away"), "\(headline)")
    }

    @Test("unchanged: a checked sound row, the quick tier, a worse row elsewhere, and a file with no sound track")
    func theOtherHeadlinesAreUnchanged() throws {
        let quick = try CheckMediaFixtures.healthy()
        let notChecked = try soundRow(for: failedPassDiagnosis())
        let fine = try soundRow(for: S.soundDiagnosis(channels: [-18, -20]))
        #expect(fine.verdict == .ok)
        #expect(CheckMediaRules.headline(checks: [decodeOK, fine], quick: quick, tier: .full) == CheckMediaRules.fullPassHeadline)
        // The quick tier does not include the sound pass: its row says so, and the headline is the quick one.
        let quickRows = CheckMediaRules.quickChecks(quick) + CheckMediaRules.fullRowsNotRun()
        #expect(CheckMediaRules.headline(checks: quickRows, quick: quick, tier: .quick) == CheckMediaRules.quickPassHeadline)
        // A Problem or Warning elsewhere still leads.
        let problem = MediaCheck(kind: .decode, verdict: .problem, sentence: "Decoding found: errors.", evidence: [])
        #expect(CheckMediaRules.headline(checks: [problem, notChecked], quick: quick, tier: .full).hasPrefix("Damaged picture"))
        let warning = MediaCheck(kind: .black, verdict: .warning, sentence: "Black.", evidence: [])
        #expect(CheckMediaRules.headline(checks: [warning, notChecked], quick: quick, tier: .full).hasPrefix("Plays, with 1 thing"))
        // No sound track at all: nothing was there to check (the presence policy owns that row).
        var silentFile = quick
        silentFile.facts.streams.removeAll { $0.kind == .audio }
        #expect(silentFile.facts.audio == nil, "fixture: the sound stream is gone")
        let noTrack = CheckMediaRules.checkSound(nil, facts: silentFile.facts)
        #expect(CheckMediaRules.headline(checks: [decodeOK, noTrack], quick: silentFile, tier: .full) == CheckMediaRules.fullPassHeadline)
    }

    @Test("the job's one-line summary does not put OK in front of 'Sound not checked'")
    @MainActor func theSummaryDoesNotSayOK() throws {
        let quick = try CheckMediaFixtures.healthy()
        let rows = [decodeOK, try soundRow(for: failedPassDiagnosis())]
        let card = CheckMediaRules.card(tier: .full, checks: rows, quick: quick, at: Date())
        let summary = CheckMediaJob.summary([CheckMediaItem(id: UUID(), filename: "a.avi", outcome: .checked(card))])
        #expect(summary.hasPrefix("Sound not checked — "), "\(summary)")
    }
}

// MARK: - F2

@Suite("Verify Audio verdict consumers — F2 Repair stays reachable")
struct VerifyAudioVerdictRepairDoorTests {

    @Test func undecodableTrackStillOpensRepair() {
        var shape = AudioVerifyShape(); shape.audioStreams = 1; shape.audioCodec = "aac"
        let d = AudioVerifyDiagnosis(findings: [.unsupportedCodec(codec: "aac", decodable: false)], shape: shape, balanceAnalysis: nil)
        let row = MediaCheck(kind: .sound, verdict: .notRun(reason: "x"), sentence: "Not checked — x.", evidence: [])
        let card = MediaReportCard(tier: .full, checkedAt: Date(), fileSizeBytes: 1000, headline: "", checks: [row])
        let state = MediaRepairPlan.menuState(card: card, fileSizeBytes: 1000, sound: MediaRepairSoundFacts(diagnosis: d),
                                              reachable: true, selectionCount: 1)
        #expect(state.isEnabled); #expect(!state.help.contains("plays properly"))
        #expect(state == .ready(count: 1))
        let offers = MediaRepairPlan.offers(for: card, sound: MediaRepairSoundFacts(diagnosis: d), originalProtected: false)
        #expect(offers.first { $0.answers == .sound }?.fix == .rebuildAudio, "the fix on offer is Rebuild Audio Track")
    }

    @Test("after a relaunch (no diagnosis in memory) the card's own Sound row keeps the door open")
    func theCardRowAloneOpensRepair() throws {
        let card = fullCard([try soundRow(for: failedPassDiagnosis())])
        let state = MediaRepairPlan.menuState(card: card, fileSizeBytes: 1000, sound: MediaRepairSoundFacts(diagnosis: nil),
                                              reachable: true, selectionCount: 1)
        #expect(state == .ready(count: 1), "\(state)")
    }

    @Test("a not-run Sound row that is NOT 'could not be decoded' earns no rebuild: partial pass, quick tier, a newer clean diagnosis")
    func otherNotRunRowsDoNotOfferRebuild() throws {
        let none = MediaRepairSoundFacts(diagnosis: nil)
        let partial = fullCard([try soundRow(for: S.soundDiagnosis(channels: [-18, -20], levelsComplete: false))])
        #expect(!MediaRepairPlan.menuState(card: partial, fileSizeBytes: 1000, sound: none, reachable: true, selectionCount: 1).isEnabled)
        let quickOnly = fullCard([.notRun(.sound, because: "quick check only — the full check decodes every frame and listens to every sample")])
        #expect(!MediaRepairPlan.menuState(card: quickOnly, fileSizeBytes: 1000, sound: none, reachable: true, selectionCount: 1).isEnabled)
        // The card is from the failed run, but this session measured the track in full: nothing to rebuild.
        let stale = fullCard([try soundRow(for: failedPassDiagnosis())])
        let measured = MediaRepairSoundFacts(diagnosis: S.soundDiagnosis(channels: [-18, -20]))
        #expect(!MediaRepairPlan.menuState(card: stale, fileSizeBytes: 1000, sound: measured, reachable: true, selectionCount: 1).isEnabled)
    }

    @Test("a protected original still says why the sound fix cannot write beside it")
    func protectedOriginalStillRefuses() throws {
        let card = fullCard([try soundRow(for: failedPassDiagnosis())])
        let offer = MediaRepairPlan.offers(for: card, sound: MediaRepairSoundFacts(diagnosis: failedPassDiagnosis()),
                                           originalProtected: true).first { $0.answers == .sound }
        #expect(offer?.unavailableReason == MediaRepairPlan.protectedSoundReason)
    }
}

// MARK: - F3

@Suite("Verify Audio verdict consumers — F3 Balance needs a complete measurement")
struct VerifyAudioVerdictBalanceGateTests {

    @Test func partlyMeasuredTrackIsNeverBalanceable() throws {
        let d = MasterArchiveTestSupport.soundDiagnosis(channels: [-18, nil])
        let analysis = try #require(d.balanceAnalysis)
        #expect(analysis.classification == .leftOnly, "fixture: the unread channel classifies one-sided")
        #expect(BalanceAudioFix.refusalReason(for: analysis) != nil)
    }

    @Test("a pass that skipped a stream is refused too; the same levels measured in full are balanceable")
    func aSkippedStreamIsRefusedAndACompletePassIsNot() throws {
        let partial = try #require(S.soundDiagnosis(channels: [-18, -.infinity], levelsComplete: false).balanceAnalysis)
        let reason = try #require(BalanceAudioFix.refusalReason(for: partial))
        #expect(reason.contains("partly measured"), "\(reason)")
        let complete = try #require(S.soundDiagnosis(channels: [-18, -.infinity]).balanceAnalysis)
        #expect(BalanceAudioFix.refusalReason(for: complete) == nil)
    }

    @Test("the Angel reads a partly measured one-sided track as could-not-check, never fixable")
    func theAngelNeverCallsItFixable() {
        var d = S.soundDiagnosis(channels: [-18, nil])
        d.findings = [.channelImbalance(.leftOnly)]   // a finding pasted on by an older build
        if case .fixable = ArchiveAngelAudioOutcome.from(d) { Issue.record("a partly measured track must not be fixable") }
    }
}

// MARK: - F4

@Suite("Verify Audio verdict consumers — F4 the Angel's already-verified skip")
struct VerifyAudioVerdictAngelReuseTests {

    @Test("an earlier stored ok + a newer cached not-checked diagnosis: verify again, do not reuse")
    func aNotCheckedDiagnosisIsNotReused() {
        for notChecked in [failedPassDiagnosis(), S.soundDiagnosis(channels: [-18, -20], levelsComplete: false)] {
            #expect(ArchiveAngelAudioOutcome.reusableDiagnosis(storedStatus: "ok", cached: notChecked) == nil)
            #expect(ArchiveAngelAudioOutcome.reusableDiagnosis(storedStatus: "damaged", cached: notChecked) == nil)
        }
    }

    @Test("unchanged: a checked diagnosis behind a stored verdict is reused; no stored verdict or no diagnosis is not")
    func checkedDiagnosesAreReused() {
        let fine = S.soundDiagnosis(channels: [-18, -20])
        #expect(ArchiveAngelAudioOutcome.reusableDiagnosis(storedStatus: "ok", cached: fine)?.verdict == .ok)
        let short = S.soundDiagnosis(channels: [-18, -20],
                                     extraFindings: [.durationMismatch(audioSeconds: 2, videoSeconds: 10)])
        #expect(ArchiveAngelAudioOutcome.reusableDiagnosis(storedStatus: "damaged", cached: short)?.verdict == .damaged)
        #expect(ArchiveAngelAudioOutcome.reusableDiagnosis(storedStatus: "", cached: fine) == nil)
        #expect(ArchiveAngelAudioOutcome.reusableDiagnosis(storedStatus: "ok", cached: nil) == nil)
    }
}

// MARK: - F5

@Suite("Verify Audio verdict consumers — F5 the note claims only what was measured")
struct VerifyAudioVerdictNoteWordingTests {

    @Test func damagedNoteDoesNotClaimUndecodable() {
        var s = AudioVerifyShape(); s.audioStreams = 1; s.audioCodec = "aac"; s.audioDurationSeconds = 60; s.videoDurationSeconds = 600
        let f = VerifyAudioRules.findings(shape: s, referencedPaths: [], levels: .failure(.probeFailed("I/O")))
        #expect(f.count == 2, "fixture: short audio + a failed levels pass: \(f)")
        #expect(!VerifyAudioRules.note(for: f).contains("undecodable"))
        #expect(VerifyAudioRules.note(for: f) == "Damaged audio — audio shorter than video (60s vs 600s); audio could not be read (aac)")
    }

    @Test("no finding's words say 'undecodable': the rebuild's reason and the Angel's note read the same fragment")
    func noFragmentSaysUndecodable() {
        for codec in ["cook", ""] {
            let fragment = VerifyAudioRules.noteFragment(for: .unsupportedCodec(codec: codec, decodable: false))
            #expect(!fragment.contains("undecodable"), "\(fragment)")
            #expect(fragment == "audio could not be read (\(codec.isEmpty ? "unknown codec" : codec))")
        }
        #expect(VerifyAudioRules.noteFragment(for: .unsupportedCodec(codec: "qdm2", decodable: true)) == "invalid codec (qdm2)")
    }
}
