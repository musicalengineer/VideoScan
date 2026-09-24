import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// QA findings on the service-stories branch (2026-09-24), in an extension
/// of the same @Suite so a suite-level filter on HallieServiceStoriesTests
/// runs them (and the struct body stays under the lint length).
extension HallieServiceStoriesTests {

    // MARK: - QA findings (2026-09-24)

    /// P2-1: the 2026-09-23 family-wide shapes took any family word plus a
    /// bare "fight"/"served in the"/"navy" as a service ask — ahead of the
    /// person-fact and lineage lanes.
    @Test("a family word plus fight / served in / a branch word is not enough on its own")
    func familyAskNeedsAMilitaryNoun() {
        for question in [
            "who in the family fought cancer",
            "did anyone in the family fight cancer",
            "why did my grandparents fight so much",
            "who in the family served in the peace corps",
            "which relatives worked at the navy yard",
            "did anyone in the family fight with their siblings",
            "who in our family served in the church choir",
        ] {
            #expect(HallieServiceQuestion.familyAsk(question) == nil, "\(question)")
        }
        for question in [
            "who in the family served in the military",
            "did anyone fight in WWII",
            "who was in the navy",
            "did anyone in the family fight in the army",
            "who in our family fought with the marines",
            "did any of my relatives serve in the navy",
            "was anyone in the family drafted",
            "any veterans in the family",
        ] {
            #expect(HallieServiceQuestion.familyAsk(question) != nil, "\(question)")
        }
    }

    /// P2-2: the tradition's source line came from `sourceIDs.first`; with
    /// the teller listed first it named the teller as the tradition.
    @Test("a tradition's source line names the tradition's source whatever the order")
    func traditionSourceOrder() async throws {
        let context = try HallieTurnExecutor.Context(
            graph: Self.tree(),
            cyberBrain: Self.cyberBrain(josiahSources: ["source.rick", "source.lark-tradition"]),
            speakers: .init(ownerName: "Rick Example", archivistName: nil))
        let result = try await ask("did Josiah Lark serve", context: context)
        #expect(result.prose.contains("That's family tradition, from Barry Lark;"), "\(result.prose)")
        #expect(!result.prose.contains("from Rick Example"))
    }

    @Test("an engagement's article: 'the' before a battle, none before a bare place")
    func engagementArticles() {
        func line(_ names: [String]) -> String {
            HallieServiceStory.summaryLine(name: "Josiah Lark", record: CyberBrainServiceRecord(
                conflict: .civilWar, force: "Confederate States Army",
                engagements: names.map { .init(name: $0) }, combat: .yes, basis: .familyTradition))
        }
        #expect(line(["Fort Wagner"]).hasPrefix("Josiah Lark fought with the Confederate States Army at Fort Wagner ("))
        #expect(line(["Fort Wagner", "Gettysburg"]).hasPrefix("Josiah Lark fought with the Confederate States Army at Fort Wagner and Gettysburg ("))
        #expect(line(["Battle of Gettysburg"]).hasPrefix("Josiah Lark fought with the Confederate States Army at the Battle of Gettysburg ("))
        #expect(line(["First Battle of Fort Wagner", "Siege of Petersburg"]).hasPrefix(
            "Josiah Lark fought with the Confederate States Army at the First Battle of Fort Wagner and the Siege of Petersburg ("))
        #expect(line(["the Battle of the Crater"]).hasPrefix("Josiah Lark fought with the Confederate States Army at the Battle of the Crater ("))
    }

    @Test("with no family tree loaded, Hallie never says the tree records none")
    func noTreeNoTreeClaim() async throws {
        let context = try HallieTurnExecutor.Context(
            graph: nil, cyberBrain: Self.cyberBrain(),
            speakers: .init(ownerName: "Rick Example", archivistName: nil))
        let edna = try await ask("did Edna Example serve", context: context)
        #expect(edna.outcome == .declined)
        #expect(!edna.prose.contains("family tree"), "\(edna.prose)")
        #expect(!edna.basisLine.contains("family tree"), "\(edna.basisLine)")
        let coast = try await ask("did anyone in the family serve in the coast guard", context: context)
        #expect(coast.outcome == .declined)
        #expect(coast.prose.hasPrefix("Nobody in the family has told me about service in the Coast Guard."), "\(coast.prose)")
        #expect(!coast.prose.contains("family tree"), "\(coast.prose)")
        let none = try await ask("was anyone in the family in world war 1", context: context)
        #expect(!none.prose.contains("family tree"), "\(none.prose)")
        // With a tree, the tree WAS checked and says so.
        let withTree = try await ask("did Edna Example serve", context: try self.context())
        #expect(withTree.prose.contains("the family tree records none"), "\(withTree.prose)")
    }

    @Test("one story among several listed people: the offer names whose story")
    func offerNamesThePersonInAList() async throws {
        let tree = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @J@ INDI
        1 NAME Josiah /Lark/
        1 SEX M
        1 BIRT
        2 DATE 1840
        0 @C@ INDI
        1 NAME Caleb /Example/
        1 SEX M
        1 BIRT
        2 DATE 1835
        1 _MILT Private in Civil War
        0 TRLR

        """)
        let context = try HallieTurnExecutor.Context(
            graph: tree, cyberBrain: Self.cyberBrain(),
            speakers: .init(ownerName: "Rick Example", archivistName: nil))
        let result = try await ask("who in our family served in the civil war", context: context)
        #expect(result.prose.contains("Caleb Example"), "\(result.prose)")
        #expect(result.prose.hasSuffix("Would you like to hear Josiah Lark's story?"), "\(result.prose)")
        #expect(result.clarification?.candidates.map(\.id) == [.cyberBrainPersonID("person.josiah")])
    }
}
