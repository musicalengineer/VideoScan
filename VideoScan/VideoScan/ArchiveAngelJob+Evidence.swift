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

import Foundation

extension ArchiveAngelJob {

    struct EvidencePick: Equatable {
        var selection: ArchiveAngelSelection
        var computedAt: Date
        /// How many records were projected — the walk projects them all.
        var projections: Int
    }

    static let evidenceFreshness: TimeInterval = 24 * 3600

    /// nil = evidence missing, stale, incomplete, or thinner than `count`
    /// → the caller walks. Pure over the store + the injected projection.
    @MainActor
    static func selectFromEvidence(store: ArchiveAngelEvidenceStore, count: Int,
                                   freshness: TimeInterval = evidenceFreshness,
                                   now: Date,
                                   weights: ArchiveAngelWeights = .standard,
                                   excluding: Set<UUID> = [],
                                   project: (UUID) -> ArchiveAngelCandidate?) -> EvidencePick? {
        guard count > 0, store.isFresh(within: freshness, now: now),
              store.eligibleCount >= count else { return nil }
        var collected: [ArchiveAngelPick] = []
        collected.reserveCapacity(count)
        var rejected = store.rejectionCounts()
        var projections = 0
        // The score of the count-th distinct-group head seen so far, in
        // arrival (descending score) order. Once the next head scores
        // strictly below it, nothing later can enter the batch. A group's
        // first-arrived member carries the group's best score, so this
        // band is the same one the final `rank` order would cut at.
        var seenGroups: Set<UUID> = []
        var distinctSeen = 0
        var bandScore: Int? = nil
        for id in store.rankedEligibleIDs() {
            guard let evidence = store.record(for: id) else { continue }
            if let band = bandScore, evidence.score < band { break }
            if excluding.contains(id) { rejected[.inAnotherBatch, default: 0] += 1; continue }
            guard let candidate = project(id) else { continue }
            projections += 1
            if let reason = ArchiveAngelScorer.hardFloor(candidate, weights: weights) {
                rejected[reason, default: 0] += 1
                continue
            }
            collected.append(.init(candidate: candidate, score: evidence.score, evidence: evidence.lines))
            if candidate.duplicateGroupID.map({ seenGroups.insert($0).inserted }) ?? true {
                distinctSeen += 1
                if distinctSeen == count { bandScore = evidence.score }
            }
        }
        collected.sort(by: ArchiveAngelScorer.rank)
        let ranked = ArchiveAngelScorer.onePerDuplicateGroup(collected, rejected: &rejected)
        let picks = Array(ranked.prefix(count))
        // Evidence that no longer yields a full batch is not trusted — walk.
        guard picks.count == count else { return nil }
        let overflow = max(0, store.eligibleCount - projections) + (ranked.count - picks.count)
        return EvidencePick(selection: .init(picks: picks, overflow: overflow, rejected: rejected),
                            computedAt: store.computedAt ?? now, projections: projections)
    }
}
