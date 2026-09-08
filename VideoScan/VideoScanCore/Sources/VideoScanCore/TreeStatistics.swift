// TreeStatistics.swift
// Rick, 2026-09-07: "computer software is good at this kinda stuff, finding
// patterns, averages, outliers, finding things humans overlook. This app
// should be able to do these things and hallie is the interface ... compute
// average ages for groups, how many people live in what location, how many
// generations between Ireland and Boston."
//
// Arithmetic over recorded fields. No inference about people, no model, no
// view — the query engine only, so it can be tested and budgeted on its own.
// Design and the measured feasibility numbers: docs/hallie_tree_aggregate_queries.md
//
// THE RULE THAT MATTERS: every figure carries its DENOMINATOR. On Rick's tree
// 11,920 of 16,383 people have a computable lifespan, so a mean lifespan is a
// mean over 11,920 — and an answer that says "57.5 years" without saying over
// how many has invented its own coverage. Every result here reports both the
// population it measured and how many records lacked the field, so the prose
// layer cannot omit what it never received.

import Foundation

public enum TreeStatistics {

    // MARK: - Asking

    /// Which people a question is about. Whole-tree and ancestors-only are
    /// DIFFERENT ANSWERS and must never be conflated (codex #1157): 14,851
    /// people in Rick's tree were born outside the US, while 12,045 of his
    /// own ancestors were born in Europe.
    public enum Scope: Sendable, Equatable {
        case wholeTree
        case ancestors(of: String, maxGenerations: Int)
        case descendants(of: String, maxGenerations: Int)
    }

    /// A birthplace test. Every case is decided by `BirthplaceClassifier`
    /// over the recorded string, so colonial and historical names keep their
    /// own identity and a name that spanned today's borders is reported but
    /// never counted.
    public enum PlaceFilter: Sendable, Equatable {
        case anywhere
        case country(String)
        case continent(BirthplaceClassifier.Continent)
        case outsideCountry(String)
        /// A raw recorded region ("New England"): matched against the place
        /// string as written, because the classifier knows countries, not
        /// every region a person may name.
        case recordedText(String)
    }

    /// Born and/or died within a year range, inclusive. Nil ends are open.
    public struct TimeFilter: Sendable, Equatable {
        public var bornFrom: Int?
        public var bornTo: Int?
        public init(bornFrom: Int? = nil, bornTo: Int? = nil) {
            self.bornFrom = bornFrom
            self.bornTo = bornTo
        }
        public var isEmpty: Bool { bornFrom == nil && bornTo == nil }
    }

    public struct Query: Sendable, Equatable {
        public var scope: Scope
        public var place: PlaceFilter
        public var time: TimeFilter
        public init(scope: Scope = .wholeTree,
                    place: PlaceFilter = .anywhere,
                    time: TimeFilter = TimeFilter()) {
            self.scope = scope
            self.place = place
            self.time = time
        }
    }

    // MARK: - Answering

    /// A count with the population it was drawn from, and every way a person
    /// can fall OUT of the measurement — the numbers an honest sentence has
    /// to mention (codex #1181: the first version filtered undated people out
    /// BEFORE counting, so "born before 1800" over a pool of one dated and one
    /// undated person reported 1 of 1 and looked complete).
    ///
    ///   considered     the whole population the question was asked of
    ///   matched        people who satisfied every filter
    ///   unrecorded     people whose record LACKS a field a filter needed —
    ///                  no birth year for a time filter, no birthplace for a
    ///                  place filter
    ///   unclassifiable people whose birthplace IS recorded but could not be
    ///                  judged against a country/continent filter: an unknown
    ///                  place name, or a historical name that spanned today's
    ///                  borders ("New France"). Reported, never counted.
    public struct Count: Sendable, Equatable {
        public let matched: Int
        public let considered: Int
        public let unrecorded: Int
        public let unclassifiable: Int
        public init(matched: Int, considered: Int, unrecorded: Int, unclassifiable: Int = 0) {
            self.matched = matched
            self.considered = considered
            self.unrecorded = unrecorded
            self.unclassifiable = unclassifiable
        }
    }

    /// A statistic over a numeric field, with the same denominator contract.
    public struct Summary: Sendable, Equatable {
        public let count: Int
        public let considered: Int
        public let unrecorded: Int
        public let mean: Double
        public let median: Double
        public let minimum: Int
        public let maximum: Int
    }

    // MARK: - Selecting

    /// The people a query names, in a stable order (by id) so two runs of the
    /// same question list the same people in the same sequence.
    public static func people(matching query: Query,
                              in graph: GedcomFamilyGraph) -> [GedcomFamilyGraph.Person] {
        population(query.scope, in: graph)
            .filter { matches(place: query.place, $0) && matches(time: query.time, $0) }
            .sorted { $0.id < $1.id }
    }

    /// How many people match, out of how many — with everyone who could not
    /// be judged accounted for, so the denominator is the population and not
    /// a pre-filtered subset that happens to look complete.
    public static func count(_ query: Query, in graph: GedcomFamilyGraph) -> Count {
        let pool = population(query.scope, in: graph)
        let needsYear = !query.time.isEmpty
        let needsPlace = query.place != .anywhere
        var matched = 0, unrecorded = 0, unclassifiable = 0
        for person in pool {
            if needsYear, person.birthYear == nil { unrecorded += 1; continue }
            if needsPlace {
                guard let raw = person.birthPlace, !raw.isEmpty else { unrecorded += 1; continue }
                if case .recordedText = query.place {
                    // Raw text needs no classification to be judged.
                } else {
                    let place = BirthplaceClassifier.classify(raw)
                    if place.isUnknown || place.isAmbiguous { unclassifiable += 1; continue }
                }
            }
            if matches(time: query.time, person), matches(place: query.place, person) { matched += 1 }
        }
        return Count(matched: matched, considered: pool.count,
                     unrecorded: unrecorded, unclassifiable: unclassifiable)
    }

    /// Lifespan in years over the matching people. Only people with BOTH a
    /// birth and a death year are counted, and an implausible span (negative,
    /// or over 120) is treated as unrecorded rather than averaged in — a
    /// twenty-generation tree carries transcription errors and one 900-year
    /// life would move a mean that people will quote.
    public static func lifespan(_ query: Query, in graph: GedcomFamilyGraph) -> Summary? {
        let matched = people(matching: query, in: graph)
        let spans = matched.compactMap { person -> Int? in
            guard let born = person.birthYear, let died = person.deathYear else { return nil }
            let span = died - born
            return (0...120).contains(span) ? span : nil
        }
        return summarize(spans, considered: matched.count)
    }

    /// Birth years over the matching people — the shape of "when was this
    /// family alive", and the basis for grouping by century.
    public static func birthYears(_ query: Query, in graph: GedcomFamilyGraph) -> Summary? {
        let matched = people(matching: query, in: graph)
        return summarize(matched.compactMap(\.birthYear), considered: matched.count)
    }

    /// Recorded birth countries and how many people were born in each,
    /// commonest first, ties by name so the order is stable. Ambiguous and
    /// unrecorded places are excluded from the rows and reported separately.
    public static func birthCountries(_ query: Query,
                                      in graph: GedcomFamilyGraph)
    -> (rows: [(country: String, count: Int)], unrecorded: Int, ambiguous: Int) {
        var tally: [String: Int] = [:]
        var unrecorded = 0, ambiguous = 0
        for person in people(matching: query, in: graph) {
            guard let raw = person.birthPlace, !raw.isEmpty else { unrecorded += 1; continue }
            let place = BirthplaceClassifier.classify(raw)
            if place.isAmbiguous { ambiguous += 1; continue }
            guard let country = place.country else { unrecorded += 1; continue }
            tally[country, default: 0] += 1
        }
        let rows = tally.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { (country: $0.key, count: $0.value) }
        return (rows, unrecorded, ambiguous)
    }

    // MARK: - Internals

    private static func population(_ scope: Scope,
                                   in graph: GedcomFamilyGraph) -> [GedcomFamilyGraph.Person] {
        switch scope {
        case .wholeTree:
            return Array(graph.people.values)
        case .ancestors(let id, let maxGenerations):
            guard let root = graph.people[id] else { return [] }
            return graph.ancestorLine(of: root, line: .both, generations: maxGenerations)
                .flatMap(\.people)
        case .descendants(let id, let maxGenerations):
            guard let root = graph.people[id] else { return [] }
            var seen: Set<String> = [root.id]
            var frontier = [root], out: [GedcomFamilyGraph.Person] = []
            var generation = 0
            while !frontier.isEmpty, generation < maxGenerations {
                var next: [GedcomFamilyGraph.Person] = []
                for person in frontier {
                    for unit in graph.familyUnits(of: person) {
                        for child in unit.children where seen.insert(child.id).inserted {
                            out.append(child)
                            next.append(child)
                        }
                    }
                }
                frontier = next
                generation += 1
            }
            return out
        }
    }

    static func matches(place filter: PlaceFilter, _ person: GedcomFamilyGraph.Person) -> Bool {
        switch filter {
        case .anywhere:
            return true
        case .recordedText(let text):
            // A WHOLE comma-separated component, never a substring (codex
            // #1180): "england" as a substring matched "New England", so a
            // count of English births would have swallowed Massachusetts.
            // Same rule as GedcomFamilyGraph.place(_:mentions:) — "Cork,
            // Ireland" matches "ireland" because a component IS "ireland".
            guard let raw = person.birthPlace, !raw.isEmpty else { return false }
            let wanted = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespaces)
            return raw.split(separator: ",").contains { component in
                component.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    .trimmingCharacters(in: .whitespaces) == wanted
            }
        case .country, .continent, .outsideCountry:
            guard let raw = person.birthPlace, !raw.isEmpty else { return false }
            let place = BirthplaceClassifier.classify(raw)
            switch filter {
            case .country(let name):
                guard !place.isAmbiguous, let country = place.country else { return false }
                return country.compare(name, options: .caseInsensitive) == .orderedSame
            case .continent(let continent):
                return place.isIn(continent)
            case .outsideCountry(let name):
                return place.isOutside(country: name)
            default:
                return false
            }
        }
    }

    static func matches(time filter: TimeFilter, _ person: GedcomFamilyGraph.Person) -> Bool {
        guard !filter.isEmpty else { return true }
        guard let year = person.birthYear else { return false }
        if let from = filter.bornFrom, year < from { return false }
        if let to = filter.bornTo, year > to { return false }
        return true
    }

    private static func summarize(_ values: [Int], considered: Int) -> Summary? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2)
            ? Double(sorted[middle - 1] + sorted[middle]) / 2
            : Double(sorted[middle])
        return Summary(
            count: sorted.count,
            considered: considered,
            unrecorded: considered - sorted.count,
            mean: Double(sorted.reduce(0, +)) / Double(sorted.count),
            median: median,
            minimum: sorted[0],
            maximum: sorted[sorted.count - 1])
    }
}
