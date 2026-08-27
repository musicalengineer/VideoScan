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
//   - `.impossible` only when the death year is KNOWN and precedes the
//     fact's EARLIEST year (1838 / 1888 / 1877) — "before it existed at
//     all" means before the lower bound, never the upper;
//   - no death year: a birth AT OR AFTER the earliest year proves the
//     medium existed in the person's lifetime → `.possible`; a birth
//     before it is `.unknown` — an early birth makes a photograph
//     unlikely, not impossible, and Hallie does not say "can't" on a
//     guess. Only `.impossible` is operational (vetoes); the other two
//     arms behave identically today (ordinary offer).
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
        /// Death year is known and precedes the medium's earliest year.
        case impossible(WorldFact)
        /// The medium existed at some point in the person's known
        /// lifetime: death year at or after the earliest year, or birth
        /// year at or after it. Year precision only — when the death year
        /// EQUALS the earliest year this says "temporally possible", not
        /// that the person was alive on the milestone date. Whether
        /// anyone actually captured them is the catalog's business.
        case possible
        /// No death year on record. Never a veto.
        case unknown

        public var isImpossible: Bool {
            if case .impossible = self { return true }
            return false
        }

        /// Ordering (codex #708): a death before the earliest year is
        /// `.impossible`; otherwise a birth at or after it proves the
        /// medium existed in the person's lifetime (`.possible`); otherwise
        /// a death at or after it is `.possible`; otherwise (no death year
        /// and an early or unknown birth) `.unknown`. A birth year never
        /// vetoes: without a death year the lifespan is unknown, and
        /// "unknown" is the honest answer.
        public static func assess(birthYear: Int?, deathYear: Int?, medium: Medium) -> MediumFeasibility {
            let earliest = medium.earliestYear
            if let deathYear, deathYear < earliest { return .impossible(medium.fact) }
            if let birthYear, birthYear >= earliest { return .possible }
            if let deathYear, deathYear >= earliest { return .possible }
            return .unknown
        }

        public static func assess(person: GedcomFamilyGraph.Person, medium: Medium) -> MediumFeasibility {
            assess(birthYear: person.birthYear, deathYear: person.deathYear, medium: medium)
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
            canHavePhotograph(birthYear: person.birthYear, deathYear: person.deathYear)
        }

        /// Why the medium is impossible, for the log: "d. 1737 < photograph
        /// 1838". Nil unless `.impossible`.
        public static func impossibilityNote(person: GedcomFamilyGraph.Person,
                                             medium: Medium = .photograph) -> String? {
            guard case .impossible(let fact) = MediumFeasibility.assess(person: person, medium: medium),
                  let d = person.deathYear else { return nil }
            return "d. \(d) < \(medium.rawValue) \(fact.earliestYear)"
        }

        /// The honest line for a direct "photo of X" / "videos of X" /
        /// "recording of X" ask about a person who predates THAT medium.
        /// Deterministic; cites the medium's own spoken clause from the
        /// table rather than a number typed inline. Nil unless the medium
        /// is `.impossible` for this person.
        public static func impossibilityLine(person: GedcomFamilyGraph.Person,
                                             medium: Medium) -> String? {
            guard case .impossible(let fact) = MediumFeasibility.assess(person: person, medium: medium),
                  let d = person.deathYear else { return nil }
            let lived = "\(person.name) died in \(d)"
            let gap = fact.earliestYear - d
            let distance: String
            switch gap {
            case 180...: distance = "nearly two centuries"
            case 80..<180: distance = "about a century"
            case 20..<80: distance = "decades"
            default: distance = "\(gap) year\(gap == 1 ? "" : "s")"
            }
            let possessive = person.sex == "M" ? "his" : person.sex == "F" ? "her" : "their"
            let objective = person.sex == "M" ? "him" : person.sex == "F" ? "her" : "them"
            let head = "\(lived), \(distance) before \(fact.spokenClause) — there can\u{2019}t be \(medium.noun) of \(objective)."
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
    }
}
