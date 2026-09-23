// ArchiveAngelAudioOutcome.swift
// What a finished Verify Audio diagnosis MEANS — balanced, fixable by
// Balance Audio, refused (plain words why), damaged, or no audio. Pure; no
// I/O. The Archive Angel's prepare step writes `headline` as its verify
// note (ArchiveAngelJob.prepare).
//
// Consolidation S4 (2026-09-22): moved out of HelperAudioRepair.swift and
// renamed from `HelperAudioOutcome` when the Promote Helper was retired.
// The Helper's own verify → balance driver (VerifyThenBalanceCoordinator)
// and its action-list overlay (HelperAudioActions) went with the Helper
// panel: the Angel's prepare step is now the ONE verify → balance
// implementation (it verifies, then balances only when
// BalanceAudioFix.refusalReason says the track is fixable).

import Foundation

// MARK: - Pure: outcome of a diagnosis

/// What a completed Verify Audio diagnosis means for the next step. (≈ a C++ tagged union — each case carries only what its
/// branch of the UI needs.)
enum ArchiveAngelAudioOutcome: Equatable {
    /// Nothing to fix — true stereo / dual-mono / healthy.
    case balanced(String)
    /// One-sided or mono track that Balance Audio WILL fix.
    /// `verdict` = "One-sided audio — left channel only".
    case fixable(analysis: AudioBalanceAnalysis, verdict: String)
    /// The track has a non-damage finding Balance Audio refuses to touch
    /// (surround, two live tracks, silence…) — plain words, no button.
    case refused(String)
    /// Verify found DAMAGE Balance Audio cannot repair (reference movie,
    /// undecodable codec, wrong-length audio) — the assessor's damaged
    /// caution stays in force.
    case damaged(String)
    /// The file carries no audio stream at all.
    case noAudio

    static func from(_ d: AudioVerifyDiagnosis) -> ArchiveAngelAudioOutcome {
        // The imbalance finding is only ever produced when the fix gate
        // is open (VerifyAudioRules), but the gate is consulted AGAIN
        // here — never promise what the Balance job refuses.
        for f in d.findings {
            if case .channelImbalance(let c) = f, let analysis = d.balanceAnalysis {
                if let reason = BalanceAudioFix.refusalReason(for: analysis) {
                    return .refused(reason)
                }
                return .fixable(analysis: analysis, verdict: verdict(for: c))
            }
        }
        if d.isHealthy {
            return .balanced(d.balanceAnalysis?.classification.familyDescription
                             ?? "Audio is balanced — the track checked out.")
        }
        if d.findings.contains(where: { if case .noAudioStream = $0 { return true }; return false }) {
            return .noAudio
        }
        if d.findings.contains(where: VerifyAudioRules.isDamage) {
            return .damaged(d.persistedNote)
        }
        // Non-damage, non-fixable: silent / surround / multiple live
        // tracks. The analysis' own refusal sentence when we have one.
        if let analysis = d.balanceAnalysis,
           let reason = BalanceAudioFix.refusalReason(for: analysis) {
            return .refused(reason)
        }
        let words = d.findings.map(VerifyAudioRules.noteFragment(for:)).joined(separator: "; ")
        return .refused("Balance Audio can't help here — \(words).")
    }

    static func verdict(for c: AudioChannelClass) -> String {
        switch c {
        case .leftOnly:  return "One-sided audio — left channel only"
        case .rightOnly: return "One-sided audio — right channel only"
        case .mono:      return "Mono audio — one channel"
        default:         return c.familyDescription
        }
    }

    /// "L −18.2 dBFS RMS · R silent" — the probe's numbers, one line.
    static func levelsLine(_ analysis: AudioBalanceAnalysis) -> String {
        let names = ["L", "R", "C", "LFE", "Ls", "Rs", "7", "8"]
        let parts = analysis.measurements.channels.enumerated().map { i, ch -> String in
            let name = i < names.count ? names[i] : "\(i + 1)"
            if ch.rmsDBFS == -Double.infinity || ch.rmsDBFS < AudioBalanceClassifier.programFloorDBFS {
                return "\(name) silent"
            }
            return "\(name) \(String(format: "%.1f", ch.rmsDBFS)) dBFS RMS"
        }
        return parts.joined(separator: " · ")
    }

    /// The one-line status (the Angel's verify step note).
    var headline: String {
        switch self {
        case .balanced(let s):            return s
        case .fixable(_, let verdict):    return verdict
        case .refused(let s):             return s
        case .damaged(let s):             return "Audio problem — \(s)"
        case .noAudio:                    return "No audio track in this file."
        }
    }
}
