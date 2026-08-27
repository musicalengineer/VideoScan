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
// C++ readers: `WorldFact` is a plain immutable record; `WorldKnowledge` is
// a namespace (an enum with no cases cannot be instantiated). The table is
// a `static let` — built once, thread-safe, like a function-local static.

import Foundation

public struct WorldFact: Sendable, Equatable, Identifiable {
    public let id: String
    /// What happened, in one sentence, for a basis line or a doc.
    public let statement: String
    /// The year, or the range when history records a span ("late 1838 /
    /// early 1839" → 1838...1839). `year` is the conservative end: the
    /// LAST year of the range, so "before `year`" is safely "before it
    /// existed at all".
    public let years: ClosedRange<Int>
    public let source: String
    /// The short clause Hallie may say aloud ("photography begins in 1839").
    public let spokenClause: String

    public var year: Int { years.upperBound }

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
            spokenClause: "photography begins in 1839"),
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

    // MARK: - Photography (the only rule in use so far)

    public enum photography {
        public static let firstPersonInPhotograph: WorldFact = {
            guard let fact = WorldKnowledge.fact("photography.firstPersonInPhotograph") else {
                preconditionFailure("WorldKnowledge table lost its photography fact")
            }
            return fact
        }()

        /// First year anyone could have been photographed.
        public static var year: Int { firstPersonInPhotograph.year }

        /// When a death year is unknown, a birth this far before `year`
        /// still rules a photograph out: the person would have to reach
        /// this age just to be alive when photography began. Nobody in a
        /// family tree is credibly photographed at 80+ in 1839.
        public static let lifespanAllowance = 79

        /// The rule. A known death before photography, or — with no death
        /// recorded — a birth so early the person could not plausibly have
        /// lived to see it, means no photograph can exist. Unknown dates
        /// never suppress anything: honesty means not guessing.
        public static func canHavePhotograph(birthYear: Int?, deathYear: Int?) -> Bool {
            if let deathYear { return deathYear >= year }
            if let birthYear { return birthYear + lifespanAllowance >= year }
            return true
        }

        public static func canHavePhotograph(person: GedcomFamilyGraph.Person) -> Bool {
            canHavePhotograph(birthYear: person.birthYear, deathYear: person.deathYear)
        }

        /// Why a photograph is impossible, for the log: "d. 1737" or
        /// "b. 1651". Nil when one is possible.
        public static func impossibilityNote(person: GedcomFamilyGraph.Person) -> String? {
            guard !canHavePhotograph(person: person) else { return nil }
            if let d = person.deathYear { return "d. \(d)" }
            if let b = person.birthYear { return "b. \(b)" }
            return nil
        }

        public enum Medium: Sendable { case photograph, film }

        /// The honest line for a direct "photo of X" / "videos of X" ask
        /// about a person who predates the medium. Deterministic; cites the
        /// spoken clause from the table rather than a number typed inline.
        public static func impossibilityLine(person: GedcomFamilyGraph.Person,
                                             medium: Medium) -> String? {
            guard !canHavePhotograph(person: person) else { return nil }
            let lived: String
            let anchorYear: Int
            if let d = person.deathYear {
                lived = "\(person.name) died in \(d)"; anchorYear = d
            } else if let b = person.birthYear {
                lived = "\(person.name) was born in \(b)"; anchorYear = b
            } else {
                return nil
            }
            let gap = year - anchorYear
            let distance: String
            switch gap {
            case 180...: distance = "nearly two centuries"
            case 80..<180: distance = "about a century"
            case 20..<80: distance = "decades"
            default: distance = "\(gap) year\(gap == 1 ? "" : "s")"
            }
            let possessive = person.sex == "M" ? "his" : person.sex == "F" ? "her" : "their"
            let clause = firstPersonInPhotograph.spokenClause
            switch medium {
            case .photograph:
                return "\(lived), \(distance) before \(clause) — there can\u{2019}t be a photograph. "
                    + "If the family has a painting, engraving, or gravestone photo, put it in \(possessive) People folder and I\u{2019}ll show it."
            case .film:
                let filmClause = WorldKnowledge.fact("film.firstMotionPictures")?.spokenClause
                    ?? "motion pictures come later still"
                return "\(lived), \(distance) before \(clause), and \(filmClause) — there can\u{2019}t be film of \(possessive == "their" ? "them" : possessive == "his" ? "him" : "her") either."
            }
        }
    }
}
