// FootageFolderTitleSearch.swift
// A folder's own name is searchable (Rick, 2026-10-19): with Show ▸ As
// folders on, typing "thanksgiving" — any case — shows the
// "Thanksgiving · 1984" folder with its visible members, even when no
// member's own fields carry the word.
//
// The rule: a folder answers the query when EVERY plain word typed is in
// its title, compared lowercased + NFC — exactly the normalisation the
// catalog search index applies to its needles and haystacks
// (CatalogSearchIndex.prepareTokens / buildHaystack), so a title can never
// be more or less case-sensitive than a filename. A query carrying a
// year range, a field prefix (people:, tag:, …) or a quoted phrase that is
// not in the title is a question about the files, not the folder name:
// no folder answers it by title.
//
// The answer only ADDS rows: the folder's members that the view's other
// filters already let through (purge / set-aside / superseded / kind
// facet — the search's own input) join the search's hits. Nothing a
// filter hid comes back.
//
// Pure and O(folders + members of the matching folders); the caller runs
// it from computeFiltered (an event handler), never a view body.
//
// (For Rick: an `enum` with only `static` members is Swift's namespace —
// ≈ a C++ `namespace` of free functions.)

import Foundation

enum FootageFolderTitleSearch {

    /// The ids of every folder whose title answers `query`.
    static func folderIDs(answering query: String, in index: FootageFolders.Index) -> [UUID] {
        guard let needles = titleNeedles(query), !index.folders.isEmpty else { return [] }
        var out: [UUID] = []
        for (id, folder) in index.folders where titleAnswers(folder.title, needles: needles) {
            out.append(id)
        }
        return out.sorted { $0.uuidString < $1.uuidString }
    }

    /// Every record id in the folders whose title answers `query`.
    static func memberIDs(answering query: String, in index: FootageFolders.Index) -> Set<UUID> {
        var ids: Set<UUID> = []
        for id in folderIDs(answering: query, in: index) {
            guard let folder = index.folders[id] else { continue }
            for fi in folder.families where index.families.indices.contains(fi) {
                for m in index.families[fi].members { ids.insert(m.id) }
            }
        }
        return ids
    }

    /// `hits` (the search's survivors, in their order) plus the members of
    /// title-matching folders found in `candidates` (the search's input, in
    /// its order) that are not already hits. `hits` stays first and
    /// untouched, so the linear order the table knows is kept.
    static func adding(folderMembers ids: Set<UUID>, from candidates: [VideoRecord],
                       to hits: [VideoRecord]) -> [VideoRecord] {
        guard !ids.isEmpty else { return hits }
        let already = Set(hits.map(\.id))
        var out = hits
        for rec in candidates where ids.contains(rec.id) && !already.contains(rec.id) {
            out.append(rec)
        }
        return out
    }

    // MARK: - The rule

    /// The query's plain words, normalised like the index's needles; nil
    /// when the query is empty or carries anything but plain words.
    static func titleNeedles(_ query: String) -> [String]? {
        let tokens = CatalogSearchIndex.prepareTokens(pfTokenizeSearchQuery(query))
        guard !tokens.isEmpty else { return nil }
        var needles: [String] = []
        for token in tokens {
            guard case .substring(let needle) = token, !needle.isEmpty else { return nil }
            needles.append(needle)
        }
        return needles
    }

    /// Every needle is in the title, lowercased + NFC on both sides.
    static func titleAnswers(_ title: String, needles: [String]) -> Bool {
        let hay = title.lowercased().precomposedStringWithCanonicalMapping
        return needles.allSatisfy { CatalogSearchIndex.literalContains(haystack: hay, needle: $0) }
    }
}
