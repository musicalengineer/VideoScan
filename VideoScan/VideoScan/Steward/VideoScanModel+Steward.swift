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
// can never disagree (GH #258, 2026-10-03: until then the Angel's picks and
// filed-as-Archived copies were only the steward's restraint, and the card
// had to say the drive's cleanup "would still check" them):
//
//   a file of the Master Archive, the
//   archive's whole drive, or a drive that
//   cannot be told apart from it ............. bulkDeleteRefusal(_:volume:)
//                                              with archiveVolumeProtection()
//   an archive copy while no Master Archive
//   is designated; filed as Archived in
//   Triage; Archive Angel recommends it,
//   holds it in a prepared batch, has just
//   promoted it or is preparing it now ....... duplicateDeletionHoldRule()
//                                              (VideoScanModel+Duplicates)
//
// The Angel's sets change without a catalog mutation (a sweep, a batch); the
// queue picks that up at the next catalog change or when the pane appears.
// The run itself asks again at every copy's turn.
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
            case nil: break
            }
            switch hold(r) {
            case .promotedArchiveCopy?, .filedArchived?: return .filedArchived
            case .angelChosen?: return .angel
            case nil: return .none
            }
        }
    }

    /// The People tab's birthdays, as the event guess wants them — the
    /// Angel's own reading of them (AngelFamilyBirthdays, read off the
    /// main actor when the Angel starts and before each of its sweeps).
    func stewardPeople() -> [StewardEventGuess.Person] {
        archiveAngel.familyBirthdays.map {
            StewardEventGuess.Person(displayName: $0.name, birthYear: $0.born.year,
                                     birthMonth: $0.born.month, birthDay: $0.born.day)
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
        let people = stewardPeople()
        // What was skipped, so the per-kind limit is spent on the rest.
        let skipped = StewardSkipStore(defaults: stewardDefaults).snapshot()
        stewardTask = Task { [weak self] in
            let queue = await Task.detached(priority: .utility) {
                StewardCaseBuilder.build(inputs: inputs, volumes: volumes,
                                         mountedRoots: VolumeReachability.currentMountedRoots(),
                                         alsoCleanUpWorkingCopies: alsoCleanUp, people: people, skipped: skipped)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.stewardSnapshot.publish(queue)
        }
    }

    /// The pane is on screen: start keeping the queue current.
    func stewardPaneAppeared() {
        stewardWanted = true
        scheduleStewardRefresh()
    }
}
