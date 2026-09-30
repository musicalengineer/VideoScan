// FamilyMapTally.swift (VideoScanCore/FamilyMap)
// Per-unit counts for the family map (GH #227 design §4): how many of the
// walked ancestors were born in each unit, split by line (Rick's / Donna's
// / both), the top surnames, and the people themselves nearest generation
// first for the side panel — plus, since the follow-up round (2026-09-29),
// WHO IS NOT ON THE MAP and why.
//
// INPUT is the walk's flat per-person columns (parallel arrays over the
// same ordinals the fan and the Highlight use) plus two more the app
// computes ONCE per walk: the unit key per person (from
// `BirthplaceUnitResolver`) and the recorded place text that key came from
// (the tree's birthplace, or the family's own notes when the tree is
// blank). This pass never touches a place string except to carry it.
//
// WHO IS COUNTED. The `visited` ordinals, optionally filtered by
//   • `mask` — the Highlight match mask, PARALLEL TO `visited`. nil means
//     everyone; the app passes nil when no checks are ticked, because
//     `TreeWalkHighlight.mask` returns all-false for an empty selection
//     and all-false here honestly counts nobody. A mask whose length is
//     not `visited.count` is REFUSED (thrown), never truncated.
//   • `yearCeiling` — the time slider: births ≤ Y. A person with no birth
//     year is counted when there is no ceiling and EXCLUDED when there is
//     one: a slider that shows everyone at every year says nothing.
// Each person is counted once even if an ordinal is listed twice (the walk
// never does that; a bitmap makes it true anyway).
//
// NOT ON THE MAP. A considered person with no unit key is `unresolved`.
// Two honest reasons, told apart in `Totals`: a recorded place the map
// does not cover ("Berlin, Germany" — `unsupported`), and no recorded
// place at all (`unresolved - unsupported`). `Result.unplaced` lists them
// nearest generation first, capped by `unplacedLimit`, each with the text
// that was recorded so the panel can say "recorded as Berlin, Germany"
// rather than the misleading "no recorded place" (codex #1782, stage 2 F2).
//
// COST. `People.init` interns the unit keys and the folded surnames to
// small integers ONCE per walk (that is where the String hashing lives).
// `counts` is then one O(visited) integer pass, then per unit: surnames
// ranked (O(s log s), s = distinct surnames in that unit), the spelling
// census over the top surnames only, and members ordered nearest
// generation first by a counting sort with only the generations that
// make the cut string-sorted. The unplaced list is one more such sort over
// the unresolved ordinals. 40k people in ~10 ms at -Onone; measured in
// FamilyMapTallyTests. It is the year slider's hot path. Never in a
// SwiftUI body.
//
// (C++ readers: `enum FamilyMapTally` with no cases is a namespace; the
// structs are plain values; the "interning" is an enum table built with
// one std::unordered_map pass.)

import Foundation

public enum FamilyMapTally {

    /// The walk's per-person columns, parallel over ordinals.
    public struct People: Sendable {
        public let ids: [String]
        public let names: [String]
        public let surnames: [String]
        /// `TreeWalkHighlight.surnameKeys(surnames)` — the folded keys the
        /// Highlight already computes once per walk.
        public let surnameKeys: [String]
        public let birthYears: [Int?]
        /// Generations above the nearest start person (0 = a start).
        public let generations: [Int?]
        public let lines: [TreeWalk.Line]
        /// `BirthplaceUnitResolver.resolve(place)?.unitKey`, per person.
        public let unitKeys: [String?]
        /// The place text the unit key was resolved FROM (or that failed to
        /// resolve): the tree's birthplace, or the family's note. nil when
        /// nothing was recorded anywhere. Carried to `Member.recordedPlace`.
        public let recordedPlaces: [String?]

        // Interned once here: the tally pass compares integers only.
        let unitIDs: [Int32]          // -1 = no unit
        let unitTable: [String]       // id → unit key
        let surnameIDs: [Int32]       // -1 = blank surname
        let surnameTable: [String]    // id → folded surname key

        /// `surnameKeys` nil = fold them here, once, at construction.
        /// `recordedPlaces` nil = nothing recorded for anyone (older callers
        /// and the tally's own tests).
        public init(ids: [String], names: [String], surnames: [String], surnameKeys: [String]? = nil,
                    birthYears: [Int?], generations: [Int?], lines: [TreeWalk.Line], unitKeys: [String?],
                    recordedPlaces: [String?]? = nil) {
            self.ids = ids
            self.names = names
            self.surnames = surnames
            let folded = surnameKeys ?? TreeWalkHighlight.surnameKeys(surnames)
            self.surnameKeys = folded
            self.birthYears = birthYears
            self.generations = generations
            self.lines = lines
            self.unitKeys = unitKeys
            self.recordedPlaces = recordedPlaces ?? [String?](repeating: nil, count: ids.count)

            var unitIndex: [String: Int32] = [:]
            var units: [String] = []
            var uids = [Int32](repeating: -1, count: unitKeys.count)
            for (o, key) in unitKeys.enumerated() {
                guard let key else { continue }
                if let id = unitIndex[key] { uids[o] = id } else {
                    let id = Int32(units.count)
                    units.append(key)
                    unitIndex[key] = id
                    uids[o] = id
                }
            }
            var surnameIndex: [String: Int32] = [:]
            var surnameList: [String] = []
            var sids = [Int32](repeating: -1, count: folded.count)
            for (o, key) in folded.enumerated() where !key.isEmpty {
                if let id = surnameIndex[key] { sids[o] = id } else {
                    let id = Int32(surnameList.count)
                    surnameList.append(key)
                    surnameIndex[key] = id
                    sids[o] = id
                }
            }
            unitIDs = uids
            unitTable = units
            surnameIDs = sids
            surnameTable = surnameList
        }

        public var count: Int { ids.count }
    }

    public struct Member: Sendable, Equatable {
        public let id: String
        public let name: String
        public let birthYear: Int?
        public let generation: Int?
        public let line: TreeWalk.Line
        /// The place as it was recorded ("Massachusetts Bay Colony",
        /// "Lothian, Scotland", "Berlin, Germany"); nil when nothing was.
        public let recordedPlace: String?

        public init(id: String, name: String, birthYear: Int?, generation: Int?, line: TreeWalk.Line,
                    recordedPlace: String? = nil) {
            self.id = id
            self.name = name
            self.birthYear = birthYear
            self.generation = generation
            self.line = line
            self.recordedPlace = recordedPlace
        }
    }

    public struct SurnameCount: Sendable, Equatable {
        /// The most common spelling in this unit.
        public let surname: String
        public let count: Int
    }

    public struct UnitCount: Sendable, Equatable {
        public let people: Int
        public let byLine: [TreeWalk.Line: Int]
        /// Most common first; ties alphabetical by folded key. ≤ surnameLimit.
        public let topSurnames: [SurnameCount]
        public let distinctSurnames: Int
        /// Nearest generation first (unknown generation last), then folded
        /// surname, name, id. ≤ memberLimit.
        public let members: [Member]
    }

    public struct Totals: Sendable, Equatable {
        /// Visited people that passed the mask and the ceiling.
        public let considered: Int
        /// …of which had a unit key (the sum of every UnitCount.people).
        public let resolved: Int
        /// …of which only to a country outline.
        public let countryOnly: Int
        /// considered − resolved: not on the map, for either reason below.
        public let unresolved: Int
        /// …of the unresolved, those WITH a recorded place the map does not
        /// cover (Berlin, Germany). The rest have no recorded place at all.
        public let unsupported: Int

        public init(considered: Int, resolved: Int, countryOnly: Int, unresolved: Int, unsupported: Int = 0) {
            self.considered = considered
            self.resolved = resolved
            self.countryOnly = countryOnly
            self.unresolved = unresolved
            self.unsupported = unsupported
        }

        /// The unresolved people who recorded nothing at all.
        public var noRecordedPlace: Int { unresolved - unsupported }
    }

    public struct Result: Sendable, Equatable {
        public let counts: [String: UnitCount]
        public let totals: Totals
        /// The considered people with no unit, nearest generation first
        /// (same order as a unit's members). ≤ unplacedLimit; the totals
        /// carry the full count.
        public let unplaced: [Member]

        public init(counts: [String: UnitCount], totals: Totals, unplaced: [Member] = []) {
            self.counts = counts
            self.totals = totals
            self.unplaced = unplaced
        }

        public static let empty = Result(counts: [:], totals: Totals(considered: 0, resolved: 0, countryOnly: 0, unresolved: 0))
    }

    public enum TallyError: Error, Equatable, CustomStringConvertible {
        case maskLengthMismatch(mask: Int, visited: Int)
        case columnLengthMismatch(column: String, count: Int, expected: Int)

        public var description: String {
            switch self {
            case .maskLengthMismatch(let m, let v): return "mask has \(m) entries for \(v) visited people"
            case .columnLengthMismatch(let c, let n, let e): return "column '\(c)' has \(n) rows, ids has \(e)"
            }
        }
    }

    // MARK: - The pass

    public static func counts(people: People, visited: [Int], mask: [Bool]? = nil, yearCeiling: Int? = nil,
                              memberLimit: Int = 200, surnameLimit: Int = 10, unplacedLimit: Int = 25) throws -> Result {
        let n = people.count
        for (name, count) in [("names", people.names.count), ("surnames", people.surnames.count),
                              ("surnameKeys", people.surnameKeys.count),
                              ("birthYears", people.birthYears.count), ("generations", people.generations.count),
                              ("lines", people.lines.count), ("unitKeys", people.unitKeys.count),
                              ("recordedPlaces", people.recordedPlaces.count)] where count != n {
            throw TallyError.columnLengthMismatch(column: name, count: count, expected: n)
        }
        if let mask, mask.count != visited.count {
            throw TallyError.maskLengthMismatch(mask: mask.count, visited: visited.count)
        }

        var seen = [Bool](repeating: false, count: n)
        var ordinalsByUnit = [[Int]](repeating: [], count: people.unitTable.count)
        var unplacedOrdinals: [Int] = []
        var considered = 0, resolved = 0, countryOnly = 0, unsupported = 0
        for (i, o) in visited.enumerated() {
            guard o >= 0, o < n, !seen[o] else { continue }
            if let mask, !mask[i] { continue }
            if let yearCeiling {
                guard let year = people.birthYears[o], year <= yearCeiling else { continue }
            }
            seen[o] = true
            considered += 1
            let id = people.unitIDs[o]
            guard id >= 0 else {
                unplacedOrdinals.append(o)
                if hasText(people.recordedPlaces[o]) { unsupported += 1 }
                continue
            }
            resolved += 1
            ordinalsByUnit[Int(id)].append(o)
        }

        var counts: [String: UnitCount] = [:]
        var scratch = Scratch(surnames: people.surnameTable.count)
        for (id, ordinals) in ordinalsByUnit.enumerated() where !ordinals.isEmpty {
            let key = people.unitTable[id]
            if FamilyMapKey.isCountryKey(key) { countryOnly += ordinals.count }
            counts[key] = unitCount(people: people, ordinals: ordinals, memberLimit: memberLimit,
                                    surnameLimit: surnameLimit, scratch: &scratch)
        }
        let totals = Totals(considered: considered, resolved: resolved, countryOnly: countryOnly,
                            unresolved: considered - resolved, unsupported: unsupported)
        return Result(counts: counts, totals: totals,
                      unplaced: nearestMembers(people: people, ordinals: unplacedOrdinals, limit: unplacedLimit))
    }

    /// A recorded place is one with at least one non-blank character.
    /// Public because the app applies the same test when choosing between
    /// the tree's place and the family's note.
    @inline(__always) public static func hasText(_ s: String?) -> Bool {
        guard let s else { return false }
        return s.utf8.contains { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }
    }

    /// Dense per-surname-id counters, reused across units and reset via
    /// the touched list — no hashing per person. (C++: a scratch vector
    /// sized to the enum, cleared by walking the dirty list.)
    struct Scratch {
        var counts: [Int]
        var isTop: [Bool]
        var touched: [Int32] = []
        init(surnames: Int) {
            counts = [Int](repeating: 0, count: surnames)
            isTop = [Bool](repeating: false, count: surnames)
        }
    }

    /// Integers only per person: lines in a fixed array, surnames by
    /// interned id, and the spelling census over the top surnames only.
    static func unitCount(people: People, ordinals: [Int], memberLimit: Int, surnameLimit: Int,
                          scratch: inout Scratch) -> UnitCount {
        var lineCounts = [Int](repeating: 0, count: 4)
        scratch.touched.removeAll(keepingCapacity: true)
        for o in ordinals {
            lineCounts[lineIndex(people.lines[o])] += 1
            let sid = people.surnameIDs[o]
            if sid >= 0 {
                let s = Int(sid)
                if scratch.counts[s] == 0 { scratch.touched.append(sid) }
                scratch.counts[s] += 1
            }
        }
        var byLine: [TreeWalk.Line: Int] = [:]
        for (i, line) in TreeWalk.Line.allCases.enumerated() where lineCounts[i] > 0 { byLine[line] = lineCounts[i] }

        let distinct = scratch.touched.count
        let ranked = scratch.touched
            .sorted { a, b in
                let ca = scratch.counts[Int(a)], cb = scratch.counts[Int(b)]
                return ca != cb ? ca > cb : people.surnameTable[Int(a)] < people.surnameTable[Int(b)]
            }
            .prefix(max(0, surnameLimit))
        // The commonest exact spelling, for the top surnames only.
        var spellings: [Int32: [String: Int]] = [:]
        if !ranked.isEmpty {
            for sid in ranked { scratch.isTop[Int(sid)] = true }
            for o in ordinals {
                let sid = people.surnameIDs[o]
                guard sid >= 0, scratch.isTop[Int(sid)] else { continue }
                spellings[sid, default: [:]][trimmedSpelling(people.surnames[o]), default: 0] += 1
            }
            for sid in ranked { scratch.isTop[Int(sid)] = false }
        }
        func display(_ sid: Int32) -> String {
            spellings[sid]?.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
                ?? people.surnameTable[Int(sid)]
        }
        let top = ranked.map { SurnameCount(surname: display($0), count: scratch.counts[Int($0)]) }
        for sid in scratch.touched { scratch.counts[Int(sid)] = 0 }

        return UnitCount(people: ordinals.count, byLine: byLine, topSurnames: top,
                         distinctSurnames: distinct,
                         members: nearestMembers(people: people, ordinals: ordinals, limit: memberLimit))
    }

    static func lineIndex(_ line: TreeWalk.Line) -> Int {
        switch line {
        case .first: return 0
        case .second: return 1
        case .both: return 2
        case .none: return 3
        }
    }

    /// "Breen " → "Breen" for the spelling count, by bytes — no allocation
    /// when there is nothing to trim (the common case).
    static func trimmedSpelling(_ raw: String) -> String {
        let utf8 = raw.utf8
        guard let first = utf8.first, let last = utf8.last else { return raw }
        func space(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }
        guard space(first) || space(last) else { return raw }
        var lo = utf8.startIndex, hi = utf8.endIndex
        while lo < hi, space(utf8[lo]) { lo = utf8.index(after: lo) }
        while hi > lo, space(utf8[utf8.index(before: hi)]) { hi = utf8.index(before: hi) }
        return String(raw[lo..<hi])
    }

    /// The first `limit` members by (generation asc, unknown last; folded
    /// surname; name; id). A counting sort by generation (O(n), no
    /// comparisons), then only the generation buckets that make the cut
    /// are string-sorted. A negative generation is treated as unknown.
    static func nearestMembers(people: People, ordinals: [Int], limit: Int) -> [Member] {
        guard limit > 0, !ordinals.isEmpty else { return [] }
        var maxGeneration = -1
        for o in ordinals {
            if let g = people.generations[o], g > maxGeneration { maxGeneration = g }
        }
        // A corrupt walk could say generation 1_000_000; cap the buckets and
        // let everyone beyond the cap share the last known bucket — order
        // among them still falls to surname / name / id.
        let cap = 4_096
        let unknown = min(maxGeneration, cap) + 1
        var buckets = [[Int]](repeating: [], count: unknown + 1)
        for o in ordinals {
            let g = people.generations[o].map { $0 < 0 ? unknown : min($0, cap) } ?? unknown
            buckets[g].append(o)
        }
        var out: [Member] = []
        out.reserveCapacity(min(limit, ordinals.count))
        for bucket in buckets where !bucket.isEmpty {
            guard out.count < limit else { break }
            let sorted = bucket.count == 1 ? bucket : bucket.sorted { a, b in
                let ka = people.surnameKeys[a], kb = people.surnameKeys[b]
                if ka != kb { return ka < kb }
                let na = people.names[a], nb = people.names[b]
                if na != nb { return na < nb }
                return people.ids[a] < people.ids[b]
            }
            for o in sorted where out.count < limit {
                out.append(Member(id: people.ids[o], name: people.names[o], birthYear: people.birthYears[o],
                                  generation: people.generations[o], line: people.lines[o],
                                  recordedPlace: people.recordedPlaces[o]))
            }
        }
        return out
    }
}
