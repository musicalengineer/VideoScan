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
                               bestMatch: r.duplicateBestMatchFilename))
        }
        return facts
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
        })
        let groupCount = Set(facts.map(\.groupID)).count
        guard !plan.isEmpty else {
            duplicateDigestSplitNote("OUTCOME — nothing to split: every one of \(groupCount.formatted()) duplicate group(s) "
                                     + "holds at most one whole-file SHA-256. Nothing was changed.")
            return .nothingToSplit
        }
        duplicateDigestSplitNote("START — \(plan.groups.count.formatted()) of \(groupCount.formatted()) duplicate group(s) hold "
                                 + "files with different whole-file SHA-256s; each is split into groups of true copies. "
                                 + "Only the duplicate-group fields of \(plan.changes.count.formatted()) row(s) change — "
                                 + "no file is touched.")
        guard let copy = snapshotCatalog(prefix: "pre-dup-split") else {
            let why = "no safety copy of the catalog could be made — nothing was changed"
            duplicateDigestSplitNote("REFUSED — \(why)")
            return .refused(why)
        }
        duplicateDigestSplitNote("safety copy: \(copy)")
        applyDuplicateDigestSplit(plan, byID: byID)
        for (i, g) in plan.groups.enumerated() {
            duplicateDigestSplitNote("\(i + 1) of \(plan.groups.count) — \(g.words)")
        }
        let saved = saveCatalogNow()
        NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
        let tally = "\(plan.groups.count.formatted()) group(s) split · \(plan.newGroupCount.formatted()) new group(s) of copies · "
            + "\(plan.recordsLeaving.formatted()) file(s) left their group (unique bytes)"
        if saved {
            duplicateDigestSplitNote("OUTCOME — \(tally) · saved to the catalog")
        } else {
            duplicateDigestSplitNote("OUTCOME — \(tally) · NOT SAVED YET — the catalog store would not take the change now; "
                                     + "it stays in memory and the catalog store's own line says why")
        }
        return .split(groups: plan.groups.count, newGroups: plan.newGroupCount, left: plan.recordsLeaving,
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
