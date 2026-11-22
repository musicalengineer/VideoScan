// DeleteDuplicatesWorkTypes.swift
// Delete Duplicates — the VALUES that cross between the job (main actor)
// and its disk worker (off it): the work item for one pair, the answer
// asked at the removal boundary, and the outcomes of the two disk phases.
// Pure declarations, moved out of DeleteDuplicatesJob.swift unchanged on
// 2026-11-21 (GH #504) to keep that file under its length limit; the job
// and `DeleteDuplicatesDiskWorker` are in DeleteDuplicatesJob.swift.
//
// (For Rick: plain structs/enums passed by value between threads —
// `Sendable` ≈ "safe to hand to another thread", checked by the compiler.)

import Foundation
import VideoScanCore

// MARK: - Off-main work item + outcome

struct DeleteDuplicatesWorkItem: Sendable {
    let path: String
    let keeperPath: String
    let keeperFilename: String
    /// The keeper's stored whole-file fixity, if it has one.
    let keeperFixity: ContentFixity?
    /// True when THIS RUN already has fresh evidence for exactly that
    /// fixity (GH #504 D4): an earlier pair re-read the keeper and got its
    /// digest, or a verified two-file comparison in this run produced it.
    /// False → the worker reads the keeper once, in full, before the hold.
    var keeperConfirmedThisRun: Bool = false
    /// The quarantine folder name for THIS row (plan + row ids), so a
    /// crash leaves a folder the plan can name even before it is saved.
    let quarantineDirectoryName: String
    /// The family's other copies, for the copy-count tier.
    let tierCandidates: DeletionTierCandidates
    /// Which siblings the worker may READ to prove them (2026-09-21), and
    /// when to stop. `.none` = stat only, as before.
    var siblingAllowance: SiblingProver.Allowance = .none
    /// R4 — the NETWORK gate: a copy on a network share is never a target
    /// (no reliable Trash, no reliable identity). Asked before the move and
    /// again at the removal. Tests inject; production asks statfs.
    var isNetworkMount: @Sendable (String) -> Bool = DeleteDuplicatesTargetGate.liveIsNetworkMount
    /// R4 — a CATALOG target gate that holds this copy (half of a recovered
    /// A/V pair; longer than an archive master, or not comparable with
    /// one), found at the copy's turn (`duplicateTargetHold`). nil = none.
    var targetHold: String? = nil
    /// The drive the plan cleans — so a copy not on disk at its turn can be
    /// told MISSING (drive here, file gone) from OFFLINE (drive away). R6.
    var volumePath: String = ""
    /// The Master Archive VOLUME re-check (2026-09-22 follow-up, QA
    /// MINOR 3), captured on the main actor: the snapshot plus the UUID
    /// probe. Asked of the file's OWN volume before it is moved into
    /// quarantine and again as the final verdict before removal — so a
    /// symlinked scan root or custom mount path to FamilyArchive, whose
    /// path text says "boot disk", is still refused (as Junk does).
    /// nil = no Master Archive designated.
    var archiveCheck: ArchiveRemovalCheck? = nil
    /// THE REMOVAL BOUNDARY (codex #258 F6, r3, r4): asked ONCE by the final
    /// verdict, immediately before the unlink / the move to the Trash —
    /// everything it reads is read there and then, and the model's part
    /// comes over in ONE synchronous hop to the main actor
    /// (`DeleteDuplicatesJob.removalBoundary`). Built per row at dispatch;
    /// it is handed the path the file is at when it is asked (its
    /// quarantine path). nil only for hand-built items in tests.
    var boundary: (@Sendable (_ currentPath: String) -> RemovalBoundaryAnswer)? = nil
    /// REVIEWED plans (codex delete-engines F4): the target and keeper Rick
    /// reviewed. The bytes phase one PROVED must be those files — the
    /// quarantine baseline and the proof's keeper — else the copy is put
    /// back and held. nil for bulk plans.
    var reviewed: ReviewedIdentity? = nil
}

/// What the final verdict learns at the removal boundary, all of it read
/// immediately before the removal (MOPS-2).
struct RemovalBoundaryAnswer: Sendable {
    /// The copy is HELD now (in use by the Archive Angel, the Angel's
    /// buffer unreadable, on a drive marked Read only, the catalog gone):
    /// the row's note. The file is put back; the row is a skip.
    var holdNote: String?
    /// The Master Archive rule, from the designation as it is NOW, refuses
    /// the file (asked only when nothing holds it): its note, and whether
    /// the refusal is only transient (the drive list is being rebuilt).
    var archive: (note: String, transient: Bool)?
}

enum DeleteDuplicatesDiskOutcome: Sendable {
    /// Phase 1 done: verified and in quarantine, not yet removed; the
    /// tier facts were gathered with the file's digest in hand.
    case quarantined(QuarantineTicket, facts: DeletionTierFacts)
    /// UNLINKED. Never requested since Trash only (2026-10-09): the job
    /// hands the verifier `.trash` and nothing else. Kept so that if the
    /// verifier ever reported an unlink, the row would say what really
    /// happened (the file is gone) instead of a comfortable lie.
    case deleted(bytes: Int64, proof: VerifiedDuplicate)
    case trashed(bytes: Int64, location: String, proof: VerifiedDuplicate)
    case refused(reason: String, cancelled: Bool)
    /// The tier said too few verified copies would remain: put back
    /// untouched (or never moved), not a refusal, the row keeps its
    /// disposition. `facts` carry the count for the row.
    case leftAlone(reason: String, facts: DeletionTierFacts)
    case failed(reason: String)
    case retained(path: String, reason: String)
    /// R6: not on disk at its turn, its drive connected — nothing to move.
    case missing(reason: String)
    /// R6: its drive is not connected at its turn.
    case offline(reason: String)
}

/// Phase 1's result: the outcome, plus the keeper's fresh whole-file
/// fixity when path 1 read it AND the pair verified (the duplicate's full
/// read produced the same digest). A refused pair teaches nothing that may
/// be stored (GH #504 D2): its keeper digest is one unconfirmed read.
struct DeleteDuplicatesPhaseOne: Sendable {
    let outcome: DeleteDuplicatesDiskOutcome
    let learnedKeeperFixity: ContentFixity?
    /// The keeper's fresh fixity when this pair read the keeper in full to
    /// CONFIRM its stored one (GH #504 D4) — whatever the read found. Equal
    /// digests: the stored fixity is confirmed for the rest of the run. A
    /// different digest: the stored one was not used (the pair read both
    /// files instead) and the job says so. Never stored from here.
    var keeperReread: ContentFixity? = nil
    /// When phase one ended `.retained` with the file still inside a
    /// quarantine folder (the single-read path moves BEFORE it hashes, and
    /// the put-back after a doubt can fail — drive dropped, original path
    /// re-occupied): that folder, and the file's stamp there taken on the
    /// disk thread right after (nil when it could not be stat'ed, e.g. the
    /// drive is gone). The row records both so the plan owes a put-back
    /// (QA 2026-09-21 F1). nil for every other outcome.
    var retainedInQuarantine: RetainedInQuarantine? = nil
    /// Every sibling this pair read in full to prove it (2026-09-21),
    /// WHATEVER the pair's verdict — the fresh fixity of each sibling that
    /// MATCHED is stored on its record so no later row or run reads it
    /// again while its stamp holds.
    var siblingReads: [SiblingRead] = []
    /// Set when the worker left the copy alone for a PROTECTION it found
    /// itself (a drive marked Read only, seen only by the file's own
    /// identity): the why. The row is then never counted as a surviving
    /// copy for another copy of this run (`DeleteDuplicatesPlan.Entry.notCountedWhy`).
    var notCountedWhy: String? = nil

    struct RetainedInQuarantine: Sendable, Equatable {
        let directory: String
        let stamp: FileIdentityStamp?
    }
}

/// Phase 2's result: the outcome, the decision the file ACTUALLY went by
/// and the facts behind it. When the removal boundary's re-check dropped
/// a counted copy (codex 1611), `evidenceChanged` is true, `decision` is
/// the re-decided tier (reason naming the copy) and `facts` is what still
/// held — the row and the ledger take these over the ones saved with the
/// ticket. Otherwise they are the phase-one values, untouched.
struct DeleteDuplicatesPhaseTwo: Sendable {
    let outcome: DeleteDuplicatesDiskOutcome
    let decision: DeletionTierDecision
    let facts: DeletionTierFacts
    let evidenceChanged: Bool
    /// Set when the removal boundary found the copy HELD (in use by the
    /// Archive Angel, on a drive marked Read only since its turn): the note.
    /// The file was put back; the row is a skip, never a refusal.
    var heldNote: String? = nil
    /// Set when the copy was RETAINED for a protection found at the removal
    /// boundary — a hold (the why of `heldNote`), or the Master Archive rule
    /// refusing it from TODAY's designation where the check captured at its
    /// turn had let it go (codex #258 r4-1). Main would have removed this
    /// file; so it is never counted as a surviving copy for another copy of
    /// this run (`DeleteDuplicatesPlan.Entry.notCountedWhy`).
    var notCountedWhy: String? = nil
}
