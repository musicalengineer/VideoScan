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
//   SiblingProver.readableSiblings(_:allowance:)
//        which copies WITHOUT current evidence the run could read to prove
//   DeletionTierDecision.decide(facts:preferTrash:)
//        ≥ 3 remain on ≥ 2 drives (or with the archive copy) → deleted
//        outright · ≥ 2 otherwise → the Trash · fewer → left alone
//   SiblingProver.worthReading(…)
//        which of those reads the run would actually make
//
// What differs from the run, said on the card: the run READS the copy and
// the keeper in full before it counts anything, and reads siblings that
// have no evidence yet; the card reads nothing. So (QA 2026-10-03, F2) the
// card never states a flat outcome when a read stands between now and the
// decision: it says how many copies the run would read first and what
// would happen if they match. With no digest stored on the copy or its
// keeper, only the keeper can be counted and the card says the run reads
// the copy first. The keeper itself is counted here as the run counts it —
// once it has been read.
//
// ROWS OF THE SAME RUN (QA F1, F6). Every other copy of the set that the
// same drive's cleanup would decide — the WHOLE set's (`StewardCase
// .runRows`, not the capped evidence rows) — is handed to the planner as
// the run's rows still to be decided: it may go too, so it is never counted
// as a copy that remains. A copy the planner leaves alone on that drive (in
// use by the Archive Angel, on a folder marked Read only — GH #258) is not
// a row of the run and is NOT counted either: the planner's own
// survivor-counting rule (`duplicateSurvivorStandingRule`, codex #258 F1),
// which the card asks through `deletionTierCandidates(…run:)` exactly as
// the job does. And the copy's own identity is stat'ed
// (`duplicateIdentity`) so a hard link of it is not counted.
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
    /// DeletionTierFacts.remainingVerifiedCopies — as things stand.
    var remaining: Int
    /// Who counted, in the planner's words ("keeper on LaCie", …).
    var counted: [String]
    /// How many copies exist but could not be counted yet.
    var notCounted: Int
    /// DeletionTierDecision.tier as things stand — nil = left alone.
    var tier: DeletionTier?
    /// False when no digest is stored for the copy or its keeper: nothing
    /// but the keeper can be counted until the run reads.
    var hadStoredDigest: Bool
    /// Copies the run would read first to prove them (0 = none needed, or
    /// none it could read). With no stored digest: the other copies that
    /// might match once this one has been read.
    var readsFirst: Int = 0
    /// The tier if every one of those matches — nil = still left alone.
    var tierIfTheyMatch: DeletionTier?

    /// "3 verified copies would remain: keeper on LaCie, archive copy on
    /// FamilyArchive, sibling b.mov on X9"
    var remainLine: String {
        "\(remaining) verified cop\(remaining == 1 ? "y" : "ies") would remain"
            + (counted.isEmpty ? "" : ": " + counted.joined(separator: ", "))
    }

    private static func fate(_ tier: DeletionTier?) -> String {
        switch tier {
        case .permanent?: return "be deleted outright"
        case .trash?: return "go to the Trash, not be deleted"
        case nil: return "be left alone"
        }
    }

    /// What the run would do with it, by the survival rule — flat only
    /// when nothing stands between now and the decision.
    var outcomeLine: String {
        let n = readsFirst
        if !hadStoredDigest {
            let lead = "The run reads this copy first"
            guard n > 0, tierIfTheyMatch != nil else {
                return lead + "; as things stand only the keeper would remain, so it would be left alone."
            }
            return lead + "; if the other \(n == 1 ? "copy matches" : "\(n) copies match"), it would \(Self.fate(tierIfTheyMatch))."
        }
        if n > 0 {
            let lead = "The run reads \(n) more cop\(n == 1 ? "y" : "ies") first"
            return tierIfTheyMatch == nil
                ? lead + "; even if \(n == 1 ? "it matches" : "they match"), this copy would be left alone."
                : lead + "; if \(n == 1 ? "it matches" : "they match"), this copy would \(Self.fate(tierIfTheyMatch))."
        }
        if notCounted > 0 { return "As things stand, it would \(Self.fate(tier))." }
        return "It would \(Self.fate(tier))."
    }

    /// Why some copies were not counted, when no read would change that.
    var caveatLine: String? {
        guard hadStoredDigest, notCounted > 0, readsFirst == 0 else { return nil }
        return "\(notCounted) other cop\(notCounted == 1 ? "y was" : "ies were") not counted — not connected, different, or part of the same cleanup."
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
        /// The copy's own path — stat'ed once so a hard link of it is
        /// never counted as another copy.
        var copyPath: String
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
        // From the WHOLE set (`runRows`); a copy the planner leaves alone
        // there is never counted — the planner's own rule decides.
        let checkable = c.copies.filter { $0.standing == .wouldBeChecked }
        var questions: [Question] = []
        for row in checkable.prefix(maxProvedCopies) {
            guard let record = model.record(forID: row.id) else { continue }
            let sameRun = Set(c.runRows.filter { $0.driveRoot == row.driveRoot && $0.id != row.id }.map(\.id))
            let candidates = model.deletionTierCandidates(
                record: record, keeper: keeper, run: DuplicateRunScope(volumePath: row.driveRoot, pending: sameRun))
            questions.append(Question(copyID: row.id, copyPath: record.fullPath, candidates: candidates,
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
    /// and apply the tier rule — the planner's functions, unchanged.
    nonisolated static func prove(_ questions: [Question], preferTrash: Bool) -> [UUID: StewardCopyProof] {
        var out: [UUID: StewardCopyProof] = [:]
        for q in questions { out[q.copyID] = proof(q, preferTrash: preferTrash) }
        return out
    }

    /// `driveOf` = the planner's own test seam for where a copy sits (two
    /// drives cannot be had in one temp folder); nil in production — the
    /// planner's resolver, `DuplicateDrives`.
    nonisolated static func proof(_ q: Question, preferTrash: Bool,
                                  driveOf seam: ((_ path: String, _ stamp: FileIdentityStamp) -> DeletionTierFacts.Drive)? = nil)
        -> StewardCopyProof {
        // The copy's own identity, as the job's worker sets it: a
        // candidate that is the same inode is not another copy.
        var candidates = q.candidates
        candidates.duplicateIdentity = FileIdentityStamp.capture(path: q.copyPath)
        let goal = SiblingProver.Allowance.goal(preferTrash: preferTrash)

        var resolver = DuplicateDrives.Resolver()
        func drive(_ path: String, _ stamp: FileIdentityStamp) -> DeletionTierFacts.Drive {
            seam?(path, stamp) ?? resolver.drive(path: path, stamp: stamp)
        }
        /// The facts if the run read `copies` in order and each matched —
        /// reading only what its own rule would (`worthReading`: never a
        /// copy that cannot change the tier). Returns how many it reads.
        func hoping(_ facts: DeletionTierFacts,
                    _ copies: [(path: String, stamp: FileIdentityStamp, isArchive: Bool)]) -> (facts: DeletionTierFacts, reads: Int) {
            var hoped = facts
            var reads = 0
            for copy in copies {
                let d = drive(copy.path, copy.stamp)
                guard SiblingProver.worthReading(count: hoped.remainingVerifiedCopies,
                                                 drives: Set(hoped.countedDrives.map(\.key)),
                                                 countsArchiveCopy: hoped.countsArchiveCopy,
                                                 candidateDrive: d.kind.addsADrive ? d.key : nil, goal: goal) else { continue }
                hoped.addCounted(drive: d, isArchive: copy.isArchive)
                reads += 1
            }
            return (hoped, reads)
        }

        guard let digest = q.digest else {
            // Nothing stored to ask with: the planner would count the
            // keeper alone until it has read this copy. The other copies
            // (not rows of the same run) might match once it has — where
            // they sit (one stat each) decides what that would earn.
            var facts = DeletionTierFacts()
            if !candidates.keeperPath.isEmpty, let k = FileIdentityStamp.capture(path: candidates.keeperPath) {
                let d = drive(candidates.keeperPath, k)
                facts.keeperDrive = d
                if d.kind.addsADrive { facts.countedDrives = [d] }
            }
            facts.countsArchiveCopy = candidates.keeperIsVerifiedArchive
            let decision = DeletionTierDecision.decide(facts: facts, preferTrash: preferTrash)
            let others = candidates.archiveCopies.count + candidates.otherCopies.count
            let reachable = candidates.archiveCopies.compactMap { c in
                FileIdentityStamp.capture(path: c.path).map { (path: c.path, stamp: $0, isArchive: true) }
            } + candidates.otherCopies.compactMap { c in
                FileIdentityStamp.capture(path: c.path).map { (path: c.path, stamp: $0, isArchive: false) }
            }
            let hoped = hoping(facts, reachable)
            return StewardCopyProof(copyID: q.copyID, remaining: decision.remainingVerifiedCopies,
                                    counted: [candidates.keeperLabel],
                                    notCounted: others + candidates.alsoInThisRun.count + candidates.leftAloneByRun.count,
                                    tier: decision.tier, hadStoredDigest: false,
                                    readsFirst: hoped.reads,
                                    tierIfTheyMatch: DeletionTierDecision.decide(facts: hoped.facts, preferTrash: preferTrash).tier)
        }
        let facts = DeletionTierFacts.gather(candidates, digest: digest, driveOf: seam)
        let decision = DeletionTierDecision.decide(facts: facts, preferTrash: preferTrash)
        // The copies the run could read to prove (stat only here): it
        // reads while a read can still lift the tier, never more.
        let readable = SiblingProver.readableSiblings(
            candidates, allowance: .init(goal: goal, readablePaths: Set(candidates.otherCopies.map(\.path)))).readable
        let hoped = hoping(facts, readable.map { (path: candidates.otherCopies[$0.index].path, stamp: $0.stamp, isArchive: false) })
        return StewardCopyProof(copyID: q.copyID, remaining: decision.remainingVerifiedCopies,
                                counted: facts.counted, notCounted: facts.unverifiedCopies,
                                tier: decision.tier, hadStoredDigest: true,
                                readsFirst: hoped.reads,
                                tierIfTheyMatch: hoped.reads > 0
                                    ? DeletionTierDecision.decide(facts: hoped.facts, preferTrash: preferTrash).tier
                                    : decision.tier)
    }
}
