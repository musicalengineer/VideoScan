// FamilyTreeBookmarks.swift
// "Some way to tag someone in the family tree as interesting or follow up"
// (Rick, 2026-08-30). One flag, not a rating.
//
// NAMED "bookmark" ON PURPOSE. Rick's first instinct was a heart, then he
// caught himself: in a FAMILY archive a favourites list ranks relatives,
// and Donna opening the tree to find her cousin hearted and her sister not
// is a bad afternoon. A bookmark says something about the reader's
// navigation, not about the person. "Pin" was unavailable — this codebase
// already uses it for the owner pin, identity pins and the durable tree
// pin, and a fourth meaning would be a trap.
//
// STORED BESIDE THE ARCHIVE, not in UserDefaults. Preferences are
// per-machine, and Donna is meant to curate from the iPad this autumn; a
// bookmark she makes there has to be one Rick sees here. The store already
// writes JSON sidecars next to the assets (current.json, .notof.json), so
// this follows that precedent rather than inventing a location.
//
// One flag also removes a design trap discussed and dropped: an earlier
// sketch auto-marked everyone who appears in both the People tab and the
// tree. That mixes a derived set with a manual one, so un-marking someone
// the rule keeps re-adding needs three states rather than two. A single
// explicit flag has none of that.

import Foundation

/// Person IDs the reader has marked to come back to.
///
/// Pure and injectable: `directory` is supplied, never discovered, so a
/// test writes to its own scratch dir and never the real archive.
struct FamilyTreeBookmarks: Equatable, Sendable {

    /// One marked person. The date is kept so a future "recently marked"
    /// view is a sort rather than a migration.
    struct Entry: Codable, Equatable, Sendable {
        let personID: String
        let markedAt: Date
    }

    private(set) var entries: [String: Entry]

    init(entries: [String: Entry] = [:]) { self.entries = entries }

    var ids: Set<String> { Set(entries.keys) }
    var count: Int { entries.count }
    func contains(_ personID: String) -> Bool { entries[personID] != nil }

    /// Newest first — the order a "take me back" list wants.
    var mostRecentFirst: [Entry] {
        entries.values.sorted { $0.markedAt > $1.markedAt }
    }

    /// Returns whether the person is marked AFTER the toggle, so a caller
    /// can report "Marked" / "Unmarked" without asking again.
    @discardableResult
    mutating func toggle(_ personID: String, now: Date = Date()) -> Bool {
        if entries[personID] != nil {
            entries[personID] = nil
            return false
        }
        entries[personID] = Entry(personID: personID, markedAt: now)
        return true
    }

    // MARK: - Persistence

    static let fileName = "family-tree-bookmarks.json"

    static func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// Never throws. A missing or unreadable file means "no bookmarks",
    /// which is the right answer: losing the file must not stop the tree
    /// from opening, and this is a convenience layer, not catalog data.
    static func load(from directory: URL) -> FamilyTreeBookmarks {
        guard let data = try? Data(contentsOf: fileURL(in: directory)) else {
            return FamilyTreeBookmarks()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([Entry].self, from: data) else {
            return FamilyTreeBookmarks()
        }
        return FamilyTreeBookmarks(
            entries: Dictionary(list.map { ($0.personID, $0) },
                                uniquingKeysWith: { a, b in a.markedAt >= b.markedAt ? a : b }))
    }

    /// Written as an ARRAY, sorted by id, so two machines editing the same
    /// archive produce a diffable file rather than a dictionary whose key
    /// order churns.
    func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let ordered = entries.values.sorted { $0.personID < $1.personID }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try encoder.encode(ordered).write(to: Self.fileURL(in: directory), options: .atomic)
    }
}
