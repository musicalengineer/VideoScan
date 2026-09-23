// ArchiveAngelAudioOutcomeTests.swift
// What a finished Verify Audio diagnosis means (ArchiveAngelAudioOutcome —
// the Archive Angel prepare step's verify note). Formerly
// HelperAudioRepairTests.swift ("Verify / Fix Audio", 2026-08-26).
//
//   LOGIC     ArchiveAngelAudioOutcome.from(diagnosis) → outcome, every
//             refusal class, the levels line.
//   (S4, 2026-09-22: the HelperAudioActions suite and the coordinator /
//   fixture / poisoned-state suites drove the retired Helper panel —
//   VerifyThenBalanceCoordinator through AssessCopiesJob; they moved to the
//   repo's .trash with it. The Angel's prepare step is the one verify →
//   balance implementation now; its fixture coverage is ArchiveAngelTestbed.)

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

@Suite("Archive Angel audio — outcome from a diagnosis")
struct ArchiveAngelAudioOutcomeTests {

    @Test func leftOnlyIsFixableWithTheVerdictWording() {
        let o = ArchiveAngelAudioOutcome.from(fixableLeft())
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
        guard case .fixable(_, let rv) = ArchiveAngelAudioOutcome.from(right) else { Issue.record("right"); return }
        guard case .fixable(_, let mv) = ArchiveAngelAudioOutcome.from(mono) else { Issue.record("mono"); return }
        #expect(rv == "One-sided audio — right channel only")
        #expect(mv == "Mono audio — one channel")
    }

    @Test func healthyStereoAndDualMonoAreBalanced() {
        guard case .balanced(let s) = ArchiveAngelAudioOutcome.from(healthy(.trueStereo)) else { Issue.record("stereo"); return }
        #expect(s.contains("True stereo"))
        guard case .balanced(let d) = ArchiveAngelAudioOutcome.from(healthy(.dualMono)) else { Issue.record("dualMono"); return }
        #expect(d.contains("already balanced"))
    }

    @Test func healthyWithoutAnalysisStillReadsBalanced() {
        let d = AudioVerifyDiagnosis(findings: [], shape: verifyShape(), balanceAnalysis: nil)
        #expect(ArchiveAngelAudioOutcome.from(d) == .balanced("Audio is balanced — the track checked out."))
    }

    /// The fix gate is consulted AGAIN — an imbalance finding whose
    /// analysis the job would refuse (two live tracks) must not become
    /// a button.
    @Test func imbalanceFindingWithTwoLiveTracksIsRefusedNotFixable() {
        let d = AudioVerifyDiagnosis(findings: [.channelImbalance(.leftOnly)], shape: verifyShape(),
                                     balanceAnalysis: analysis(.leftOnly, programStreams: 2))
        guard case .refused(let why) = ArchiveAngelAudioOutcome.from(d) else { Issue.record("expected refusal"); return }
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
        guard case .refused(let s1) = ArchiveAngelAudioOutcome.from(surround) else { Issue.record("surround"); return }
        guard case .refused(let s2) = ArchiveAngelAudioOutcome.from(silent) else { Issue.record("silent"); return }
        guard case .refused(let s3) = ArchiveAngelAudioOutcome.from(multi) else { Issue.record("multi"); return }
        #expect(s1.contains("Surround"))
        #expect(s2.contains("No audio program"))
        #expect(s3.contains("2 live audio tracks"))
    }

    @Test func damageFindingsStayDamaged() {
        let ref = AudioVerifyDiagnosis(findings: [.referenceMovie(referencedPaths: ["/x"])],
                                       shape: AudioVerifyShape(), balanceAnalysis: nil)
        let codec = AudioVerifyDiagnosis(findings: [.unsupportedCodec(codec: "qdm2", decodable: false)],
                                         shape: AudioVerifyShape(), balanceAnalysis: nil)
        guard case .damaged(let n1) = ArchiveAngelAudioOutcome.from(ref) else { Issue.record("ref"); return }
        guard case .damaged(let n2) = ArchiveAngelAudioOutcome.from(codec) else { Issue.record("codec"); return }
        #expect(n1.contains("reference movie"))
        #expect(n2.contains("undecodable audio"))
    }

    @Test func noAudioStreamIsItsOwnCase() {
        let d = AudioVerifyDiagnosis(findings: [.noAudioStream], shape: AudioVerifyShape(), balanceAnalysis: nil)
        #expect(ArchiveAngelAudioOutcome.from(d) == .noAudio)
    }

    @Test func levelsLineShowsNumbersAndSilence() {
        #expect(ArchiveAngelAudioOutcome.levelsLine(analysis(.leftOnly)) == "L -18.2 dBFS RMS · R silent")
        #expect(ArchiveAngelAudioOutcome.levelsLine(analysis(.rightOnly)) == "L silent · R -21.0 dBFS RMS")
        // Below the −60 dBFS program floor counts as silent too.
        #expect(ArchiveAngelAudioOutcome.levelsLine(analysis(.leftOnly, m: levels(-20, -75))) == "L -20.0 dBFS RMS · R silent")
    }
}

// MARK: - LOGIC: action composition
