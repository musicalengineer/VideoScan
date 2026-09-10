// ArchiveAngelJob+Evidence.swift
// Archive Angel phase 2: when the background sweep's evidence is FRESH
// (a complete run within 24 h) and holds enough candidates, the job picks
// its batch from the sidecar instead of walking the catalog. Every pick is
// still projected NOW and re-checked against the hard floor (a file may
// have been archived, purged or rated junk since the sweep), and the
// preparation step re-checks identity per entry as before.

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
        var picks: [ArchiveAngelPick] = []
        picks.reserveCapacity(count)
        var rejected = store.rejectionCounts()
        var projections = 0
        for id in store.rankedEligibleIDs() {
            if picks.count == count { break }
            if excluding.contains(id) { rejected[.inAnotherBatch, default: 0] += 1; continue }
            guard let evidence = store.record(for: id), let candidate = project(id) else { continue }
            projections += 1
            if let reason = ArchiveAngelScorer.hardFloor(candidate, weights: weights) {
                rejected[reason, default: 0] += 1
                continue
            }
            picks.append(.init(candidate: candidate, score: evidence.score, evidence: evidence.lines))
        }
        // Evidence that no longer yields a full batch is not trusted — walk.
        guard picks.count == count else { return nil }
        let overflow = max(0, store.eligibleCount - projections)
        return EvidencePick(selection: .init(picks: picks, overflow: overflow, rejected: rejected),
                            computedAt: store.computedAt ?? now, projections: projections)
    }
}
