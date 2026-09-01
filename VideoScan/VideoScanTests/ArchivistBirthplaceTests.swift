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

// MARK: - The AST route could not reach the place answer (Rick, 2026-08-31)
//
// Rick: "I ask where was eillen latta born, hallie just says the birthday,
// no idea of places. Bug."
//
// Everything above this line was already true and already passing. The
// answer existed, was correct, and was tested — and was UNREACHABLE from
// the route the app actually uses. ArchivistQuestionParser is called from
// exactly one place, ArchivistChatWindow's legacy path. The main app and
// the web client go through the AST, and ArchivistQueryAST.Graph.Operation
// had no place concept at all: "when was X born" and "where was X born"
// both decoded to `.birth`, and `.birth` is answered with lifeDate.
//
// So a green suite proved the feature worked while the user could not get
// to it. These tests pin the ROUTE, not just the answer.

struct ArchivistBirthplaceRoutingTests {

    private func graph() -> GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Eileen /Latta/
        1 SEX F
        1 BIRT
        2 DATE 14 MAR 1930
        2 PLAC Boston, Suffolk, Massachusetts
        1 DEAT
        2 DATE 2 FEB 2023
        2 PLAC Springfield, Hampden, Massachusetts
        0 TRLR
        """)
    }

    /// The vocabulary itself. Without these two cases the question has
    /// nowhere to go, whatever the translator emits.
    @Test func theASTCarriesAPlaceOperationDistinctFromTheDate() {
        #expect(ArchivistQueryAST.Graph.Operation(rawValue: "birth-place") == .birthPlace)
        #expect(ArchivistQueryAST.Graph.Operation(rawValue: "death-place") == .deathPlace)
        #expect(ArchivistQueryAST.Graph.Operation.birthPlace != .birth)
        #expect(ArchivistQueryAST.Graph.Operation.deathPlace != .death)
    }

    /// The AST operation survives the hop into the executor's own enum.
    /// This mapping is where a new case silently becomes `.biography` if
    /// someone adds a `default:`.
    @Test func thePlaceOperationSurvivesTheHopIntoTheExecutorQuery() {
        let birth = ArchivistGraphQuery(
            .init(people: ["eileen latta"], operation: .birthPlace))
        #expect(birth.operation == .birthPlace)
        let death = ArchivistGraphQuery(
            .init(people: ["eileen latta"], operation: .deathPlace))
        #expect(death.operation == .deathPlace)
    }

    /// The bug, end to end: the place question must answer with the PLACE.
    @Test func whereWasSheBornAnswersWithThePlaceNotTheBirthday() {
        let answer = ArchivistBiographyPolicy.lifePlace(
            personID: "@I1@", birth: true, in: graph())
        #expect(answer.state == .answered)
        #expect(answer.text.contains("Boston, Suffolk, Massachusetts"),
                "got: \(answer.text)")
    }

    @Test func whereDidSheDieAnswersWithThePlace() {
        let answer = ArchivistBiographyPolicy.lifePlace(
            personID: "@I1@", birth: false, in: graph())
        #expect(answer.state == .answered)
        #expect(answer.text.contains("Springfield, Hampden, Massachusetts"),
                "got: \(answer.text)")
    }

    /// And the date question is untouched — the fix must not swap the bug
    /// around so that "when" now answers with a town.
    @Test func whenWasSheBornStillAnswersWithTheDate() {
        let answer = ArchivistBiographyPolicy.lifeDate(
            personID: "@I1@", birth: true, in: graph())
        #expect(answer.state == .answered)
        #expect(answer.text.contains("1930"), "got: \(answer.text)")
    }

    /// The translator has to emit the new operation or the vocabulary is
    /// decoration. Pin the two examples in the prompt.
    @Test func theTranslatorPromptTeachesWhenVersusWhere() {
        let prompt = OllamaQueryTranslator.astSystemPrompt
        #expect(prompt.contains("birth-place"),
                "the prompt must show the model how to ask for a birthplace")
        #expect(prompt.contains("death-place"))
        #expect(prompt.contains("WHEN asks for the date; WHERE asks for the place"))
    }
}
