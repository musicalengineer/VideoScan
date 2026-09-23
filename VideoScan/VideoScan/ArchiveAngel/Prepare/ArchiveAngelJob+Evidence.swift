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
        // codex #1643 A4: copy key → members (built on first use; O(records)).
        var groupIndex: [String: [UUID]]?
        var settledGroups: Set<String> = []
        for (id, rowTier) in ranked.ids {
            guard let evidence = store.record(for: id) else { continue }
            if let band = bandKey, rowTier > band.tier || (rowTier == band.tier && evidence.score < band.score) { pastBand = true }
            if pastBand {
                if freshCollected >= freshWanted || extraLooks >= freshScanBudget { break }
                extraLooks += 1
                if evidence.score < weights.freshMinimumScore { continue }
                if evidence.timesProposed > 0 || evidence.familySkips > 0 { continue }
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
            let groupIsNew = candidate.duplicateGroupID.map { seenGroups.insert($0).inserted } ?? true
            let familyIsNew = seenFamilies.insert(candidate.resolvedFamilyKey).inserted
            if candidate.isFreshToPerson, groupIsNew, familyIsNew { freshCollected += 1 }
            if !pastBand, candidate.duplicateGroupID.map({ bandGroups.insert($0).inserted }) ?? true {
                distinctSeen += 1
                if distinctSeen == count { bandKey = (tier, pickEvidence.score) }
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
        let picks = ArchiveAngelScorer.withFreshSlots(kept, count: count, weights: weights, by: order)
        // Evidence that no longer yields a full batch is not trusted — walk.
        guard picks.count == count else { return nil }
        let overflow = max(0, ranked.ids.count - projections) + (kept.count - picks.count)
        return EvidencePick(selection: .init(picks: picks, overflow: overflow, rejected: rejected),
                            computedAt: store.computedAt ?? now, projections: projections)
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
