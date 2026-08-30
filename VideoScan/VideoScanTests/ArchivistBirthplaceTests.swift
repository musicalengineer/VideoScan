import Testing
import Foundation
@testable import VideoScan
import VideoScanCore

// MARK: - ArchivistBirthplaceTests
//
// Donna asked Hallie "where was Martha Lamson born?" on the web client
// (2026-08-30) and got nothing useful. The cause was not retrieval and not
// performance: the GEDCOM carries 44,469 PLAC lines, the parser reads them
// into Person.birthPlace, and the graph holds them in memory. But
//
//   * ArchivistQuestionParser had no `where` pattern at all, so the
//     question matched nothing and fell through before reaching an answer;
//   * ArchivistBiographyPolicy.biography() built its facts from birthDate
//     and deathDate only, so even "tell me about X" never mentioned a
//     place.
//
// Places were parsed, stored, and used to tell two same-named people
// apart — never to answer a question. These tests pin both halves.

struct ArchivistBirthplaceTests {

    // MARK: Fixture

    /// Martha with a birthplace, Silas with none, Mabel with placeholder
    /// junk of the kind the real export actually contains.
    private func graph() -> GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Martha /Lamson/
        1 SEX F
        1 BIRT
        2 DATE 12 MAY 1633
        2 PLAC Ipswich, Massachusetts
        1 DEAT
        2 DATE 3 JAN 1701
        2 PLAC Sudbury, Middlesex
        1 FAMS @F1@
        0 @I2@ INDI
        1 NAME Silas /Lamson/
        1 SEX M
        1 BIRT
        2 DATE 1630
        1 FAMS @F1@
        0 @I3@ INDI
        1 NAME Mabel /Lamson/
        1 SEX F
        1 BIRT
        2 PLAC xx
        0 @F1@ FAM
        1 HUSB @I2@
        1 WIFE @I1@
        1 MARR
        2 DATE 8 JUN 1650
        0 TRLR
        """)
    }

    private func person(_ id: String) -> GedcomFamilyGraph.Person {
        graph().people[id]!   // swiftlint:disable:this force_unwrapping
    }

    // MARK: 1. The parser — Donna's exact question

    @Test func donnasQuestionIsRecognised() {
        #expect(ArchivistQuestionParser.general("where was Martha Lamson born")
                == .lifePlace(personText: "Martha Lamson", birth: true))
    }

    @Test func theWhereFormsPeopleActuallyType() {
        let cases: [(String, Bool)] = [
            ("where was Martha Lamson born?", true),
            ("Where Was Martha Lamson Born", true),
            ("where did Martha Lamson die", false),
            ("where did Martha Lamson died", false),
            ("where is Martha Lamson buried", false),
        ]
        for (text, wantsBirth) in cases {
            #expect(ArchivistQuestionParser.general(text)
                    == .lifePlace(personText: "Martha Lamson", birth: wantsBirth),
                    Comment(rawValue: "did not parse: \(text)"))
        }
    }

    /// The `where` pattern must not swallow the `when` one.
    @Test func whenQuestionsStillRouteToTheDate() {
        #expect(ArchivistQuestionParser.general("when was Martha Lamson born")
                == .lifeDate(personText: "Martha Lamson", birth: true))
        #expect(ArchivistQuestionParser.general("tell me about Martha Lamson")
                == .biography(personText: "Martha Lamson"))
    }

    // MARK: 2. The answer

    @Test func aBirthplaceIsAnsweredWithItsDate() {
        let answer = ArchivistBiographyPolicy.lifePlace(
            personID: "@I1@", birth: true, in: graph())
        #expect(answer.state == .answered)
        #expect(answer.text == "Martha Lamson was born in Ipswich, Massachusetts, 12 MAY 1633.")
    }

    @Test func aPlaceOfDeathIsAnswered() {
        let answer = ArchivistBiographyPolicy.lifePlace(
            personID: "@I1@", birth: false, in: graph())
        #expect(answer.state == .answered)
        #expect(answer.text.contains("Sudbury, Middlesex") == true)
    }

    /// Absent is absent — say so rather than inventing or going silent.
    @Test func aMissingPlaceSaysSoRatherThanFailing() {
        let answer = ArchivistBiographyPolicy.lifePlace(
            personID: "@I2@", birth: true, in: graph())
        #expect(answer.state == .missingFact)
        #expect(answer.text == "The family tree doesn't record a birthplace for Silas Lamson.")
    }

    /// The real export contains literal "xx" as a place. Hallie must not
    /// read it aloud as though it were a town.
    @Test func placeholderJunkIsTreatedAsUnknown() {
        for junk in ["xx", "  ", "?", "unknown", "n/a", "-"] {
            #expect(ArchivistBiographyPolicy.cleanPlace(junk) == nil,
                    Comment(rawValue: "\(junk) should not be spoken as a place"))
        }
        #expect(ArchivistBiographyPolicy.cleanPlace("Ipswich, Massachusetts")
                == "Ipswich, Massachusetts")
        // NOT normalised — "England" and "Yorkshire, England" both stand as
        // recorded. Hallie says what the record says.
        #expect(ArchivistBiographyPolicy.cleanPlace("England") == "England")

        let answer = ArchivistBiographyPolicy.lifePlace(
            personID: "@I3@", birth: true, in: graph())
        #expect(answer.state == .missingFact,
                "a person whose only recorded place is the literal xx has no birthplace")
    }

    // MARK: 3. The biography now carries the vitals

    @Test func theBiographyStatesPlacesAndMarriageDates() {
        let answer = ArchivistBiographyPolicy.biography(
            personID: "@I1@", in: graph())
        let text = answer.text ?? ""
        #expect(text.contains("born 12 MAY 1633 in Ipswich, Massachusetts"),
                Comment(rawValue: text))
        #expect(text.contains("Sudbury, Middlesex"), Comment(rawValue: text))
        // Spouse names alone never said WHEN; Rick's vitals list includes
        // the marriage date.
        #expect(text.contains("8 JUN 1650"), Comment(rawValue: text))
    }

    /// A date with no place, and a place with no date, must each stand
    /// alone — the four combinations are where a naive format string
    /// produces "born  in " or a dangling comma.
    @Test func eachDatePlaceCombinationReadsCleanly() {
        let silas = ArchivistBiographyPolicy.biography(personID: "@I2@", in: graph()).text
        #expect(silas.contains("born 1630"), Comment(rawValue: silas))
        #expect(!silas.contains(" in ,"), Comment(rawValue: silas))
        #expect(!silas.contains("born  "), Comment(rawValue: silas))

        let mabel = ArchivistBiographyPolicy.biography(personID: "@I3@", in: graph()).text
        #expect(!mabel.contains("xx"), Comment(rawValue: mabel))
    }
}
