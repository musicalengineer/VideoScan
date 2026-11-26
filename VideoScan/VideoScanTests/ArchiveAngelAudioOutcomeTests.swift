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
        case .notMeasured: return AudioBalanceMeasurements(channels: [], differenceRMSDBFS: nil)
        }
    }()
    var a = AudioBalanceAnalysis(classification: c, measurements: measured,
                                 shape: shape(channels: c == .mono ? 1 : (c == .multichannel ? 6 : 2)),
                                 programStreamCount: programStreams, programStreamIndex: 1,
                                 droppedStreamIndices: [])
    a.levelsComplete = true   // the probe's answer for a pass that covered everything
    return a
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

    @Test func rightOnlyIsFixable() {
        let right = AudioVerifyDiagnosis(findings: [.channelImbalance(.rightOnly)], shape: verifyShape(),
                                         balanceAnalysis: analysis(.rightOnly))
        guard case .fixable(_, let rv) = ArchiveAngelAudioOutcome.from(right) else { Issue.record("right"); return }
        #expect(rv == "One-sided audio — right channel only")
    }

    // Rick 2026-11-16: mono (one channel) plays on both sides and is how the
    // recording was made. Prepare used to widen it to two channels and
    // promote that copy; it is not something to fix.
    @Test func monoIsNotSomethingToFix() {
        let mono = AudioVerifyDiagnosis(findings: [.channelImbalance(.mono)], shape: verifyShape(),
                                        balanceAnalysis: analysis(.mono))
        let o = ArchiveAngelAudioOutcome.from(mono)
        #expect(o == .balanced(ArchiveAngelAudioOutcome.monoIsFineNote), "got \(o)")
        #expect(o.headline.contains("plays on both sides"))
    }

    @Test("the Angel's balance step runs for one-sided sound only — never for mono, stereo, dual mono, silence or surround")
    func balanceStepRunsForOneSidedOnly() {
        #expect(ArchiveAngelAudioOutcome.balanceSkipReason(for: analysis(.leftOnly)) == nil)
        #expect(ArchiveAngelAudioOutcome.balanceSkipReason(for: analysis(.rightOnly)) == nil)
        #expect(ArchiveAngelAudioOutcome.balanceSkipReason(for: analysis(.mono)) == ArchiveAngelAudioOutcome.monoIsFineNote)
        for c in [AudioChannelClass.trueStereo, .dualMono, .silent, .multichannel] {
            #expect(ArchiveAngelAudioOutcome.balanceSkipReason(for: analysis(c)) != nil, "\(c)")
        }
        // Balance Audio itself (Repair…, on Rick's say-so) still accepts mono.
        #expect(BalanceAudioFix.refusalReason(for: analysis(.mono)) == nil)
    }

    // Codex #300 F3 (A): a two-channel stream whose levels pass read only one
    // channel classifies `.mono` with an incomplete measurement. The mono
    // words must not be said of it: the completeness guard speaks first.
    @Test func aPartlyMeasuredTrackIsNeverCalledMono() {
        var partial = analysis(.mono)
        partial.shape.audioChannels = 2
        partial.levelsComplete = false
        #expect(ArchiveAngelAudioOutcome.balanceSkipReason(for: partial)
                == BalanceAudioFix.incompleteMeasurementReason)
        // A complete one-channel measurement still reads as mono.
        #expect(ArchiveAngelAudioOutcome.balanceSkipReason(for: analysis(.mono))
                == ArchiveAngelAudioOutcome.monoIsFineNote)
    }

    // Codex #300 F3 (B): mono beside measured damage is damage. "Mono is
    // fine" is the answer only when mono is the ONLY finding.
    @Test func monoBesideDamageIsDamage() {
        let damaged = AudioVerifyDiagnosis(
            findings: [.durationMismatch(audioSeconds: 20, videoSeconds: 100), .channelImbalance(.mono)],
            shape: verifyShape(), balanceAnalysis: analysis(.mono))
        #expect(ArchiveAngelAudioOutcome.from(damaged) == .damaged(damaged.persistedNote))
        #expect(ArchiveAngelAudioOutcome.from(damaged).headline.contains("audio shorter than video"))
        // Order of the findings does not matter.
        let reversed = AudioVerifyDiagnosis(
            findings: [.channelImbalance(.mono), .unsupportedCodec(codec: "qdm2", decodable: true)],
            shape: verifyShape(), balanceAnalysis: analysis(.mono))
        #expect(ArchiveAngelAudioOutcome.from(reversed) == .damaged(reversed.persistedNote))
    }

    @Test func monoBesideAnyOtherFindingIsNotCalledFine() {
        let noStream = AudioVerifyDiagnosis(findings: [.channelImbalance(.mono), .noAudioStream],
                                            shape: verifyShape(), balanceAnalysis: analysis(.mono))
        #expect(ArchiveAngelAudioOutcome.from(noStream) == .noAudio)
        let silent = AudioVerifyDiagnosis(findings: [.channelImbalance(.mono), .silentAudio],
                                          shape: verifyShape(), balanceAnalysis: analysis(.mono))
        guard case .refused = ArchiveAngelAudioOutcome.from(silent) else {
            Issue.record("got \(ArchiveAngelAudioOutcome.from(silent))"); return
        }
        // Mono alone is still fine.
        let alone = AudioVerifyDiagnosis(findings: [.channelImbalance(.mono)], shape: verifyShape(),
                                         balanceAnalysis: analysis(.mono))
        #expect(ArchiveAngelAudioOutcome.from(alone) == .balanced(ArchiveAngelAudioOutcome.monoIsFineNote))
    }

    @Test func healthyStereoAndDualMonoAreBalanced() {
        guard case .balanced(let s) = ArchiveAngelAudioOutcome.from(healthy(.trueStereo)) else { Issue.record("stereo"); return }
        #expect(s.contains("True stereo"))
        guard case .balanced(let d) = ArchiveAngelAudioOutcome.from(healthy(.dualMono)) else { Issue.record("dualMono"); return }
        #expect(d.contains("already balanced"))
    }

    /// GH #467: a sound track with no measurement, or a partial one, is not
    /// "balanced" — the Angel says it could not be checked, and why.
    @Test func aSoundTrackThatWasNotMeasuredIsNotBalanced() {
        let none = AudioVerifyDiagnosis(findings: [], shape: verifyShape(), balanceAnalysis: nil)
        #expect(ArchiveAngelAudioOutcome.from(none)
                == .refused("The sound could not be checked — the sound track was not decoded."))
        var partial = analysis(.trueStereo)
        partial.levelsComplete = false
        let some = AudioVerifyDiagnosis(findings: [], shape: verifyShape(), balanceAnalysis: partial)
        #expect(ArchiveAngelAudioOutcome.from(some)
                == .refused("The sound could not be checked — the sound track was only partly measured."))
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
                                         balanceAnalysis: analysis(.trueStereo, programStreams: 2))
        guard case .refused(let s1) = ArchiveAngelAudioOutcome.from(surround) else { Issue.record("surround"); return }
        guard case .refused(let s2) = ArchiveAngelAudioOutcome.from(silent) else { Issue.record("silent"); return }
        guard case .refused(let s3) = ArchiveAngelAudioOutcome.from(multi) else { Issue.record("multi"); return }
        #expect(s1.contains("Surround"))
        #expect(s2.contains("No audio program"))
        #expect(s3.contains("both carry sound"), "the measured analysis' own refusal: \(s3)")
    }

    @Test func damageFindingsStayDamaged() {
        let ref = AudioVerifyDiagnosis(findings: [.referenceMovie(referencedPaths: ["/x"])],
                                       shape: AudioVerifyShape(), balanceAnalysis: nil)
        let codec = AudioVerifyDiagnosis(findings: [.unsupportedCodec(codec: "qdm2", decodable: true)],
                                         shape: verifyShape(), balanceAnalysis: nil)
        guard case .damaged(let n1) = ArchiveAngelAudioOutcome.from(ref) else { Issue.record("ref"); return }
        guard case .damaged(let n2) = ArchiveAngelAudioOutcome.from(codec) else { Issue.record("codec"); return }
        // Still the Angel's .damaged outcome; the note names each (Rick 2026-11-25).
        #expect(n1.hasPrefix("Reference movie — "))
        // No levels measured here, so not "needs rebuilding" (Codex #372: only a complete decode promises that).
        #expect(n2 == "Damaged audio — invalid codec (qdm2)", "\(n2)")
    }

    /// GH #468: a levels pass that failed is a failed read OR a track that
    /// will not decode — "could not be checked", never "damaged".
    @Test func aFailedLevelsPassIsNotDamage() {
        let failed = AudioVerifyDiagnosis(findings: [.unsupportedCodec(codec: "qdm2", decodable: false)],
                                          shape: verifyShape(), balanceAnalysis: nil)
        guard case .refused(let why) = ArchiveAngelAudioOutcome.from(failed) else {
            Issue.record("got \(ArchiveAngelAudioOutcome.from(failed))"); return
        }
        #expect(why.hasPrefix("The sound could not be checked — the sound track could not be decoded (qdm2)"))
        #expect(!why.lowercased().contains("damaged"))
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
