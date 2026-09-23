// VideoScanModel+ArchiveAngelSweep.swift
// The catalog's half of the Archive Angel's background sweep: the scorer
// inputs for every active record (AngelCatalog.archiveAngelSweepCandidates).
// Since S2 the façade (Facade/ArchiveAngel.swift) owns the evidence store,
// the sweep, its configuration, the launch trigger and the setting.

import Foundation

extension VideoScanModel {

    /// Scorer inputs for every active record. ONE keeper policy for the
    /// whole pass (it is the expensive part of the projection). Main actor,
    /// called by the sweep at plan time — never from a view body.
    func archiveAngelSweepCandidates() -> [ArchiveAngelCandidate] {
        let policy = duplicateKeeperPolicy()
        let active = pfActiveRecords(records)
        var out: [ArchiveAngelCandidate] = []
        out.reserveCapacity(active.count)
        for r in active {
            out.append(ArchiveAngelCandidate.project(r, model: self, policy: policy))
        }
        let rules = archiveAngel.policy   // the recommendation policy (S3b: floors, signals, tables as data)
        ArchiveAngelScorer.markDerivatives(&out, policy: rules)   // T10 H3: needs the whole set (one O(n) pass)
        ArchiveAngelScorer.applyFamilyAttention(&out, weights: rules.weights)   // Phase 1: a variant of a skipped file is not new
        return out
    }
}
