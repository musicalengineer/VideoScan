import Foundation
import Testing
@testable import VideoScan

// MARK: - Preservation checklist (Rick's idea, 2026-08-12)
//
// The sheet's job changed from "here is what happened" to "here is what
// is still missing", so these tests pin the two properties that decide
// whether it stays useful:
//
//   * The scoring is HONEST — a green tick means the file really has
//     that protection, so "safe" cannot be reached on three copies that
//     are all in the same building.
//   * The scoring does not CRY WOLF — no step can sit unchecked on a
//     file where there is nothing to do, because a checklist that is
//     permanently incomplete gets ignored, and then it protects nothing.

private func pcRec(
    signature: String = "",
    stage: ArchiveStage = .none,
    backups: [BackupEntry] = []
) -> VideoRecord {
    let r = VideoRecord()
    r.filename = "clip.mov"
    r.fullPath = "/Volumes/V/clip.mov"
    r.sizeBytes = 1_000
    r.contentHash = signature
    r.archiveStage = stage
    r.backupDestinations = backups
    return r
}

private let sig = "v1:" + String(repeating: "a", count: 64)

@Suite("Preservation checklist — scoring")
struct PreservationChecklistTests {

    /// A freshly catalogued file: known, but nothing else yet. Exactly
    /// one box ticked, and the next action names the very next step.
    @Test func freshRecordIsCataloguedOnly() {
        let steps = PreservationChecklist.steps(for: pcRec())
        #expect(steps.count == 4)
        #expect(steps[0].done, "holding the record IS being catalogued")
        #expect(!steps[1].done)
        #expect(!steps[2].done)
        #expect(!steps[3].done)
        #expect(PreservationChecklist.nextAction(for: pcRec())?.contains("signature") == true)
    }

    @Test func signatureTicksTheSignedStep() {
        let steps = PreservationChecklist.steps(for: pcRec(signature: sig))
        #expect(steps[1].done)
        #expect(PreservationChecklist.completion(for: pcRec(signature: sig)) == 0.5)
    }

    /// THE honesty test. Three copies that never leave the house are not
    /// a 3-2-1 backup — a fire takes all of them. A local copy must
    /// never satisfy the offsite step.
    @Test func localCopiesAloneNeverReachSafe() {
        let rec = pcRec(signature: sig, backups: [
            BackupEntry(name: "LTA_Crucial", kind: .local, date: Date()),
            BackupEntry(name: "Master RAID", kind: .local, date: Date()),
        ])
        let steps = PreservationChecklist.steps(for: rec)
        #expect(steps[2].done, "local archive satisfied")
        #expect(!steps[3].done, "offsite must NOT be satisfied by local copies")
        let allDone = steps.filter(\.done).count == steps.count
        #expect(!allDone)
    }

    /// Cloud and offsite are the same claim — "not in this building" —
    /// which is the only property that matters against fire and theft.
    @Test func cloudOrOffsiteBothSatisfyTheAwayCopy() {
        for kind in [BackupEntry.BackupKind.cloud, .offsite] {
            let rec = pcRec(signature: sig, backups: [
                BackupEntry(name: "local", kind: .local, date: Date()),
                BackupEntry(name: "away", kind: kind, date: Date()),
            ])
            let steps = PreservationChecklist.steps(for: rec)
            let allDone = steps.filter(\.done).count == steps.count
            #expect(allDone, "\(kind) should complete the journey")
            #expect(PreservationChecklist.nextAction(for: rec) == nil)
        }
    }

    /// A record already marked archived counts as locally archived even
    /// with no BackupEntry — older records predate that bookkeeping, and
    /// nagging someone to redo work they already did is how a checklist
    /// loses their trust.
    @Test func archivedStageSatisfiesLocalWithoutABackupEntry() {
        let steps = PreservationChecklist.steps(for: pcRec(signature: sig, stage: .archived))
        #expect(steps[2].done)
    }

    /// SENSOR — the design rule. "Migrated" was in Rick's first sketch
    /// and was deliberately left out: most files never migrate, so the
    /// box would sit grey forever on perfectly safe media. Every SCORED
    /// step must be one a fully-protected file can actually complete.
    @Test func aFullyProtectedFileScoresOneHundredPercent() {
        let rec = pcRec(signature: sig, stage: .archived, backups: [
            BackupEntry(name: "Master RAID", kind: .local, date: Date()),
            BackupEntry(name: "Backblaze", kind: .cloud, date: Date()),
        ])
        #expect(PreservationChecklist.completion(for: rec) == 1.0,
                "no step may be unreachable — an always-grey box teaches the eye to ignore all of them")
        #expect(PreservationChecklist.nextAction(for: rec) == nil)
    }

    /// Every incomplete step must say what to DO. A box that reports a
    /// gap without naming the fix is a scold, not an instruction.
    @Test func everyIncompleteStepCarriesAnAction() {
        for step in PreservationChecklist.steps(for: pcRec()) where !step.done {
            #expect(!step.todo.isEmpty, "\(step.kind) has no next action")
        }
    }
}
