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
// decided HERE, per record, by the predicates the rest of the app already
// uses. None is new:
//
//   REFUSED BY THE DELETE PLANNER TOO (`plannerRefuses`):
//   a file of the Master Archive, the
//   archive's whole drive, or a drive that
//   cannot be told apart from it ............. bulkDeleteRefusal(_:volume:)
//                                              with archiveVolumeProtection()
//                                              (the Delete planner's own rule)
//   THE STEWARD'S OWN RESTRAINT (the planner has no such guard — QA F1;
//   the card says a drive's cleanup would still check these):
//   an archive copy while no Master Archive
//   is designated ............................ isArchiveElement(_:)
//   filed as Archived in Triage .............. lifecycleStage == .archived
//                                              (Triage's own table rule)
//   Archive Angel recommends it, holds it in
//   a prepared batch, or just promoted it .... archiveAngel.recommendations
//                                              .candidateIDs / .preparedIDs /
//                                              .promotedIDs (the Angel's ONE
//                                              set of numbers)
//
// Rule 2 is about what a card proposes to LET GO. An event card proposes
// nothing of the kind — it lists what belongs together — so it may list an
// archived clip or one the Angel has chosen, and says so ("3 are in the
// archive").
//
// The Angel's sets change without a catalog mutation (a sweep, a batch); the
// queue picks that up at the next catalog change or when the pane appears.
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

extension VideoScanModel {

    /// The rule-2 answer for one record, from the canonical predicates (see
    /// the file header). Build ONCE per pass and call per record: the
    /// archive-drive snapshot and the Angel's sets are captured here.
    func stewardProtectionRule() -> (VideoRecord) -> StewardProtection {
        let archiveDrive = archiveVolumeProtection()
        let angel = archiveAngel.recommendations
        // Used and dropped within one pass, so a strong `self` is fine.
        return { r in
            switch self.bulkDeleteRefusal(r, volume: archiveDrive) {
            case .archiveTree?: return .archived
            case .archiveVolume?, .archiveVolumeUnprovable?: return .archiveDrive
            case nil: break
            }
            if self.isArchiveElement(r) || r.lifecycleStage == .archived { return .filedArchived }
            if angel.preparedIDs.contains(r.id) || angel.candidateIDs.contains(r.id) || angel.promotedIDs.contains(r.id) {
                return .angel
            }
            return .none
        }
    }

    /// Project on the main actor, build off it, publish once. A newer call
    /// cancels the in-flight one. Does nothing until the pane has asked.
    func scheduleStewardRefresh() {
        guard stewardWanted else { return }
        stewardTask?.cancel()
        let inputs = StewardCaseBuilder.project(records, protection: stewardProtectionRule())
        let volumes = AnalyzeCoverageCalculator.volumeFacts(scanTargets)
        let alsoCleanUp = duplicateKeeperSettings.alsoCleanUpWorkingCopies
        // What the event labeller is told, exactly as the Angel tells it:
        // the policy's birthday window and the People tab's birthdays (the
        // Angel's own reading of them, off the main actor when it starts
        // and before each of its sweeps), captured by value. The labels
        // themselves are always on for a reader.
        let events = archiveAngel.occasionReader
        let now = Date()
        // What was skipped, so the per-kind limit is spent on the rest.
        let skipped = StewardSkipStore(defaults: stewardDefaults).snapshot()
        stewardTask = Task { [weak self] in
            let queue = await Task.detached(priority: .utility) {
                StewardCaseBuilder.build(inputs: inputs, volumes: volumes,
                                         mountedRoots: VolumeReachability.currentMountedRoots(),
                                         alsoCleanUpWorkingCopies: alsoCleanUp, events: events, skipped: skipped,
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
        scheduleStewardRefresh()
    }

    /// The pane left the screen (QA F9): stop rebuilding the queue on every
    /// catalog change. The last queue stays published — it is ≤ 100 cases.
    /// Counted, because the next pane's appear can arrive before this.
    func stewardPaneDisappeared() {
        stewardPaneCount = max(0, stewardPaneCount - 1)
        guard stewardPaneCount == 0 else { return }
        stewardWanted = false
        stewardTask?.cancel()
        stewardTask = nil
    }
}
