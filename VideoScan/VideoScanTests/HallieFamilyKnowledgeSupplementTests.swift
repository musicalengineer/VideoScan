import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// Where the family tree falls short, Hallie says how far it reaches and
/// what the family told her — quoted and attributed (Rick, 2026-08-21:
/// "who are Rick's sons" must not end at "the tree doesn't record").
struct HallieFamilyKnowledgeSupplementTests {
    typealias Supplement = HallieTurnExecutor.FamilyKnowledgeSupplement

    private func graph() -> GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Richard Harding /Breen/ Jr
        1 SEX M
        1 BIRT
        2 DATE 4 Mar 1959
        1 FAMC @F1@
        0 @I2@ INDI
        1 NAME Richard Harding /Breen/ Sr
        1 SEX M
        1 BIRT
        2 DATE 1927
        1 FAMS @F1@
        0 @F1@ FAM
        1 HUSB @I2@
        1 CHIL @I1@
        0 TRLR
        """)
    }

    private func cyberBrain() throws -> CyberBrainIndex {
        let told = Date(timeIntervalSince1970: 1_787_300_000)
        let archive = CyberBrainArchive(
            archiveID: "breen-family", displayName: "Breen",
            people: [
                CyberBrainPerson(
                    id: "person.rick-breen", gedcomPersonID: "@I1@",
                    canonicalName: "Rick Breen", aliases: ["Dicky"],
                    biographyPassages: [
                        CyberBrainItem(
                            id: "bio.sons", kind: .biography,
                            text: "Rick and Donna have four adult sons: two work in software development, one is a therapy counselor, and one is a bartender.",
                            subjectPersonIDs: ["person.rick-breen"], sourceIDs: ["source.rick"],
                            confidence: .confirmed, privacy: .family,
                            createdAt: told, updatedAt: told),
                        CyberBrainItem(
                            id: "bio.career", kind: .biography,
                            text: "Rick is a retired software engineer.",
                            subjectPersonIDs: ["person.rick-breen"], sourceIDs: ["source.rick"],
                            confidence: .confirmed, privacy: .family,
                            createdAt: told, updatedAt: told),
                    ]),
            ],
            sources: [
                CyberBrainSource(id: "source.rick", type: .firstPerson,
                                 title: "Rick Breen project context", attribution: "Rick Breen"),
            ])
        return try CyberBrainIndex(archive: archive)
    }

    @Test func trailingYearReadsRawGedcomDatesHonestly() {
        #expect(Supplement.trailingYear("4 Mar 1959") == 1959)
        #expect(Supplement.trailingYear("ABT 1927") == 1927)
        #expect(Supplement.trailingYear("BET 1580 AND 1590") == 1590)
        #expect(Supplement.trailingYear("12 Jun") == nil)
        #expect(Supplement.trailingYear(nil) == nil)
        #expect(Supplement.latestBirthYear(in: graph()) == 1959)
    }

    /// Retired 2026-08-26: a max birth year is not the tree's reach
    /// (FamilySearch strips living people's dates), so no relation gets
    /// the "only goes up to people born in YYYY" note any more.
    @Test func coverageNoteIsNeverGeneratedFromAMaxBirthYear() {
        let tree = graph()
        #expect(Supplement.coverageNote(relation: .children, graph: tree) == nil)
        #expect(Supplement.coverageNote(relation: .parents, graph: tree) == nil)
        #expect(Supplement.coverageNote(relation: .children, graph: nil) == nil)
    }

    @Test func missingChildrenAreAnsweredFromWhatRickToldHer() throws {
        let tree = graph()
        let rick = try #require(tree.people["@I1@"])
        let graphResult = ArchivistGraphExecutor.executeSingleHop(
            .children, person: rick, graph: tree, identityBridge: nil)
        #expect(graphResult.conclusion == .missingFact)
        #expect(graphResult.prose == "The family tree doesn't record any children for Richard Harding Breen Jr. You can try another relationship or ask for the family tree.")

        let base = HallieTurnExecutor.Result(
            route: .graph, outcome: .declined, prose: graphResult.prose,
            basisLine: graphResult.basisLine, queryDescription: "shape=graph",
            citations: [], catalogPersonName: nil)
        let payload = ArchivistQueryAST.Graph(people: ["Rick"], operation: .kinship, relation: .children)
        let enriched = Supplement.apply(
            to: base, payload: payload, graphResult: graphResult, graph: tree,
            context: .init(graph: tree, cyberBrain: try cyberBrain()))

        #expect(enriched.outcome == .answered)
        #expect(enriched.prose == "The family tree doesn't record any children for Richard Harding Breen Jr. You can try another relationship or ask for the family tree. "
                + "But Rick Breen told me: “Rick and Donna have four adult sons: two work in software development, one is a therapy counselor, and one is a bartender.”")
        #expect(enriched.knowledgeCitations.map(\.id) == ["source.rick"])
        #expect(enriched.basisLine.contains("Family knowledge: bio.sons."))
        #expect(enriched.answerPlan?.shape == .fixed, "the composer must not re-phrase a quoted passage")
        #expect(enriched.answerPlan?.isComposable == false)
    }

    @Test func nothingIsAddedWhenTheFamilyHasNotSaid() throws {
        let tree = graph()
        let senior = try #require(tree.people["@I2@"])
        let graphResult = ArchivistGraphExecutor.executeSingleHop(
            .parents, person: senior, graph: tree, identityBridge: nil)
        let base = HallieTurnExecutor.Result(
            route: .graph, outcome: .declined, prose: graphResult.prose,
            basisLine: graphResult.basisLine, queryDescription: "shape=graph",
            citations: [], catalogPersonName: nil)
        let payload = ArchivistQueryAST.Graph(people: ["Richard Sr"], operation: .kinship, relation: .parents)
        let same = Supplement.apply(
            to: base, payload: payload, graphResult: graphResult, graph: tree,
            context: .init(graph: tree, cyberBrain: try cyberBrain()))
        #expect(same == base, "no coverage note for parents, no passage about them → untouched")
    }

    @Test func notFoundOffersTheTellingDoorWithoutAReachClaim() {
        let base = HallieTurnExecutor.Result(
            route: .graph, outcome: .declined,
            prose: "I don't find “matt” in the family tree.",
            basisLine: "Checked: GEDCOM", queryDescription: "shape=graph",
            citations: [], catalogPersonName: nil)
        let offered = Supplement.notFoundOffer(base, typed: "matt", graph: graph())
        #expect(offered.prose == "I don't find “matt” in the family tree. "
                + "If you tell me about Matt — “let me tell you about Matt” — I'll remember it.")
        #expect(offered.outcome == .declined)
    }
}
