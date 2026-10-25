// VideoScanModel+DuplicateDigestSplit.swift
// "Split Duplicate Groups by Full Hash" (Rick 2026-10-19): the repair half
// of DuplicateGroupDigestSplit. Every duplicate group whose live members
// carry more than one known whole-file SHA-256 is split into groups of true
// copies; a member whose digest matches no other member leaves its group.
// Settles Verify Catalog's `duplicateGroupDigestsAgree` findings without a
// person — the machine has the digests, so the machine decides.
//
// The door, in order (fail safe at each step):
//   1. refused on a read-only session — nothing planned;
//   2. the plan (pure, O(grouped records)); an empty plan is one OUTCOME
//      line and NOTHING else (no safety copy, no commit) — idempotent;
//   3. the safety copy (`snapshotCatalog(prefix: "pre-dup-split")`: under
//      catalog.sqlite a sealed VACUUM INTO copy, with what is in memory
//      committed first); no copy → refused, nothing changed;
//   4. catalog.sqlite only: the LIKENESS the split groups knew is recorded
//      in `footage_likeness` in ONE transaction through the session's
//      committer (`commitSideTables(via: .footageLikeness)`), BEFORE any
//      record changes. Refused → the split is refused, nothing changed. A
//      group whose pair the store cannot take (a digest that is not a
//      stored content yet) is HELD, with words; the others go on;
//   5. the plan applied to the in-memory records (group id, disposition,
//      count, best match — never a path, a marker, a digest or a file);
//   6. ONE synchronous save through the single writer (`saveCatalogNow` →
//      CatalogCommitter.commitNow under catalog.sqlite);
//   7. START, one line per split group (what stayed, what became a new
//      group, what left, the likeness kept — by filename) and OUTCOME,
//      through one sink: console + catalog.log, videoscan.log, the unified
//      log.
// Milliseconds on 15k rows (one pass + a dictionary + one small write), so
// not an MFO job (CLAUDE.md "Long operations" starts at about a minute).
//
// NOTHING IS LOST (Rick 2026-10-19). Under catalog.sqlite every multi-digest
// group is split: each file that leaves its copies group is still a copy in
// a new group, or its content has a pair in footage_likeness (anchored or
// weak, the duplicate check's reasons verbatim, or the old group's reasons
// when only the group remembered), or the evidence says it is a different
// length. Weak pairs show in the inspector as "Same footage as (possible)"
// for a person to confirm or reject (footage decisions); Verify Catalog
// counts the undecided ones as a YELLOW, informational item. The menu item
// starts a Find Similar Footage run after a split so anchored likeness
// shows as footage links at once. Neither footage links nor likeness pairs
// are ever delete-eligible.
//
// catalog.json (no table): a simulated Find Similar Footage pass
// (`duplicateDigestSplitFootageGroups`) says which files stay linked; a
// group whose members would be cut apart is HELD exactly as it is, as
// before (DuplicateGroupDigestSplit `.footageGroups`).
//
// (For Rick: `@discardableResult` lets a caller ignore the returned
// outcome, like a C++ function whose return value may be dropped without a
// warning.)

import Foundation
import VideoScanCore
import os

private let digestSplitLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "duplicateDigestSplit")

/// How a split run ended.
enum DuplicateDigestSplitOutcome: Equatable {
    /// Nothing to split — no group holds two different known digests.
    case nothingToSplit
    case split(groups: Int, newGroups: Int, left: Int, saved: Bool, safetyCopy: String)
    case refused(String)
}

/// What step 4 recorded (catalog.sqlite only).
struct DuplicateDigestSplitLikenessWrite: Equatable {
    var recorded = 0
    var alreadyRecorded = 0
    /// Groups whose pairs the store could not take — held by the door.
    var heldGroups: Set<UUID> = []
}

extension VideoScanModel {

    nonisolated static let duplicateDigestSplitTitle = "Split Duplicate Groups by Full Hash"

    /// The one sink: console + catalog.log, videoscan.log, the unified log.
    func duplicateDigestSplitNote(_ line: String) {
        log("Split duplicate groups: " + line)
        appLog.write("[dup-split] " + line)
        digestSplitLog.notice("\(line, privacy: .public)")
    }

    /// The live grouped records as plan facts (one O(records) pass).
    func duplicateDigestSplitFacts() -> [DuplicateGroupDigestSplit.MemberFact] {
        var facts: [DuplicateGroupDigestSplit.MemberFact] = []
        for r in records where r.removal == nil {
            guard let g = r.duplicateGroupID else { continue }
            facts.append(.init(id: r.id, groupID: g, filename: r.filename, digest: Self.storedFullDigest(r),
                               disposition: r.duplicateDisposition, confidence: r.duplicateConfidence,
                               bestMatch: r.duplicateBestMatchFilename, likeness: DuplicateLikeness.Facts(record: r),
                               groupReasons: r.duplicateReasons))
        }
        return facts
    }

    /// Record id → footage group after a SIMULATED Find Similar Footage pass
    /// over the whole catalog (pure; no stat, no write): every stored whole-
    /// file digest is taken as current, because only CONNECTIVITY matters
    /// here — would the files stay linked once their old group is gone?
    /// catalog.json only (catalog.sqlite keeps the likeness as pairs). One
    /// main-actor snapshot pass plus the grouping (≈1 s on 11k rows, Debug).
    ///
    /// A group whose confidence is only POSSIBLE is left out: a Possible
    /// link attaches a lone file as a leaf, and WHICH leaf it takes depends
    /// on the order links are offered — the real run (which stats the files)
    /// may take another (2026-10-19 evidence: one such pair). Only links the
    /// real run is sure to make count as "kept".
    func duplicateDigestSplitFootageGroups() -> [UUID: UUID] {
        let inputs = footageInputs().map { x -> FootageInput in
            var y = x
            if y.storedDigest != nil { y.fixityFresh = true }
            return y
        }
        return FootageGrouping.run(inputs, options: .init(), now: Date()).memberships
            .filter { $0.value.confidence != .possible }
            .mapValues(\.groupID)
    }

    /// Where this session keeps the likeness a split cuts: catalog.sqlite's
    /// table when it is the authority, else the catalog.json hold rule.
    func duplicateDigestSplitLikenessHome() -> DuplicateGroupDigestSplit.LikenessHome {
        catalogCutover.isSQLiteAuthority ? .pairs : .footageGroups(duplicateDigestSplitFootageGroups())
    }

    /// Plan, safety copy, likeness, apply, save, say so. See the file header.
    @discardableResult
    func splitDuplicateGroupsByFullDigest() -> DuplicateDigestSplitOutcome {
        if isReadOnly {
            let why = "the catalog is read-only in this session — nothing was changed"
            duplicateDigestSplitNote("REFUSED — \(why)")
            return .refused(why)
        }
        let facts = duplicateDigestSplitFacts()
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let policy = duplicateKeeperPolicy()
        var plan = DuplicateGroupDigestSplit.plan(facts, elect: { ids in
            DuplicateDetector.electKeeper(from: ids.compactMap { byID[$0] }, policy: policy)?.id
        }, keeping: duplicateDigestSplitLikenessHome())
        let groupCount = Set(facts.map(\.groupID)).count
        guard !plan.isEmpty else {
            noteNothingToSplit(plan, groupCount: groupCount)
            return .nothingToSplit
        }
        duplicateDigestSplitNote("START — \(plan.splitGroups.count.formatted()) of \(groupCount.formatted()) duplicate group(s) hold "
                                 + "files with different whole-file SHA-256s; each is split into groups of true copies, "
                                 + "and what the group knew about likeness is kept (\(plan.pairs.count.formatted()) pair(s)). "
                                 + "Only the duplicate-group fields of \(plan.changes.count.formatted()) row(s) change — "
                                 + "no file is touched." + heldClause(plan.heldGroups))
        guard let copy = snapshotCatalog(prefix: "pre-dup-split") else {
            return refuseSplit("no safety copy of the catalog could be made — nothing was changed")
        }
        duplicateDigestSplitNote("safety copy: \(copy)")
        var likeness: DuplicateDigestSplitLikenessWrite?
        if let committer = catalogCutover.committer {
            switch recordSplitLikeness(plan, committer: committer) {
            case .failure(let refusal): return refuseSplit(refusal.words)
            case .success(let written): likeness = written
            }
            plan = plan.holding(likeness?.heldGroups ?? [], why: Self.contentMissingWords)
        }
        guard !plan.isEmpty else {
            // Every split group's pairs were refused by the store: all held.
            noteNothingToSplit(plan, groupCount: groupCount)
            return .nothingToSplit
        }
        return applySplit(plan, byID: byID, likeness: likeness, copy: copy)
    }

    static let contentMissingWords = "a file's whole-file SHA-256 is not a stored content of catalog.sqlite yet, so the "
        + "likeness the group knew could not be kept — Fill In Full Hashes, then split again"

    private func noteNothingToSplit(_ plan: DuplicateGroupDigestSplit.Plan, groupCount: Int) {
        let held = plan.heldGroups
        for (i, g) in held.enumerated() { duplicateDigestSplitNote("held \(i + 1) of \(held.count) — \(g.words)") }
        duplicateDigestSplitNote("OUTCOME — nothing to split: "
                                 + (held.isEmpty ? "every one of \(groupCount.formatted()) duplicate group(s) holds at most one whole-file SHA-256"
                                                 : heldClause(held).trimmingCharacters(in: .whitespaces))
                                 + ". Nothing was changed.")
    }

    private func heldClause(_ held: [DuplicateGroupDigestSplit.GroupOutcome]) -> String {
        guard !held.isEmpty else { return "" }
        return " \(held.count.formatted()) group(s) held as they are — splitting would lose likeness that nothing here can "
            + "keep (catalog.json has no footage_likeness table, a file has no whole-file SHA-256 yet, or its content is not stored yet)."
    }

    private func refuseSplit(_ why: String) -> DuplicateDigestSplitOutcome {
        duplicateDigestSplitNote("REFUSED — \(why)")
        return .refused(why)
    }

    struct SplitLikenessRefusal: Error, Equatable { let words: String }

    /// Step 4: every split group's pairs in ONE transaction. A group with a
    /// pair whose content is not stored is returned in `heldGroups` (its
    /// other pairs stay recorded — true evidence either way). The store's
    /// refusal is the split's refusal.
    func recordSplitLikeness(_ plan: DuplicateGroupDigestSplit.Plan,
                             committer: CatalogCommitter) -> Result<DuplicateDigestSplitLikenessWrite, SplitLikenessRefusal> {
        let now = Int64(Date().timeIntervalSince1970.rounded(.down))
        let groups = plan.splitGroups.filter { !$0.pairs.isEmpty }
        guard !groups.isEmpty else { return .success(DuplicateDigestSplitLikenessWrite()) }
        var written = DuplicateDigestSplitLikenessWrite()
        var landed: [CatalogRow.FootageLikeness] = []
        let why = committer.commitSideTables("split duplicate groups: \(plan.pairs.count) likeness pair(s)",
                                             via: .footageLikeness) { tx in
            written = DuplicateDigestSplitLikenessWrite()
            landed = []
            for g in groups {
                for pair in g.pairs {
                    let row = pair.row(recordedAt: now)
                    switch try tx.recordFootageLikeness(row) {
                    case .recorded: written.recorded += 1; landed.append(row)
                    case .alreadyRecorded: written.alreadyRecorded += 1
                    case .contentMissing: written.heldGroups.insert(g.oldGroupID)
                    }
                }
            }
        }
        if let why { return .failure(SplitLikenessRefusal(words: "the likeness could not be kept in catalog.sqlite (\(why)) — nothing was changed")) }
        footageLikeness.absorb(landed)
        return .success(written)
    }

    /// Steps 5–7: apply, save, say so.
    private func applySplit(_ plan: DuplicateGroupDigestSplit.Plan, byID: [UUID: VideoRecord],
                            likeness: DuplicateDigestSplitLikenessWrite?, copy: String) -> DuplicateDigestSplitOutcome {
        applyDuplicateDigestSplit(plan, byID: byID)
        let split = plan.splitGroups, held = plan.heldGroups
        for (i, g) in split.enumerated() { duplicateDigestSplitNote("\(i + 1) of \(split.count) — \(g.words)") }
        for (i, g) in held.enumerated() { duplicateDigestSplitNote("held \(i + 1) of \(held.count) — \(g.words)") }
        let saved = saveCatalogNow()
        NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
        let tally = "\(split.count.formatted()) group(s) split · \(plan.newGroupCount.formatted()) new group(s) of copies · "
            + "\(plan.recordsLeaving.formatted()) file(s) left their group (unique bytes) · "
            + "\(plan.sameFootageFiles.formatted()) file(s) are the same footage in a different file — kept as same footage "
            + "(never delete-eligible) · "
            + "\(plan.differentLengthFiles.formatted()) file(s) are a different length (only the sampled hash matched) — not the same footage"
            + (likeness.map { " · likeness kept in catalog.sqlite: \($0.recorded.formatted()) new pair(s), \($0.alreadyRecorded.formatted()) already there" } ?? "")
            + (held.isEmpty ? "" : " ·" + heldClause(held))
        if saved {
            duplicateDigestSplitNote("OUTCOME — \(tally) · saved to the catalog")
        } else {
            duplicateDigestSplitNote("OUTCOME — \(tally) · NOT SAVED YET — the catalog store would not take the change now; "
                                     + "it stays in memory and the catalog store's own line says why")
        }
        return .split(groups: split.count, newGroups: plan.newGroupCount, left: plan.recordsLeaving,
                      saved: saved, safetyCopy: copy)
    }

    /// The plan onto the records: group fields only.
    private func applyDuplicateDigestSplit(_ plan: DuplicateGroupDigestSplit.Plan, byID: [UUID: VideoRecord]) {
        for change in plan.changes {
            guard let r = byID[change.id] else { continue }
            guard let group = change.groupID else {
                r.duplicateGroupID = nil
                r.duplicateConfidence = nil
                r.duplicateDisposition = .none
                r.duplicateReasons = ""
                r.duplicateBestMatchFilename = ""
                r.duplicateGroupCount = 0
                continue
            }
            r.duplicateGroupID = group
            r.duplicateDisposition = change.disposition
            r.duplicateGroupCount = change.groupCount
            r.duplicateBestMatchFilename = change.bestMatch
        }
    }
}

// MARK: - The menu verb

extension MediaFileOperationsCenter {
    /// "Split Duplicate Groups by Full Hash" as the menu runs it: the split,
    /// then — when anything was split — a whole-catalog Find Similar Footage
    /// run, so the files that left the copies as the same footage show their
    /// links at once (the run is an MFO job; it queues behind one in flight).
    @discardableResult
    func splitDuplicateGroupsKeepingSameFootage(model: VideoScanModel) -> DuplicateDigestSplitOutcome {
        let outcome = model.splitDuplicateGroupsByFullDigest()
        if case .split = outcome { startFindSimilarFootage(scope: .catalog, model: model) }
        return outcome
    }
}
