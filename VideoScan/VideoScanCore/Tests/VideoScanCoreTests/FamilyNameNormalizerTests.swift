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

        // The surname between slashes is the only place "Mac" is fused when leading.
        let john = graph.people["@I2@"]
        #expect(john?.name == "John Mac Donald Jr")
        #expect(john?.surname == "Donald")
        #expect(john?.alternateNames == ["Jack MacDonald"])
        #expect(john?.alternateSurnames == ["MacDonald"])

        let pierre = graph.people["@I3@"]
        #expect(pierre?.name == "Pierre De Hendour")
        #expect(pierre?.surname == "De Hendour")
    }
}
