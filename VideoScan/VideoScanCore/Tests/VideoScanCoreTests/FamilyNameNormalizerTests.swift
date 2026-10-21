import Testing
import Foundation
@testable import VideoScanCore

/// FamilySearch's "Mc Gill" must never reach prose or speech as "Mic Gill"
/// (Rick 2026-08-26). Fused at the display/surname layer only.
struct FamilyNameNormalizerTests {
    @Test func spacedParticlesFuseInSurnames() {
        #expect(FamilyNameNormalizer.normalizeSurname("Mc Gill") == "McGill")
        #expect(FamilyNameNormalizer.normalizeSurname("Mac Donald") == "MacDonald")
        #expect(FamilyNameNormalizer.normalizeSurname("O' Brien") == "O'Brien")
        #expect(FamilyNameNormalizer.normalizeSurname("O’ Brien") == "O’Brien")
        #expect(FamilyNameNormalizer.normalizeSurname("Fitz Gerald") == "FitzGerald")
        #expect(FamilyNameNormalizer.normalizeSurname("McGill") == "McGill")
        #expect(FamilyNameNormalizer.normalizeSurname("Breen") == "Breen")
    }

    @Test func lowercaseParticlesAreLeftAlone() {
        for name in ["De Hendour", "de Hendour", "van Buren", "von Trapp", "ap Rhys", "ab Owen", "ferch Gruffudd", "Van Buren"] {
            #expect(FamilyNameNormalizer.normalizeSurname(name) == name, Comment(rawValue: name))
            #expect(FamilyNameNormalizer.normalizeName("John " + name) == "John " + name, Comment(rawValue: name))
        }
    }

    @Test func fullNamesFuseButALeadingMacIsAGivenName() {
        #expect(FamilyNameNormalizer.normalizeName("Ann Mc Gill") == "Ann McGill")
        #expect(FamilyNameNormalizer.normalizeName("John Mac Donald") == "John MacDonald")
        #expect(FamilyNameNormalizer.normalizeName("Mac Breen") == "Mac Breen")
        #expect(FamilyNameNormalizer.normalizeName("Mc Gill") == "McGill")
        #expect(FamilyNameNormalizer.normalizeName("Mary O' Brien Sullivan") == "Mary O'Brien Sullivan")
        // A particle before a lowercase or non-letter word is not fused.
        #expect(FamilyNameNormalizer.normalizeName("Mc gill") == "Mc gill")
        #expect(FamilyNameNormalizer.normalizeName("Mc 1") == "Mc 1")
        #expect(FamilyNameNormalizer.normalizeName("") == "")
        #expect(FamilyNameNormalizer.normalizeName("Mc") == "Mc")
    }

    static let sample = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Ann /Mc Gill/
    1 SEX F
    0 @I2@ INDI
    1 NAME John Mac /Donald/ Jr
    1 NAME Jack /Mac Donald/
    1 SEX M
    0 @I3@ INDI
    1 NAME Pierre /De Hendour/
    1 SEX M
    0 TRLR
    """

    @Test func gedcomDisplayAndSurnameAreFusedWhileLookupsAcceptEitherSpelling() {
        let graph = GedcomFamilyGraph(gedcomText: Self.sample)
        let ann = graph.people["@I1@"]
        #expect(ann?.name == "Ann McGill")
        #expect(ann?.surname == "McGill")
        #expect(graph.people(namedLike: "Ann McGill").map(\.id) == ["@I1@"])
        #expect(graph.people(namedLike: "Ann Mc Gill").map(\.id) == ["@I1@"])
        #expect(graph.people(namedLike: "McGill").map(\.id) == ["@I1@"])
        #expect(graph.people(withSurname: "the McGills").map(\.id) == ["@I1@"])
        #expect(graph.people(withSurname: "Mc Gill").map(\.id) == ["@I1@"])
        #expect(GedcomFamilyGraph.NameIndex(graph: graph).people(namedLike: "Mc Gill").map(\.id) == ["@I1@"])

        // A non-leading "Mac" just before the slash is half of the surname
        // (2026-10-21, see `particleBeforeTheSlash...` below). Until then
        // this pinned "John Mac Donald Jr" / "Donald" — a display that
        // `people(matching:)` could not find by typing it.
        let john = graph.people["@I2@"]
        #expect(john?.name == "John MacDonald Jr")
        #expect(john?.surname == "MacDonald")
        #expect(john?.alternateNames == ["Jack MacDonald"])
        // "Jack /Mac Donald/" now carries the same surname as the primary
        // record, so it is no longer a distinct alternate.
        #expect(john?.alternateSurnames == [])
        #expect(graph.people(matching: "John MacDonald Jr").map(\.id) == ["@I2@"])

        let pierre = graph.people["@I3@"]
        #expect(pierre?.name == "Pierre De Hendour")
        #expect(pierre?.surname == "De Hendour")
    }

    /// Nightly 2026-10-21 (M4, Release): FamilySearch writes some Norman
    /// names with the particle on the GIVEN side of the slash —
    /// "John Fitz /Roger/". The parser displayed "John Fitz Roger", but
    /// every lookup runs the typed text through `normalizeName`, which
    /// fuses it to "john fitzroger": the person could not be found by his
    /// own displayed name (and with a "John /Fitz Roger/" elsewhere in
    /// the tree, the lookup answered with that other record instead).
    /// The particle belongs to the surname wherever the slash sits.
    static let particleBeforeSlash = """
    0 HEAD
    0 @I1@ INDI
    1 NAME John Fitz /Roger/
    1 NAME John /Rogers/ II
    1 SEX M
    0 @I2@ INDI
    1 NAME John /FitzRoger/ Lord of Chewton
    1 NAME John /Fitz Roger/
    1 SEX M
    0 @I3@ INDI
    1 NAME William Fitz /Haute/
    1 SEX M
    0 @I4@ INDI
    1 NAME Richard fitz /Emeric/
    1 SEX M
    0 @I5@ INDI
    1 NAME Ann Mc /Gill/
    1 SEX F
    0 @I6@ INDI
    1 NAME Mac /Breen/
    1 SEX M
    0 @I7@ INDI
    1 NAME Eva Fitz /de Wyndon/
    1 SEX F
    0 TRLR
    """

    @Test func particleBeforeTheSlashFusesIntoTheSurnameSoTheDisplayedNameFindsThePerson() {
        let graph = GedcomFamilyGraph(gedcomText: Self.particleBeforeSlash)
        #expect(graph.people["@I1@"]?.name == "John FitzRoger")
        #expect(graph.people["@I1@"]?.surname == "FitzRoger")
        #expect(graph.people["@I3@"]?.name == "William FitzHaute")
        #expect(graph.people["@I3@"]?.surname == "FitzHaute")
        #expect(graph.people["@I4@"]?.name == "Richard fitzEmeric")
        #expect(graph.people["@I5@"]?.name == "Ann McGill")
        #expect(graph.people["@I5@"]?.surname == "McGill")
        // A leading "Mac" is a given name; a particle before a lowercase
        // surname word is left alone (same rules as FamilyNameNormalizer).
        #expect(graph.people["@I6@"]?.name == "Mac Breen")
        #expect(graph.people["@I6@"]?.surname == "Breen")
        #expect(graph.people["@I7@"]?.name == "Eva Fitz de Wyndon")
        #expect(graph.people["@I7@"]?.surname == "de Wyndon")

        // The invariant: every displayed name is a fixed point of the
        // normalizer every lookup applies, and finds its own person.
        for person in graph.people.values {
            #expect(FamilyNameNormalizer.normalizeName(person.name) == person.name, Comment(rawValue: person.name))
            #expect(graph.people(matching: person.name).contains { $0.id == person.id }, Comment(rawValue: person.name))
            #expect(graph.people(namedLike: person.name).contains { $0.id == person.id }, Comment(rawValue: person.name))
        }
        // Both spellings of the same Norman name reach both records.
        #expect(graph.people(matching: "John Fitz Roger").map(\.id).sorted() == ["@I1@", "@I2@"])
        #expect(graph.people(withSurname: "FitzRoger").map(\.id).sorted() == ["@I1@", "@I2@"])
    }

    /// The merge writer must round-trip the fused surname: "John Fitz
    /// /Roger/" → display "John FitzRoger", surname "FitzRoger" → written
    /// "John /FitzRoger/" → parsed back identically.
    @Test func fusedParticleSurnameSurvivesTheWriterRoundTrip() throws {
        #expect(GedcomFamilyGraph.gedcomName("John FitzRoger", surnames: ["FitzRoger"]) == "John /FitzRoger/")
        let graph = GedcomFamilyGraph(gedcomText: Self.particleBeforeSlash)
        let person = try #require(graph.people["@I1@"])
        let surname = try #require(person.surname)
        let again = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME \(GedcomFamilyGraph.gedcomName(person.name, surnames: [surname]))
        0 TRLR
        """)
        #expect(again.people["@I1@"]?.name == person.name)
        #expect(again.people["@I1@"]?.surname == person.surname)
    }
}
