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
//
// codex #1643 A4: the cached classes are a sweep old. A Keep chosen after
// the sweep (A = Ready, B = Another copy; the person marks B Keep) must
// win before the next rescore — so a row whose evidence carries a copy key
// has its WHOLE duplicate group reclassified live (the one classifier, over
// live projections and the stored evidence) before the class filter, and
// the group's live choice is the pick. Each row then goes through the ONE
// effective-class function the counts and the badge use (codex #1643 A3).

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

    /// Rules v13 coverage: how far past the band the coverage arm may read
    /// for rows of years (or days) the batch still has room for. Rows of a
    /// year already at its share cost a dictionary lookup, never a
    /// projection (the evidence carries the classifier's year); rows that
    /// might enter are projected. A batch that cannot be filled within
    /// these budgets declines the cache and the job walks.
    static let coverageProjectionBudget = 400
    static let coverageLookBudget = 20_000

    /// nil = evidence missing, stale, incomplete, thinner than `count`, or
    /// scored under an OLDER attention state than the store holds now —
    /// `attentionRevision` (the store's current revision; exact, within a
    /// launch) or, as the fallback, `attentionChangedAt` (the store's
    /// `lastEventAt`) newer than the stamp the sweep captured → the caller
    /// walks. Rules v13: with any coverage rule on, also nil when the
    /// catalog changed since the sweep's snapshot (`catalogRevision` newer
    /// than the file's stamp — the per-year backlog and the archived set
    /// are catalog facts, not per-record ones; codex acceptance gate
    /// "cache/fallback parity"), or when the coverage passes would have to
    /// top the batch up from rows the cache did not read. Pure over the
    /// store + the injected projection.
    @MainActor
    static func selectFromEvidence(store: ArchiveAngelEvidenceStore, count: Int,
                                   freshness: TimeInterval = evidenceFreshness,
                                   now: Date,
                                   policy: AngelRecommendationPolicy = .builtIn,
                                   excluding: Set<UUID> = [],
                                   attentionChangedAt: Date? = nil,
                                   attentionRevision: Int? = nil,
                                   catalogRevision: Int? = nil,
                                   project: (UUID) -> ArchiveAngelCandidate?) -> EvidencePick? {
        guard count > 0, store.isFresh(within: freshness, now: now),
              store.eligibleCount >= count else { return nil }
        guard attentionIsCurrent(store: store, changedAt: attentionChangedAt, revision: attentionRevision),
              coverageIsCurrent(stamped: store.catalogRevision, current: catalogRevision, coverage: policy.coverage) else { return nil }
        let coverage = policy.coverage
        let weights = policy.weights
        var collected: [ArchiveAngelPick] = []
        var tiers: [UUID: Int] = [:]
        collected.reserveCapacity(count)
        var rejected = store.rejectionCounts()
        var projections = 0
        // The band: the count-th best (class tier, score) among the
        // distinct-group picks ACTUALLY collected so far. Rows arrive in
        // (tier, arrival score) order, and a row's arrival key is an upper
        // bound on what it can add (a copy group arrives at its best
        // eligible member — `rankedPrepareIDs`). So once a row arrives
        // strictly below the band, nothing later can enter the batch —
        // except the explore arm: past the band only never-proposed
        // records that clear `freshMinimumScore` are projected, until
        // `freshWanted` new files are in hand or the scan budget is spent.
        // The cut falls between whole arrival bands, so which rows are
        // read never depends on the order of equal keys (record ids) —
        // codex #1643 A4 ruling, 2026-09-23: before it, a group whose live
        // Keep scored below its cached row lowered the band to that Keep's
        // score and ~1 run in 5 walked the whole file.
        var bandGroups: Set<UUID> = []
        var best: [(tier: Int, score: Int)] = []     // best-first, at most `count`
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
        // codex #1643 A4: copy key → members (built on first use; O(records)).
        var groupIndex: [String: [UUID]]?
        var settledGroups: Set<String> = []
        // Rules v13 — the COVERAGE ARM (CoverageArm below): past the band,
        // rows whose year still has room are read too.
        var arm = CoverageArm(coverage: coverage, count: count, now: now)
        var stoppedEarly = false                // the loop broke out; rows remain unread
        for (id, rowTier, arrivalScore) in ranked.ids {
            guard let evidence = store.record(for: id) else { continue }
            if let band = bandKey, rowTier > band.tier || (rowTier == band.tier && arrivalScore < band.score) { pastBand = true }
            arm.noteArrival(tier: rowTier, score: arrivalScore)
            if pastBand {
                let freshDone = freshCollected >= freshWanted || extraLooks >= freshScanBudget
                var freshWants = false
                if !freshDone {
                    extraLooks += 1
                    freshWants = arrivalScore >= weights.freshMinimumScore
                        && evidence.timesProposed == 0 && evidence.familySkips == 0
                }
                let coverageWants = arm.wants(tier: rowTier, score: arrivalScore, evidenceYear: evidence.year)
                if freshDone && arm.done { stoppedEarly = true; break }
                if !freshWants && !coverageWants { continue }
            }
            // The copies of this recording, reclassified LIVE: the pick is
            // the group's live choice (the new Keep, not the cached one).
            var pickID = id
            var pickEvidence = evidence
            var tier = rowTier
            var groupCandidate: ArchiveAngelCandidate?
            var groupKind: ArchiveAngelRecommendationClass?
            if let key = evidence.copyKey {
                guard settledGroups.insert(key).inserted else { continue }   // this recording was decided
                if groupIndex == nil { groupIndex = Self.copyGroups(store) }
                let group = Self.liveGroupChoice(members: groupIndex?[key] ?? [id], anchor: id, store: store,
                                                 policy: policy, now: now, excluding: excluding, project: project)
                projections += group.projections
                // codex #1650: a group too large to decide live is never
                // judged from a prefix — the cached selection is declined
                // and the job walks the whole catalog instead.
                if group.oversized { return nil }
                guard let choice = group.choice else {
                    if group.inFlight { rejected[.inAnotherBatch, default: 0] += 1 }
                    continue
                }
                if choice.id != id { rejected[.duplicateOfPick, default: 0] += 1 }
                pickID = choice.id
                pickEvidence = choice.evidence
                groupCandidate = choice.candidate
                groupKind = choice.kind
                tier = prepare.isEmpty ? 0 : (prepare.firstIndex(of: choice.kind) ?? prepare.count)
                // The arrival key must bound what this row adds (QA
                // follow-up 2026-09-24): a live choice that outranks it
                // means earlier cuts may have been wrong — walk instead.
                if Self.liveChoiceExceedsArrival(liveTier: tier, liveScore: choice.evidence.score,
                                                 arrivalTier: rowTier, arrivalScore: arrivalScore) {
                    return nil
                }
            }
            // THE effective class (codex #1643 A3): in a batch → skipped;
            // refused live (gone, purged, set aside, superseded, promoted)
            // → skipped; else projected once.
            var liveProjection: ArchiveAngelCandidate?
            var askedLive = false
            let effective = ArchiveAngelRecommendationSummary.effective(
                stored: groupKind ?? pickEvidence.recommendation,
                prepared: excluding.contains(pickID), promoted: false,
                live: {
                    askedLive = true
                    liveProjection = groupCandidate ?? project(pickID)
                    return liveProjection.map(\.filename)
                })
            if effective?.kind == .prepared { rejected[.inAnotherBatch, default: 0] += 1; continue }
            if !askedLive { liveProjection = groupCandidate ?? project(pickID) }
            guard var candidate = liveProjection else { continue }
            if groupCandidate == nil { projections += 1 }
            // The projection is per record; the family pass ran in the
            // sweep. Its result is current: this evidence is only used
            // when no attention event happened since it was scored.
            candidate.familySkips = pickEvidence.familySkips
            if let reason = ArchiveAngelScorer.hardFloor(candidate, policy: policy, now: now) {
                rejected[reason, default: 0] += 1
                continue
            }
            collected.append(.init(candidate: candidate, score: pickEvidence.score, evidence: pickEvidence.lines))
            tiers[pickID] = tier
            arm.noteCollected(candidate)
            let groupIsNew = candidate.duplicateGroupID.map { seenGroups.insert($0).inserted } ?? true
            let familyIsNew = seenFamilies.insert(candidate.resolvedFamilyKey).inserted
            if candidate.isFreshToPerson, groupIsNew, familyIsNew { freshCollected += 1 }
            if !pastBand, candidate.duplicateGroupID.map({ bandGroups.insert($0).inserted }) ?? true {
                let key = (tier: tier, score: pickEvidence.score)
                let at = best.firstIndex { key.tier < $0.tier || (key.tier == $0.tier && key.score > $0.score) } ?? best.count
                if at < count {
                    best.insert(key, at: at)
                    if best.count > count { best.removeLast() }
                }
                if best.count == count { bandKey = best[count - 1] }
            }
        }
        let tables = policy.tables
        let order: (ArchiveAngelPick, ArchiveAngelPick) -> Bool = { a, b in
            let ta = tiers[a.id] ?? .max, tb = tiers[b.id] ?? .max
            return ta != tb ? ta < tb : ArchiveAngelScorer.rank(a, b, tables: tables)
        }
        collected.sort(by: order)
        var kept = ArchiveAngelScorer.onePerDuplicateGroup(collected, rejected: &rejected,
                                                           collapseBy: policy.recommend.copies.batchCollapseBy)
        kept = ArchiveAngelScorer.onePerFamily(kept, rejected: &rejected)
        // Rules v13 coverage: the same POST-band passes the walk applies
        // (never a band mutation — codex #1643 A4). A top-up is only the
        // walk's top-up when the cache read the WHOLE ranked list and
        // skipped nothing on its year alone; otherwise rows it never read
        // could rank above the ones it would put back — decline, the job
        // walks. The same when a coverage budget ran out short.
        let cut = ArchiveAngelScorer.coverageCut(kept, coverage: coverage, count: count, rejected: &rejected, now: now, by: order)
        let declined = arm.incomplete || (cut.toppedUp > 0 && (stoppedEarly || arm.skipped > 0))
        kept = cut.picks
        let picks = ArchiveAngelScorer.withFreshSlots(kept, count: count, weights: weights, by: order)
        // Evidence that no longer yields a full batch is not trusted — walk.
        guard !declined, picks.count == count else { return nil }
        let overflow = max(0, ranked.ids.count - projections) + (kept.count - picks.count)
        return EvidencePick(selection: .init(picks: picks, overflow: overflow, rejected: rejected),
                            computedAt: store.computedAt ?? now, projections: projections)
    }

    /// Rules v13: with any coverage rule on, evidence stamped older than
    /// the catalog is now (`ArchiveAngel.catalogRevision`) is not current —
    /// the per-year backlog and the archived set are catalog facts. An
    /// unstamped file reads as revision 0; a caller with no revision (a
    /// test of the pick alone) never declines on it; with every coverage
    /// key off the stamp is ignored (rules v12). Pure.
    static func coverageIsCurrent(stamped: Int?, current: Int?, coverage: AngelCoverageRules) -> Bool {
        let coverageOn = coverage.maxPerYearPerBatch > 0 || coverage.onePerEvent || coverage.backlogBonusMax > 0
        guard coverageOn, let current else { return true }
        return (stamped ?? 0) >= current
    }

    /// Rules v13 — the coverage arm of `selectFromEvidence` (codex
    /// acceptance gate "coverage beyond the cutoff"). The band is read
    /// whole as before; past it, while the rows collected would not fill
    /// the batch under the day and year rules, this arm asks for rows
    /// whose year still has room (or whose year the evidence does not
    /// know) — a year at its share is skipped by the evidence's own year,
    /// never projected — and, once the batch would fill, finishes the
    /// arrival band it is in, so the rows read never depend on the order
    /// of equal keys (A4). `within` counts collected rows that pass both
    /// rules: an upper bound on the batch (the group and family passes
    /// can only remove). Bounded by `coverageLookBudget` rows examined
    /// and `coverageProjectionBudget` rows read. Pure bookkeeping; the
    /// loop it serves does the projecting. (≈ a small state machine
    /// object owned by the loop.)
    struct CoverageArm {
        let cap: Int
        let onePerEvent: Bool
        let count: Int
        let now: Date
        /// Rows collected that pass the day and year rules so far.
        private(set) var within = 0
        /// Rows skipped on their evidence year alone (never read).
        private(set) var skipped = 0
        /// A budget ran out while the batch was still short.
        private(set) var incomplete = false
        private(set) var done: Bool
        private var perYearAll: [Int: Int] = [:]        // live years of collected rows, every band read
        private var perYearThisBand: [Int: Int] = [:]   // …of those, the arrival band being read now
        private var thisBandKey: (tier: Int, score: Int)?
        private var lastConsumedKey: (tier: Int, score: Int)?
        private var seenDays: Set<String> = []
        private var looks = 0
        private var projections = 0

        init(coverage: AngelCoverageRules, count: Int, now: Date) {
            cap = coverage.maxPerYearPerBatch
            onePerEvent = coverage.onePerEvent
            self.count = count
            self.now = now
            done = cap <= 0 && !coverage.onePerEvent   // nothing to spread: never asks for a row
        }

        var active: Bool { cap > 0 || onePerEvent }

        /// Every row's arrival key, in order: a new key folds the band just
        /// read into "every band read".
        mutating func noteArrival(tier: Int, score: Int) {
            guard active else { return }
            if thisBandKey == nil || thisBandKey!.tier != tier || thisBandKey!.score != score {
                thisBandKey = (tier, score)
                perYearThisBand = [:]
            }
        }

        /// A row was collected (projected, past the floor): count it.
        mutating func noteCollected(_ c: ArchiveAngelCandidate) {
            guard active else { return }
            let (day, year) = c.resolvedEvent(now: now)
            if onePerEvent, !day.isEmpty, !seenDays.insert(day).inserted { return }
            guard let year, cap > 0 else { within += 1; return }
            perYearAll[year, default: 0] += 1
            perYearThisBand[year, default: 0] += 1
            if perYearAll[year, default: 0] <= cap { within += 1 }
        }

        /// Past the band: should this row be read for coverage? Sets `done`
        /// when the arm has what it needs (or a budget is spent).
        mutating func wants(tier: Int, score: Int, evidenceYear: Int?) -> Bool {
            guard !done else { return false }
            if within >= count {
                // Filled: finish the band the last coverage row came from, then stop.
                let sameBand = lastConsumedKey.map { $0.tier == tier && $0.score == score } ?? false
                if !sameBand { done = true; return false }
            }
            if looks >= coverageLookBudget || projections >= coverageProjectionBudget {
                incomplete = within < count
                done = true
                return false
            }
            looks += 1
            // Could this row enter? Its year must have room among the rows
            // of HIGHER bands (a same-band row can still outrank one of them
            // by the tie-breaks); an unknown year is read.
            if cap > 0, let ey = evidenceYear, perYearAll[ey, default: 0] - perYearThisBand[ey, default: 0] >= cap {
                skipped += 1
                return false
            }
            lastConsumedKey = (tier, score)
            projections += 1
            return true
        }
    }

    /// The band cut's invariant (QA follow-up 2026-09-24): a row's arrival
    /// key must be an UPPER bound on what it can add. A copy group arrives
    /// at its best CACHED tier and score; its live choice can be better —
    /// a Keep cached as Another copy that now classifies Ready. True when
    /// the live (tier, score) outranks the arrival key in the band's own
    /// order (lower tier first, then higher score): the rows already cut
    /// or passed may have held something better, so the evidence pick is
    /// not trustworthy and the caller walks the catalog.
    static func liveChoiceExceedsArrival(liveTier: Int, liveScore: Int,
                                         arrivalTier: Int, arrivalScore: Int) -> Bool {
        liveTier != arrivalTier ? liveTier < arrivalTier : liveScore > arrivalScore
    }

    // MARK: Live copy groups (codex #1643 A4)

    /// Members per copy key, from the evidence (the sweep stamps every
    /// member of a collapsed group). One O(records) pass; ids sorted so the
    /// live chooser sees a stable order.
    @MainActor
    static func copyGroups(_ store: ArchiveAngelEvidenceStore) -> [String: [UUID]] {
        var out: [String: [UUID]] = [:]
        for (id, r) in store.file?.records ?? [:] {
            if let k = r.copyKey { out[k, default: []].append(id) }
        }
        for k in out.keys { out[k]?.sort { $0.uuidString < $1.uuidString } }
        return out
    }

    /// The largest copy group decided live from the cache (bounds the
    /// projections for one pick; a real recording has a handful of copies).
    /// A larger group is NEVER judged from a prefix (codex #1650: a Keep or
    /// an in-flight copy past the prefix was ignored) — the cached
    /// selection is declined and the job walks.
    static let maxLiveGroupMembers = 64

    struct LiveGroupChoice {
        var choice: (id: UUID, candidate: ArchiveAngelCandidate, evidence: ArchiveAngelEvidenceRecord,
                     kind: ArchiveAngelRecommendationClass)?
        var projections: Int
        /// A member is already in a batch — the recording is in flight.
        var inFlight: Bool
        /// More members than `maxLiveGroupMembers`: not decided here.
        var oversized = false
    }

    /// The group's LIVE answer: every member projected now (refused live
    /// or under a floor now → out), then THE classifier over those live
    /// candidates and their stored evidence — the person's Keep, else the
    /// best, exactly as the next sweep would decide. The chosen member must
    /// be in a class Prepare takes (`recommend.prepare`; empty = any
    /// recommendation). nil when none is, or when a member is already in a
    /// batch (never two copies of one recording in flight). The anchor (the
    /// row the ranked list reached) goes first, so on a tie it stays.
    @MainActor
    static func liveGroupChoice(members: [UUID], anchor: UUID, store: ArchiveAngelEvidenceStore,
                                policy: AngelRecommendationPolicy, now: Date, excluding: Set<UUID>,
                                project: (UUID) -> ArchiveAngelCandidate?) -> LiveGroupChoice {
        var ids = [anchor]
        for m in members where m != anchor { ids.append(m) }
        // In flight: checked across the WHOLE group (set lookups, no
        // projection) — never two copies of one recording in batches.
        if ids.contains(where: excluding.contains) { return LiveGroupChoice(choice: nil, projections: 0, inFlight: true) }
        // Too many to project for one pick: never decide from a prefix.
        guard ids.count <= maxLiveGroupMembers else {
            return LiveGroupChoice(choice: nil, projections: 0, inFlight: false, oversized: true)
        }
        var live: [ArchiveAngelCandidate] = []
        var evidence: [UUID: ArchiveAngelEvidenceRecord] = [:]
        var projections = 0
        for m in ids {
            guard let ev = store.record(for: m), var c = project(m) else { continue }
            projections += 1
            c.familySkips = ev.familySkips
            guard ArchiveAngelScorer.hardFloor(c, policy: policy, now: now) == nil else { continue }
            live.append(c)
            evidence[m] = ev
        }
        let verdicts = ArchiveAngelRecommendations.classify(live, evidence: evidence, rules: policy.recommend, now: now).verdicts
        let prepare = policy.recommend.prepareClasses
        var best: (index: Int, tier: Int)?
        for (i, v) in verdicts.enumerated() {
            let takes = prepare.isEmpty ? v.kind.isRecommended : prepare.contains(v.kind)
            guard takes else { continue }
            let tier = prepare.firstIndex(of: v.kind) ?? 0
            if let b = best {
                let (bv, bc) = (verdicts[b.index], live[b.index])
                let better = tier != b.tier ? tier < b.tier
                    : ArchiveAngelScorer.rank(live[i], score: v.score, before: bc, score: bv.score)
                if !better { continue }
            }
            best = (i, tier)
        }
        guard let b = best, let ev = evidence[live[b.index].id] else {
            return LiveGroupChoice(choice: nil, projections: projections, inFlight: false)
        }
        return LiveGroupChoice(choice: (live[b.index].id, live[b.index], ev, verdicts[b.index].kind),
                               projections: projections, inFlight: false)
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
