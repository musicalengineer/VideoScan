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
//   4. the plan applied to the in-memory records (group id, disposition,
//      count, best match — never a path, a marker, a digest or a file);
//   5. ONE synchronous save through the single writer (`saveCatalogNow` →
//      CatalogCommitter.commitNow under catalog.sqlite);
//   6. START, one line per split group (what stayed, what became a new
//      group, what left — by filename) and OUTCOME, through one sink:
//      console + catalog.log, videoscan.log, the unified log.
// Milliseconds on 15k rows (one pass + a dictionary), so not an MFO job
// (CLAUDE.md "Long operations" starts at about a minute).
//
// SAME FOOTAGE IS KEPT (Rick 2026-10-19: "I don't want to lose the 'same
// event different codec' feature"). A file that leaves the copies because
// its bytes differ is described by the duplicate check's own likeness rule
// (DuplicateLikeness): "same footage as X, different codec: FFV1 MKV · H.264
// MOV (the duplicate check matched filename+duration)". The link itself is
// Find Similar Footage's to record (FootageGrouping `copyCheckLikeness`
// derives it from the files' metadata, not from these group fields), so the
// split destroys nothing; the menu item starts a Find Similar Footage run
// right after a split so the links show at once. Footage links are never
// delete-eligible.
//
// HELD GROUPS. Before planning, a simulated Find Similar Footage pass
// (`duplicateDigestSplitFootageGroups`) says which files will stay linked as
// the same footage. A group whose members would be cut apart — alike only
// weakly (a default timecode, a camera-counter name, format and length),
// which a footage group cannot hold without demoting byte copies — is HELD
// exactly as it is and said so, one line per group. Verify keeps listing it
// until there is a place to keep weak likeness (Rick's schema decision).
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

extension VideoScanModel {

    static let duplicateDigestSplitTitle = "Split Duplicate Groups by Full Hash"

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
                               bestMatch: r.duplicateBestMatchFilename, likeness: DuplicateLikeness.Facts(record: r)))
        }
        return facts
    }

    /// Record id → footage group after a SIMULATED Find Similar Footage pass
    /// over the whole catalog (pure; no stat, no write): every stored whole-
    /// file digest is taken as current, because only CONNECTIVITY matters
    /// here — would the files stay linked once their old group is gone?
    /// One main-actor snapshot pass plus the grouping (≈1 s on 11k rows in
    /// Debug; the split is a one-off repair, not a cycler).
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

    /// Plan, safety copy, apply, save, say so. See the file header.
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
        let plan = DuplicateGroupDigestSplit.plan(facts, elect: { ids in
            DuplicateDetector.electKeeper(from: ids.compactMap { byID[$0] }, policy: policy)?.id
        }, footageGroupOf: duplicateDigestSplitFootageGroups())
        let groupCount = Set(facts.map(\.groupID)).count
        let held = plan.heldGroups
        let heldTally = "\(held.count.formatted()) group(s) held as they are — splitting would lose likeness that nothing "
            + "else can hold yet (a default timecode, a camera-counter name, or format and length alone); they wait for a "
            + "place to keep weak likeness"
        guard !plan.isEmpty else {
            for (i, g) in held.enumerated() { duplicateDigestSplitNote("held \(i + 1) of \(held.count) — \(g.words)") }
            duplicateDigestSplitNote("OUTCOME — nothing to split: "
                                     + (held.isEmpty ? "every one of \(groupCount.formatted()) duplicate group(s) holds at most one whole-file SHA-256"
                                                     : heldTally)
                                     + ". Nothing was changed.")
            return .nothingToSplit
        }
        let split = plan.splitGroups
        duplicateDigestSplitNote("START — \(split.count.formatted()) of \(groupCount.formatted()) duplicate group(s) hold "
                                 + "files with different whole-file SHA-256s; each is split into groups of true copies, "
                                 + "and a file that is the same footage in another file stays linked as SAME FOOTAGE. "
                                 + "Only the duplicate-group fields of \(plan.changes.count.formatted()) row(s) change — "
                                 + "no file is touched." + (held.isEmpty ? "" : " " + heldTally + "."))
        guard let copy = snapshotCatalog(prefix: "pre-dup-split") else {
            let why = "no safety copy of the catalog could be made — nothing was changed"
            duplicateDigestSplitNote("REFUSED — \(why)")
            return .refused(why)
        }
        duplicateDigestSplitNote("safety copy: \(copy)")
        applyDuplicateDigestSplit(plan, byID: byID)
        for (i, g) in split.enumerated() {
            duplicateDigestSplitNote("\(i + 1) of \(split.count) — \(g.words)")
        }
        for (i, g) in held.enumerated() {
            duplicateDigestSplitNote("held \(i + 1) of \(held.count) — \(g.words)")
        }
        let saved = saveCatalogNow()
        NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
        let tally = "\(split.count.formatted()) group(s) split · \(plan.newGroupCount.formatted()) new group(s) of copies · "
            + "\(plan.recordsLeaving.formatted()) file(s) left their group (unique bytes) · "
            + "\(plan.sameFootageFiles.formatted()) file(s) are the same footage in a different file — kept as same footage "
            + "(Find Similar Footage records the links; never delete-eligible) · "
            + "\(plan.differentLengthFiles.formatted()) file(s) are a different length (only the sampled hash matched) — not the same footage"
            + (held.isEmpty ? "" : " · " + heldTally)
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
