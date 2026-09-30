// TreeWalkHighlight.swift (VideoScanCore)
// "Highlight" for the Walk Tree fan (Donna 2026-09-29, after her first
// demo: "last names and/or places, as checkmarks"). The fan stays whole —
// a deep walk keeps every dot — and the checked surnames / places pick out
// who stands out: matches bright, everyone else dimmed. So a user never has
// to know which subset of a 20-generation tree "fits"; they say what they
// are interested in.
//
// THE RULE. Within a group the checks are OR ("Breen or McGill"); across
// the two groups they are AND ("a McGill born in Scotland"). No checks in a
// group = that group does not filter. No checks at all = no highlight.
//
// FACETS. Only the people the walk VISITED are counted — the checklists
// describe what is on screen, not the whole 39k-person file. Surnames are
// compared case-folded and trimmed ("BREEN", "Breen " → "breen") and shown
// in their most common spelling. Unknown birth region is listed (it is
// honest to show how many have no recorded place) but a blank surname is
// not a surname.
//
// COST. One O(visited) pass for the facets and one per change of checks for
// the match mask — ~39k array reads, well under a millisecond. Never in a
// SwiftUI body: the app computes both off-main and hands the view arrays.
//
// (C++ readers: `enum TreeWalkHighlight` with no cases is a namespace; the
// structs are plain values.)

import Foundation

public enum TreeWalkHighlight {

    public struct Facet: Sendable, Equatable, Identifiable {
        /// The comparison key (folded surname, or the region's raw value).
        public let key: String
        /// What the checkbox says ("Breen", "New England").
        public let label: String
        public let count: Int
        public var id: String { key }
    }

    public struct Facets: Sendable, Equatable {
        /// Most common first; ties alphabetical. At most `surnameLimit`.
        public let surnames: [Facet]
        /// How many distinct surnames the walk holds (the list may be capped).
        public let distinctSurnames: Int
        /// Every region present, most common first; Unknown last.
        public let regions: [Facet]
        public static let empty = Facets(surnames: [], distinctSurnames: 0, regions: [])
    }

    public struct Selection: Sendable, Equatable {
        public var surnames: Set<String> = []
        public var regions: Set<String> = []
        public init(surnames: Set<String> = [], regions: Set<String> = []) {
            self.surnames = surnames
            self.regions = regions
        }
        public var isEmpty: Bool { surnames.isEmpty && regions.isEmpty }
    }

    /// The folded comparison key for a surname ("" for none).
    public static func surnameKey(_ raw: String?) -> String {
        guard let raw else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The checklists for the people at `visited` ordinals.
    /// `surnames` and `regions` are parallel to the walk's `ids`.
    public static func facets(visited: [Int], surnames: [String],
                              regions: [BirthplaceClassifier.BirthRegion],
                              surnameLimit: Int = 40) -> Facets {
        var surnameCount: [String: Int] = [:]
        var spellings: [String: [String: Int]] = [:]
        var regionCount: [BirthplaceClassifier.BirthRegion: Int] = [:]
        for o in visited where o >= 0 && o < surnames.count && o < regions.count {
            let raw = surnames[o].trimmingCharacters(in: .whitespacesAndNewlines)
            let key = surnameKey(raw)
            if !key.isEmpty {
                surnameCount[key, default: 0] += 1
                spellings[key, default: [:]][raw, default: 0] += 1
            }
            regionCount[regions[o], default: 0] += 1
        }
        func display(_ key: String) -> String {
            // The most common spelling; ties broken alphabetically so the
            // label is stable across runs.
            spellings[key]?.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key ?? key
        }
        let sortedSurnames = surnameCount
            .sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }
            .prefix(max(0, surnameLimit))
            .map { Facet(key: $0.key, label: display($0.key), count: $0.value) }
        let sortedRegions = regionCount
            .sorted { a, b in
                if (a.key == .unknown) != (b.key == .unknown) { return b.key == .unknown }
                return a.value != b.value ? a.value > b.value : a.key.rawValue < b.key.rawValue
            }
            .map { Facet(key: $0.key.rawValue, label: $0.key.label, count: $0.value) }
        return Facets(surnames: Array(sortedSurnames), distinctSurnames: surnameCount.count,
                      regions: sortedRegions)
    }

    /// The folded keys, parallel to `surnames` — computed once per walk so
    /// a change of checks is a plain compare per person.
    public static func surnameKeys(_ surnames: [String]) -> [String] { surnames.map(surnameKey) }

    /// Does the person at `ordinal` match? (OR within a group, AND across.)
    /// An empty selection matches nobody — "no highlight" is not "all lit".
    /// `surnameKeys` are the folded keys (`surnameKeys(_:)`).
    public static func matches(ordinal o: Int, selection: Selection, surnameKeys: [String],
                               regions: [BirthplaceClassifier.BirthRegion]) -> Bool {
        guard !selection.isEmpty, o >= 0, o < surnameKeys.count, o < regions.count else { return false }
        if !selection.surnames.isEmpty && !selection.surnames.contains(surnameKeys[o]) { return false }
        if !selection.regions.isEmpty && !selection.regions.contains(regions[o].rawValue) { return false }
        return true
    }

    /// The match mask over `visited` (parallel to it) — what the fan draws.
    public static func mask(visited: [Int], selection: Selection, surnameKeys: [String],
                            regions: [BirthplaceClassifier.BirthRegion]) -> [Bool] {
        guard !selection.isEmpty else { return Array(repeating: false, count: visited.count) }
        return visited.map { matches(ordinal: $0, selection: selection, surnameKeys: surnameKeys, regions: regions) }
    }
}
