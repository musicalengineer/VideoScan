// WikipediaVetting.swift
// Screens Wikipedia / Wikidata search hits for Research Person (bug
// 2026-10-01). A full-text search for a 19th-century ancestor returned the
// article on a 1965 film because a character in it shares the surname, and
// the pane showed it like any other finding.
//
// Rick's ruling (2026-10-01): keep the near-misses — serendipity matters
// ("while browsing… I happened to see…") — but rank and label them. So every
// hit is KEPT and gets a `ResearchScreening`:
//
//   likely match — ALL of these hold:
//     1. Name: the article TITLE (or Wikidata label) names the person — the
//        surname plus a given name or a matching initial. Never the snippet:
//        an actor's article mentions the role he played.
//     2. Human: the Wikidata item has P31 (instance of) = Q5.
//     3. Dates: P569 (birth) / P570 (death), when both sides have them, fall
//        inside the plan's year window and within ± tolerance of the
//        subject's own birth / death year.
//   near miss — anything else, with a plain reason the pane shows:
//     "a film", "a book", "a place", "surname only", "a different person",
//     "different era — born 1725", "couldn't be checked", …
//
// A check that cannot run (lookup failed, no Wikidata item) never yields a
// likely match: the hit is kept as "couldn't be checked". Near-misses start
// unreviewed like every finding; only Rick's explicit Confirm sends anything
// to Hallie.
//
// Everything here is pure (no I/O) so each rule is unit-testable; the
// adapter in ResearchSources.swift does the batched fetching.
//
// C++ readers: `enum` with only `static` members ≈ a namespace;
// `struct … : Equatable` ≈ a value type with a generated operator==.

import Foundation

enum WikipediaVetting {

    // MARK: Lifespan

    /// What the subject's dates allow. `windowFrom…windowTo` is the plan's
    /// year window (already widened by the tolerance); `birth` / `death` are
    /// the subject's own years when known.
    struct Lifespan: Equatable, Sendable {
        let birth: Int?
        let death: Int?
        let windowFrom: Int
        let windowTo: Int
        let tolerance: Int

        init(birth: Int?, death: Int?, plan: ResearchQueryPlan,
             tolerance: Int = ResearchQueryPlan.defaultTolerance) {
            self.birth = birth
            self.death = death
            self.windowFrom = plan.yearFrom
            self.windowTo = plan.yearTo
            self.tolerance = tolerance
        }
    }

    // MARK: Name

    /// One way the subject is named: the surname and the given names that
    /// precede it (normalised: lower-case, no diacritics, no trailing dots).
    struct NameKey: Equatable, Sendable {
        let surname: String
        let givens: [String]
    }

    static let suffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv"]

    /// "Ébé" → "ebe"; "M." → "m"; "Sr.," → "sr".
    static func normalise(_ token: String) -> String {
        token.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:'\"()"))
    }

    /// Tokens of a personal name with Jr/Sr/II… suffixes dropped.
    static func nameTokens(_ name: String) -> [String] {
        var tokens = name.split(whereSeparator: { $0.isWhitespace })
            .map { normalise(String($0)) }
            .filter { !$0.isEmpty }
        while let last = tokens.last, suffixes.contains(last) { tokens.removeLast() }
        return tokens
    }

    /// Every (surname, givens) pair the plan's name variants imply —
    /// including maiden / alternate surnames. A one-word variant gives none.
    static func nameKeys(for plan: ResearchQueryPlan) -> [NameKey] {
        var keys: [NameKey] = []
        for variant in plan.nameVariants {
            let tokens = nameTokens(variant)
            guard tokens.count >= 2, let surname = tokens.last else { continue }
            let key = NameKey(surname: surname, givens: Array(tokens.dropLast()))
            if !keys.contains(key) { keys.append(key) }
        }
        return keys
    }

    /// The personal-name part of an article title or Wikidata label:
    /// "Amos Smith (politician)" → "Amos Smith"; "Smith, Ohio" → "Smith".
    static func personalName(fromTitle title: String) -> String {
        var name = title.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        if let comma = name.firstIndex(of: ",") { name = String(name[..<comma]) }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Two given-name tokens agree when equal, or when one is a single
    /// letter (an initial) matching the other's first letter.
    static func givensAgree(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.count == 1, let first = b.first { return a.first == first }
        if b.count == 1, let first = a.first { return b.first == first }
        return false
    }

    /// How a title relates to the subject's names.
    enum NameFit: Equatable, Sendable {
        /// Surname last, a given name or initial first.
        case match
        /// The title carries one of the surnames, but not with his given name.
        case surnameOnly
        /// The title does not carry the surname at all.
        case none
    }

    /// Rule 1. The title's last token must be a surname the subject went by
    /// and its first token one of that name's given names or initials.
    static func nameFit(title: String, keys: [NameKey]) -> NameFit {
        let tokens = nameTokens(personalName(fromTitle: title))
        if tokens.count >= 2, let surname = tokens.last, let given = tokens.first,
           keys.contains(where: { $0.surname == surname && $0.givens.contains { givensAgree($0, given) } }) {
            return .match
        }
        let surnames = Set(keys.map(\.surname))
        return tokens.contains(where: surnames.contains) ? .surnameOnly : .none
    }

    static func nameMatches(title: String, keys: [NameKey]) -> Bool {
        nameFit(title: title, keys: keys) == .match
    }

    // MARK: What the page is about (descriptions and P31)

    /// Description head nouns → the plain label the pane shows.
    private static let workLabels: [(nouns: [String], label: String)] = [
        (["film", "television film", "short film", "documentary film"], "a film"),
        (["novel", "novella", "book", "short story", "poem", "poetry collection"], "a book"),
        (["song", "single"], "a song"),
        (["album", "studio album", "live album", "compilation album", "ep"], "an album"),
        (["television series", "tv series", "miniseries", "television program", "television programme",
          "sitcom", "soap opera"], "a TV series"),
        (["episode"], "a TV episode"),
        (["video game"], "a video game"),
        (["play", "musical", "opera"], "a stage work"),
    ]

    /// Conservative on purpose: a works noun only counts when it ENDS the
    /// head phrase ("1965 film by …", "American television series
    /// (2022–present)"), so "American film and television actor" or
    /// "single-sculls rower" never match. Capture group 1 is the noun.
    private static let workPatterns: [NSRegularExpression] = {
        let nouns = workLabels.flatMap(\.nouns).sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let end = #"(?=$|\s*\(|,|;|\s(?:by|from|based|directed|starring|produced|created|written|composed|set|about|recorded|released)\b)"#
        let patterns = [
            // "1965 film by …", "1931 American western film"
            #"^\d{3,4}s?(?:[–-]\d{2,4})?\s(?:.*?\s)?(\#(nouns))\#(end)"#,
            // "song by …", "American television series (2022–present)"
            #"^(?:[\w'-]+ ){0,4}(\#(nouns))\#(end)"#,
        ]
        return patterns.map { pattern in
            // A malformed literal pattern is a programming error caught by
            // the test suite on first use, not a runtime condition.
            // swiftlint:disable:next force_try
            try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
    }()

    private static let pageKindLabels: [(phrase: String, label: String)] = [
        ("family name", "a name page"), ("surname", "a name page"), ("given name", "a name page"),
        ("disambiguation page", "a list page"), ("wikimedia list", "a list page"),
        ("wikimedia disambiguation", "a list page"),
        ("fictional character", "a fictional character"), ("fictional human", "a fictional character"),
    ]

    /// Rule 0 (cheap, no network): the one-line description says the page is
    /// about a work, a name or a list. Nil when it says nothing of the sort.
    static func nonPersonLabel(description: String?) -> String? {
        guard let description, !description.isEmpty else { return nil }
        let lowered = description.lowercased()
        if let kind = pageKindLabels.first(where: { lowered.contains($0.phrase) }) { return kind.label }
        let range = NSRange(description.startIndex..., in: description)
        for pattern in workPatterns {
            guard let match = pattern.firstMatch(in: description, options: [], range: range),
                  let nounRange = Range(match.range(at: 1), in: description)
            else { continue }
            let noun = description[nounRange].lowercased()
            if let work = workLabels.first(where: { $0.nouns.contains(noun) }) { return work.label }
        }
        return nil
    }

    static func describesNonPerson(_ description: String?) -> Bool {
        nonPersonLabel(description: description) != nil
    }

    /// P31 values → plain labels for items that are not people.
    private static let instanceLabels: [String: String] = [
        "Q11424": "a film", "Q24862": "a film", "Q506240": "a film", "Q93204": "a film",
        "Q7725634": "a book", "Q571": "a book", "Q8261": "a book", "Q47461344": "a book",
        "Q7366": "a song", "Q134556": "a song", "Q105543609": "a song",
        "Q482994": "an album", "Q208569": "an album",
        "Q5398426": "a TV series", "Q1259759": "a TV series", "Q21191270": "a TV episode",
        "Q7889": "a video game",
        "Q486972": "a place", "Q532": "a place", "Q515": "a place", "Q3957": "a place",
        "Q1093829": "a place", "Q15127012": "a place", "Q498162": "a place", "Q17343829": "a place",
        "Q4167410": "a list page", "Q13406463": "a list page",
        "Q101352": "a name page", "Q202444": "a name page", "Q12308941": "a name page",
        "Q11879590": "a name page",
        "Q95074": "a fictional character", "Q15632617": "a fictional character",
        "Q11446": "a ship",
    ]

    static func nonHumanLabel(instanceOf: [String]) -> String {
        instanceOf.lazy.compactMap { instanceLabels[$0] }.first ?? "not a person"
    }

    // MARK: Wikidata facts

    /// A year from a Wikidata time value, with the slack its precision
    /// implies (precision 9 = year → 0; 8 = decade → 10).
    struct WikidataYear: Equatable, Sendable {
        let year: Int
        let slack: Int
    }

    /// What one entity says about rules 2 and 3.
    struct EntityFacts: Equatable, Sendable {
        let instanceOf: [String]
        let births: [WikidataYear]
        let deaths: [WikidataYear]

        var isHuman: Bool { instanceOf.contains(WikipediaVetting.humanQID) }
    }

    static let humanQID = "Q5"

    /// Parses a `wbgetentities&props=claims` body. Returns nil when the body
    /// is not that shape at all (an error response, HTML, garbage) so the
    /// caller can label every pending hit "couldn't be checked". Missing
    /// entities (`"missing": ""`) are simply absent from the map.
    static func parseEntities(_ data: Data) -> [String: EntityFacts]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = root["entities"] as? [String: Any]
        else { return nil }
        var out: [String: EntityFacts] = [:]
        for (id, raw) in entities {
            guard let entity = raw as? [String: Any], entity["missing"] == nil,
                  let claims = entity["claims"] as? [String: Any]
            else { continue }
            out[id] = EntityFacts(
                instanceOf: statements(claims["P31"]).compactMap { snakValue($0)?["id"] as? String },
                births: statements(claims["P569"]).compactMap(year(from:)),
                deaths: statements(claims["P570"]).compactMap(year(from:)))
        }
        return out
    }

    /// Non-deprecated statements' main snaks.
    private static func statements(_ raw: Any?) -> [[String: Any]] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { statement in
            guard (statement["rank"] as? String) != "deprecated" else { return nil }
            return statement["mainsnak"] as? [String: Any]
        }
    }

    /// The `datavalue.value` of a snak that has a value ("somevalue" /
    /// "novalue" snaks have none).
    private static func snakValue(_ snak: [String: Any]) -> [String: Any]? {
        guard (snak["snaktype"] as? String) == "value",
              let datavalue = snak["datavalue"] as? [String: Any]
        else { return nil }
        return datavalue["value"] as? [String: Any]
    }

    /// "+1874-06-01T00:00:00Z" at precision ≥ 9 → 1874 (slack 0); decade
    /// precision widens the slack; anything coarser is treated as unknown.
    private static func year(from snak: [String: Any]) -> WikidataYear? {
        guard let value = snakValue(snak), let time = value["time"] as? String,
              let precision = value["precision"] as? Int, precision >= 8,
              let digits = ResearchText.firstCapture(#"^([+-]\d+)-"#, in: time),
              let year = Int(digits.replacingOccurrences(of: "+", with: ""))
        else { return nil }
        return WikidataYear(year: year, slack: precision >= 9 ? 0 : 10)
    }

    /// Rule 3. A side with no usable year is not held against the hit
    /// (rules 1 and 2 still apply); a side WITH years must have at least one
    /// inside the window and, when the subject's own year is known, within
    /// the tolerance of it.
    static func datesCompatible(_ facts: EntityFacts, lifespan: Lifespan) -> Bool {
        func fits(_ years: [WikidataYear], subjectYear: Int?) -> Bool {
            if years.isEmpty { return true }
            return years.contains { candidate in
                guard candidate.year + candidate.slack >= lifespan.windowFrom,
                      candidate.year - candidate.slack <= lifespan.windowTo
                else { return false }
                guard let subjectYear else { return true }
                return abs(candidate.year - subjectYear) <= lifespan.tolerance + candidate.slack
            }
        }
        return fits(facts.births, subjectYear: lifespan.birth)
            && fits(facts.deaths, subjectYear: lifespan.death)
    }

    /// "different era — born 1725" / "— died 1790" / plain "different era".
    static func eraLabel(_ facts: EntityFacts) -> String {
        if let born = facts.births.first { return "different era — born \(born.year)" }
        if let died = facts.deaths.first { return "different era — died \(died.year)" }
        return "different era"
    }

    // MARK: The screen

    /// One hit's evidence. `facts` is nil when the Wikidata check could not
    /// run (lookup failed, no item, item missing).
    struct Evidence: Equatable, Sendable {
        let title: String
        let description: String?
        let facts: EntityFacts?
    }

    /// Plain reason labels the pane shows for checks that could not run or
    /// that only the name decides.
    static let uncheckedLabel = "couldn't be checked"
    static let surnameOnlyLabel = "surname only"
    static let differentPersonLabel = "a different person"
    static let mentionsOnlyLabel = "only mentions the name"

    /// The verdict for one hit: what it IS first (a film is "a film" even
    /// when Wikidata is down), then the name, then whether it could be
    /// checked at all, then the dates.
    static func screen(_ evidence: Evidence, keys: [NameKey], lifespan: Lifespan) -> ResearchScreening {
        if let label = nonPersonLabel(description: evidence.description) { return .nearMiss(label) }
        if let facts = evidence.facts, !facts.isHuman { return .nearMiss(nonHumanLabel(instanceOf: facts.instanceOf)) }
        switch nameFit(title: evidence.title, keys: keys) {
        case .surnameOnly: return .nearMiss(surnameOnlyLabel)
        case .none: return .nearMiss(evidence.facts == nil ? mentionsOnlyLabel : differentPersonLabel)
        case .match: break
        }
        guard let facts = evidence.facts else { return .nearMiss(uncheckedLabel) }
        guard datesCompatible(facts, lifespan: lifespan) else { return .nearMiss(eraLabel(facts)) }
        return .likely
    }

    // MARK: Tally (log counts only)

    /// How the hits were screened, for one counts-only log line.
    struct Tally: Equatable, Sendable {
        var candidates = 0
        var likely = 0
        var notAPerson = 0
        var name = 0
        var dates = 0
        var unchecked = 0

        mutating func count(_ screening: ResearchScreening) {
            candidates += 1
            switch screening.reason {
            case _ where screening.outcome == .likelyMatch: likely += 1
            case WikipediaVetting.uncheckedLabel: unchecked += 1
            case WikipediaVetting.surnameOnlyLabel, WikipediaVetting.differentPersonLabel,
                 WikipediaVetting.mentionsOnlyLabel: name += 1
            case let reason where reason.hasPrefix("different era"): dates += 1
            default: notAPerson += 1
            }
        }

        /// No names, no titles, no excerpts — counts only.
        var logLine: String {
            "Research: wikipedia screened \(candidates) hits: \(likely) likely, "
                + "\(candidates - likely) also turned up (not a person \(notAPerson), name \(name), "
                + "dates \(dates), couldn't be checked \(unchecked))"
        }
    }
}
