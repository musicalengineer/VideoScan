// ShowAgainDeleteClassifier.swift
// Which of the files "Show Again" brings back are safe to move to the Trash
// (Rick 2026-10-11) — the rows of the Review… sheet's "is it safe?" table.
//
// SHAPE. Three steps, each its own piece:
//   1. PROJECTION (main actor, `showAgainDeleteFacts`): one O(records) pass
//      turns the catalog into Sendable facts — for each file the review will
//      show again: its duplicate group, disposition, stored whole-file
//      digest, junk mark and the protections the Delete Duplicates engine
//      would apply; for each group its elected keeper; and which files have
//      another copy CANDIDATE anywhere (same sampled hash + size). Never in
//      a view body: the sheet runs it once, in its `.task`.
//   2. REACHABILITY (off the main actor): is each keeper's drive connected?
//      Through `ShowAgainDisk.volumeOnline`, so tests never touch a drive.
//   3. CLASSIFICATION (pure, `ShowAgainDeleteClassifier.summary`): facts in,
//      `DeleteReviewSummary` out. Table-tested.
//
// WHAT COUNTS AS "SAFE". The rows only offer what the existing Delete
// Duplicates engine will actually attempt — a reviewed pick needs the file
// to be an Extra copy whose group has an elected Keep (that is what the
// engine authorises) — and the engine re-proves every pick with a full
// SHA-256 of BOTH files at the move, holding anything that fails. On top:
//   * "safe" (checked by default) also needs the catalog's STORED whole-file
//     digests of the file and its keeper to be equal already. A match on the
//     sampled hash alone goes to Unsure (unchecked): the night diagnostic
//     found 10 sampled-hash pairs whose bytes differ (manually_deleted_959
//     report), so the table never calls a sampled match "safe".
//   * keeper election is the catalog's own (DuplicateDetector, under the
//     keeper precedence RAID › HDD › SSD, never an offline drive); a keeper
//     whose drive is not connected now, or that is itself still hidden as
//     deleted, puts the file in Unsure with no checkbox effect.
//   * the engine's own target gates are asked here too (the Master Archive
//     tree and volume, a drive marked Read only, half of an A/V pair, the
//     Archive Angel's hold) so the table never offers a file the engine
//     would refuse.
//   * a file with no other copy candidate at all is "Only copy" — never
//     offered (DeleteReviewSummary pins that a second time).
//
// Never reads the diagnostics CSV or anything outside the catalog.
//
// Memory: the facts are O(labelled files + their groups); the projection's
// hash index holds one Int per distinct (hash, size) key — ~100k keys at
// 100k records, a few MB worst case.

import Foundation
import VideoScanCore

// MARK: - Facts (Sendable values)

struct ShowAgainDeleteFacts: Sendable, Equatable {

    /// One file the review will show again.
    struct File: Sendable, Equatable {
        let id: UUID
        let filename: String
        let path: String
        let sizeBytes: Int64
        let disposition: DuplicateDisposition
        let groupID: UUID?
        /// The stored whole-file SHA-256 (lowercase), if any.
        let digest: String?
        /// Confirmed Junk in Triage.
        let isConfirmedJunk: Bool
        /// Why the Delete Duplicates engine would never take it (archive,
        /// Read only, A/V pair, Archive Angel), in words; nil = no gate.
        let protection: String?
        /// Some other active record has the same sampled hash (or head+tail
        /// hash) and size, or shares its duplicate group.
        let hasCopyCandidate: Bool
    }

    /// A duplicate group's elected keeper.
    struct Keeper: Sendable, Equatable {
        let id: UUID
        let filename: String
        let path: String
        /// Stored whole-file digest — `contentFixity`, else the archive's.
        let digest: String?
        /// Its drive is connected (filled in off the main actor).
        var online: Bool
        /// Still hidden as deleted and NOT shown again by this run (e.g. its
        /// file is missing) — never a survivor this table relies on.
        let staysHidden: Bool
    }

    var files: [File]
    /// Group id → its elected Keep.
    var keepers: [UUID: Keeper]
}

// MARK: - The classifier (pure)

enum ShowAgainDeleteClassifier {

    /// How the Delete Duplicates engine sees one file.
    enum Route: Equatable {
        /// An Extra copy with a usable keeper: the engine can be asked.
        case pick(keeper: ShowAgainDeleteFacts.Keeper, proven: Bool)
        /// The group's elected keeper itself.
        case kept
        /// The engine would not take it, or its keeper can't be relied on.
        case held(String)
        /// A copy probably exists, but the catalog has not paired them.
        case unpaired
        /// No other copy is known.
        case unique
    }

    static let keeperOfflineNote = "the copy that stays is on a drive that is not connected"
    static let keeperHiddenNote = "the copy that stays is itself hidden as deleted and could not be checked"
    static let unpairedNote = "a copy probably exists, but the catalog has not paired them yet (Find Duplicates)"
    static let uniqueNote = "no other copy is known"
    static let keptNote = "kept: the copy that stays"
    static let keptElsewhereNote = "kept: the catalog keeps this copy; its other copies are elsewhere"

    /// The route — the first rule that answers wins (the order is the spec).
    static func route(_ f: ShowAgainDeleteFacts.File, keepers: [UUID: ShowAgainDeleteFacts.Keeper]) -> Route {
        if let why = f.protection { return .held(why) }
        if f.disposition == .extraCopy, let g = f.groupID, let k = keepers[g], k.id != f.id {
            if k.staysHidden { return .held(keeperHiddenNote) }
            if !k.online { return .held(keeperOfflineNote) }
            let proven = f.digest != nil && f.digest == k.digest
            return .pick(keeper: k, proven: proven)
        }
        if f.disposition == .keep, f.groupID != nil { return .kept }
        return f.hasCopyCandidate || f.groupID != nil ? .unpaired : .unique
    }

    /// The table for `facts`. O(files).
    static func summary(_ facts: ShowAgainDeleteFacts) -> DeleteReviewSummary {
        let shown = Set(facts.files.map(\.id))
        let routes = facts.files.map { route($0, keepers: facts.keepers) }
        // Keeper id → do its in-set extras all have proven bytes?
        var extrasProven: [UUID: Bool] = [:]
        for case .pick(let k, let proven) in routes where shown.contains(k.id) {
            extrasProven[k.id] = (extrasProven[k.id] ?? true) && proven
        }
        var placed: [(DeleteReviewCategory, DeleteReviewItem)] = []
        placed.reserveCapacity(facts.files.count)
        for (f, r) in zip(facts.files, routes) {
            placed.append(place(f, r, keeperInSet: shown, extrasProven: extrasProven))
        }
        return DeleteReviewSummary(grouping: placed)
    }

    /// One file's row and line.
    static func place(_ f: ShowAgainDeleteFacts.File, _ r: Route, keeperInSet shown: Set<UUID>,
                      extrasProven: [UUID: Bool]) -> (DeleteReviewCategory, DeleteReviewItem) {
        func item(_ note: String, _ removal: DeleteReviewRemoval? = nil) -> DeleteReviewItem {
            DeleteReviewItem(id: f.id, filename: f.filename, path: f.path, sizeBytes: f.sizeBytes,
                             note: note, removal: removal)
        }
        if f.isConfirmedJunk { return (.markedJunk, junkItem(f, r, item)) }
        switch r {
        case .pick(let k, let proven):
            let removal = DeleteReviewRemoval.duplicate(ReviewedDuplicatePick(recordID: f.id, path: f.path, keeperID: k.id))
            guard proven else {
                return (.unsure, item("probably a copy of \(k.filename); checked byte for byte before it moves", removal))
            }
            return shown.contains(k.id)
                ? (.copiesOfEachOther, item("an extra copy of \(k.filename), which stays", removal))
                : (.copiesElsewhere, item("same bytes as \(k.path)", removal))
        case .kept:
            switch extrasProven[f.id] {
            case true?: return (.copiesOfEachOther, item(keptNote))
            case false?: return (.unsure, item(keptNote))
            case nil: return (.unsure, item(keptElsewhereNote))
            }
        case .held(let why): return (.unsure, item(why))
        case .unpaired: return (.unsure, item(unpairedNote))
        case .unique: return (.onlyCopy, item(uniqueNote))
        }
    }

    /// Junk moves from here only as an extra copy (the engine needs a
    /// keeper); a junk file with no copy is Triage's Delete Junk's job.
    private static func junkItem(_ f: ShowAgainDeleteFacts.File, _ r: Route,
                                 _ item: (String, DeleteReviewRemoval?) -> DeleteReviewItem) -> DeleteReviewItem {
        guard case .pick(let k, _) = r else {
            return item("the only copy here: delete it from Triage ▸ Delete Junk", nil)
        }
        return item("junk; another copy is kept (\(k.filename)), checked byte for byte before it moves",
                    .duplicate(ReviewedDuplicatePick(recordID: f.id, path: f.path, keeperID: k.id)))
    }
}

// MARK: - The model half (projection on the main actor, reachability off it)

extension VideoScanModel {

    /// The review's "is it safe?" table for the files `plan` would show
    /// again. One O(records) pass on the main actor, keeper reachability
    /// off it, the classification pure. Reads the catalog only.
    func showAgainDeleteReview(plan: ShowAgainPlan, disk: ShowAgainDisk = .live) async -> DeleteReviewSummary {
        var facts = showAgainDeleteFacts(plan: plan)
        guard !facts.files.isEmpty else { return .empty }
        let paths = Array(Set(facts.keepers.values.map(\.path)))
        let online = await Self.reachability(of: paths, disk: disk)
        for (group, keeper) in facts.keepers {
            facts.keepers[group]?.online = online.contains(keeper.path)
        }
        return ShowAgainDeleteClassifier.summary(facts)
    }

    /// Which of `paths` sit on a connected drive. Off the main actor.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func reachability(of paths: [String], disk: ShowAgainDisk) async -> Set<String> {
        Set(paths.filter { disk.volumeOnline($0) })
    }

    /// Step 1: the facts. `keepers[].online` is false until reachability fills it.
    func showAgainDeleteFacts(plan: ShowAgainPlan) -> ShowAgainDeleteFacts {
        let shownIDs = Set(plan.toShow.map(\.id))
        guard !shownIDs.isEmpty else { return ShowAgainDeleteFacts(files: [], keepers: [:]) }
        let stillHidden = Set(plan.staying.map(\.id))
        let index = ShowAgainCopyIndex(records: records)
        let protection = showAgainProtectionRule()
        var files: [ShowAgainDeleteFacts.File] = []
        var keepers: [UUID: ShowAgainDeleteFacts.Keeper] = [:]
        files.reserveCapacity(shownIDs.count)
        for item in plan.toShow {
            guard let rec = record(forID: item.id) else { continue }
            files.append(ShowAgainDeleteFacts.File(
                id: rec.id, filename: rec.filename, path: rec.fullPath, sizeBytes: rec.sizeBytes,
                disposition: rec.duplicateDisposition, groupID: rec.duplicateGroupID,
                digest: Self.wholeFileDigest(rec.contentFixity),
                isConfirmedJunk: rec.mediaDisposition == .confirmedJunk,
                protection: protection(rec),
                hasCopyCandidate: index.hasOtherCopy(rec)))
            if let g = rec.duplicateGroupID, keepers[g] == nil, let k = index.keeper(of: g) {
                keepers[g] = ShowAgainDeleteFacts.Keeper(
                    id: k.id, filename: k.filename, path: k.fullPath,
                    digest: Self.wholeFileDigest(k.contentFixity) ?? k.archiveFixity?.digest.lowercased(),
                    online: false, staysHidden: stillHidden.contains(k.id))
            }
        }
        return ShowAgainDeleteFacts(files: files, keepers: keepers)
    }

    /// The stored whole-file SHA-256, lowercase. For CLASSIFYING only: an
    /// older digest whose stamp can no longer stand in for a read still
    /// says the bytes were equal when it was taken; the engine reads both
    /// files again in full at the move whenever the stamp doesn't reproduce.
    nonisolated static func wholeFileDigest(_ f: ContentFixity?) -> String? {
        guard let f, f.algorithm == ContentFixity.sha256, !f.digest.isEmpty else { return nil }
        return f.digest.lowercased()
    }

    /// The Delete Duplicates engine's target gates, asked of one record and
    /// worded (nil = none applies). Built once per review: the archive
    /// snapshot and the Angel's sets are captured here.
    func showAgainProtectionRule() -> (VideoRecord) -> String? {
        let archiveVolume = archiveVolumeProtection()
        let label = archiveVolume?.label ?? "the archive volume"
        let hold = duplicateDeletionHoldRule()
        return { rec in
            if let refusal = self.bulkDeleteRefusal(rec, volume: archiveVolume) {
                return Self.bulkDeleteRefusalNote(refusal, volume: label)
            }
            if CatalogScopePolicy.isPairProtected(rec) { return ExcessCopiesPlan.pairReason }
            return hold(rec)?.why
        }
    }
}

/// One O(records) pass: how many active records share each sampled hash
/// (and each head+tail hash) at a size, and each group's elected keeper.
/// Main actor (reads `VideoRecord`); the result is plain dictionaries.
@MainActor
struct ShowAgainCopyIndex {
    private var byContentHash: [String: Int] = [:]
    private var byPartialMD5: [String: Int] = [:]
    private var groupSize: [UUID: Int] = [:]
    private var keepers: [UUID: VideoRecord] = [:]

    init(records: [VideoRecord]) {
        for r in records where !r.isPurged && !r.isSetAside && !r.isSuperseded {
            if let k = Self.contentKey(r) { byContentHash[k, default: 0] += 1 }
            if let k = Self.md5Key(r) { byPartialMD5[k, default: 0] += 1 }
            if let g = r.duplicateGroupID {
                groupSize[g, default: 0] += 1
                if r.duplicateDisposition == .keep, keepers[g] == nil { keepers[g] = r }
            }
        }
    }

    func keeper(of group: UUID) -> VideoRecord? { keepers[group] }

    /// Another active record has the same bytes by a sampled signature, or
    /// shares its duplicate group.
    func hasOtherCopy(_ r: VideoRecord) -> Bool {
        if let k = Self.contentKey(r), (byContentHash[k] ?? 0) > 1 { return true }
        if let k = Self.md5Key(r), (byPartialMD5[k] ?? 0) > 1 { return true }
        if let g = r.duplicateGroupID, (groupSize[g] ?? 0) > 1 { return true }
        return false
    }

    private static func contentKey(_ r: VideoRecord) -> String? {
        r.contentHash.isEmpty || r.sizeBytes <= 0 ? nil : "\(r.contentHash)|\(r.sizeBytes)"
    }

    private static func md5Key(_ r: VideoRecord) -> String? {
        r.partialMD5.isEmpty || r.sizeBytes <= 0 ? nil : "\(r.partialMD5)|\(r.sizeBytes)"
    }
}
