// ArchiveAngel+Recommendations.swift
// ONE set of numbers (Consolidation S3b, Rick 2026-09-22). The façade turns
// the sweep's classified evidence plus the prepared batches into the counts
// every surface reads — the Archive tab's nudge sentence, the Angel strip's
// headline ("N ready · M need a date · K prepared"), the catalog row badge
// and the catalog's Archive Candidates filter — so they can never disagree.
//
// Rebuilt when the evidence store changes (its `didChange`, after the new
// file is in place) and when the prepared batches are re-read. One O(n)
// pass over the evidence plus a sort of the recommended rows; never in a
// view body. Worst case at 100k records: one [UUID] per recommended row and
// three small sets (~40 B per recommended record).

import Foundation
import OSLog
import VideoScanCore

private let summaryLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "archiveAngel")

/// What the Angel recommends right now, counted once.
struct ArchiveAngelRecommendationSummary: Equatable {
    /// Records per class. `.prepared` / `.promoted` come from the batches;
    /// a record in a prepared batch is counted there, not in its class.
    var counts: [ArchiveAngelRecommendationClass: Int] = [:]
    /// Ready + Needs a date + Worth a look, not already in a batch — the
    /// catalog's Archive Candidates filter.
    var candidateIDs: Set<UUID> = []
    var preparedIDs: Set<UUID> = []
    var promotedIDs: Set<UUID> = []
    /// Recommended ids: Ready, then Needs a date, then Worth a look, each
    /// by score (the strip's list).
    var ranked: [UUID] = []
    /// The Archive tab's nudge (Ready → ready, Needs a date → nearly ready).
    var nudge: ArchiveNudge = .empty
    /// Has any assessment been loaded or run?
    var isAssessed = false
    /// Bumps on every rebuild (catalog rows re-render their badge on it).
    var revision = 0

    func count(_ k: ArchiveAngelRecommendationClass) -> Int { counts[k] ?? 0 }

    /// "12 ready · 30 need a date · 10 prepared"
    var headline: String {
        let ready = count(.ready), need = count(.needsDate), prepared = count(.prepared)
        return "\(ready.formatted()) ready · \(need.formatted()) \(need == 1 ? "needs" : "need") a date · "
            + "\(prepared.formatted()) prepared"
    }

    /// Pure: the summary of classified evidence under the batches' overlay.
    /// `filename` resolves a record for the nudge's rows (nil = gone from
    /// the catalog → not listed).
    static func make(evidence: [UUID: ArchiveAngelEvidenceRecord]?,
                     prepared: Set<UUID>, promoted: Set<UUID>,
                     revision: Int, filename: (UUID) -> String?) -> ArchiveAngelRecommendationSummary {
        var s = ArchiveAngelRecommendationSummary()
        s.revision = revision
        s.preparedIDs = prepared
        s.promotedIDs = promoted
        s.counts[.prepared] = prepared.count
        guard let evidence else {
            return s
        }
        s.isAssessed = true
        var rows: [ArchiveAngelRecommendationClass: [(UUID, ArchiveAngelEvidenceRecord)]] = [:]
        for (id, rec) in evidence {
            if prepared.contains(id) { continue }
            if promoted.contains(id) { s.counts[.promoted, default: 0] += 1; continue }
            let kind = rec.recommendationClass
            s.counts[kind, default: 0] += 1
            if kind.isRecommended {
                s.candidateIDs.insert(id)
                rows[kind, default: []].append((id, rec))
            }
        }
        func sorted(_ k: ArchiveAngelRecommendationClass) -> [(UUID, ArchiveAngelEvidenceRecord)] {
            (rows[k] ?? []).sorted { a, b in
                a.1.score != b.1.score ? a.1.score > b.1.score : a.0.uuidString < b.0.uuidString
            }
        }
        let ready = sorted(.ready), need = sorted(.needsDate), worth = sorted(.worthALook)
        s.ranked = (ready + need + worth).map(\.0)
        func nudgeRows(_ list: [(UUID, ArchiveAngelEvidenceRecord)], needsDate: Bool) -> [ArchiveNudge.Candidate] {
            list.compactMap { id, rec in
                guard let name = filename(id) else { return nil }
                return ArchiveNudge.Candidate(id: id, filename: name, year: needsDate ? nil : rec.year,
                                              reasons: rec.reasons ?? [], needsDate: needsDate, score: rec.score)
            }
        }
        s.nudge = ArchiveNudge(ready: nudgeRows(ready, needsDate: false), nearReady: nudgeRows(need, needsDate: true))
        return s
    }

    /// The records a prepared batch holds (rows not settled as promoted,
    /// failed or skipped) and the ones a batch still in the buffer promoted.
    static func batchOverlay(ready: [ArchiveAngelPlan], buffer: [ArchiveAngelPlan]) -> (prepared: Set<UUID>, promoted: Set<UUID>) {
        var prepared = Set<UUID>(), promoted = Set<UUID>()
        for plan in ready {
            for e in plan.entries where e.status == .ready || e.status.isUnsettled { prepared.insert(e.id) }
        }
        for plan in buffer {
            for e in plan.entries where e.status == .promoted { promoted.insert(e.id) }
        }
        return (prepared, promoted.subtracting(prepared))
    }
}

extension ArchiveAngel {

    /// Recount from the evidence store and the batches. O(n); called on
    /// every evidence replace and batch refresh, never from a view body.
    func rebuildRecommendations() {
        let overlay = ArchiveAngelRecommendationSummary.batchOverlay(
            ready: batches.ready, buffer: batches.hygiene.batches.map(\.plan))
        let catalog = self.catalog
        let next = ArchiveAngelRecommendationSummary.make(
            evidence: store.file?.records, prepared: overlay.prepared, promoted: overlay.promoted,
            revision: recommendations.revision &+ 1,
            filename: { catalog?.record(forID: $0)?.filename })
        publishRecommendations(next)
        summaryLog.debug("recommendations rebuilt — \(next.headline, privacy: .public)")
    }
}
