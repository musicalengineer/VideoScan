// VideoScanModel+Steward.swift
// The model-owned cache behind the Triage tab's steward pane (trial UI,
// 2026-10-03; design §5.6).
//
// Pattern = AnalyzeCoverage / VolumeDashboard: ONE main-actor projection
// pass over `records` (Sendable rows), the case building in a detached
// task, the result published through a tiny equality-gated ObservableObject
// the pane observes. It rides the debounced catalog-change pass
// (`refreshDossierCountsNow`), so a scan's stream of appends is one rebuild
// — and ONLY once the pane has been on screen this launch (`stewardWanted`):
// a launch that never opens the Triage tab pays nothing.
//
// NO O(records) work in any view body: the pane reads
// `stewardSnapshot.queue` and nothing else.
//
// RULE 2 of §5.6 — "one steward's cases are never another's loss" — is
// decided HERE, per record, by the Delete planner's OWN two rules — the
// steward has no list of its own, so a card and the run behind its button
// can never disagree (GH #258, 2026-10-03):
//
//   a file of the Master Archive, the
//   archive's whole drive, or a drive that
//   cannot be told apart from it; a drive
//   the person marked Read only .............. bulkDeleteRefusal(_:volume:)
//                                              with archiveVolumeProtection()
//   an archive copy while no Master Archive
//   is designated; in use by the Archive
//   Angel (a prepared batch, a batch being
//   or just promoted, a running Prepare) ..... duplicateDeletionHoldRule()
//                                              (VideoScanModel+Duplicates)
//
// WHERE rule 2 runs (2026-10-04 perf; Rick's Time Profiler trace had it at
// 1.1 s of main thread per refresh): the gate's inputs and each record's
// subject + hold are captured on the main actor; the per-record gate runs
// in the detached build task. WHAT it decides is unchanged — the main-actor
// reference `stewardProtectionRule()` and the off-main path are pinned
// equal record for record (StewardOffMainProtectionTests).
//
// Rule 2 is about what a card proposes to LET GO. An event card proposes
// nothing of the kind — it lists what belongs together — so it may list an
// archived clip or one the Angel has chosen, and says so ("3 are in the
// archive").
//
// The Angel's sets change without a catalog mutation (a sweep, a batch).
// While a pane is on screen the model watches the Angel's published
// recommendations (`archiveAngel.$recommendations`, its public surface) and
// rebuilds the queue — debounced; the planner's hold rule is re-asked and an
// unchanged queue publishes nothing (QA F9). Off screen, nothing is
// watched. The run itself asks again at every copy's turn.
//
// (For Rick: `Task.detached` ≈ a worker thread that does NOT inherit the
// caller's actor; only Sendable values cross.)

import Foundation
import Combine
import VideoScanCore

/// The pane's ONLY observed dependency for cases. Publishing an unchanged
/// queue is a no-op (zero invalidation).
@MainActor
final class StewardSnapshot: ObservableObject {
    @Published private(set) var queue = StewardQueue()
    /// Test hook: how many builds actually landed.
    private(set) var publishCount = 0

    func publish(_ new: StewardQueue) {
        guard new != queue else { return }
        publishCount += 1
        queue = new
    }
}

/// Moves the projected rows into the detached build exactly once, so the
/// build owns the only reference and can fill in `protection` in place.
/// (For Rick: ≈ a std::move through a heap cell; the lock makes the single
/// hand-over safe across threads.)
final class StewardInputHandoff: @unchecked Sendable {
    private var rows: [StewardInput]?
    private let lock = NSLock()

    init(_ rows: [StewardInput]) { self.rows = rows }

    func take() -> [StewardInput] {
        lock.lock()
        defer { lock.unlock() }
        let taken = rows ?? []
        rows = nil
        return taken
    }
}

extension VideoScanModel {

    /// THE REFERENCE for rule 2, asked record by record on the main actor.
    /// The live refresh asks the very same rules as captured values off the
    /// main actor (`stewardRuleCapture` + `resolveStewardProtection`);
    /// StewardOffMainProtectionTests pins the two equal.
    ///
    /// The rule-2 answer for one record, from the Delete planner's own two
    /// rules (see the file header), in the planner's own order. Build ONCE
    /// per pass and call per record: the archive-drive snapshot and the
    /// Angel's sets are captured here.
    func stewardProtectionRule() -> (VideoRecord) -> StewardProtection {
        let archiveDrive = archiveVolumeProtection()
        let hold = duplicateDeletionHoldRule()
        // Used and dropped within one pass, so a strong `self` is fine.
        return { r in
            switch self.bulkDeleteRefusal(r, volume: archiveDrive) {
            case .archiveTree?: return .archived
            case .archiveVolume?, .archiveVolumeUnprovable?: return .archiveDrive
            case .readOnlyVolume?, .readOnlyVolumeDifferentDrive?: return .readOnlyDrive
            case nil: break
            }
            switch hold(r) {
            case .promotedArchiveCopy?: return .archiveCopy
            case .inUseByAngel?: return .angel
            case nil: return .none
            }
        }
    }

    /// What rule 2 needs of one record, captured on the main actor: the
    /// bulk-verb gate's subject and the planner's hold (a few set lookups).
    struct StewardRuleFacts: Sendable, Equatable {
        let subject: BulkDeleteSubject
        let hold: DuplicateDeletionHold?
    }

    /// The main-actor half of the off-main rule 2 (2026-10-04 perf): the
    /// Delete planner's bulk-verb gate captured as a value
    /// (`bulkDeleteGate(volume: archiveDrive)`, the same archive-drive
    /// snapshot `stewardProtectionRule` uses) and, per record, its subject
    /// and the hold rule's answer. The gate itself — the per-record path
    /// work the 2026-10-04 trace caught on the main thread — runs in
    /// `resolveStewardProtection`, off it.
    func stewardRuleCapture() -> (gate: BulkDeleteGate, facts: (VideoRecord) -> StewardRuleFacts) {
        let archiveDrive = archiveVolumeProtection()
        let gate = bulkDeleteGate(volume: archiveDrive)
        let hold = duplicateDeletionHoldRule()
        // Used and dropped within one pass, so a strong `self` is fine.
        return (gate, { r in StewardRuleFacts(subject: self.bulkDeleteSubject(r), hold: hold(r)) })
    }

    /// Rule 2's answer from the gate's refusal and the hold, in the
    /// planner's order — the mapping `stewardProtectionRule` makes.
    nonisolated static func stewardProtection(refusal: BulkDeleteRefusal?, hold: DuplicateDeletionHold?) -> StewardProtection {
        switch refusal {
        case .archiveTree?: return .archived
        case .archiveVolume?, .archiveVolumeUnprovable?: return .archiveDrive
        case .readOnlyVolume?, .readOnlyVolumeDifferentDrive?: return .readOnlyDrive
        case nil: break
        }
        switch hold {
        case .promotedArchiveCopy?: return .archiveCopy
        case .inUseByAngel?: return .angel
        case nil: return .none
        }
    }

    /// Off the main actor: fill every row's `protection` from its facts.
    /// Pure. Same answer as `stewardProtectionRule()` asked of the same
    /// records at capture time — pinned by StewardOffMainProtectionTests.
    nonisolated static func resolveStewardProtection(_ inputs: inout [StewardInput], facts: [StewardRuleFacts],
                                                     gate: BulkDeleteGate) {
        precondition(inputs.count == facts.count, "facts are index for index with the rows")
        for i in inputs.indices {
            let f = facts[i]
            inputs[i].protection = stewardProtection(refusal: gate.refusal(for: f.subject), hold: f.hold)
        }
    }

    /// Project on the main actor, build off it, publish once. A newer call
    /// cancels the in-flight one. Does nothing until the pane has asked.
    /// Rule 2 — the per-record gate — is resolved in the detached task
    /// from facts captured here (2026-10-04 perf: 1.1 s on the main thread
    /// per refresh in Rick's trace).
    func scheduleStewardRefresh() {
        guard stewardWanted else { return }
        stewardTask?.cancel()
        let rule = stewardRuleCapture()
        let gate = rule.gate
        let projected = StewardCaseBuilder.project(records, facts: rule.facts)
        // Handed to the detached task by moving, so filling in `protection`
        // there mutates in place instead of copying ~35 MB at 100k.
        let handoff = StewardInputHandoff(projected.inputs)
        let ruleFacts = projected.facts
        let volumes = AnalyzeCoverageCalculator.volumeFacts(scanTargets)
        let alsoCleanUp = duplicateKeeperSettings.alsoCleanUpWorkingCopies
        // QA F6(a): the Delete planner's own policy (a Sendable value), so
        // a working copy is "checked" only when the planner's cross-drive
        // rule would take it.
        let workingCopyPolicy = alsoCleanUp ? duplicateKeeperPolicy() : .unconfigured
        // What the event labeller is told, exactly as the Angel tells it:
        // the policy's birthday window and the People tab's birthdays (the
        // Angel's own reading of them, off the main actor when it starts
        // and before each of its sweeps), captured by value. The labels
        // themselves are always on for a reader.
        let events = archiveAngel.occasionReader
        let now = Date()
        // What was skipped, so the per-kind limit is spent on the rest.
        let store = StewardSkipStore(defaults: stewardDefaults)
        let skipped = store.snapshot()
        // …and the junk cards a person has finished from the table (QA F8).
        let reviewed = store.reviewedSnapshot()
        stewardTask = Task { [weak self] in
            let queue = await Task.detached(priority: .utility) {
                var inputs = handoff.take()
                VideoScanModel.resolveStewardProtection(&inputs, facts: ruleFacts, gate: gate)
                return StewardCaseBuilder.build(inputs: inputs, volumes: volumes,
                                         mountedRoots: VolumeReachability.currentMountedRoots(),
                                         alsoCleanUpWorkingCopies: alsoCleanUp, workingCopyPolicy: workingCopyPolicy,
                                         events: events, skipped: skipped, reviewed: reviewed,
                                         now: now)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.stewardSnapshot.publish(queue)
        }
    }

    /// The pane is on screen: start keeping the queue current.
    func stewardPaneAppeared() {
        stewardPaneCount += 1
        stewardWanted = true
        watchTheAngelForSteward()
        scheduleStewardRefresh()
    }

    /// How long the Angel's changes are gathered before one rebuild.
    static let stewardAngelDebounceMS = 300

    /// QA F9: the Angel's picks are rule 2's input, and they change without
    /// any catalog change. Watch its published recommendations (the
    /// façade's public surface) while the pane is up. `@Published` sends
    /// BEFORE the value is stored, so the debounce also lets it land.
    /// (For Rick: a Combine pipeline ≈ an observer callback with a
    /// coalescing timer in front; the AnyCancellable is its RAII handle.)
    func watchTheAngelForSteward() {
        guard stewardAngelWatch == nil else { return }
        stewardAngelWatch = archiveAngel.$recommendations
            .dropFirst()
            // No set-by-set filter here (merge of main's QA F9 with GH
            // #258): rule 2 is the planner's hold rule, which reads more
            // than this summary (batches on disk, a running Prepare, a
            // hand-over) and not the Angel's mere candidates — so the
            // steward does not second-guess which sets matter. The
            // debounce coalesces a burst; an unchanged queue publishes
            // nothing (`StewardSnapshot.publish`).
            .debounce(for: .milliseconds(Self.stewardAngelDebounceMS), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleStewardRefresh() }
            }
    }

    /// The pane left the screen (QA F9): stop rebuilding the queue on every
    /// catalog change. The last queue stays published — it is ≤ 100 cases.
    /// Counted, because the next pane's appear can arrive before this.
    func stewardPaneDisappeared() {
        stewardPaneCount = max(0, stewardPaneCount - 1)
        guard stewardPaneCount == 0 else { return }
        stewardWanted = false
        stewardAngelWatch?.cancel()
        stewardAngelWatch = nil
        stewardTask?.cancel()
        stewardTask = nil
    }
}
