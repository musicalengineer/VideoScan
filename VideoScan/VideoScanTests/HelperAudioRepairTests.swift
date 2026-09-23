// HelperAudioRepairTests.swift
// Archive Helper "Verify / Fix Audio" (2026-08-26) — five dimensions:
//
//   LOGIC     HelperAudioOutcome.from(diagnosis) → outcome, and
//             HelperAudioActions.compose (outcome → action list, incl.
//             every refusal class).
//   (S4, 2026-09-22: the coordinator / fixture / poisoned-state suites
//   drove the retired Helper panel's VerifyThenBalanceCoordinator through
//   AssessCopiesJob; they moved to the repo's .trash with it. The Angel's
//   prepare step is the one verify → balance implementation now.)

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
