// VideoScanModel+ArchiveAngelSweep.swift
// The catalog's half of the Archive Angel's background sweep: the scorer
// inputs for every active record (AngelCatalog.archiveAngelSweepCandidates).
// Since S2 the façade (Facade/ArchiveAngel.swift) owns the evidence store,
// the sweep, its configuration, the launch trigger and the setting.

import Foundation
import os

private let coverageLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "archiveAngel")

extension VideoScanModel {

    /// Scorer inputs for every active record. ONE keeper policy for the
    /// whole pass (it is the expensive part of the projection). Main actor,
    /// called by the sweep at plan time — never from a view body.
    func archiveAngelSweepCandidates() -> [ArchiveAngelCandidate] {
        let policy = duplicateKeeperPolicy()
        let active = pfActiveRecords(records)
        var out: [ArchiveAngelCandidate] = []
        out.reserveCapacity(active.count)
        // Rules v12: the buffer root is standardized ONCE per pass (QA v12 #4).
        let bufferPrefix = ArchiveAngelCandidate.bufferPrefix(archiveAngel.environment.bufferRoot)
        for r in active {
            out.append(ArchiveAngelCandidate.project(r, model: self, policy: policy, bufferPrefix: .some(bufferPrefix)))
        }
        let rules = archiveAngel.policy   // the recommendation policy (S3b: floors, signals, tables as data)
        ArchiveAngelScorer.markDerivatives(&out, policy: rules)   // T10 H3: needs the whole set (one O(n) pass)
        ArchiveAngelScorer.markArchivedFootage(&out, archivedGroups: archivedFootageGroupIDs(active))   // rules v12
        ArchiveAngelScorer.applyFamilyAttention(&out, weights: rules.weights)   // Phase 1: a variant of a skipped file is not new
        // Rules v13 coverage: event keys and the per-year backlog table, ONE
        // O(n) pass, here beside the others — never in `select`'s loop.
        // Runs after markArchivedFootage so an archived footage group's
        // members count as archived backlog, not as work to do.
        let backlog = ArchiveAngelEvent.applyCoverage(&out, policy: rules)
        coverageLog.info("\(ArchiveAngelEvent.summaryLine(backlog), privacy: .public)")
        return out
    }

    /// Rules v12: the footage groups (Likely or stronger) whose likely
    /// original is archived — by the SAME predicate the projection uses
    /// (`isArchivedOrVersionOfArchived`), asked once per distinct original
    /// (memoized), so the pass is O(n) with O(1) lookups. Main actor.
    func archivedFootageGroupIDs(_ active: [VideoRecord]) -> Set<UUID> {
        var archivedOriginal: [UUID: Bool] = [:]
        var groups = Set<UUID>()
        for r in active {
            guard let f = r.footage, f.confidence != .possible, !groups.contains(f.groupID) else { continue }
            let originalID = f.likelyOriginalID
            let archived: Bool
            if let known = archivedOriginal[originalID] {
                archived = known
            } else {
                archived = record(forID: originalID).map(isArchivedOrVersionOfArchived) ?? false
                archivedOriginal[originalID] = archived
            }
            if archived { groups.insert(f.groupID) }
        }
        return groups
    }
}
