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
    /// `live` answers, NOW, for a record the evidence recommends: its
    /// filename, or nil when it is gone from the catalog, purged, set
    /// aside, superseded or something Promote would refuse (QA on S3 — the
    /// evidence can be up to a sweep old). Such a record counts as
    /// Excluded and is never listed, badged or filtered in.
    static func make(evidence: [UUID: ArchiveAngelEvidenceRecord]?,
                     prepared: Set<UUID>, promoted: Set<UUID>,
                     revision: Int, live: (UUID) -> String?) -> ArchiveAngelRecommendationSummary {
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
        var names: [UUID: String] = [:]
        for (id, rec) in evidence {
            // THE effective class (codex #1643 A3) — the same function the
            // badge, the class accessor and Prepare read.
            guard let e = effective(stored: rec.recommendationClass, prepared: prepared.contains(id),
                                    promoted: promoted.contains(id), live: { live(id) }) else { continue }
            let kind = e.kind
            let name = e.liveName
            if kind == .prepared { continue }   // counted from the overlay above
            s.counts[kind, default: 0] += 1
            if kind.isRecommended, let name {
                s.candidateIDs.insert(id)
                rows[kind, default: []].append((id, rec))
                names[id] = name
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
                guard let name = names[id] else { return nil }
                return ArchiveNudge.Candidate(id: id, filename: name, year: needsDate ? nil : rec.year,
                                              reasons: rec.reasons ?? [], needsDate: needsDate, score: rec.score)
            }
        }
        s.nudge = ArchiveNudge(ready: nudgeRows(ready, needsDate: false), nearReady: nudgeRows(need, needsDate: true))
        return s
    }

    /// A record's EFFECTIVE class and, when recommended, its live name.
    struct Effective: Equatable {
        var kind: ArchiveAngelRecommendationClass
        /// The catalog's filename, read when the stored class is a
        /// recommendation (nil otherwise, or when refused live).
        var liveName: String?
    }

    /// THE effective classification (codex #1643 A3): stored evidence +
    /// the batches' overlay (prepared, promoted) + the LIVE refusal. The
    /// counts, the catalog filter, the badge, the class accessor and
    /// Prepare all call this — never the stored class alone. `live`
    /// answers NOW: the filename, or nil when the record is gone, purged,
    /// set aside, superseded or something Promote would refuse (it is only
    /// asked for a recommended class — O(1) index lookups). nil = not
    /// assessed and not in a batch. Pure.
    static func effective(stored: ArchiveAngelRecommendationClass?, prepared: Bool, promoted: Bool,
                          live: () -> String?) -> Effective? {
        if prepared { return Effective(kind: .prepared) }
        if promoted { return Effective(kind: .promoted) }
        guard let stored else { return nil }
        guard stored.isRecommended else { return Effective(kind: stored) }
        guard let name = live() else { return Effective(kind: .excluded) }
        return Effective(kind: stored, liveName: name)
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
        let next = ArchiveAngelRecommendationSummary.make(
            evidence: store.file?.records, prepared: overlay.prepared, promoted: overlay.promoted,
            revision: recommendations.revision &+ 1,
            live: { [catalog = self.catalog] id in Self.liveName(id, catalog: catalog) })
        publishRecommendations(next)
        summaryLog.debug("recommendations rebuilt — \(next.headline, privacy: .public)")
    }

    /// The effective class of one record (codex #1643 A3) — what the row
    /// badge and the inspector show. O(1): two set lookups, one evidence
    /// lookup, and for a recommended class one catalog index lookup.
    func effectiveRecommendation(for id: UUID) -> ArchiveAngelRecommendationSummary.Effective? {
        ArchiveAngelRecommendationSummary.effective(
            stored: store.record(for: id)?.recommendationClass,
            prepared: recommendations.preparedIDs.contains(id),
            promoted: recommendations.promotedIDs.contains(id),
            live: { [catalog = self.catalog] in Self.liveName(id, catalog: catalog) })
    }

    /// LIVE: the record's filename if it may be recommended right now.
    static func liveName(_ id: UUID, catalog: (any AngelCatalog)?) -> String? {
        guard let catalog, let r = catalog.record(forID: id), catalog.isRecommendableNow(r) else { return nil }
        return r.filename
    }

    /// The catalog changed (a purge, a set-aside, a promote, an edit):
    /// recount against the LIVE catalog shortly after it settles — the
    /// evidence may be a sweep old. Debounced 0.5 s; O(evidence) with O(1)
    /// lookups, never in a view body.
    func scheduleRecommendationsRecount() {
        recountTask?.cancel()
        recountTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.rebuildRecommendations()
        }
    }
}
