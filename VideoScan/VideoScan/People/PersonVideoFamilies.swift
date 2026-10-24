// PersonVideoFamilies.swift
// One row per piece of footage on a person's page (Rick 2026-10-24: the
// same 93-minute Thanksgiving footage listed seven times under Donna).
// Rows that are PROVEN the same footage collapse into one: the family's
// keeper leads, the other files sit under a quiet "+N versions".
//
// EVIDENCE — existing engines only, no new similarity heuristic:
//   * copies    the stored WHOLE-FILE SHA-256 + size (FootageFolders.Row
//               .copyKey). The duplicate group leg is dropped here: a group
//               can come from a sampled hash, which never says "same"
//               (GH #327).
//   * lineage   `derivedFrom`, followed up to 8 hops through records that
//               are NOT on the page, so two edits of one raw transfer meet
//               at the raw (FootageFolders.components does the union).
//   * confirmed the person's own "same footage" answer (FootageDecision
//               .same, Find Similar Footage / the inspector), read from
//               the page's side. The machine's unconfirmed likeness pairs
//               (footage_likeness) are never used.
//   * veto      a "not the same" answer between two files of a group keeps
//               that group apart (FootageGrouping's cannot-link rule) —
//               refuse rather than guess.
// The keeper is FootageFolders.family's: an original over a derivative,
// the archived file first, then the better transfer, then the longest.
// Duration alone never groups anything.
//
// COST: O(page rows × (8 + footage decisions)) record lookups, all O(1);
// never a pass over the catalog. Memory: one FootageFolders.Row (~300 B)
// per page row and per ancestor — ~6 MB for a person with 2,000 videos,
// each with an 8-deep chain, the worst case; released when the page is
// built.
//
// (For Rick: the union–find is the classic disjoint-set forest; `struct`s
// here are value types, copied like a C++ POD.)

import Foundation
import VideoScanCore

/// One row on a person's page: a piece of footage, its lead file and the
/// other files proven to be the same footage.
struct PersonVideoGroup: Identifiable, Equatable, Sendable {
    let lead: PersonVideoRow
    var versions: [PersonVideoRow] = []
    var id: UUID { lead.id }
    var rows: [PersonVideoRow] { [lead] + versions }
    var fileCount: Int { 1 + versions.count }

    /// "+2 versions" — the disclosure's words (pinned by test).
    var versionsWords: String { "+\(versions.count) version\(versions.count == 1 ? "" : "s")" }

    /// What the disclosure's help says the grouping rests on.
    static let evidenceHelp = "The same footage: identical by whole-file SHA-256, made from the same recording "
        + "(recorded lineage), or a pair you marked \u{201C}same footage\u{201D}."
}

enum PersonVideoFamilies {

    /// Two records, one answer.
    struct Pair: Sendable, Equatable, Hashable {
        let a: UUID
        let b: UUID
    }

    /// The evidence as values (built on the main actor, tested by hand).
    struct Evidence: Sendable, Equatable {
        /// The page's records and, for connectivity only, their ancestors.
        var rows: [FootageFolders.Row] = []
        /// Which of `rows` are on the page.
        var pageIDs: Set<UUID> = []
        var saidSame: [Pair] = []
        var saidNotSame: [Pair] = []
    }

    /// Page record → its group number (only records in a group of two or
    /// more), and its place in the group (0 = the keeper).
    struct Groups: Sendable, Equatable {
        var groupOf: [UUID: Int] = [:]
        var rank: [UUID: Int] = [:]
    }

    // MARK: - Evidence (main actor, O(page rows))

    @MainActor
    static func evidence(for recs: [VideoRecord], in model: VideoScanModel) -> Evidence {
        var e = Evidence()
        var seen = Set<UUID>()
        func add(_ r: VideoRecord) {
            guard seen.insert(r.id).inserted else { return }
            var row = model.footageFolderRow(r)
            row.duplicateGroupID = nil   // whole-file digests only (GH #327)
            e.rows.append(row)
        }
        for r in recs {
            add(r)
            e.pageIDs.insert(r.id)
        }
        for r in recs {
            var cursor = r
            for _ in 0..<8 {
                guard let p = cursor.derivedFrom, let parent = model.record(forID: p) else { break }
                add(parent)
                cursor = parent
            }
            for d in r.footageDecisions {
                guard let latest = r.footageDecision(about: d.otherID), latest.decidedAt == d.decidedAt else { continue }
                let pair = Pair(a: r.id, b: d.otherID)
                if latest.verdict == .same {
                    e.saidSame.append(pair)
                    // A file off the page can still bridge two that are on it.
                    if let other = model.record(forID: d.otherID) { add(other) }
                } else {
                    e.saidNotSame.append(pair)
                }
            }
        }
        return e
    }

    // MARK: - Groups (pure)

    static func groups(_ e: Evidence) -> Groups {
        let comps = FootageFolders.components(e.rows)
        var compOf: [UUID: Int] = [:]
        for (i, c) in comps.enumerated() { for r in c { compOf[r.id] = i } }
        var parent = Array(comps.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for p in e.saidSame {
            guard let i = compOf[p.a], let j = compOf[p.b] else { continue }
            let ri = find(i), rj = find(j)
            if ri != rj { parent[max(ri, rj)] = min(ri, rj) }
        }
        // Page members per final group, in evidence order.
        var members: [Int: [FootageFolders.Row]] = [:]
        for row in e.rows where e.pageIDs.contains(row.id) {
            guard let c = compOf[row.id] else { continue }
            members[find(c), default: []].append(row)
        }
        var vetoed = Set<Int>()
        for p in e.saidNotSame {
            guard let i = compOf[p.a], let j = compOf[p.b], e.pageIDs.contains(p.a), e.pageIDs.contains(p.b),
                  find(i) == find(j) else { continue }
            vetoed.insert(find(i))
        }
        var out = Groups()
        for (g, rows) in members where rows.count > 1 && !vetoed.contains(g) {
            let family = FootageFolders.family(rows)
            for (k, m) in family.members.enumerated() {
                out.groupOf[m.id] = g
                out.rank[m.id] = k
            }
        }
        return out
    }

    // MARK: - Collapse (pure)

    /// Picks keep their order; a later pick of the same footage, and every
    /// tagged file of it, sits under the first pick. Tagged rows of the
    /// same footage collapse under the keeper; groups keep the page order
    /// (`PersonVideos.sorted` of the leads).
    static func collapse(picks: [PersonVideoRow], tagged: [PersonVideoRow],
                         groups: Groups) -> (picks: [PersonVideoGroup], tagged: [PersonVideoGroup]) {
        var pickGroups: [PersonVideoGroup] = []
        var pickSlot: [Int: Int] = [:]
        for row in picks {
            if let g = groups.groupOf[row.id], let slot = pickSlot[g] {
                pickGroups[slot].versions.append(row)
            } else {
                if let g = groups.groupOf[row.id] { pickSlot[g] = pickGroups.count }
                pickGroups.append(PersonVideoGroup(lead: row))
            }
        }
        let pickIDs = Set(picks.map(\.id))
        var buckets: [Int: [PersonVideoRow]] = [:]
        var order: [Int] = []
        var loose: [PersonVideoGroup] = []
        for row in tagged where !pickIDs.contains(row.id) {
            guard let g = groups.groupOf[row.id] else { loose.append(PersonVideoGroup(lead: row)); continue }
            if let slot = pickSlot[g] { pickGroups[slot].versions.append(row); continue }
            if buckets[g] == nil { order.append(g) }
            buckets[g, default: []].append(row)
        }
        var taggedGroups = loose
        for g in order {
            let rows = (buckets[g] ?? []).sorted { (groups.rank[$0.id] ?? .max) < (groups.rank[$1.id] ?? .max) }
            guard let lead = rows.first else { continue }
            taggedGroups.append(PersonVideoGroup(lead: lead, versions: Array(rows.dropFirst())))
        }
        let leads = PersonVideos.sorted(taggedGroups.map(\.lead))
        let byLead = Dictionary(taggedGroups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return (pickGroups, leads.compactMap { byLead[$0.id] })
    }
}
