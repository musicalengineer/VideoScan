import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// A wedding-date question is never answered with a birth date (cycle 6).
struct HallieMarriageDateTests {
    private let gedcom = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Richard Harding /Breen/ Jr
    1 SEX M
    1 BIRT
    2 DATE 4 Mar 1959
    1 FAMS @F1@
    0 @I2@ INDI
    1 NAME Donna Elaine /Hudson/
    1 SEX F
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Lonely /Breen/
    1 FAMS @F2@
    0 @F1@ FAM
    1 HUSB @I1@
    1 WIFE @I2@
    1 MARR
    2 DATE 14 Jun 1980
    0 @F2@ FAM
    1 HUSB @I3@
    0 TRLR
    """

    @Test func gedcomParsesMarriageDates() {
        let graph = GedcomFamilyGraph(gedcomText: gedcom)
        let rick = graph.people["@I1@"]!
        let marriages = graph.marriages(of: rick)
        #expect(marriages.count == 1)
        #expect(marriages.first?.date == "14 Jun 1980")
        #expect(marriages.first?.spouse?.name == "Donna Elaine Hudson")
        #expect(rick.birthDate == "4 Mar 1959", "birth parsing untouched")
        #expect(graph.marriages(of: graph.people["@I3@"]!).first?.date == nil)
    }

    @Test func recognisesWeddingDateQuestionsOnly() {
        for q in ["when did Rick get married", "When did they get married?", "what year was the wedding",
                  "when is Rick and Donna's anniversary", "how long ago did Rick marry Donna"] {
            #expect(HallieMarriageDate.isWeddingDateQuestion(q), Comment(rawValue: q))
        }
        for q in ["who did Rick marry", "when was Rick born", "is Rick married", "show me the wedding video"] {
            #expect(!HallieMarriageDate.isWeddingDateQuestion(q), Comment(rawValue: q))
        }
    }

    @Test func answersTheWeddingDateNeverTheBirthDate() async throws {
        let context = HallieTurnExecutor.Context(graph: GedcomFamilyGraph(gedcomText: gedcom))
        // The translator reached for .birth — exactly the cycle-5 failure.
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "when did Richard Harding Breen Jr get married",
            ast: .graph(.init(people: ["Richard Harding Breen Jr"], operation: .birth)))
        let result = try await HallieTurnExecutor.execute(.init(intent: intent), context: context)
        #expect(result.outcome == .answered)
        // House format (`HallieDateStyle`, 2026-09-03). Was "14 Jun 1980" —
        // the raw GEDCOM month, a third format in Hallie's answers.
        #expect(result.prose == "Richard Harding Breen Jr and Donna Elaine Hudson were married on 14 June 1980.")
        #expect(!result.prose.contains("1959"))
        #expect(result.answerPlan?.isComposable == false)
    }

    @Test func declinesHonestlyWhenTheTreeHasNoDate() async throws {
        let context = HallieTurnExecutor.Context(graph: GedcomFamilyGraph(gedcomText: gedcom))
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "when did Lonely Breen get married",
            ast: .graph(.init(people: ["Lonely Breen"], operation: .birth)))
        let result = try await HallieTurnExecutor.execute(.init(intent: intent), context: context)
        #expect(result.outcome == .declined)
        #expect(result.prose.hasPrefix("The family tree doesn't record a marriage for Lonely Breen."))
        #expect(!result.prose.contains("born"))
    }

    @Test func aBirthQuestionStillGetsTheBirthDate() async throws {
        let context = HallieTurnExecutor.Context(graph: GedcomFamilyGraph(gedcomText: gedcom))
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "when was Richard Harding Breen Jr born",
            ast: .graph(.init(people: ["Richard Harding Breen Jr"], operation: .birth)))
        let result = try await HallieTurnExecutor.execute(.init(intent: intent), context: context)
        #expect(result.prose.contains("1959"), Comment(rawValue: result.prose))
    }
}
