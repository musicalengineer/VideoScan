// ArchivedContentIndex.swift
// GH #528 — "archived means fixed" for every COPY of archived content.
//
// catalog.sqlite keeps ONE date per content: `user_dates` and
// `inferred_dates` are keyed by the whole-file digest, and the loader joins
// them by digest. So a date written on an UNARCHIVED copy (a twin) of
// archived content becomes the archived copy's date after the next launch,
// while the archive's folder, filename and manifest row stay where Update…
// left them (CLAUDE.md rule 3). The date seam (`isDateReadOnly`,
// VideoScanModel+DateReadOnly.swift) therefore asks two questions: is THIS
// row archived, and does a LIVE archived copy of its content exist? This
// index answers the second in O(1).
//
// What it holds: whole-file digest → the live rows that are archived
// themselves (the seam's per-row rule, `isDateReadOnlyItself`), plus the
// set of their sizes (a size miss answers "no" without computing the
// asking row's digest). The digest is the commit's own rule
// (`CatalogCommit.digest(of:)` — the key `user_dates` is stored under);
// no digest ⇒ no twin (rule 6: identity is the whole-file SHA-256, never a
// sample, never the path).
//
// When it rebuilds: lazily, on the first lookup after its answer can have
// changed — the records array was replaced or appended (`invalidate()`,
// from `records.didSet`), any row's archive facts changed in place
// (`VideoRecord.archiveFactsGeneration`: stage, derivation, path, removal,
// size, either fixity), or the Master Archive root moved. A date writer's
// loop over 100k rows does ONE rebuild, not one per row (it writes dates,
// which bump nothing here). Each hit is re-verified live (still archived,
// still live, same digest) so a stale bucket can never say "fixed" wrongly.
//
// COST. Rebuild: one O(records) pass with an O(1) per-row test (an enum
// compare, a string compare, a path prefix test); the digest is read only
// for the archived rows. Lookup: a set probe, then (size hit) one digest
// read and a short bucket scan. Never called from a view body for more
// than the one selected row.
//
// MEMORY (worst case): one bucket entry per live archived row — the 64-char
// digest key (~100 B with String overhead), one array slot (8 B) and one
// Int64 in the size set — ≈ 15 MB if all 100k rows were archived; ≈ 0.5 MB
// for Rick's few thousand archived rows. No record is copied (references).
//
// (For Rick: a lazily rebuilt `std::unordered_map<std::string,
// std::vector<Record*>>` guarded by a generation stamp — the
// cache-invalidation-by-version idiom, like an iterator-invalidation
// counter.)

import Foundation
import VideoScanCore

@MainActor
final class ArchivedContentIndex {

    /// What the index was built against. Any difference ⇒ rebuild.
    private struct Stamp: Equatable {
        let archiveFacts: UInt64
        let root: String?
    }

    private var builtFor: Stamp?
    private var byDigest: [String: [VideoRecord]] = [:]
    private var sizes: Set<Int64> = []
    /// Rebuilds so far — the scale test's "N lookups, ONE rebuild" probe.
    private(set) var rebuildCount = 0

    /// The records array changed (append, replace, remove): rebuild on the
    /// next lookup. O(1). Called from `VideoScanModel.records.didSet`.
    func invalidate() { builtFor = nil }

    /// A LIVE row other than `record` holding `record`'s whole-file digest
    /// that `isFixedItself` calls archived, or nil. `root` is the Master
    /// Archive root the predicate reads (part of the stamp).
    func archivedCopy(sharingContentOf record: VideoRecord, in records: [VideoRecord], root: String?,
                      isFixedItself: (VideoRecord) -> Bool) -> VideoRecord? {
        rebuildIfNeeded(records, root: root, isFixedItself: isFixedItself)
        guard !sizes.isEmpty, sizes.contains(record.sizeBytes),
              let digest = CatalogCommit.digest(of: record), let bucket = byDigest[digest] else { return nil }
        return bucket.first { copy in
            copy !== record && copy.removal == nil && isFixedItself(copy) && CatalogCommit.digest(of: copy) == digest
        }
    }

    private func rebuildIfNeeded(_ records: [VideoRecord], root: String?, isFixedItself: (VideoRecord) -> Bool) {
        let stamp = Stamp(archiveFacts: VideoRecord.archiveFactsGeneration, root: root)
        guard builtFor != stamp else { return }
        var map: [String: [VideoRecord]] = [:]
        var sizeSet: Set<Int64> = []
        for rec in records where rec.removal == nil && isFixedItself(rec) {
            guard let digest = CatalogCommit.digest(of: rec) else { continue }
            map[digest, default: []].append(rec)
            sizeSet.insert(rec.sizeBytes)
        }
        byDigest = map
        sizes = sizeSet
        builtFor = stamp
        rebuildCount += 1
    }
}
