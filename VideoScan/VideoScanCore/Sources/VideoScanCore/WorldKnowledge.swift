// WorldKnowledge.swift
// Dated facts about the WORLD that Hallie's deterministic answers may lean
// on — as data, in one place (Rick 2026-08-26: "there's a lot of heuristic
// knowledge sprinkled around the app by now"). Family knowledge lives in
// CyberBrain; world knowledge lives here; nothing is inlined as a magic
// number in a chip builder.
//
// The first rule to use the table: a person who died before the first
// photograph of a human being cannot have a photograph, so Hallie must not
// offer to find one ("tell me about Nathaniel Parker Sr", 1651–1737, came
// back with a "put a photo in his People folder" card).
//
// The rule is MEDIUM-SPECIFIC and TRI-STATE (codex gate 2026-08-26):
//   - photograph, film and sound each check their OWN fact;
//   - `.impossible` only when the death is PROVEN to precede the fact's
//     EARLIEST year (1838 / 1888 / 1877) — "before it existed at all"
//     means before the lower bound, never the upper;
//   - no death year: a birth AT OR AFTER the earliest year proves the
//     medium existed in the person's lifetime → `.possible`; a birth
//     before it is `.unknown` — an early birth makes a photograph
//     unlikely, not impossible, and Hallie does not say "can't" on a
//     guess — UNLESS the latest possible birth is more than a lifetime
//     (`maximumLifespanYears`, 125; nobody has lived past 122) before
//     the medium: then the person was gone before it existed and it is
//     `.impossible` (eval 2026-09-01: "videos of Martha Lamson", b. BEF
//     1633, d. AFT 1717, was a catalog search). Only `.impossible` is
//     operational (vetoes); the other two arms behave identically today
//     (ordinary offer).
//
// Dates are GEDCOM dates, qualifiers included (codex #721/#723): the
// rule reasons on `GedcomYearInterval`s, never on a bare year. "AFT
// 1837" is [1838, ∞) — NOT a death in 1837 and NOT impossible for a
// photograph; "BEF 1838" is (−∞, 1837] — proven before photography.
// "Proven before" = the death interval's UPPER bound < earliest;
// "proven within" = a LOWER bound ≥ earliest. A record whose death
// ends before its birth begins is contradictory → `.unknown`, never a
// veto on garbage.
//
// C++ readers: `WorldFact` is a plain immutable record; `WorldKnowledge` is
// a namespace (an enum with no cases cannot be instantiated). The table is
// a `static let` — built once, thread-safe, like a function-local static.
// `MediumFeasibility` is a tagged union (a `std::variant` with a payload
// on one arm) — callers `switch` on it and the compiler makes them handle
// every arm.

import Foundation

public struct WorldFact: Sendable, Equatable, Identifiable {
    public let id: String
    /// What happened, in one sentence, for a basis line or a doc.
    public let statement: String
    /// The year, or the range when history records a span ("late 1838 /
    /// early 1839" → 1838...1839).
    public let years: ClosedRange<Int>
    public let source: String
    /// The short clause Hallie may say aloud ("photography begins in 1838").
    public let spokenClause: String

    /// The FIRST year the thing existed. This is the only bound an
    /// impossibility argument may use: a death in any year of the range
    /// (or after) could, in principle, have been captured.
    public var earliestYear: Int { years.lowerBound }

    public init(id: String, statement: String, years: ClosedRange<Int>,
                source: String, spokenClause: String) {
        self.id = id
        self.statement = statement
        self.years = years
        self.source = source
        self.spokenClause = spokenClause
    }
}

public enum WorldKnowledge {

    // MARK: - The table

    public static let facts: [WorldFact] = [
        WorldFact(
            id: "photography.firstPersonInPhotograph",
            statement: "The oldest known photograph to include a person was taken in late 1838 or early 1839 (Daguerre, \"Boulevard du Temple\").",
            years: 1838...1839,
            source: "Louis Daguerre, \"Boulevard du Temple\", daguerreotype, Paris, 1838–1839.",
            spokenClause: "photography begins in 1838"),
        WorldFact(
            id: "film.firstMotionPictures",
            statement: "The first motion pictures were shot in 1888 (Le Prince, \"Roundhay Garden Scene\"); public cinema followed in 1895 (Lumière).",
            years: 1888...1895,
            source: "Louis Le Prince, \"Roundhay Garden Scene\", 1888; Lumière brothers, first paid public screening, Paris, 28 Dec 1895.",
            spokenClause: "motion pictures begin in 1888"),
        WorldFact(
            id: "film.amateur16mm",
            statement: "Amateur film-making began with Kodak's 16 mm Cine-Kodak system in 1923.",
            years: 1923...1923,
            source: "Eastman Kodak, Cine-Kodak camera and Kodascope projector, 1923.",
            spokenClause: "home movies on 16 mm begin in 1923"),
        WorldFact(
            id: "film.amateur8mm",
            statement: "Kodak's 8 mm home-movie format arrived in 1932.",
            years: 1932...1932,
            source: "Eastman Kodak, Standard 8 (\"Cine-Kodak Eight\"), 1932.",
            spokenClause: "8 mm home movies begin in 1932"),
        WorldFact(
            id: "audio.firstSoundRecording",
            statement: "Sound recording begins with Edison's phonograph in 1877.",
            years: 1877...1877,
            source: "Thomas Edison, tinfoil phonograph, demonstrated December 1877.",
            spokenClause: "sound recording begins in 1877"),
        WorldFact(
            id: "video.consumerVideotape",
            statement: "Consumer videotape arrived with Betamax in 1975 and VHS in 1976.",
            years: 1975...1976,
            source: "Sony Betamax SL-6300 (1975); JVC HR-3300 VHS (1976).",
            spokenClause: "home videotape begins in 1975"),
        WorldFact(
            id: "video.camcorder",
            statement: "The one-piece camcorder was introduced in 1983.",
            years: 1983...1983,
            source: "Sony Betamovie BMC-100 (1983); JVC GR-C1 VHS-C (1984).",
            spokenClause: "camcorders begin in 1983"),
    ]

    public static func fact(_ id: String) -> WorldFact? {
        facts.first { $0.id == id }
    }

    private static func requiredFact(_ id: String) -> WorldFact {
        guard let fact = fact(id) else {
            preconditionFailure("WorldKnowledge table lost its \(id) fact")
        }
        return fact
    }

    // MARK: - Media and their founding facts

    /// A recording medium Hallie can be asked for. Each one knows the
    /// world fact that dates its beginning.
    public enum Medium: String, Sendable, CaseIterable {
        case photograph, film, soundRecording

        public var fact: WorldFact {
            switch self {
            case .photograph: return requiredFact("photography.firstPersonInPhotograph")
            case .film: return requiredFact("film.firstMotionPictures")
            case .soundRecording: return requiredFact("audio.firstSoundRecording")
            }
        }

        /// First year anyone could have been captured in this medium.
        public var earliestYear: Int { fact.earliestYear }

        /// What the thing is called in a sentence ("a photograph").
        var noun: String {
            switch self {
            case .photograph: return "a photograph"
            case .film: return "film"
            case .soundRecording: return "a recording"
            }
        }
    }

    // MARK: - Feasibility (the rule)

    /// Could this person appear in this medium? `.impossible` carries the
    /// fact that rules it out, for the honest line and the basis line.
    public enum MediumFeasibility: Sendable, Equatable {
        /// Death is PROVEN (interval upper bound) to precede the medium's
        /// earliest year.
        case impossible(WorldFact)
        /// The medium existed at some point in the person's known
        /// lifetime: death year at or after the earliest year, or birth
        /// year at or after it. Year precision only — when the death year
        /// EQUALS the earliest year this says "temporally possible", not
        /// that the person was alive on the milestone date. Whether
        /// anyone actually captured them is the catalog's business.
        case possible
        /// Nothing proven either way: no dates, a death straddling the
        /// line, or a birth before the medium but within a lifetime of
        /// it. Never a veto.
        case unknown

        public var isImpossible: Bool {
            if case .impossible = self { return true }
            return false
        }

        /// Exact-year convenience: each year is the closed interval [y, y].
        public static func assess(birthYear: Int?, deathYear: Int?, medium: Medium) -> MediumFeasibility {
            assess(birth: birthYear.map(GedcomYearInterval.exact),
                   death: deathYear.map(GedcomYearInterval.exact),
                   medium: medium)
        }

        /// Nobody has lived past 122 (Jeanne Calment, 1875–1997). A birth
        /// interval whose LATEST year plus this is still before a medium's
        /// earliest year proves the person was gone before the medium
        /// existed, death record or not. 125 leaves a margin over the
        /// record; the boundary is strict (see `birthProvesGone`).
        public static let maximumLifespanYears = 125

        /// Rule 5: the latest possible birth year is more than a lifetime
        /// before `year` — born in `year − 126` or earlier. A birth exactly
        /// `maximumLifespanYears` before is NOT a veto (the person could,
        /// on the record, still be alive that year).
        public static func birthProvesGone(_ birth: GedcomYearInterval, before year: Int) -> Bool {
            guard let latestBirth = birth.upper else { return false }
            return latestBirth + maximumLifespanYears < year
        }

        /// The rule, on intervals (codex #708 ordering, #721/#723 bounds;
        /// rule 5 added 2026-09-01 for the Martha Lamson case):
        ///   1. birth and death contradict (death ends before birth
        ///      begins) → `.unknown` — the record is broken, not the person
        ///      pre-photographic;
        ///   2. death entirely before the earliest year → `.impossible`;
        ///   3. birth entirely at/after the earliest year → `.possible`;
        ///   4. death entirely at/after the earliest year → `.possible`;
        ///   5. birth ends more than `maximumLifespanYears` before the
        ///      earliest year → `.impossible` — the only way a birth
        ///      vetoes, and only when no death bound has already decided
        ///      (a PROVEN death at/after the medium, rule 4, outranks it:
        ///      a 130-year lifespan is a broken record, not a veto);
        ///   6. otherwise `.unknown` ("AFT 1837" death with no lower-bound
        ///      proof, "ABT 1838" straddling the line, a birth within a
        ///      lifetime of the medium, no dates at all).
        /// A birth otherwise never vetoes.
        public static func assess(birth: GedcomYearInterval?, death: GedcomYearInterval?,
                                  medium: Medium) -> MediumFeasibility {
            let earliest = medium.earliestYear
            if let birth, let death, death.endsBefore(birth) { return .unknown }
            if let death, death.isEntirelyBefore(earliest) { return .impossible(medium.fact) }
            if let birth, birth.isEntirelyAtOrAfter(earliest) { return .possible }
            if let death, death.isEntirelyAtOrAfter(earliest) { return .possible }
            if let birth, birthProvesGone(birth, before: earliest) { return .impossible(medium.fact) }
            return .unknown
        }

        public static func assess(person: GedcomFamilyGraph.Person, medium: Medium) -> MediumFeasibility {
            assess(birth: person.birthYearInterval, death: person.deathYearInterval, medium: medium)
        }
    }

    // MARK: - Honest lines and log notes (medium-specific)

    public enum photography {
        public static let firstPersonInPhotograph: WorldFact = Medium.photograph.fact

        /// First year anyone could have been photographed (1838).
        public static var year: Int { Medium.photograph.earliestYear }

        /// Convenience for the photograph medium.
        public static func canHavePhotograph(birthYear: Int?, deathYear: Int?) -> Bool {
            !MediumFeasibility.assess(birthYear: birthYear, deathYear: deathYear, medium: .photograph).isImpossible
        }

        public static func canHavePhotograph(person: GedcomFamilyGraph.Person) -> Bool {
            !MediumFeasibility.assess(person: person, medium: .photograph).isImpossible
        }

        /// Why the medium is impossible, for the log: "d. 1737 < photograph
        /// 1838" / "d. before 1800 < photograph 1838" / — by the lifespan
        /// cap (rule 5) — "b. before 1633 + 125 < film 1888". Nil unless
        /// `.impossible`.
        public static func impossibilityNote(person: GedcomFamilyGraph.Person,
                                             medium: Medium = .photograph) -> String? {
            guard case .impossible(let fact) = MediumFeasibility.assess(person: person, medium: medium)
            else { return nil }
            if let d = person.deathYearInterval, d.isEntirelyBefore(fact.earliestYear) {
                return "d. \(d.spoken) < \(medium.rawValue) \(fact.earliestYear)"
            }
            guard let b = person.birthYearInterval else { return nil }
            return "b. \(b.spoken) + \(MediumFeasibility.maximumLifespanYears) < \(medium.rawValue) \(fact.earliestYear)"
        }

        /// The honest line for a direct "photo of X" / "videos of X" /
        /// "recording of X" ask about a person who predates THAT medium.
        /// Deterministic; cites the medium's own spoken clause from the
        /// table rather than a number typed inline. Nil unless the medium
        /// is `.impossible` for this person.
        public static func impossibilityLine(person: GedcomFamilyGraph.Person,
                                             medium: Medium) -> String? {
            guard case .impossible(let fact) = MediumFeasibility.assess(person: person, medium: medium)
            else { return nil }
            let lived: String
            let gap: Int
            let why: String
            if let d = person.deathYearInterval, d.isEntirelyBefore(fact.earliestYear), let latest = d.upper {
                // "died in 1737" / "died before 1800" / "died about 1700".
                lived = "\(person.name) died \(d.qualifier == .exact ? "in " : "")\(d.spoken)"
                // Distance from the LATEST possible death — the smallest gap
                // the record allows, so the phrase can only understate.
                gap = fact.earliestYear - latest
                why = ""
            } else if let b = person.birthYearInterval, let latest = b.upper {
                // Rule 5 — no death bound decided it; the latest possible
                // BIRTH is more than a lifetime before the medium: "born
                // before 1633" (an open-ended "died after 1717" says nothing
                // about 1888, so the line does not lean on it).
                lived = "\(person.name) was born \(b.qualifier == .exact ? "in " : "")\(b.spoken)"
                gap = fact.earliestYear - latest
                why = " no one lives that long, so"
            } else {
                return nil
            }
            let distance = distancePhrase(years: gap)
            let possessive = person.sex == "M" ? "his" : person.sex == "F" ? "her" : "their"
            let objective = person.sex == "M" ? "him" : person.sex == "F" ? "her" : "them"
            let head = "\(lived), \(distance) before \(fact.spokenClause) —\(why) there can\u{2019}t be \(medium.noun) of \(objective)."
            switch medium {
            case .photograph:
                return head + " If the family has a painting, engraving, or gravestone photo, put it in \(possessive) People folder and I\u{2019}ll show it."
            case .film, .soundRecording:
                // Whether a PHOTOGRAPH is also out depends on the photograph
                // fact, not this one — say so only when it is.
                if MediumFeasibility.assess(person: person, medium: .photograph).isImpossible {
                    return head + " There can\u{2019}t be a photograph either; a painting, engraving, or gravestone photo in \(possessive) People folder is the best the family can do, and I\u{2019}ll show it."
                }
                return head + " If the family has a photograph of \(objective), put it in \(possessive) People folder and I\u{2019}ll show it."
            }
        }

        /// "decades" / "about a century" / "nearly two centuries" / "more
        /// than two and a half centuries" — a gap in years, as said.
        static func distancePhrase(years gap: Int) -> String {
            switch gap {
            case 250...:
                let centuries = ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
                let whole = gap / 100
                let half = gap % 100 >= 50 ? " and a half" : ""
                let count = whole < centuries.count ? centuries[whole] : "\(whole)"
                return "more than \(count)\(half) centuries"
            case 180..<250: return "nearly two centuries"
            case 80..<180: return "about a century"
            case 20..<80: return "decades"
            default: return "\(gap) year\(gap == 1 ? "" : "s")"
            }
        }
    }
}
