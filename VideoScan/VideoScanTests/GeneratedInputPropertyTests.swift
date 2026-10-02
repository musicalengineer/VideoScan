// GeneratedInputPropertyTests.swift
// Generated-input properties for the APP-target readers (Rick approved
// 2026-10-01); the Core readers are swept in VideoScanCoreTests/
// *PropertyTests.swift with the same harness (PropertyTestingSupport.swift).
//
//   A1  FamilyTreeBirthCountries — the flag on a person card. A US place
//       that shares a British-Isles name always flies the US flag; English /
//       Scottish / Welsh / Irish / Northern Irish places fly their own; "New
//       South Wales" never flies the Welsh flag.
//   A2  ResearchRecordHints — a record with no surname (a lone given name,
//       or GEDCOM's explicit empty surname "Mary Ellen //") never sends a
//       given name to the census as a family name (QA P3-11's rule).
//   A3  HallieAncestorStatisticsQuestion — paraphrases carrying a
//       constraint the recognizer cannot hold ("first ancestor TO <verb>",
//       "on the <surname> line", "who <verb>…") ABSTAIN; the same sentence
//       without the constraint is recognized (the control that keeps the
//       abstention from being vacuous).
//
// Synthetic only: invented given names and surnames, real place names.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Places (a compact copy of the Core generator's vocabulary)

enum AppPlaceGenerator {
    struct Place: CustomStringConvertible {
        let text: String
        let want: FamilyMap.Country?
        /// True for the New South Wales cases: the only rule is "not Wales".
        let notWales: Bool
        var description: String { text.debugDescription }
    }

    static let us: [(String, String, String)] = [
        ("Boston", "Suffolk", "Massachusetts"), ("Salem", "Essex", "MA"), ("Wales", "Hampden", "Mass."),
        ("Derry", "Rockingham", "New Hampshire"), ("Antrim", "Hillsborough", "N.H."), ("Londonderry", "Rockingham", "NH"),
        ("Kent", "Litchfield", "Connecticut"), ("Scotland", "Windham", "CT"), ("Belfast", "Waldo", "Maine"),
        ("Limerick", "York", "ME"), ("Dover", "Kent", "Delaware"), ("Glasgow", "Barren", "Ky."),
        ("Ireland", "Dubois", "Indiana"), ("England", "Lonoke", "Arkansas"), ("Dublin", "Franklin", "Ohio"),
        ("Plymouth", "Plymouth", "Massachusetts"), ("Durham", "Strafford", "N.H."), ("York", "York", "Pennsylvania"),
    ]
    static let isles: [(String, String, String, FamilyMap.Country)] = [
        ("Ipswich", "Suffolk", "England", .england), ("Norwich", "Norfolk", "England", .england),
        ("Leeds", "Yorkshire", "England", .england), ("Glasgow", "Lanarkshire", "Scotland", .scotland),
        ("Perth", "Perthshire", "Scotland", .scotland), ("Cardiff", "Glamorgan", "Wales", .wales),
        ("Cork", "County Cork", "Ireland", .ireland), ("Ballina", "Co. Mayo", "Ireland", .ireland),
        ("Belfast", "Antrim", "Northern Ireland", .northernIreland), ("Derry", "Londonderry", "Ireland", .northernIreland),
    ]

    static func place(_ g: inout SeededGenerator) -> Place {
        let sep = g.pick([", ", ",", " , "])
        switch g.int(0...9) {
        case 0...4:
            let (town, county, state) = g.pick(us)
            let country = g.pick(["", "USA", "United States", "U.S.A."])
            let parts = [g.chance(0.8) ? town : "", g.chance(0.5) ? county + " County" : county, state, country]
            return Place(text: parts.filter { !$0.isEmpty }.joined(separator: sep), want: .unitedStates, notWales: false)
        case 5...8:
            let (town, county, country, want) = g.pick(isles)
            let tail = g.chance(0.3) && want != .ireland ? [country, "United Kingdom"] : [country]
            return Place(text: ([g.chance(0.7) ? town : "", county] + tail).filter { !$0.isEmpty }.joined(separator: sep),
                         want: want, notWales: false)
        default:
            let town = g.pick(["Sydney", "Newcastle", "Bathurst", "Goulburn"])
            let parts = [g.chance(0.8) ? town : "", "New South Wales", g.chance(0.5) ? "Australia" : ""]
            return Place(text: parts.filter { !$0.isEmpty }.joined(separator: sep), want: nil, notWales: true)
        }
    }
}

// MARK: - A1 · the person-card flag

@Suite("FamilyTreeBirthCountries — generated places")
struct FamilyTreeBirthCountriesPropertyTests {

    @Test("A1: the card flag is the place's own country; New South Wales is never Wales",
          arguments: Property.batches)
    func flagIsTheRightCountry(batch: Int) {
        Property.check("birth-flag", batch: batch, generate: AppPlaceGenerator.place) { place in
            let built = FamilyTreeBirthCountries.build(ids: ["@I1@"], treePlaces: [place.text])
            let flag = built["@I1@"]?.country
            if place.notWales { return flag == .wales ? "flag = Wales" : nil }
            return flag == place.want ? nil : "flag = \(flag.map { "\($0)" } ?? "none"), want \(place.want.map { "\($0)" } ?? "none")"
        }
    }
}

// MARK: - A2 · given names are never surnames

@Suite("ResearchRecordHints — generated given-name-only records")
struct ResearchHintsSurnamePropertyTests {

    static let givens = ["Bridget", "Honora", "Ellen", "Ann", "Cornelius", "Thomasina", "Ansel", "Mary"]

    /// The record as the tree gives it, through the real parser.
    static func hints(nameLine: String) -> ResearchRecordHints? {
        let ged = "0 HEAD\n0 @I1@ INDI\n1 NAME \(nameLine)\n1 BIRT\n2 DATE 1880\n2 PLAC Cork, Ireland\n0 TRLR\n"
        guard let person = GedcomFamilyGraph(gedcomText: ged).people["@I1@"] else { return nil }
        return ResearchRecordHints(subject: ResearchSubject(person: person))
    }

    @Test("A2: a record with no surname never sends a given name as the family name",
          arguments: Property.batches)
    func givenNameNeverSurname(batch: Int) {
        Property.check("hints-no-surname", batch: batch, cases: 250, generate: { g -> String in
            let given = (0..<g.int(1...3)).map { _ in g.pick(Self.givens) }.joined(separator: " ")
            // One given name alone, or any given names with GEDCOM's
            // explicit empty surname ("//", "/ /").
            if !given.contains(" "), g.chance(0.4) { return given }
            return given + " " + g.pick(["//", "/ /", "/  /"])
        }, describe: { "1 NAME \($0)" }) { nameLine in
            guard let hints = Self.hints(nameLine: nameLine) else { return "no person parsed" }
            return hints.surnames.isEmpty ? nil : "surnames sent: \(hints.surnames)"
        }
    }
}

// MARK: - A3 · Hallie abstains on constraints it cannot hold

/// One paraphrase: the sentence without the constraint (must be
/// recognized) and with it (must abstain).
struct HallieParaphrase: CustomStringConvertible {
    let control: String
    let constrained: String
    var description: String { "control \(control.debugDescription) / constrained \(constrained.debugDescription)" }
}

/// The constraint shapes. Each runs as its own test case, so one
/// shape's bug cannot hide another's verdict.
enum HallieShape: String, CaseIterable, CustomTestStringConvertible {
    case earliestToVerb, earliestOnSurnameLine, deepestSurnameLine
    case ageAtDeathOnSurnameSide, ageAtDeathWhoVerbed
    case birthplacesOnSurnameLine, birthplacesWhoVerbed
    // Adversarial review 2026-10-01: cce4ea0e, 784f0da7, 1a73b432.
    case ageAtDeathDiedOrPlace, birthplacesReducedOrPlace, longSurnameScope
    var testDescription: String { rawValue }
}

enum HallieParaphraseGenerator {
    static let surnames = ["quillfeather", "larkspur", "fenlane", "polwenna", "testerly", "glendarroch", "marrowby"]
    static let verbs = ["fight in a war", "serve in the army", "own land", "go to college", "vote", "learn to read",
                        "become a citizen", "work in a mill", "buy a farm", "marry", "die in a war", "join the navy",
                        "leave a will", "graduate", "run a business", "own a car", "keep a diary"]
    static let pastVerbs = ["fought in a war", "served in the army", "owned land", "went to college", "voted",
                            "became citizens", "worked in a mill", "bought a farm", "joined the navy", "left a will"]
    static let places = ["ireland", "england", "scotland", "wales", "new england", "canada", "france"]
    /// Places a constraint names (any word: the recognizer must abstain
    /// whether or not it knows the place).
    static let filterPlaces = ["ohio", "ireland", "boston", "county cork", "the old country", "kent"]
    /// Surnames of three words, with a period, or with non-ASCII letters.
    static let longSurnames = ["van der quill", "de la fenlane", "st. larkspur", "müllerby", "ó testerly",
                               "mac an polwenna", "o'glendarroch", "saint-marrowby"]

    static func lineWord(_ g: inout SeededGenerator) -> String { g.pick(["line", "side", "branch", "family"]) }

    static func paraphrase(_ shape: HallieShape, _ g: inout SeededGenerator) -> HallieParaphrase {
        let whose = g.pick(["our", "my"])
        let surname = g.pick(surnames)
        let pair: (String, String)
        switch shape {
        case .earliestToVerb:
            let lead = g.pick(["who is", "who was", "who's", "tell me", "name"])
            let rank = g.pick(["earliest", "first", "oldest known"])
            let base = "\(lead) \(whose) \(rank) ancestor"
            pair = (base, "\(base) to \(g.pick(verbs))")
        case .earliestOnSurnameLine:
            pair = ("who is the earliest ancestor in \(whose) family tree",
                    "who is the earliest ancestor \(g.pick(["on", "of", "in"])) the \(surname) \(lineWord(&g))")
        case .deepestSurnameLine:
            pair = ("how many generations back does \(whose) tree go",
                    "how many generations back does the \(surname) \(lineWord(&g)) go")
        case .ageAtDeathOnSurnameSide:
            let base = "what was the average age at death of \(whose) ancestors"
            pair = (base, "\(base) \(g.pick(["on", "in"])) the \(surname) \(lineWord(&g))")
        case .ageAtDeathWhoVerbed:
            let base = "what was the average age at death of \(whose) ancestors"
            pair = (base, "\(base) who \(g.pick(pastVerbs))")
        case .birthplacesOnSurnameLine:
            let place = g.pick(places)
            pair = ("how many of \(whose) ancestors were born in \(place)",
                    "how many of \(whose) ancestors \(g.pick(["on", "in"])) the \(surname) \(lineWord(&g)) were born in \(place)")
        case .birthplacesWhoVerbed:
            let place = g.pick(places)
            pair = ("how many of \(whose) ancestors were born in \(place)",
                    "how many of \(whose) ancestors who \(g.pick(pastVerbs)) were born in \(place)")
        case .ageAtDeathDiedOrPlace:
            let base = "what was the average age at death of \(whose) ancestors"
            let filter = g.pick(filterPlaces)
            let constraint = g.pick(["who died in \(filter)", "who died young", "who died before the war",
                                     "in \(filter)", "buried in \(filter)", "from \(filter)"])
            pair = (base, "\(base) \(constraint)")
        case .birthplacesReducedOrPlace:
            let place = g.pick(places)
            let filter = g.pick(filterPlaces)
            let constraint = g.pick(["buried in \(filter)", "in \(filter)", "from \(filter)",
                                     "baptized in \(filter)", "who died in \(filter)"])
            pair = ("how many of \(whose) ancestors were born in \(place)",
                    "how many of \(whose) ancestors \(constraint) were born in \(place)")
        case .longSurnameScope:
            let name = g.pick(longSurnames)
            let line = lineWord(&g)
            switch g.int(0...3) {
            case 0:
                pair = ("how many generations back does \(whose) tree go",
                        "how many generations back does the \(name) \(line) go")
            case 1:
                pair = ("who is the earliest ancestor in \(whose) family tree",
                        "who is the earliest ancestor on the \(name) \(line)")
            case 2:
                let base = "what was the average age at death of \(whose) ancestors"
                pair = (base, "\(base) on the \(name) \(line)")
            default:
                let place = g.pick(places)
                pair = ("how many of \(whose) ancestors were born in \(place)",
                        "how many of \(whose) ancestors on the \(name) \(line) were born in \(place)")
            }
        }
        // Surface variety: a capital, a question mark, all caps.
        func surface(_ s: String, _ g: inout SeededGenerator) -> String {
            var t = s
            if g.chance(0.5) { t = t.prefix(1).uppercased() + t.dropFirst() }
            if g.chance(0.6) { t += "?" }
            if g.chance(0.1) { t = t.uppercased() }
            return t
        }
        return HallieParaphrase(control: surface(pair.0, &g), constrained: surface(pair.1, &g))
    }
}

// The recognizer is regex-heavy (~3 ms a question in Debug), so each shape
// gets 8 × 30 = 240 paraphrases (1,680 per property) to stay near 5 s.
@Suite("HallieAncestorStatisticsQuestion — generated paraphrases")
struct HallieAncestorRoutingPropertyTests {

    @Test("A3 control: the unconstrained sentence is recognized", arguments: HallieShape.allCases, Property.batches)
    func controlIsRecognized(shape: HallieShape, batch: Int) {
        Property.check("hallie-control/\(shape)", batch: batch, cases: 30,
                       generate: { HallieParaphraseGenerator.paraphrase(shape, &$0) }) { p in
            HallieAncestorStatisticsQuestion.detect(p.control) == nil ? "control abstained: \(p.control)" : nil
        }
    }

    @Test("A3: a constraint the recognizer cannot hold makes it abstain", arguments: HallieShape.allCases, Property.batches)
    func constrainedAbstains(shape: HallieShape, batch: Int) {
        Property.check("hallie-constrained/\(shape)", batch: batch, cases: 30,
                       generate: { HallieParaphraseGenerator.paraphrase(shape, &$0) }) { p in
            guard let got = HallieAncestorStatisticsQuestion.detect(p.constrained) else { return nil }
            return "recognized \(p.constrained.debugDescription) as \(got)"
        }
    }
}

// MARK: - Pins for what the app-side sweeps found (2026-10-01)

// RED until fixed; each then stays as a sensor. Seeds replay with
// `SeededGenerator(seed:)` and the generator named in the property.
@Suite("Found by generated inputs — app (2026-10-01)")
struct GeneratedInputAppFindingsTests {

    // AF1 — the card flag: "New South Wales" flies the Welsh flag (the
    // resolver's half of Core finding F3). Seed 0x68f9f02abd92f6a9.
    @Test("AF1: New South Wales never flies the Welsh flag", arguments: ["Sydney, New South Wales", "New South Wales"])
    func newSouthWalesFlag(place: String) {
        let built = FamilyTreeBirthCountries.build(ids: ["@I1@"], treePlaces: [place])
        #expect(built["@I1@"]?.country != .wales)
    }

    // AF2 — Research hints: GEDCOM's EXPLICIT empty surname ("Ann
    // Thomasina //") reaches ResearchRecordHints as "no surname", and the
    // last-token fallback then sends the last GIVEN name — plus its clerk
    // variants ("Ann" → "An", "Mary" → "Marey") — to the census as the
    // family name. ResearchRecordSources.swift:79-80; the distinction is
    // lost in GedcomFamilyGraph.parseName (GedcomFamilyGraph.swift:1129).
    @Test("AF2: an explicit empty surname sends no surname", arguments: [
        "Ann Thomasina //",      // seed 0x76ae104762261cda → ["Thomasina"]
        "Thomasina Ann / /",     // seed 0xca0865059a0591b1 → ["Ann", "An"]
        "Honora Mary / /",       // seed 0x32ae28be3bbec7d4 → ["Mary", "Marey"]
    ])
    func explicitEmptySurname(nameLine: String) {
        #expect(ResearchHintsSurnamePropertyTests.hints(nameLine: nameLine)?.surnames == [])
    }

    // AF3 — Hallie: the age-at-death and birthplace shapes answer as
    // "ours" while ignoring a family-line scope or a relative clause the
    // recognizer cannot hold (the earliest / deepest shapes abstain).
    // HallieAncestorStatisticsQuestion.swift:147-156 (ageAtDeath) and
    // :160-184 (birthplaces) — no `unreadFamilyScope` / "who <verb>" guard.
    // And the earliest shape reads "of the polwenna BRANCH" as a PERSON
    // named "Polwenna Branch" (`who(in:)` → HallieLineageQuestion.personScope
    // before `unreadFamilyScope` is consulted; "line" / "side" / "family"
    // are caught, "branch" after "of" is not).
    @Test("AF3: Hallie abstains on a line scope or a relative clause", arguments: [
        "who is the earliest ancestor of the polwenna branch",                     // seed 0x6353356bb5048064
        "how many of my ancestors on the fenlane side were born in scotland",      // seed 0x652971e81eb5eae
        "how many of our ancestors on the testerly branch were born in france",    // seed 0xd4fedf850e108611
        "how many of my ancestors who voted were born in france",                  // seed 0x235098ef030e84b4
        "what was the average age at death of my ancestors on the marrowby line",  // seed 0xe8a8a7c1b220707d
        "what was the average age at death of our ancestors who fought in a war",  // seed 0xc4b2a6e9fd656dc6
    ])
    func hallieAbstains(question: String) {
        #expect(HallieAncestorStatisticsQuestion.detect(question) == nil)
    }
}
