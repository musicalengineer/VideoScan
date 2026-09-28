// ArchiveAngelScorer+Coverage.swift
// Rules v13 (2026-09-26): the scorer's two POST-band coverage passes —
// one pick per DAY and the per-year share of a batch — and the soft rule
// they share. Split out of ArchiveAngelScorer.swift (the +Sets / +Rules
// pattern) so that file stays readable. Both passes run AFTER the one
// rank order and never change it (codex #1643 A4); both are batch
// limits, never exclusions; both are SOFT (Manager ruling 2026-09-26: a
// partial batch reads as "nothing to do"). Pure.

import Foundation

extension ArchiveAngelScorer {

    /// What a soft coverage pass did: the rows it kept (in `order`), how
    /// many it held back for another batch (before any top-up), and how
    /// many of those it put back to fill the batch. Rows still held are
    /// the ones counted as rejected.
    struct CoverageCut {
        var picks: [ArchiveAngelPick]
        var heldBack: Int
        var toppedUp: Int
        var stillHeld: Int { heldBack - toppedUp }
    }

    /// Both coverage passes in order: one per event (when the policy says
    /// so), then the per-year share. Pure.
    static func coverageCut(_ picks: [ArchiveAngelPick], coverage: AngelCoverageRules, count: Int,
                            rejected: inout [ArchiveAngelRejection: Int], now: Date = Date(),
                            by order: (ArchiveAngelPick, ArchiveAngelPick) -> Bool = rank) -> CoverageCut {
        guard coverage.onePerEvent || coverage.maxPerYearPerBatch > 0 else {
            return CoverageCut(picks: picks, heldBack: 0, toppedUp: 0)
        }
        // A pick that missed the pre-pass (a set scored without it) is
        // resolved ONCE here, not once per pass: RecordDateResolver is the
        // costly read (0.8 s per 100k in Debug).
        var picks = picks
        for i in picks.indices where picks[i].candidate.eventKey == nil {
            let r = ArchiveAngelEvent.resolve(picks[i].candidate, now: now)
            picks[i].candidate.eventKey = r.key
            picks[i].candidate.eventYear = r.year
        }
        var out = CoverageCut(picks: picks, heldBack: 0, toppedUp: 0)
        if coverage.onePerEvent {
            let events = onePerEvent(picks, count: count, rejected: &rejected, now: now, by: order)
            out = CoverageCut(picks: events.picks, heldBack: events.heldBack, toppedUp: events.toppedUp)
        }
        let years = capPerYear(out.picks, cap: coverage.maxPerYearPerBatch, count: count, rejected: &rejected, now: now, by: order)
        return CoverageCut(picks: years.picks, heldBack: out.heldBack + years.heldBack, toppedUp: out.toppedUp + years.toppedUp)
    }

    /// Rules v13 coverage: one pick per EVENT (ArchiveAngelEvent: the same
    /// DAY) ahead of the batch cut — a diversity choice, never identity.
    /// `picks` must be in `order`; the best member of a day stays, the rest
    /// are HELD BACK — but a batch is never left short for it: when the
    /// rows kept are fewer than `count`, the best held-back rows top the
    /// list up (Manager ruling 2026-09-26: a partial batch reads as
    /// "nothing to do"). Only rows still held are counted under
    /// `.sameEventAsPick`. Rows with no day never collapse. The result is
    /// in `order` (a top-up re-sorts: everything kept is in the batch, so
    /// its order is the rank order again). Pure.
    static func onePerEvent(_ picks: [ArchiveAngelPick], count: Int,
                            rejected: inout [ArchiveAngelRejection: Int],
                            now: Date = Date(),
                            by order: (ArchiveAngelPick, ArchiveAngelPick) -> Bool = rank) -> CoverageCut {
        var seen: Set<String> = []
        var within: [ArchiveAngelPick] = []
        var held: [ArchiveAngelPick] = []
        within.reserveCapacity(picks.count)
        for pick in picks {
            let key = pick.candidate.resolvedEvent(now: now).key
            if key.isEmpty || seen.insert(key).inserted { within.append(pick) } else { held.append(pick) }
        }
        return softCut(within: within, held: held, count: count, reason: .sameEventAsPick, rejected: &rejected, by: order)
    }

    /// Rules v13 coverage: at most `cap` picks per YEAR ahead of the batch
    /// cut (`cap` ≤ 0 = no cap). Same soft rule as `onePerEvent`: rows a
    /// year has no room for are held back, the batch is topped up from
    /// them when other years cannot fill it, and only rows still held are
    /// counted under `.yearCoverage`. Rows with NO year are never capped:
    /// there is no year to spread them over (rules v12 behaviour for every
    /// undated row; the backlog table reports them in their own bucket and
    /// never rewards them — codex D3). Pure.
    static func capPerYear(_ picks: [ArchiveAngelPick], cap: Int, count: Int,
                           rejected: inout [ArchiveAngelRejection: Int],
                           now: Date = Date(),
                           by order: (ArchiveAngelPick, ArchiveAngelPick) -> Bool = rank) -> CoverageCut {
        guard cap > 0 else { return CoverageCut(picks: picks, heldBack: 0, toppedUp: 0) }
        var perYear: [Int: Int] = [:]
        var within: [ArchiveAngelPick] = []
        var held: [ArchiveAngelPick] = []
        within.reserveCapacity(picks.count)
        for pick in picks {
            guard let year = pick.candidate.resolvedEvent(now: now).year else { within.append(pick); continue }
            let n = perYear[year, default: 0]
            if n < cap {
                perYear[year] = n + 1
                within.append(pick)
            } else {
                held.append(pick)
            }
        }
        return softCut(within: within, held: held, count: count, reason: .yearCoverage, rejected: &rejected, by: order)
    }

    /// The soft rule shared by the coverage passes: `held` tops `within`
    /// up to `count` (in `order`), the rest are counted under `reason`.
    static func softCut(within: [ArchiveAngelPick], held: [ArchiveAngelPick], count: Int,
                        reason: ArchiveAngelRejection, rejected: inout [ArchiveAngelRejection: Int],
                        by order: (ArchiveAngelPick, ArchiveAngelPick) -> Bool) -> CoverageCut {
        guard !held.isEmpty else { return CoverageCut(picks: within, heldBack: 0, toppedUp: 0) }
        var kept = within
        let topUp = max(0, min(held.count, count - within.count))
        if topUp > 0 {
            kept.append(contentsOf: held.prefix(topUp))
            kept.sort(by: order)
        }
        let stillHeld = held.count - topUp
        if stillHeld > 0 { rejected[reason, default: 0] += stillHeld }
        return CoverageCut(picks: kept, heldBack: held.count, toppedUp: topUp)
    }

    /// Phase 1: one member per EVENT FAMILY per batch (the generalised
    /// duplicateOfPick — "one Thanksgiving variant per batch"). `picks`
    /// must be in `rank` order; the best member stays, the rest are
    /// counted under `.sameFamilyAsPick`. Pure.
    static func onePerFamily(_ picks: [ArchiveAngelPick],
                             rejected: inout [ArchiveAngelRejection: Int]) -> [ArchiveAngelPick] {
        var seen: Set<String> = []
        return picks.filter { pick in
            if seen.insert(pick.candidate.resolvedFamilyKey).inserted { return true }
            rejected[.sameFamilyAsPick, default: 0] += 1
            return false
        }
    }
}
