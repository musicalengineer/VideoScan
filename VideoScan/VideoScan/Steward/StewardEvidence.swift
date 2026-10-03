// StewardEvidence.swift
// RULE 1 of §5.6: a delete card shows the PROOF, not the score — "3
// verified copies would remain: keeper on LaCie, archive copy on
// FamilyArchive, sibling on X9".
//
// The proof on a Reclaim set card is worked out with the Delete planner's
// OWN facts, by the planner's OWN functions — nothing is re-implemented:
//
//   VideoScanModel.deletionTierCandidates(record:keeper:excluding:)
//        the family's copies the job would ask the disk about
//   DeletionTierFacts.gather(_:digest:)
//        one stat per copy: does its stored evidence still describe the
//        file on disk, and is it these bytes?
//   DeletionTierDecision.decide(facts:preferTrash:)
//        ≥ 3 remain → deleted outright · exactly 2 → the Trash · fewer →
//        left alone
//
// What differs from the run, said on the card: the run READS the copy and
// the keeper in full before it counts anything; the card reads nothing, so
// it asks with the digest already stored on the copy (or on the keeper).
// With neither stored, only the keeper can be counted and the card says the
// run will have to read first. The keeper itself is counted here as the run
// counts it — once it has been read.
//
// WHEN. Only for the ONE focused card, from the pane's `.task(id:)` — never
// in a view body, never for the whole queue. `prepare` runs on the main
// actor (the planner's candidate function walks `records` once per copy, so
// at most `maxProvedCopies` passes — the same order of work as the Storage
// card's click-time forecast); `prove` runs detached (stat only, no reads).
//
// (For Rick: `@MainActor` ≈ "must run on the UI thread"; `nonisolated
// static` ≈ a plain free function callable from any thread.)

import Foundation
import VideoScanCore

/// What the planner would find if ONE copy of a set were let go.
struct StewardCopyProof: Sendable, Equatable {
    var copyID: UUID
    /// DeletionTierFacts.remainingVerifiedCopies.
    var remaining: Int
    /// Who counted, in the planner's words ("keeper on LaCie", …).
    var counted: [String]
    /// How many copies exist but could not be counted yet.
    var notCounted: Int
    /// DeletionTierDecision.tier — nil = left alone.
    var tier: DeletionTier?
    /// False when no digest is stored for the copy or its keeper: nothing
    /// but the keeper can be counted until the run reads.
    var hadStoredDigest: Bool

    /// "3 verified copies would remain: keeper on LaCie, archive copy on
    /// FamilyArchive, sibling b.mov on X9"
    var remainLine: String {
        "\(remaining) verified cop\(remaining == 1 ? "y" : "ies") would remain"
            + (counted.isEmpty ? "" : ": " + counted.joined(separator: ", "))
    }

    /// What the run would do with it, by the survival rule.
    var outcomeLine: String {
        switch tier {
        case .permanent?: return "It would be deleted outright."
        case .trash?: return "It would go to the Trash, not be deleted."
        case nil: return "It would be left alone."
        }
    }

    var caveatLine: String? {
        if !hadStoredDigest {
            return "This copy has not been read yet, so only the keeper can be counted. The run reads it first."
        }
        if notCounted > 0 {
            return "\(notCounted) other cop\(notCounted == 1 ? "y" : "ies") could not be counted yet — the run reads them if it needs to."
        }
        return nil
    }
}

/// The focused Reclaim set's evidence.
struct StewardGroupEvidence: Sendable, Equatable {
    var caseID: String
    var keeperReason: String
    /// nil while the disk is being asked.
    var proofs: [UUID: StewardCopyProof]?
    /// Copies beyond `maxProvedCopies` are not worked out on the card.
    var unprovedCopies = 0

    static let keeperCaveat = "The keeper counts once the run has read it in full."
}

enum StewardEvidenceBuilder {

    /// The card works out the proof for at most this many copies of a set.
    static let maxProvedCopies = 8

    /// One copy's question for the disk, ready to leave the main actor.
    struct Question: Sendable {
        var copyID: UUID
        var candidates: DeletionTierCandidates
        /// The digest to ask with: the copy's own stored one, else the
        /// keeper's; nil when neither is stored.
        var digest: String?
    }

    struct Prepared: Sendable {
        var evidence: StewardGroupEvidence
        var questions: [Question]
        var preferTrash: Bool
    }

    /// Main actor: the keeper's reason and the planner's candidates for
    /// each copy the flow would check. O(set) index lookups plus one
    /// `deletionTierCandidates` pass per proved copy.
    @MainActor
    static func prepare(model: VideoScanModel, for c: StewardCase) -> Prepared? {
        guard c.kind == .reclaimGroup, let keeperID = c.keeperID, let keeper = model.record(forID: keeperID) else { return nil }
        let members = c.copies.compactMap { model.record(forID: $0.id) }
        let policy = model.duplicateKeeperPolicy()
        func key(_ r: VideoRecord) -> DuplicateKeeperPolicy.ElectionKey {
            policy.electionKey(for: r, technicalScore: DuplicateDetector.keeperScore(r))
        }
        let reason = StewardKeeperReason.words(
            keeper: key(keeper),
            others: members.filter { $0.id != keeper.id }.map(key),
            keeperDrive: VolumeReachability.volumeName(forPath: keeper.fullPath),
            keeperIsInArchive: model.isArchiveElement(keeper))

        // The copies a Delete duplicates run would decide, drive by drive:
        // the others on the SAME drive are rows of the same run, still to
        // be decided — the planner never counts those (they may go too).
        let checkable = c.copies.filter { $0.standing == .wouldBeChecked }
        var questions: [Question] = []
        for row in checkable.prefix(maxProvedCopies) {
            guard let record = model.record(forID: row.id) else { continue }
            let sameRun = Set(checkable.filter { $0.drive == row.drive && $0.id != row.id }.map(\.id))
            let candidates = model.deletionTierCandidates(record: record, keeper: keeper, excluding: sameRun)
            questions.append(Question(copyID: row.id, candidates: candidates,
                                      digest: usableDigest(record) ?? usableDigest(keeper)))
        }
        return Prepared(evidence: StewardGroupEvidence(caseID: c.id, keeperReason: reason, proofs: nil,
                                                       unprovedCopies: max(0, checkable.count - maxProvedCopies)),
                        questions: questions,
                        preferTrash: model.duplicateKeeperSettings.preferTrashForEveryDuplicate)
    }

    @MainActor
    static func usableDigest(_ r: VideoRecord) -> String? {
        guard let f = r.contentFixity, f.isUsableForVerification else { return nil }
        return f.digest
    }

    /// Off the main actor: ask the disk (one stat per candidate, no reads)
    /// and apply the tier rule — the planner's two functions, unchanged.
    nonisolated static func prove(_ questions: [Question], preferTrash: Bool) -> [UUID: StewardCopyProof] {
        var out: [UUID: StewardCopyProof] = [:]
        for q in questions { out[q.copyID] = proof(q, preferTrash: preferTrash) }
        return out
    }

    nonisolated static func proof(_ q: Question, preferTrash: Bool) -> StewardCopyProof {
        guard let digest = q.digest else {
            // Nothing stored to ask with: the planner would count the
            // keeper alone until it has read this copy.
            let facts = DeletionTierFacts()
            let decision = DeletionTierDecision.decide(facts: facts, preferTrash: preferTrash)
            return StewardCopyProof(copyID: q.copyID, remaining: decision.remainingVerifiedCopies,
                                    counted: [q.candidates.keeperLabel],
                                    notCounted: q.candidates.archiveCopies.count + q.candidates.otherCopies.count
                                        + q.candidates.alsoInThisRun.count,
                                    tier: decision.tier, hadStoredDigest: false)
        }
        let facts = DeletionTierFacts.gather(q.candidates, digest: digest)
        let decision = DeletionTierDecision.decide(facts: facts, preferTrash: preferTrash)
        return StewardCopyProof(copyID: q.copyID, remaining: decision.remainingVerifiedCopies,
                                counted: facts.counted, notCounted: facts.unverifiedCopies,
                                tier: decision.tier, hadStoredDigest: true)
    }
}
