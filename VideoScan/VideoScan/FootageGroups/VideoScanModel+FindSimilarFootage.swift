// VideoScanModel+FindSimilarFootage.swift
// Find Similar Footage, Phase 1 — the model half: the ONE main-actor pass
// that snapshots records into Sendable FootageInputs, the off-main
// (@concurrent) grouping phases, the sliced main-actor apply, the person's
// "same footage" / "not the same" decisions (+ Media Ledger), and the
// lookups the sheet / catalog / Archive Angel read.
//
// CONCURRENCY. `VideoRecord` is a main-actor reference type and never
// leaves the main actor (the approachable-concurrency trap: a
// `nonisolated async` func runs on the CALLER's actor in this project, so
// the compute functions are `@concurrent` to really leave it). Only
// FootageInput / FootageGrouping values cross.
//
// SAFETY. Reads catalog metadata only — no media is opened, no file is
// touched. Writes only `footage` (the machine answer) on records, and
// `footageDecisions` when the person answers. Writes NO dates. Human
// decisions are never rewritten by a run.
//
// INCREMENTAL. The whole-catalog grouping is cheap (≈0.3 s for 14k
// records, ≈2.5 s for 100k in Debug), so every run recomputes from the
// catalog and then writes ONLY the records whose answer changed
// (`FootageMembership.sameAnswer`) — an unchanged catalog re-run writes
// nothing and does not dirty the catalog.
//
// MEMORY. One FootageInput per record (~400 B with its strings) — 40 MB
// at 100k — plus the grouping's own working set (see FootageGrouping).
// All of it is released when the job ends.

import Foundation
import VideoScanCore

// MARK: - Scope

/// What a run covers. The grouping always sees the WHOLE catalog (the
/// other copies can be anywhere); the scope decides which groups are
/// written back and reported.
enum FootageScope: Sendable, Equatable {
    case catalog
    case records(Set<UUID>)
    case volume(prefix: String, label: String)

    var title: String {
        switch self {
        case .catalog: return "whole catalog"
        case .records(let ids): return ids.count == 1 ? "1 file" : "\(ids.count) files"
        case .volume(_, let label): return label
        }
    }

    func contains(id: UUID, path: String) -> Bool {
        switch self {
        case .catalog: return true
        case .records(let ids): return ids.contains(id)
        case .volume(let prefix, _):
            let p = prefix.hasSuffix("/") ? prefix : prefix + "/"
            return path == prefix || path.hasPrefix(p)
        }
    }
}

/// One run's numbers (logged, shown on the MFO row).
struct FootageRunSummary: Sendable, Equatable {
    var scopeTitle: String
    var groups = 0
    var members = 0
    var byConfidence: [FootageConfidence: Int] = [:]
    var largestGroup = 0
    var originalNotInCatalog = 0
    var recordsChanged = 0
    var recordsCleared = 0
    var refusedByCap = 0
    var refusedPossibleChain = 0
    var refusedByPerson = 0
    var sampledConflicts = 0
    var elapsed: TimeInterval = 0

    var line: String {
        let conf = FootageConfidence.allCases.compactMap { c -> String? in
            guard let n = byConfidence[c], n > 0 else { return nil }
            return "\(c.label.lowercased()) \(n)"
        }.joined(separator: ", ")
        var s = "Find Similar Footage (\(scopeTitle)): \(groups) group\(groups == 1 ? "" : "s") of the same footage, "
            + "\(members) files"
        if !conf.isEmpty { s += " (\(conf))" }
        s += "; largest \(largestGroup); original not in catalog for \(originalNotInCatalog)"
        s += "; \(recordsChanged) record\(recordsChanged == 1 ? "" : "s") updated, \(recordsCleared) cleared"
        if refusedByCap + refusedPossibleChain + refusedByPerson + sampledConflicts > 0 {
            s += "; refused: cap \(refusedByCap), possible-chain \(refusedPossibleChain), "
                + "your answers \(refusedByPerson), sampled-hash conflicts \(sampledConflicts)"
        }
        return s + String(format: "; %.1f s", elapsed)
    }
}

// MARK: - Snapshot (main actor, one pass)

extension FootageInput {
    /// Capture one record by value. (`@MainActor` ≈ "the record lives on
    /// the UI thread; read it there".)
    @MainActor
    init(record r: VideoRecord) {
        self.init(id: r.id, filename: r.filename, fullPath: r.fullPath, durationSeconds: r.durationSeconds,
                  frameRate: r.frameRate, sizeBytes: r.sizeBytes, contentHash: r.contentHash,
                  partialMD5: r.partialMD5, fixityDigest: r.contentFixity?.digest ?? r.archiveFixity?.digest,
                  derivedFrom: r.derivedFrom, derivationKind: r.derivationKind,
                  cleanupRecipeID: r.cleanupRecipeID, pairGroupID: r.pairGroupID,
                  pairConfidence: r.pairConfidence, combinedFromPairID: r.combinedFromPairID,
                  materialPackageUMID: r.materialPackageUMID, streamTypeRaw: r.streamTypeRaw,
                  mediaIdentifier: r.proAppsMediaIdentifier, originMake: r.originMake,
                  originModel: r.originModel, originEncoder: r.originEncoder, videoCodec: r.videoCodec,
                  embeddedCreationDate: r.embeddedCreationDate, decisions: r.footageDecisions,
                  isHidden: r.isPurged || r.isSetAside || r.isSuperseded, existing: r.footage)
    }
}

extension VideoScanModel {

    /// The ONE main-actor pass over `records`.
    func footageInputs() -> [FootageInput] {
        var out: [FootageInput] = []
        out.reserveCapacity(records.count)
        for r in records { out.append(FootageInput(record: r)) }
        return out
    }

    // MARK: Off-main phases (@concurrent — really leave the main actor)

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func footagePrepareAndLink(_ inputs: [FootageInput],
                                                  options: FootageGrouping.Options)
        async -> (FootageGrouping.Prepared, [FootageGrouping.Edge], FootageGrouping.Stats) {
        var stats = FootageGrouping.Stats()
        let p = FootageGrouping.prepare(inputs, options: options, stats: &stats)
        let e = FootageGrouping.edges(p, stats: &stats)
        return (p, e, stats)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func footageGroup(_ p: FootageGrouping.Prepared, edges: [FootageGrouping.Edge],
                                         options: FootageGrouping.Options, stats: FootageGrouping.Stats,
                                         now: Date) async -> FootageGrouping.Result {
        var stats = stats
        let c = FootageGrouping.components(p, edges: edges, options: options, stats: &stats)
        return FootageGrouping.assemble(p, edges: edges, components: c, now: now, stats: stats)
    }

    // MARK: Apply (main actor, in slices)

    /// Record ids a scoped run writes: every in-scope record, plus every
    /// member of a group that touches the scope.
    nonisolated static func footageTouchedIDs(result: FootageGrouping.Result, inputs: [FootageInput],
                                              scope: FootageScope) -> Set<UUID> {
        if scope == .catalog { return Set(inputs.map(\.id)) }
        var touched = Set<UUID>()
        var groupsInScope = Set<UUID>()
        for x in inputs where scope.contains(id: x.id, path: x.fullPath) {
            touched.insert(x.id)
            if let g = result.memberships[x.id]?.groupID { groupsInScope.insert(g) }
            // An old group the record was in: its other members are re-answered too.
            if let old = x.existing?.groupID { groupsInScope.insert(old) }
        }
        for x in inputs {
            if let g = result.memberships[x.id]?.groupID, groupsInScope.contains(g) { touched.insert(x.id) }
            if let old = x.existing?.groupID, groupsInScope.contains(old) { touched.insert(x.id) }
        }
        return touched
    }

    /// Write the run's answers onto records — only where they changed.
    /// Slices of about `sliceSize` records with a yield between (the UI
    /// stays live on a 100k catalog), cut at GROUP boundaries: every member
    /// of a group — new, or the old group a record is leaving — is written
    /// in the same slice, so a Stop never leaves a group half-written (QA
    /// 2026-09-23). `checkpoint` is polled per slice (Stop / pause wait).
    func applyFootage(_ result: FootageGrouping.Result, touched: Set<UUID>, sliceSize: Int = 2000,
                      progress: ((Double) -> Void)? = nil,
                      checkpoint: (() async -> Bool)? = nil) async -> (changed: Int, cleared: Int, stopped: Bool) {
        let units = footageApplyUnits(result, touched: touched)
        var changed = 0, cleared = 0, done = 0
        var u = 0
        while u < units.count {
            if let checkpoint, await !checkpoint() {
                finishFootageApply(changed: changed, cleared: cleared)
                return (changed, cleared, true)
            }
            var inSlice = 0
            while u < units.count, inSlice == 0 || inSlice + units[u].count <= sliceSize {
                for id in units[u] {
                    guard let rec = record(forID: id) else { continue }
                    if let new = result.memberships[id] {
                        if let old = rec.footage, old.sameAnswer(as: new) { continue }
                        rec.footage = new
                        changed += 1
                    } else if rec.footage != nil {
                        rec.footage = nil
                        cleared += 1
                    }
                }
                inSlice += units[u].count
                u += 1
            }
            done += inSlice
            progress?(Double(done) / Double(max(touched.count, 1)))
            await Task.yield()
        }
        finishFootageApply(changed: changed, cleared: cleared)
        return (changed, cleared, false)
    }

    /// Touched ids partitioned into write units: one per NEW group (its
    /// members), one per OLD group being dissolved (its members that join
    /// no new group), and singletons for the rest. Deterministic order.
    func footageApplyUnits(_ result: FootageGrouping.Result, touched: Set<UUID>) -> [[UUID]] {
        var byGroup: [String: [UUID]] = [:]
        for id in touched {
            let key: String
            if let g = result.memberships[id]?.groupID {
                key = "n:" + g.uuidString
            } else if let old = record(forID: id)?.footage?.groupID {
                key = "o:" + old.uuidString
            } else {
                key = "s:" + id.uuidString
            }
            byGroup[key, default: []].append(id)
        }
        return byGroup.keys.sorted().compactMap { k in byGroup[k]?.sorted { $0.uuidString < $1.uuidString } }
    }

    private func finishFootageApply(changed: Int, cleared: Int) {
        guard changed + cleared > 0 else { return }
        noteCatalogRecordsMutated()
        saveCatalogDebounced()
    }

    // MARK: Lookups (sheet / catalog)

    /// The live members of `rec`'s footage group, likely original first.
    /// One O(records) pass — call from an event handler or a sheet's
    /// `.task`, never from a view body.
    func footageGroupMembers(of rec: VideoRecord) -> [VideoRecord] {
        guard let g = rec.footage?.groupID else { return [] }
        return records.filter { $0.footage?.groupID == g }
            .sorted { ($0.footage?.rank ?? .max, $0.fullPath) < ($1.footage?.rank ?? .max, $1.fullPath) }
    }

    // MARK: The person's decisions

    /// Rick says `a` and `b` ARE (`.same`) / are NOT (`.notSame`) the same
    /// footage, or takes the answer back (`nil`). Stored on BOTH records,
    /// never touched by a run, mirrored to the Media Ledger (one line per
    /// record). The caller re-runs the grouping for the two files.
    @discardableResult
    func setFootageDecision(_ verdict: FootageDecision.Verdict?, between a: UUID, and b: UUID,
                            at now: Date = Date()) -> Task<Void, Never>? {
        guard a != b, !isReadOnly, let ra = record(forID: a), let rb = record(forID: b) else { return nil }
        if let verdict {
            ra.setFootageDecision(FootageDecision(otherID: b, verdict: verdict, decidedAt: now))
            rb.setFootageDecision(FootageDecision(otherID: a, verdict: verdict, decidedAt: now))
        } else {
            ra.forgetFootageDecision(about: b)
            rb.forgetFootageDecision(about: a)
        }
        noteCatalogRecordsMutated()
        saveCatalogDebounced()
        let answer = verdict?.rawValue ?? "forgotten"
        log("Find Similar Footage: you said \(ra.filename) and \(rb.filename) "
            + (verdict == .same ? "are the same footage" : verdict == .notSame ? "are NOT the same footage"
               : "— answer taken back"))
        return ledgerAppend([
            ledgerEvent(.footageDecided, for: ra, by: .rick, at: now, detail: [
                MediaLedgerEvent.Detail.answer: answer,
                MediaLedgerEvent.Detail.other: b.uuidString,
                MediaLedgerEvent.Detail.label: rb.filename,
            ]),
            ledgerEvent(.footageDecided, for: rb, by: .rick, at: now, detail: [
                MediaLedgerEvent.Detail.answer: answer,
                MediaLedgerEvent.Detail.other: a.uuidString,
                MediaLedgerEvent.Detail.label: ra.filename,
            ]),
        ])
    }
}

// MARK: - "One per footage" (pure; the catalog filter)

enum FootageOnePerGroup {
    /// Keep, per footage group, the member with the lowest rank among the
    /// rows ALREADY visible (so an offline likely original doesn't hide the
    /// whole group), plus every ungrouped row. Order preserved. O(n).
    static func filter(_ rows: [VideoRecord]) -> [VideoRecord] {
        var best: [UUID: (rank: Int, id: UUID)] = [:]
        for r in rows {
            guard let f = r.footage else { continue }
            if let cur = best[f.groupID], cur.rank <= f.rank { continue }
            best[f.groupID] = (f.rank, r.id)
        }
        guard !best.isEmpty else { return rows }
        return rows.filter { r in
            guard let f = r.footage else { return true }
            return best[f.groupID]?.id == r.id
        }
    }
}
