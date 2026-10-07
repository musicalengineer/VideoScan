import Foundation
import Testing
@testable import VideoScan

@MainActor
@Suite("Graph executor decomposition contracts", .serialized)
struct ArchivistGraphCharacterizationTests {
    struct ProjectionCase: Sendable {
        let question: String
        let supplied: ArchivistQueryAST.Graph.Operation
        let expected: ArchivistGraphQuery.Operation
        let relation: ArchivistGraphQuery.Relation?
    }

    @Test(arguments: [
        ProjectionCase(question: "Where was Alex River born?", supplied: .death, expected: .birthPlace, relation: nil),
        ProjectionCase(question: "Where did Alex River die?", supplied: .birth, expected: .deathPlace, relation: nil),
        ProjectionCase(question: "Where did Alex River die after being born in France?", supplied: .birth, expected: .birth, relation: nil),
        ProjectionCase(question: "When was Alex River's father born?", supplied: .biography, expected: .biography, relation: nil),
        ProjectionCase(question: "Who was Alex River's father?", supplied: .biography, expected: .kinship, relation: .father),
        ProjectionCase(question: "Tell me about Alex River", supplied: .birth, expected: .biography, relation: nil),
        ProjectionCase(question: "Tell me about Alex River's death", supplied: .birth, expected: .birth, relation: nil),
        ProjectionCase(question: "A shared ancestor", supplied: .commonAncestor, expected: .relationship, relation: nil)
    ])
    func operationProjectionKeepsGuardPriorityAndWireFields(_ scenario: ProjectionCase) {
        let payload = ArchivistQueryAST.Graph(
            people: ["Alex River"], operation: scenario.supplied, side: .maternal, surname: "River")
        let query = ArchivistGraphQuery(payload, voices: [0: .owner], question: scenario.question)
        #expect(query == ArchivistGraphQuery(
            people: ["Alex River"], operation: scenario.expected, relation: scenario.relation,
            side: .maternal, surname: "River", voices: [0: .owner]))
    }

    private func seededResult(_ conclusion: ArchivistGraphConclusion = .answered) -> ArchivistGraphResult {
        let plan = HallieAnswerPlan(route: .graph, shape: .fact, subject: "Alex River",
            claims: [.init(id: "fact.birth", text: "Alex River was born in 1800.", evidenceIDs: ["@I1@"])],
            fallbackText: "Alex River was born in 1800.")
        return ArchivistGraphResult(
            conclusion: conclusion, prose: "Exact prose", basisLine: "Exact basis", evidence: nil,
            candidates: [], profileCandidates: ["Alex River"],
            ambiguityCandidates: [.init(id: .gedcomPersonID("@I1@"), canonicalName: "Alex River", label: "Alex (1800)")],
            catalogPersonName: "Al", familyTreeFocus: .person(name: "Alex River"), subjectIndex: 0,
            answerPlan: plan, possibleDuplicate: .init(personID: "@I2@", personName: "Another Alex"),
            subjectLifeStatus: .living, peopleTabProfileStableID: "synthetic-profile")
    }

    @Test func taggingChangesOnlyTheSelectedSlot() {
        let original = seededResult()
        let tagged = original.taggingSubject(1)
        #expect(tagged.subjectIndex == 1)
        #expect(tagged.taggingSubject(0) == original)
    }

    @Test(arguments: [ArchivistGraphConclusion.answered, .missingFact])
    func lifeStatusReachesBothResultAndPlanWithoutDroppingOtherFields(_ conclusion: ArchivistGraphConclusion) {
        let original = seededResult(conclusion)
        let changed = original.withSubjectLifeStatus(.deceased)
        #expect(changed.subjectLifeStatus == .deceased)
        #expect(changed.answerPlan?.subjectLifeStatus == .deceased)
        let plan = original.answerPlan!
        let expectedPlan = HallieAnswerPlan(route: plan.route, shape: plan.shape, subject: plan.subject,
            claims: plan.claims, counts: plan.counts, fallbackText: plan.fallbackText, subjectLifeStatus: .deceased)
        let expected = ArchivistGraphResult(
            conclusion: conclusion, prose: original.prose, basisLine: original.basisLine,
            evidence: original.evidence, candidates: original.candidates,
            profileCandidates: original.profileCandidates, ambiguityCandidates: original.ambiguityCandidates,
            catalogPersonName: original.catalogPersonName, familyTreeFocus: original.familyTreeFocus,
            subjectIndex: original.subjectIndex, answerPlan: expectedPlan, possibleDuplicate: original.possibleDuplicate,
            subjectLifeStatus: .deceased, peopleTabProfileStableID: original.peopleTabProfileStableID)
        #expect(changed == expected)
    }

    @Test func missingStatusAndDeclinesDoNotChangeTheResult() {
        let answered = seededResult()
        #expect(answered.withSubjectLifeStatus(nil) == answered)
        let declined = seededResult(.personNotFound)
        #expect(declined.withSubjectLifeStatus(.deceased) == declined)
    }
}
