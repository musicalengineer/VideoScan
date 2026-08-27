// HelperAudioRepair.swift
// Archive Helper — "Verify / Fix Audio" (Rick, 2026-08-26 live report):
// the Helper's Verify Audio step ended in a log line and offered
// nothing; the panel kept showing "Verify Audio First". Now the verdict
// lands INLINE under the actions, and when the track is one-sided or
// mono the panel offers Balance Audio right there (one-click "Verify
// and Fix Audio" chains the two).
//
// Two halves, the engine/commit split the rest of the app uses:
//
//   * PURE — `HelperAudioOutcome` (what a finished diagnosis means to
//     the Helper) and `HelperAudioActions.compose` (how it reshapes the
//     assessor's action list). No I/O, fully unit-tested.
//   * COORDINATOR — `VerifyThenBalanceCoordinator` drives the EXISTING
//     MFO verbs (startVerifyAudio / startBalanceAudio(fromDiagnosis:))
//     for one record and watches their jobs to completion. Nothing here
//     decodes or renders media itself; the Catalog Verify sheet's path
//     is untouched and the same Center entry points are shared.
//
// Memory: the coordinator holds one diagnosis (≈1 KB) and weak/strong
// refs to at most two live jobs — nothing scales with file size.

import Combine
import Foundation

// MARK: - Pure: outcome of a diagnosis, as the Helper reads it

/// What a completed Verify Audio diagnosis means for the Helper's next
/// step. (≈ a C++ tagged union — each case carries only what its
/// branch of the UI needs.)
enum HelperAudioOutcome: Equatable {
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

    static func from(_ d: AudioVerifyDiagnosis) -> HelperAudioOutcome {
        // The imbalance finding is only ever produced when the fix gate
        // is open (VerifyAudioRules), but the gate is consulted AGAIN
        // here — the Helper must never promise what the job refuses.
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

    /// The one-line status the panel prints under the actions.
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

// MARK: - Pure: reshape the assessor's actions

enum HelperAudioActions {
    /// Overlay a verify outcome on the assessor's action list.
    ///
    /// `repairedCopyExists` = the family already holds a repaired copy
    /// (a `balanceAudio` derivation) OR this session just made one. The
    /// 2026-08-19 rule: an already-balanced companion NEVER re-offers
    /// Balance — the repaired copy answers the audio question, and the
    /// assessor's `.promoteOriginalAndRepaired` takes over.
    static func compose(base: [CopyFamilyAction],
                        outcome: HelperAudioOutcome?,
                        repairedCopyExists: Bool) -> [CopyFamilyAction] {
        var out = base.filter { $0 != .balanceAudio }
        if repairedCopyExists {
            out.removeAll { $0 == .verifyAudioFirst }
            return out
        }
        guard let outcome else { return out }
        switch outcome {
        case .fixable:
            out.removeAll { $0 == .verifyAudioFirst }
            out.insert(.balanceAudio, at: 0)
        case .balanced, .refused, .noAudio:
            out.removeAll { $0 == .verifyAudioFirst }
        case .damaged:
            break       // the assessor's damaged-audio nag stands
        }
        return out
    }
}

// MARK: - Coordinator: verify → (balance) for ONE record

/// Drives Verify Audio and, when the verdict is fixable, Balance Audio
/// for one record through the MFO Center, watching each job to its
/// terminal state. Owned by the AssessCopiesJob (one per record) so it
/// outlives the panel's view re-creation.
///
/// (`@MainActor` ≈ "every member runs on the UI thread"; the jobs it
/// watches are main-actor objects too, so no locking is needed.)
@MainActor
final class VerifyThenBalanceCoordinator: ObservableObject {

    enum Phase: Equatable {
        case idle
        case verifying
        case verified
        case balancing
        case balanced
        case failed(String)
    }

    let record: VideoRecord
    private weak var center: MediaFileOperationsCenter?
    private weak var model: VideoScanModel?

    @Published private(set) var phase: Phase = .idle
    /// Newest completed diagnosis for the record (seeded from the
    /// Center's session cache — the same cache the Catalog sheet reads —
    /// so a verify done from the Catalog shows here without re-running).
    @Published private(set) var diagnosis: AudioVerifyDiagnosis?
    @Published private(set) var verifyJob: VerifyAudioJob?
    @Published private(set) var balanceJob: BalanceAudioJob?
    /// Set once a balance job publishes its output.
    @Published private(set) var balancedOutputName: String?

    /// Hooks the owning job uses to re-assess the family.
    var onVerifyFinished: (() -> Void)?
    var onBalanceFinished: (() -> Void)?

    private var watchers: [AnyCancellable] = []
    private var chainBalanceAfterVerify = false

    /// TEST SEAM only (the VerifyAudioProbe override convention) —
    /// forwarded to startVerifyAudio; production never sets it.
    var diagnoseOverride: (@Sendable (String) async throws -> AudioVerifyDiagnosis)?

    init(record: VideoRecord, center: MediaFileOperationsCenter, model: VideoScanModel) {
        self.record = record
        self.center = center
        self.model = model
        if let cached = center.verifyDiagnosis(forRecordID: record.id) {
            diagnosis = cached
            phase = .verified
        }
    }

    var outcome: HelperAudioOutcome? { diagnosis.map(HelperAudioOutcome.from) }

    var isBusy: Bool { phase == .verifying || phase == .balancing }

    /// Where the balanced copy will land — the SAME planner the Catalog
    /// sheet and the job use (`<stem>_balanced.<ext>`, raw DV → .mov).
    var plannedBalanceOutput: URL? {
        guard case .fixable(let analysis, _)? = outcome else { return nil }
        return BalanceAudioFix.balancedOutputURL(forSourcePath: record.fullPath,
                                                containerFormat: analysis.shape.containerFormat)
    }

    // MARK: Verify

    /// Start (or attach to) a Verify Audio job. `thenBalance` chains a
    /// balance when the verdict is fixable — the one-click path.
    func verify(thenBalance: Bool) {
        guard let center, let model, !isBusy else { return }
        chainBalanceAfterVerify = thenBalance
        phase = .verifying
        // The Center refuses a duplicate dispatch (returns nil) when a
        // verify for this record is already running — attach to that
        // one instead of failing the click.
        let job = center.startVerifyAudio(record: record, model: model,
                                          diagnoseOverride: diagnoseOverride)
            ?? center.jobs.compactMap { $0 as? VerifyAudioJob }
                .first { $0.record.id == record.id && $0.state.isActive }
        guard let job else {
            phase = .failed("Verify Audio could not be started.")
            return
        }
        verifyJob = job
        watch(job) { [weak self] in self?.verifyReachedTerminal(job) }
    }

    private func verifyReachedTerminal(_ job: VerifyAudioJob) {
        guard phase == .verifying else { return }     // terminal handled once
        switch job.state {
        case .finished:
            diagnosis = job.diagnosis
            phase = .verified
            onVerifyFinished?()
            if chainBalanceAfterVerify, case .fixable? = outcome {
                balance()
            }
            chainBalanceAfterVerify = false
        case .failed(let message):
            phase = .failed(message)
        case .cancelled:
            phase = .idle
        case .running, .cancelling:
            break
        }
    }

    // MARK: Balance

    /// Start Balance Audio from the held diagnosis. Refuses (no-op) when
    /// the outcome is not fixable — the button is never shown then, this
    /// is the model-layer twin of that rule.
    func balance() {
        guard let center, let model, !isBusy,
              case .fixable(let analysis, _)? = outcome,
              let diagnosis else { return }
        _ = analysis
        let planned = plannedBalanceOutput
        phase = .balancing
        appLog.write("balance audio (helper): \(record.filename) — started from Archive Helper")
        guard let job = center.startBalanceAudio(record: record,
                                                 fromDiagnosis: diagnosis,
                                                 model: model,
                                                 plannedOutput: planned) else {
            phase = .failed("A balance job for this file is already running — watch it in Media File Operations.")
            return
        }
        balanceJob = job
        watch(job) { [weak self] in self?.balanceReachedTerminal(job) }
    }

    private func balanceReachedTerminal(_ job: BalanceAudioJob) {
        guard phase == .balancing else { return }     // terminal handled once
        switch job.state {
        case .finished:
            balancedOutputName = job.publishedURL?.lastPathComponent ?? job.outputURL.lastPathComponent
            phase = .balanced
            onBalanceFinished?()
        case .failed(let message):
            phase = .failed(message)
        case .cancelled:
            phase = .verified
        case .running, .cancelling:
            break
        }
    }

    // MARK: Job watching

    /// Re-publish the job's changes as our own (so the panel repaints
    /// progress) and run `onChange` after each — it checks for the
    /// terminal state. `receive(on:)` delivers AFTER the job's property
    /// has actually changed (objectWillChange fires before).
    private func watch<J: MediaFileOperationJob>(_ job: J, onChange: @escaping () -> Void) {
        watchers.removeAll()
        let c = job.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                onChange()
            }
        watchers.append(c)
        // A job can already be terminal (refused at dispatch).
        DispatchQueue.main.async(execute: onChange)
    }
}
