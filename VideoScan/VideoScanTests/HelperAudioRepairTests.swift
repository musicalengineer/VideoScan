// HelperAudioRepairTests.swift
// Archive Helper "Verify / Fix Audio" (2026-08-26) — five dimensions:
//
//   LOGIC     HelperAudioOutcome.from(diagnosis) → outcome, and
//             HelperAudioActions.compose (outcome → action list, incl.
//             every refusal class).
//   ISOLATION Coordinator + AssessCopiesJob driven with canned
//             diagnoses on fake /tmp paths — no real volumes, no prefs.
//   MEDIA     ONE synthetic ffmpeg fixture (mov/h264 + left-only PCM)
//             run verify → balance → re-assess end to end through the
//             coordinator; skipped with a reason when ffmpeg is absent.
//   SENSOR    Poisoned state: a family that already holds a
//             `_balanced` companion NEVER re-offers Balance Audio, even
//             with a fresh "left only" verdict in hand (the 8/19 rule).
//   SCALE     n/a — nothing here iterates `records` beyond the family.

import Foundation
import Testing
@testable import VideoScan

// MARK: - Canned diagnoses

private func levels(_ l: Double, _ r: Double, diff: Double? = nil) -> AudioBalanceMeasurements {
    AudioBalanceMeasurements(channels: [AudioChannelLevels(rmsDBFS: l, peakDBFS: l + 6),
                                        AudioChannelLevels(rmsDBFS: r, peakDBFS: r + 6)],
                             differenceRMSDBFS: diff)
}

private func shape(container: String = "mov", channels: Int = 2) -> AudioBalanceStreamShape {
    var s = AudioBalanceStreamShape(videoCodec: "h264", totalStreams: 2, videoStreams: 1,
                                    audioStreams: 1, audioCodec: "pcm_s16le",
                                    audioChannels: channels, audioBitRate: nil,
                                    durationSeconds: 2.0, audioStreamInfos: [])
    s.containerFormat = container
    return s
}

private func analysis(_ c: AudioChannelClass,
                      programStreams: Int = 1,
                      m: AudioBalanceMeasurements? = nil) -> AudioBalanceAnalysis {
    let measured: AudioBalanceMeasurements = m ?? {
        switch c {
        case .leftOnly:   return levels(-18.2, -Double.infinity)
        case .rightOnly:  return levels(-Double.infinity, -21.0)
        case .dualMono:   return levels(-18.0, -18.0, diff: -95)
        case .trueStereo: return levels(-18.0, -19.0, diff: -21)
        case .silent:     return levels(-Double.infinity, -Double.infinity)
        case .mono:       return AudioBalanceMeasurements(channels: [AudioChannelLevels(rmsDBFS: -20, peakDBFS: -14)],
                                                          differenceRMSDBFS: nil)
        case .multichannel: return AudioBalanceMeasurements(channels: Array(repeating: AudioChannelLevels(rmsDBFS: -20, peakDBFS: -14), count: 6),
                                                            differenceRMSDBFS: nil)
        }
    }()
    return AudioBalanceAnalysis(classification: c, measurements: measured,
                                shape: shape(channels: c == .mono ? 1 : (c == .multichannel ? 6 : 2)),
                                programStreamCount: programStreams, programStreamIndex: 1,
                                droppedStreamIndices: [])
}

private func verifyShape() -> AudioVerifyShape {
    var s = AudioVerifyShape()
    s.audioStreams = 1
    s.audioCodec = "pcm_s16le"
    s.audioChannels = 2
    s.containerDurationSeconds = 2.0
    return s
}

private func fixableLeft(container: String = "mov") -> AudioVerifyDiagnosis {
    var a = analysis(.leftOnly)
    a.shape.containerFormat = container
    return AudioVerifyDiagnosis(findings: [.channelImbalance(.leftOnly)], shape: verifyShape(),
                                balanceAnalysis: a)
}

private func healthy(_ c: AudioChannelClass = .trueStereo) -> AudioVerifyDiagnosis {
    AudioVerifyDiagnosis(findings: [], shape: verifyShape(), balanceAnalysis: analysis(c))
}

// MARK: - LOGIC: outcome mapping

@Suite("Helper audio — outcome from a diagnosis")
struct HelperAudioOutcomeTests {

    @Test func leftOnlyIsFixableWithTheVerdictWording() {
        let o = HelperAudioOutcome.from(fixableLeft())
        guard case .fixable(let a, let verdict) = o else { Issue.record("got \(o)"); return }
        #expect(a.classification == .leftOnly)
        #expect(verdict == "One-sided audio — left channel only")
        #expect(o.headline == verdict)
    }

    @Test func rightOnlyAndMonoAreFixable() {
        let right = AudioVerifyDiagnosis(findings: [.channelImbalance(.rightOnly)], shape: verifyShape(),
                                         balanceAnalysis: analysis(.rightOnly))
        let mono = AudioVerifyDiagnosis(findings: [.channelImbalance(.mono)], shape: verifyShape(),
                                        balanceAnalysis: analysis(.mono))
        guard case .fixable(_, let rv) = HelperAudioOutcome.from(right) else { Issue.record("right"); return }
        guard case .fixable(_, let mv) = HelperAudioOutcome.from(mono) else { Issue.record("mono"); return }
        #expect(rv == "One-sided audio — right channel only")
        #expect(mv == "Mono audio — one channel")
    }

    @Test func healthyStereoAndDualMonoAreBalanced() {
        guard case .balanced(let s) = HelperAudioOutcome.from(healthy(.trueStereo)) else { Issue.record("stereo"); return }
        #expect(s.contains("True stereo"))
        guard case .balanced(let d) = HelperAudioOutcome.from(healthy(.dualMono)) else { Issue.record("dualMono"); return }
        #expect(d.contains("already balanced"))
    }

    @Test func healthyWithoutAnalysisStillReadsBalanced() {
        let d = AudioVerifyDiagnosis(findings: [], shape: verifyShape(), balanceAnalysis: nil)
        #expect(HelperAudioOutcome.from(d) == .balanced("Audio is balanced — the track checked out."))
    }

    /// The fix gate is consulted AGAIN — an imbalance finding whose
    /// analysis the job would refuse (two live tracks) must not become
    /// a button.
    @Test func imbalanceFindingWithTwoLiveTracksIsRefusedNotFixable() {
        let d = AudioVerifyDiagnosis(findings: [.channelImbalance(.leftOnly)], shape: verifyShape(),
                                     balanceAnalysis: analysis(.leftOnly, programStreams: 2))
        guard case .refused(let why) = HelperAudioOutcome.from(d) else { Issue.record("expected refusal"); return }
        #expect(why == BalanceAudioFix.refusalReason(for: analysis(.leftOnly, programStreams: 2)))
        #expect(why.contains("both carry sound"))
    }

    @Test func surroundSilentAndMultiTrackAreRefusedInPlainWords() {
        let surround = AudioVerifyDiagnosis(findings: [.surround(channels: 6)], shape: verifyShape(),
                                            balanceAnalysis: analysis(.multichannel))
        let silent = AudioVerifyDiagnosis(findings: [.silentAudio], shape: verifyShape(),
                                          balanceAnalysis: analysis(.silent))
        let multi = AudioVerifyDiagnosis(findings: [.multipleProgramTracks(count: 2)], shape: verifyShape(),
                                         balanceAnalysis: nil)
        guard case .refused(let s1) = HelperAudioOutcome.from(surround) else { Issue.record("surround"); return }
        guard case .refused(let s2) = HelperAudioOutcome.from(silent) else { Issue.record("silent"); return }
        guard case .refused(let s3) = HelperAudioOutcome.from(multi) else { Issue.record("multi"); return }
        #expect(s1.contains("Surround"))
        #expect(s2.contains("No audio program"))
        #expect(s3.contains("2 live audio tracks"))
    }

    @Test func damageFindingsStayDamaged() {
        let ref = AudioVerifyDiagnosis(findings: [.referenceMovie(referencedPaths: ["/x"])],
                                       shape: AudioVerifyShape(), balanceAnalysis: nil)
        let codec = AudioVerifyDiagnosis(findings: [.unsupportedCodec(codec: "qdm2", decodable: false)],
                                         shape: AudioVerifyShape(), balanceAnalysis: nil)
        guard case .damaged(let n1) = HelperAudioOutcome.from(ref) else { Issue.record("ref"); return }
        guard case .damaged(let n2) = HelperAudioOutcome.from(codec) else { Issue.record("codec"); return }
        #expect(n1.contains("reference movie"))
        #expect(n2.contains("undecodable audio"))
    }

    @Test func noAudioStreamIsItsOwnCase() {
        let d = AudioVerifyDiagnosis(findings: [.noAudioStream], shape: AudioVerifyShape(), balanceAnalysis: nil)
        #expect(HelperAudioOutcome.from(d) == .noAudio)
    }

    @Test func levelsLineShowsNumbersAndSilence() {
        #expect(HelperAudioOutcome.levelsLine(analysis(.leftOnly)) == "L -18.2 dBFS RMS · R silent")
        #expect(HelperAudioOutcome.levelsLine(analysis(.rightOnly)) == "L silent · R -21.0 dBFS RMS")
        // Below the −60 dBFS program floor counts as silent too.
        #expect(HelperAudioOutcome.levelsLine(analysis(.leftOnly, m: levels(-20, -75))) == "L -20.0 dBFS RMS · R silent")
    }
}

// MARK: - LOGIC: action composition

@Suite("Helper audio — actions from an outcome")
struct HelperAudioActionsTests {
    private let base: [CopyFamilyAction] = [.verifyAudioFirst, .promoteRecommendedOriginal,
                                             .createAndPromoteCompanion, .createAccessCopy]

    @Test func noOutcomePassesTheAssessorThrough() {
        #expect(HelperAudioActions.compose(base: base, outcome: nil, repairedCopyExists: false) == base)
    }

    @Test func fixableSwapsVerifyForBalanceFirst() {
        let out = HelperAudioActions.compose(base: base,
                                             outcome: HelperAudioOutcome.from(fixableLeft()),
                                             repairedCopyExists: false)
        #expect(out.first == .balanceAudio)
        #expect(!out.contains(.verifyAudioFirst))
        #expect(out.contains(.promoteRecommendedOriginal))
    }

    @Test func balancedRefusedAndNoAudioDropTheVerifyNagWithoutAButton() {
        for o: HelperAudioOutcome in [.balanced("ok"), .refused("no"), .noAudio] {
            let out = HelperAudioActions.compose(base: base, outcome: o, repairedCopyExists: false)
            #expect(!out.contains(.verifyAudioFirst), "\(o)")
            #expect(!out.contains(.balanceAudio), "\(o)")
            #expect(out.first == .promoteRecommendedOriginal, "\(o)")
        }
    }

    @Test func damagedKeepsTheAssessorsVerifyNag() {
        let out = HelperAudioActions.compose(base: base, outcome: .damaged("reference movie"),
                                             repairedCopyExists: false)
        #expect(out == base)
    }

    /// The 8/19 rule at the composition level.
    @Test func repairedCopyPresentNeverOffersBalanceNorVerify() {
        let repairedBase: [CopyFamilyAction] = [.promoteOriginalAndRepaired, .createAccessCopy]
        let out = HelperAudioActions.compose(base: repairedBase,
                                             outcome: HelperAudioOutcome.from(fixableLeft()),
                                             repairedCopyExists: true)
        #expect(out == repairedBase)
        // Even a stale .balanceAudio in the input is scrubbed.
        let scrubbed = HelperAudioActions.compose(base: [.balanceAudio] + repairedBase,
                                                  outcome: nil, repairedCopyExists: true)
        #expect(scrubbed == repairedBase)
    }
}

// MARK: - ISOLATION: coordinator + job on fake paths

@MainActor
private func fakeRecord(_ name: String, dir: String = "/tmp/HelperAudioRepairTests") -> VideoRecord {
    let r = VideoRecord()
    r.filename = name
    r.fullPath = "\(dir)/\(name)"
    r.directory = dir
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    r.videoCodec = "dvvideo"; r.audioCodec = "pcm_s16le"; r.container = "dv"
    r.resolution = "720x480"; r.frameRate = "29.97"; r.audioChannels = "2"
    r.audioSampleRate = "48000"; r.durationSeconds = 3604
    r.isPlayable = "Yes"
    return r
}

@MainActor
private func settle(timeoutMS: Int = 3000, until done: () -> Bool) async {
    let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000)
    while Date() < deadline {
        if done() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Suite("Helper audio — coordinator (canned diagnoses, no media)")
struct VerifyThenBalanceCoordinatorTests {

    @Test func verifyLandsTheVerdictReassessesAndOffersBalance() async {
        let model = VideoScanModel()
        let rec = fakeRecord("May2000_Misc_People.dv")
        model.records = [rec]
        let center = MediaFileOperationsCenter()
        let job = center.startAssessCopies(seed: rec, model: model)
        await job.task?.value
        #expect(job.assessment?.actions.first == .verifyAudioFirst, "never verified → nag")

        let c = job.audioCoordinator(for: rec, center: center, model: model)
        #expect(c.phase == .idle)
        #expect(c.outcome == nil)
        c.diagnoseOverride = { _ in fixableLeft(container: "dv") }   // raw DV, as ffprobe reports it
        c.verify(thenBalance: false)
        #expect(c.phase == .verifying)
        await settle { c.phase != .verifying }

        #expect(c.phase == .verified)
        guard case .fixable? = c.outcome else { Issue.record("outcome \(String(describing: c.outcome))"); return }
        #expect(rec.audioVerifyStatus == "ok", "verify persists its verdict on the live record")
        // The job re-assessed: the assessor no longer nags (status ok)…
        #expect(job.assessment?.actions.contains(.verifyAudioFirst) == false)
        // …and the overlay offers Balance first, no Verify.
        let composed = HelperAudioActions.compose(base: job.assessment?.actions ?? [],
                                                  outcome: c.outcome, repairedCopyExists: false)
        #expect(composed.first == .balanceAudio)
        #expect(!composed.contains(.verifyAudioFirst))
        #expect(c.plannedBalanceOutput?.lastPathComponent == "May2000_Misc_People_balanced.mov",
                "raw DV → QuickTime, the same planner the Catalog sheet uses")
        // Same coordinator comes back for the same record (state survives
        // the panel collapsing).
        #expect(job.audioCoordinator(for: rec, center: center, model: model) === c)
        #expect(job.existingAudioCoordinator(for: rec.id) === c)
    }

    @Test func healthyVerdictDropsTheNagAndBalanceIsANoOp() async {
        let model = VideoScanModel()
        let rec = fakeRecord("stereo.dv")
        model.records = [rec]
        let center = MediaFileOperationsCenter()
        let job = center.startAssessCopies(seed: rec, model: model)
        await job.task?.value
        let c = job.audioCoordinator(for: rec, center: center, model: model)
        c.diagnoseOverride = { _ in healthy(.trueStereo) }
        c.verify(thenBalance: true)         // one-click path — must NOT balance
        await settle { c.phase != .verifying }
        #expect(c.phase == .verified)
        guard case .balanced? = c.outcome else { Issue.record("outcome"); return }
        c.balance()
        #expect(c.phase == .verified, "balance() on a balanced verdict starts nothing")
        #expect(c.balanceJob == nil)
        let composed = HelperAudioActions.compose(base: job.assessment?.actions ?? [],
                                                  outcome: c.outcome, repairedCopyExists: false)
        #expect(!composed.contains(.verifyAudioFirst))
        #expect(!composed.contains(.balanceAudio))
    }

    @Test func refusedVerdictShowsReasonAndNoButton() async {
        let model = VideoScanModel()
        let rec = fakeRecord("twopairs.dv")
        model.records = [rec]
        let center = MediaFileOperationsCenter()
        let job = center.startAssessCopies(seed: rec, model: model)
        await job.task?.value
        let c = job.audioCoordinator(for: rec, center: center, model: model)
        c.diagnoseOverride = { _ in
            AudioVerifyDiagnosis(findings: [.channelImbalance(.leftOnly)], shape: verifyShape(),
                                 balanceAnalysis: analysis(.leftOnly, programStreams: 2))
        }
        c.verify(thenBalance: true)
        await settle { c.phase != .verifying }
        guard case .refused(let why)? = c.outcome else { Issue.record("outcome"); return }
        #expect(why.contains("Balance Audio handles a single program track"))
        #expect(c.phase == .verified, "chained balance must not fire on a refusal")
        #expect(c.balanceJob == nil)
        let composed = HelperAudioActions.compose(base: job.assessment?.actions ?? [],
                                                  outcome: c.outcome, repairedCopyExists: false)
        #expect(!composed.contains(.balanceAudio))
    }

    @Test func balanceOnAMissingSourceFailsHonestlyWithoutTouchingTheVerdict() async {
        let model = VideoScanModel()
        let rec = fakeRecord("gone.dv")
        model.records = [rec]
        let center = MediaFileOperationsCenter()
        // Seed the Center's cache — the same cache the Catalog sheet reads
        // — and the coordinator must pick it up without a verify run.
        center.storeVerifyDiagnosis(fixableLeft(), forRecordID: rec.id)
        let job = center.startAssessCopies(seed: rec, model: model)
        await job.task?.value
        let c = job.audioCoordinator(for: rec, center: center, model: model)
        #expect(c.phase == .verified)
        guard case .fixable? = c.outcome else { Issue.record("cache not picked up"); return }
        c.balance()
        #expect(c.phase == .balancing)
        await settle { c.phase != .balancing }
        guard case .failed(let msg) = c.phase else { Issue.record("phase \(c.phase)"); return }
        #expect(msg.contains("Source file missing"))
        guard case .fixable? = c.outcome else { Issue.record("verdict lost"); return }
        #expect(c.balancedOutputName == nil)
    }

    @Test func verifyFailureIsReportedNotSwallowed() async {
        let model = VideoScanModel()
        let rec = fakeRecord("broken.dv")
        model.records = [rec]
        let center = MediaFileOperationsCenter()
        let job = center.startAssessCopies(seed: rec, model: model)
        await job.task?.value
        let c = job.audioCoordinator(for: rec, center: center, model: model)
        c.diagnoseOverride = { _ in throw AudioVerifyProbeError.probeFailed("ffprobe exited 1") }
        c.verify(thenBalance: false)
        await settle { c.phase != .verifying }
        guard case .failed(let msg) = c.phase else { Issue.record("phase \(c.phase)"); return }
        #expect(msg.contains("Could not check the audio"))
        #expect(c.outcome == nil)
        #expect(rec.audioVerifyStatus.isEmpty, "a failed probe persists nothing")
    }
}

// MARK: - SENSOR: the 8/19 rule against a poisoned state

@MainActor
@Suite("Helper audio — sensor: already-balanced companion never re-offers Balance")
struct HelperAudioAlreadyBalancedSensor {

    @Test func balancedCompanionInFamilyBeatsAFreshLeftOnlyVerdict() async {
        let model = VideoScanModel()
        let original = fakeRecord("Clip 01.dv", dir: "/tmp/HelperAudioRepairTests/LaCie")
        let balanced = fakeRecord("Clip 01_balanced.mov", dir: "/tmp/HelperAudioRepairTests/LaCie")
        balanced.container = "mov"
        balanced.derivedFrom = original.id
        balanced.derivationKind = "balanceAudio"
        balanced.audioVerifyStatus = "ok"
        model.records = [original, balanced]
        let center = MediaFileOperationsCenter()
        // POISON: a stale fixable verdict for the ORIGINAL sits in the
        // Center's cache (Rick verified it before balancing).
        center.storeVerifyDiagnosis(fixableLeft(), forRecordID: original.id)

        let job = center.startAssessCopies(seed: original, model: model)
        await job.task?.value
        let a = try? #require(job.assessment)
        #expect(a?.actions.first == .promoteOriginalAndRepaired)
        #expect(a?.actions.contains(.verifyAudioFirst) == false)
        #expect(a?.representations.contains { $0.role == .repairedCopy } == true)

        let c = job.audioCoordinator(for: original, center: center, model: model)
        guard case .fixable? = c.outcome else { Issue.record("cache should hold the stale verdict"); return }
        let repairedExists = a?.representations.contains { $0.role == .repairedCopy } == true
        let composed = HelperAudioActions.compose(base: a?.actions ?? [],
                                                  outcome: c.outcome,
                                                  repairedCopyExists: repairedExists)
        #expect(!composed.contains(.balanceAudio), "\(composed)")
        #expect(!composed.contains(.verifyAudioFirst), "\(composed)")
        #expect(composed.first == .promoteOriginalAndRepaired)

        // And re-assessing (what the coordinator does after verify)
        // changes nothing about that.
        job.reassess(model: model, reason: "sensor")
        #expect(job.assessment?.actions.first == .promoteOriginalAndRepaired)
    }
}

// MARK: - MEDIA: one fixture end to end through the coordinator

@MainActor
@Suite("Helper audio — verify → balance → re-assess on a real left-only fixture")
struct HelperAudioFixtureRoundTrip {

    // `.enabled(if:)` = Swift Testing's skip-with-reason (no XCTSkip here).
    @Test(.enabled(if: BalanceAudioTestMedia.toolsAvailable,
                   "ffmpeg/ffprobe not available — fixture round trip skipped"))
    func leftOnlyMovBecomesPromoteOriginalPlusRepaired() async throws {
        let dir = try BalanceAudioTestMedia.makeScratchDir("helper_roundtrip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try BalanceAudioTestMedia.generate(into: dir, channelCase: .leftOnly, wrapper: .movH264Pcm)

        let model = VideoScanModel()
        let rec = makeBalanceSourceRecord(path: path, durationSeconds: 2.0, audioCodec: "pcm_s16le")
        rec.videoCodec = "h264"; rec.container = "mov"; rec.resolution = "320x240"
        rec.frameRate = "25"; rec.audioChannels = "2"; rec.audioSampleRate = "48000"
        rec.isPlayable = "Yes"
        model.records = [rec]
        let center = MediaFileOperationsCenter()
        let job = center.startAssessCopies(seed: rec, model: model)
        await job.task?.value
        #expect(job.assessment?.actions.first == .verifyAudioFirst)

        // ONE click: Verify and Fix Audio.
        let c = job.audioCoordinator(for: rec, center: center, model: model)
        c.verify(thenBalance: true)
        await settle(timeoutMS: 120_000) { !c.isBusy }

        guard c.phase == .balanced else {
            Issue.record("expected balanced, got \(c.phase) — outcome \(String(describing: c.outcome))")
            return
        }
        guard case .fixable(let a, let verdict)? = c.outcome else { Issue.record("outcome"); return }
        #expect(a.classification == .leftOnly)
        #expect(verdict == "One-sided audio — left channel only")
        #expect(c.balancedOutputName == "test_balance_leftOnly_balanced.mov")

        // Output exists, is catalogued as a balanceAudio derivation, and
        // re-verifies balanced.
        let out = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent("test_balance_leftOnly_balanced.mov")
        #expect(FileManager.default.fileExists(atPath: out.path))
        let derived = model.records.first { $0.fullPath == out.path }
        #expect(derived?.derivedFrom == rec.id)
        #expect(derived?.derivationKind == "balanceAudio")
        let check = try await AudioBalanceProbe.analyze(path: out.path)
        #expect(check.classification == .dualMono)

        // The panel re-assessed on its own: the assessor's balanceAudio
        // rule fired for the fresh output.
        let assessment = try #require(job.assessment)
        #expect(assessment.representations.contains { $0.role == .repairedCopy })
        #expect(assessment.actions.first == .promoteOriginalAndRepaired, "\(assessment.actions)")
        #expect(!assessment.actions.contains(.verifyAudioFirst))
        let composed = HelperAudioActions.compose(base: assessment.actions, outcome: c.outcome,
                                                  repairedCopyExists: true)
        #expect(!composed.contains(.balanceAudio), "never re-offer Balance once the copy exists")
    }
}
