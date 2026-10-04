// RollCall.swift (VideoScanCore)
// ROLL CALL (Rick 2026-10-01): the end-credits list that drifts past while
// the family map assembles — names with birthplace and years, interleaved
// with portraits. This file builds the LIST (pure, off the main actor); the
// app's overlay only animates what it is handed.
//
// THE LIST, in three steps:
//   1. DEDUPE — one row per person id; and two rows with the same folded
//      name AND the same birth year are one person recorded twice (the
//      walk's "likely duplicate" shape) — the row with a portrait, then the
//      nearer generation, is kept. A name alone is never identity: two
//      undated John Smiths stay two rows.
//   2. CHOOSE ≤ `limit` (default 36 ≈ 32 s of credits) — with
//      `Options.shuffleSeed` set, a seeded shuffle (the every-3rd "mix");
//      otherwise the people with a
//      portrait first, then family notes, then dated-and-placed, then the
//      nearest generations; taken ROUND-ROBIN across Rick's line, Donna's
//      line and the rest, so a long credits roll is never all one side.
//      Privacy is asked lazily in that order (the app's LifeStatus walks
//      descendants — ask about the 36 shown, not the 39k walked):
//        deceased          → name, years, birthplace;
//        livingInnerCircle → LEFT OUT by default (Rick 2026-10-01: "we
//                            should refrain from showing living people such
//                            as me and Donna, someday we'll have a roll call
//                            but not yet"); name only when a future family
//                            roll call turns on
//                            `Options.includesLivingInnerCircle`;
//        livingPrivate     → left out, always.
//   3. ORDER for the story (a parameter; default oldest → newest, "feels
//      like a story"): by birth year, by generation outward (home people
//      first), or the reverses. Undated people go to the end of a year
//      order; ties break on generation, then name, then id — fully
//      deterministic.
//
// COST: O(n log n) over the walked people (one sort of priorities), n ≤ the
// walk (39k real, 100k in the scale test). Memory: the input plus ≤ `limit`
// entries.

import Foundation

public enum RollCall {

    public enum Order: String, Sendable, CaseIterable, Equatable {
        /// Oldest birth first — the default; reads like a story.
        case oldestFirst
        case newestFirst
        /// The home people first, then parents, grandparents …
        case generationOutward
        /// The furthest generation first, ending with the home people.
        case generationInward
    }

    /// One walked person, as the caller knows them.
    public struct Person: Sendable, Equatable {
        public let id: String
        public let name: String
        public let birthDate: String?
        public let deathDate: String?
        public let birthPlace: String?
        public let generation: Int?
        public let line: TreeWalk.Line
        public let hasPortrait: Bool
        public let storyCount: Int
        public let isInnerCircle: Bool

        public init(id: String, name: String, birthDate: String? = nil, deathDate: String? = nil,
                    birthPlace: String? = nil, generation: Int? = nil, line: TreeWalk.Line = .none,
                    hasPortrait: Bool = false, storyCount: Int = 0, isInnerCircle: Bool = false) {
            self.id = id
            self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            self.birthDate = birthDate
            self.deathDate = deathDate
            self.birthPlace = birthPlace
            self.generation = generation
            self.line = line
            self.hasPortrait = hasPortrait
            self.storyCount = storyCount
            self.isInnerCircle = isInnerCircle
            self.birthYear = GedcomFamilyGraph.year(in: birthDate)
        }

        /// Parsed once here, not in every sort comparison.
        let birthYear: Int?
    }

    /// One credit line. `years` and `place` are nil for a living person.
    public struct Entry: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let years: String?
        public let place: String?
        public let birthYear: Int?
        public let generation: Int?
        public let line: TreeWalk.Line
        public let hasPortrait: Bool
        public let isLiving: Bool
    }

    public struct Options: Sendable, Equatable {
        public var order: Order
        public var limit: Int
        /// THE switch for a future "family roll call": when true, living
        /// members of the inner circle (the home people, their spouses and
        /// children) appear by NAME ONLY — no years, no place. Off by
        /// default: today's Roll Call shows no living person at all (Rick
        /// 2026-10-01). Living people outside the inner circle are never
        /// shown, whatever this says.
        public var includesLivingInnerCircle: Bool
        /// THE MIX (Rick 2026-10-04: "it always picks the same people …
        /// every 3rd time we get a random selection"). When set, step 2
        /// takes the walked people in a SEEDED shuffle instead of priority
        /// order — still round-robin across the lines, still the same
        /// privacy. Same seed → same list (testable); nil → today's list.
        public var shuffleSeed: UInt64?

        public init(order: Order = .oldestFirst, limit: Int = 36, includesLivingInnerCircle: Bool = false,
                    shuffleSeed: UInt64? = nil) {
            self.order = order
            self.limit = max(0, limit)
            self.includesLivingInnerCircle = includesLivingInnerCircle
            self.shuffleSeed = shuffleSeed
        }
    }

    /// How long the credits run for `entries` rows: ~0.9 s a row, never
    /// under 20 s nor over 40 s (Rick: "~20–40 s").
    public static func duration(entries: Int, secondsPerEntry: Double = 0.9,
                                range: ClosedRange<Double> = 20...40) -> Double {
        min(range.upperBound, max(range.lowerBound, Double(entries) * secondsPerEntry))
    }

    /// The list (see the header). `life` is asked lazily, priority order.
    public static func build(_ people: [Person], options: Options = Options(),
                             life: (Person) -> PersonOfTheDay.Life) -> [Entry] {
        guard options.limit > 0, !people.isEmpty else { return [] }
        let unique = dedupe(people)

        // Priority: portrait › notes › dated-and-placed › nearest generation › id.
        // Computed once per person (not per comparison), then sorted by index.
        let priority: [Int] = unique.map { p in
            (p.hasPortrait ? 4 : 0) + (p.storyCount > 0 ? 2 : 0)
                + (p.birthYear != nil && PersonOfTheDay.clean(p.birthPlace) != nil ? 1 : 0)
        }
        let ordered: [Person]
        if let seed = options.shuffleSeed {
            var rng = SeededGenerator(seed: seed)
            ordered = unique.shuffled(using: &rng)
        } else {
            ordered = unique.indices.sorted { i, j in
                if priority[i] != priority[j] { return priority[i] > priority[j] }
                let ga = unique[i].generation ?? Int.max, gb = unique[j].generation ?? Int.max
                if ga != gb { return ga < gb }
                return unique[i].id < unique[j].id
            }.map { unique[$0] }
        }
        // Round-robin over three buckets: first line, second line, the rest.
        var buckets: [[Person]] = [[], [], []]
        for p in ordered {
            switch p.line {
            case .first: buckets[0].append(p)
            case .second: buckets[1].append(p)
            case .both, .none: buckets[2].append(p)
            }
        }
        var cursor = [0, 0, 0]
        var chosen: [Entry] = []
        chosen.reserveCapacity(options.limit)
        var b = 0
        while chosen.count < options.limit, (0..<3).contains(where: { cursor[$0] < buckets[$0].count }) {
            defer { b = (b + 1) % 3 }
            guard cursor[b] < buckets[b].count else { continue }
            let p = buckets[b][cursor[b]]
            cursor[b] += 1
            if let e = entry(p, life: life(p), includesLivingInnerCircle: options.includesLivingInnerCircle) {
                chosen.append(e)
            }
        }
        return sort(chosen, by: options.order)
    }

    /// One row per id; same folded name + same birth year = one person.
    static func dedupe(_ people: [Person]) -> [Person] {
        var byID: [String: Int] = [:]
        var byNameYear: [String: Int] = [:]
        var out: [Person] = []
        out.reserveCapacity(people.count)
        func better(_ a: Person, than b: Person) -> Bool {
            if a.hasPortrait != b.hasPortrait { return a.hasPortrait }
            let ga = a.generation ?? Int.max, gb = b.generation ?? Int.max
            if ga != gb { return ga < gb }
            return a.id < b.id
        }
        for p in people where p.name.contains(where: \.isLetter) {
            if byID[p.id] != nil { continue }
            if let year = p.birthYear {
                let key = fold(p.name) + "|\(year)"
                if let i = byNameYear[key] {
                    byID[p.id] = i
                    if better(p, than: out[i]) { out[i] = p }
                    continue
                }
                byNameYear[key] = out.count
            }
            byID[p.id] = out.count
            out.append(p)
        }
        return out
    }

    /// Case-, diacritic- and spacing-insensitive name key.
    static func fold(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// One credit line, or nil when this person is not shown. A living
    /// inner-circle member is shown (name only) ONLY with the family roll
    /// call switch on.
    static func entry(_ p: Person, life: PersonOfTheDay.Life,
                      includesLivingInnerCircle: Bool = false) -> Entry? {
        switch life {
        case .livingPrivate:
            return nil
        case .livingInnerCircle:
            guard includesLivingInnerCircle else { return nil }
            return Entry(id: p.id, name: p.name, years: nil, place: nil, birthYear: nil,
                         generation: p.generation, line: p.line, hasPortrait: p.hasPortrait, isLiving: true)
        case .deceased:
            return Entry(id: p.id, name: p.name,
                         years: GedcomFamilyGraph.lifeYearsLabel(birth: p.birthDate, death: p.deathDate),
                         place: PersonOfTheDay.shortPlace(p.birthPlace), birthYear: p.birthYear,
                         generation: p.generation, line: p.line, hasPortrait: p.hasPortrait, isLiving: false)
        }
    }

    static func sort(_ entries: [Entry], by order: Order) -> [Entry] {
        func tie(_ a: Entry, _ b: Entry) -> Bool {
            let ga = a.generation ?? Int.max, gb = b.generation ?? Int.max
            if ga != gb { return ga > gb }
            if a.name != b.name { return a.name < b.name }
            return a.id < b.id
        }
        switch order {
        case .oldestFirst, .newestFirst:
            let ascending = order == .oldestFirst
            return entries.sorted { a, b in
                switch (a.birthYear, b.birthYear) {
                case let (x?, y?) where x != y: return ascending ? x < y : x > y
                case (.some, nil): return true          // undated last either way
                case (nil, .some): return false
                default: return tie(a, b)
                }
            }
        case .generationOutward, .generationInward:
            let outward = order == .generationOutward
            return entries.sorted { a, b in
                switch (a.generation, b.generation) {
                case let (x?, y?) where x != y: return outward ? x < y : x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default:
                    let ya = a.birthYear ?? Int.max, yb = b.birthYear ?? Int.max
                    if ya != yb { return ya < yb }
                    if a.name != b.name { return a.name < b.name }
                    return a.id < b.id
                }
            }
        }
    }
}

/// SplitMix64 — a tiny, fast, seedable generator (≈ a seeded std::mt19937
/// stand-in) so a shuffled Roll Call is reproducible in tests. Not for
/// anything security-related.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
