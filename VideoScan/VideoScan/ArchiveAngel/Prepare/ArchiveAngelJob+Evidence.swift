// ArchiveAngelJob+Evidence.swift
// Archive Angel phase 2: when the background sweep's evidence is FRESH
// (a complete run within 24 h) and holds enough candidates, the job picks
// its batch from the sidecar instead of walking the catalog. Every pick is
// still projected NOW and re-checked against the hard floor (a file may
// have been archived, purged or rated junk since the sweep), and the
// preparation step re-checks identity per entry as before.
//
// T10 H2 (codex #1306): the sidecar ranks equal scores by UUID, so the
// pick must NOT stop in the middle of a score band — it collects every
// head down to the band of the last needed pick, orders them with the
// scorer's ONE comparator (`ArchiveAngelScorer.rank`) and applies the
// same one-per-duplicate-group filter the walk applies. Either path
// keeps the same member of an equal-score group.
//
// Phase 1 attention (codex 2026-09-20 #5/#6): the evidence is only as
// current as the attention state it was scored under, so the file is
// stamped with that state's revision and the pick refuses anything
// older than the store holds now; and the family pass's `familySkips`
// travels in each record, because the per-record projection here never
// runs that pass — without it a never-proposed variant of skipped footage
// came back "New to you" from the cache but not from the walk.

import Foundation

extension ArchiveAngelJob {

    struct EvidencePick: Equatable {
        var selection: ArchiveAngelSelection
        var computedAt: Date
        /// How many records were projected — the walk projects them all.
        var projections: Int
    }

    static let evidenceFreshness: TimeInterval = 24 * 3600
    /// Phase 1: how far past the score band the pick looks for never-
    /// proposed "fresh eyes" candidates (projections are cheap; this
    /// bounds the worst case on a catalog where everything was proposed).
    static let freshScanBudget = 200

    /// nil = evidence missing, stale, incomplete, thinner than `count`, or
    /// scored under an OLDER attention state than the store holds now —
    /// `attentionRevision` (the store's current revision; exact, within a
    /// launch) or, as the fallback, `attentionChangedAt` (the store's
    /// `lastEventAt`) newer than the stamp the sweep captured → the caller
    /// walks. Pure over the store + the injected projection.
    @MainActor
    static func selectFromEvidence(store: ArchiveAngelEvidenceStore, count: Int,
                                   freshness: TimeInterval = evidenceFreshness,
                                   now: Date,
                                   policy: AngelRecommendationPolicy = .builtIn,
                                   excluding: Set<UUID> = [],
                                   attentionChangedAt: Date? = nil,
                                   attentionRevision: Int? = nil,
                                   project: (UUID) -> ArchiveAngelCandidate?) -> EvidencePick? {
        guard count > 0, store.isFresh(within: freshness, now: now),
              store.eligibleCount >= count else { return nil }
        guard attentionIsCurrent(store: store, changedAt: attentionChangedAt, revision: attentionRevision) else { return nil }
        let weights = policy.weights
        var collected: [ArchiveAngelPick] = []
        var tiers: [UUID: Int] = [:]
        collected.reserveCapacity(count)
        var rejected = store.rejectionCounts()
        var projections = 0
        // The score of the count-th distinct-group head seen so far, in
        // arrival (descending score) order. Once the next head scores
        // strictly below it, nothing later can enter the batch — except
        // the explore arm: past the band only never-proposed records that
        // clear `freshMinimumScore` are projected, until `freshWanted` new
        // files are in hand or the scan budget is spent. A group's
        // first-arrived member carries the group's best score, so this
        // band is the same one the final `rank` order would cut at.
        var bandGroups: Set<UUID> = []
        var distinctSeen = 0
        // QA on S3: the band is (class tier, score) — Ready before Worth a
        // look whatever the scores (Prepare agrees with the numbers).
        var bandKey: (tier: Int, score: Int)? = nil
        let freshWanted = min(count, Int((Double(count) * weights.freshShare).rounded(.up)))
        // Fresh files counted the way the batch will see them: AFTER the
        // one-per-duplicate-group and one-per-family filters. A fresh
        // variant whose family (or group) already has a better-ranked
        // member here will be filtered out below, so it must not satisfy
        // the scan — the walk would have gone on to the next new file.
        var freshCollected = 0
        var seenGroups: Set<UUID> = []
        var seenFamilies: Set<String> = []
        var pastBand = false
        var extraLooks = 0
        let prepare = policy.recommend.prepareClasses
        let ranked = store.rankedPrepareIDs(prepare)
        rejected[.notRecommendedNow, default: 0] += ranked.skipped
        if rejected[.notRecommendedNow] == 0 { rejected[.notRecommendedNow] = nil }
        for (id, tier) in ranked.ids {
            guard let evidence = store.record(for: id) else { continue }
            if let band = bandKey, tier > band.tier || (tier == band.tier && evidence.score < band.score) { pastBand = true }
            if pastBand {
                if freshCollected >= freshWanted || extraLooks >= freshScanBudget { break }
                extraLooks += 1
                if evidence.score < weights.freshMinimumScore { continue }
                if evidence.timesProposed > 0 || evidence.familySkips > 0 { continue }
            }
            if excluding.contains(id) { rejected[.inAnotherBatch, default: 0] += 1; continue }
            guard var candidate = project(id) else { continue }
            projections += 1
            // The projection is per record; the family pass ran in the
            // sweep. Its result is current: this evidence is only used
            // when no attention event happened since it was scored.
            candidate.familySkips = evidence.familySkips
            if let reason = ArchiveAngelScorer.hardFloor(candidate, policy: policy, now: now) {
                rejected[reason, default: 0] += 1
                continue
            }
            collected.append(.init(candidate: candidate, score: evidence.score, evidence: evidence.lines))
            tiers[id] = tier
            let groupIsNew = candidate.duplicateGroupID.map { seenGroups.insert($0).inserted } ?? true
            let familyIsNew = seenFamilies.insert(candidate.resolvedFamilyKey).inserted
            if candidate.isFreshToPerson, groupIsNew, familyIsNew { freshCollected += 1 }
            if !pastBand, candidate.duplicateGroupID.map({ bandGroups.insert($0).inserted }) ?? true {
                distinctSeen += 1
                if distinctSeen == count { bandKey = (tier, evidence.score) }
            }
        }
        let tables = policy.tables
        let order: (ArchiveAngelPick, ArchiveAngelPick) -> Bool = { a, b in
            let ta = tiers[a.id] ?? .max, tb = tiers[b.id] ?? .max
            return ta != tb ? ta < tb : ArchiveAngelScorer.rank(a, b, tables: tables)
        }
        collected.sort(by: order)
        var kept = ArchiveAngelScorer.onePerDuplicateGroup(collected, rejected: &rejected)
        kept = ArchiveAngelScorer.onePerFamily(kept, rejected: &rejected)
        let picks = ArchiveAngelScorer.withFreshSlots(kept, count: count, weights: weights, by: order)
        // Evidence that no longer yields a full batch is not trusted — walk.
        guard picks.count == count else { return nil }
        let overflow = max(0, ranked.ids.count - projections) + (kept.count - picks.count)
        return EvidencePick(selection: .init(picks: picks, overflow: overflow, rejected: rejected),
                            computedAt: store.computedAt ?? now, projections: projections)
    }

    /// Is the evidence scored under the attention state the store holds
    /// NOW? Revision first (exact within a launch: the sweep captured it
    /// before the snapshot, the store bumps it on every note); a file
    /// without a revision stamp counts as revision 0. Then the date: the
    /// store's newest event must not be newer than the stamped
    /// `attentionLastEventAt` — or, for an unstamped file, than
    /// `computedAt` (the pre-v9 rule). Pure.
    @MainActor
    static func attentionIsCurrent(store: ArchiveAngelEvidenceStore, changedAt: Date?, revision: Int?) -> Bool {
        if let current = revision, (store.attentionRevision ?? 0) < current { return false }
        if let changed = changedAt {
            let captured: Date? = store.attentionRevision != nil ? store.attentionLastEventAt : store.computedAt
            guard let captured, changed <= captured else { return false }
        }
        return true
    }
}
