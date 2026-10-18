// CatalogCommitConflicts.swift
// Two copies of one content, the SAME curated field, DIFFERENT values, in
// ONE commit (cutover B2.3, regression F2 — the Manager's rule, 2026-10-18,
// Rick may change it): nothing is silently dropped.
//
// Before: the commit wrote the copies in records order and the shared
// display row kept the LAST one — the person's later edit could lose to an
// earlier one on the other copy, with no edit time to tell them apart. Now:
//   * both values go to `row_knowledge` (each row writes its own, with its
//     row id — as before);
//   * the display row says `conflict = 1` with no value — the field shows
//     empty after a relaunch and is counted as a conflict, exactly like a
//     conflict the import found between copies;
//   * the field is NOT reported as written-to-share, so neither in-memory
//     copy is overwritten by the other: each keeps showing its own value
//     until the relaunch;
//   * a later edit on ONE copy writes the display row again (conflict = 0)
//     and the other copy follows, as any shared edit does.
// Only the scalar groups can conflict (stars, notes, disposition, date,
// place, family music): tags and backup attestations are sets (every copy's
// value is kept) and people are written as each copy's own delta.
//
// "Changed" is the record's own per-field baseline (CatalogSharedCurated
// .edited(since:)), so a copy that merely still carries the older value is
// not a conflict — it is the sibling the edit propagates to.
//
// (For Rick: a merge conflict detected inside one transaction — both sides
// kept in the history table, the working value marked "unresolved".)

import Foundation

struct CatalogCommitConflicts: Sendable {

    struct Key: Hashable, Sendable {
        let digest: String
        let group: CatalogSharedCurated.Group
    }

    static let scalarGroups: [CatalogSharedCurated.Group] = [.stars, .notes, .disposition, .date, .place, .music]

    private(set) var keys: Set<Key> = []

    init(_ items: [CatalogCommit.Item]) {
        var first: [Key: CatalogSharedCurated] = [:]
        for item in items {
            guard let baseline = item.sharedBaseline, let digest = Self.digest(item.snapshot) else { continue }
            let now = CatalogSharedCurated(item.snapshot)
            for group in Self.scalarGroups where !now.same(group, as: baseline) {
                let key = Key(digest: digest, group: group)
                guard let earlier = first[key] else {
                    first[key] = now
                    continue
                }
                if !earlier.same(group, as: now) { keys.insert(key) }
            }
        }
    }

    /// The knowledge fields of `digest` that are in conflict in this commit.
    func fields(of digest: String) -> Set<CatalogDDL.KnowledgeField> {
        Set(keys.filter { $0.digest == digest }.flatMap(\.group.fields))
    }

    private static func digest(_ snapshot: VideoRecordDTO) -> String? {
        (try? CatalogRecordDTO(snapshot: snapshot, migrationLoadedAt: 0))?.digestState.digest
    }
}
