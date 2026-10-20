// ImportToSQLitePhases.swift
// The phase pieces Import to SQLite introduced (Rick 2026-10-17: "in future
// this should be one action verb") that Validate Catalog still drives. The
// import job itself, its dry-run marker and build identity were retired
// 2026-10-20 ("JSON gone": the cutover is done); what is left here is used by
// ValidateCatalogJob / CatalogPhaseDriver and the audit's owner-token save.
// (The names keep their "Import" prefix to keep this retirement a pure
// removal; a rename is a separate, mechanical change.)
//
//   • ImportPhaseJob — what a driver needs from the two jobs it runs as
//     phases 1 and 2 (the existing CatalogAuditJob and VerifyCatalogJob,
//     unchanged in what they do; they are simply not added to the center).
//   • ImportPhaseVerdict — PURE: what a finished phase job's state means
//     for the import (go on / stopped / could not complete, with words).
//   • ImportToSQLiteTiming.verifyStartDelay — PURE: the importer's gate
//     refuses an audit that finished in the same whole second Verify
//     Catalog started (`finishedAt >= report.startedAt`, unix seconds); the
//     job waits out that second before it makes the verify job, re-reading
//     the wall clock after each wake (`waitForVerifyStart`, bounded — a
//     backward clock step is waited out again, codex 2026-10-17 P3).
//     Validate Catalog keeps the same rule between its two phases.
//
// (For Rick: a protocol here ≈ a C++ abstract interface the two concrete
// job classes already satisfy; `extension X: P {}` declares that they do.)

import Foundation

/// What Validate Catalog (and, until 2026-10-20, Import to SQLite) drives in
/// a phase job through CatalogPhaseDriver: start it, await its task, read
/// its state. Both phase jobs already have these members (main-actor
/// isolated conformances, like their MediaFileOperationJob ones).
protocol ImportPhaseJob: MediaFileOperationJob {
    func start()
    var task: Task<Void, Never>? { get }
}

extension CatalogAuditJob: @MainActor ImportPhaseJob {}
extension VerifyCatalogJob: @MainActor ImportPhaseJob {}

/// What a phase job's terminal state means for the import.
enum ImportPhaseVerdict: Equatable {
    case proceed
    case stopped
    /// The phase's own words, prefixed with who could not complete.
    case couldNotComplete(String)

    /// `step` names the phase in the row ("the audit", "Verify Catalog").
    static func of(_ state: MediaFileOperationState, step: String) -> ImportPhaseVerdict {
        switch state {
        case .finished: return .proceed
        case .cancelled, .cancelling: return .stopped
        case .failed(let message): return .couldNotComplete("\(step) could not complete: \(message)")
        case .running: return .couldNotComplete("\(step) did not finish")
        }
    }
}

enum ImportToSQLiteTiming {
    /// Seconds to wait after the audit finished before Verify Catalog may
    /// start. The marker and the report both carry ISO-8601 whole seconds
    /// (truncated or rounded — either way monotone), and the gate refuses
    /// `audit.finishedAt >= report.startedAt`; starting at or after
    /// floor(finished) + 1.5 s puts the report's second strictly after the
    /// audit's under either rounding. Worst case 1.5 s.
    static func verifyStartDelay(auditFinishedAt: Date, now: Date) -> TimeInterval {
        let safe = auditFinishedAt.timeIntervalSince1970.rounded(.down) + 1.5
        return max(0, safe - now.timeIntervalSince1970)
    }

    /// How many waits `waitForVerifyStart` makes before it gives up on a
    /// clock that keeps stepping back (each wait is at most ~1.5 s plus
    /// the step).
    static let verifyWaitRounds = 5

    /// Wait until Verify may start, RE-READING the wall clock after every
    /// wake (codex 2026-10-17 P3): a backward clock step during the sleep
    /// (NTP slew/step) would otherwise start Verify inside the audit's
    /// second and the gate would refuse. Returns false when the clock is
    /// still short after `verifyWaitRounds` waits — the job refuses with
    /// words rather than start a run the gate must refuse. `now` and
    /// `sleep` are injected (tests step the clock). (For Rick: a
    /// check-sleep-recheck loop, as with a condition variable's spurious
    /// wakeups — never trust that the sleep alone made the condition true.)
    @MainActor
    static func waitForVerifyStart(auditFinishedAt: Date, now: () -> Date,
                                   sleep: (TimeInterval) async -> Void) async -> Bool {
        for _ in 0..<verifyWaitRounds {
            let wait = verifyStartDelay(auditFinishedAt: auditFinishedAt, now: now())
            if wait <= 0 { return true }
            await sleep(wait)
        }
        return verifyStartDelay(auditFinishedAt: auditFinishedAt, now: now()) <= 0
    }
}

extension VideoScanModel {
    /// The acknowledged durable save (codex #1659), presenting the token of
    /// a MOPS-16 write hold — the holder's own writer (the audit inside
    /// Import to SQLite) passes the hold; nil = an ordinary save, which a
    /// hold refuses. `saveCatalogAcknowledged()` is this with nil.
    func saveCatalogAcknowledged(asHoldOwner owner: CatalogWriteHoldOwner?) async -> Bool {
        noteCatalogMutated()
        // Cutover B2: under catalog.sqlite the committer takes it (the hold's
        // OWN owner passes, as with the JSON store — B2.1 compares the token).
        if let committer = catalogCutover.committer { return await committer.commitAcknowledged(owner: owner) }
        return await catalogStore.saveAcknowledged(records: records, as: owner)
    }
}
