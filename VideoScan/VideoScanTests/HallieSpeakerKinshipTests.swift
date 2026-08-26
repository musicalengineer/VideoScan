import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// "show me videos of my dad" must mean Rick's father, by name, from the
/// family tree — or decline by name (Rick 2026-08-21 eval: it came back as
/// "videos tagged with me").
struct HallieSpeakerKinshipTests {
    typealias Kin = HallieTurnExecutor.SpeakerKinship

    private func graph() -> GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Rick /Breen/
        1 SEX M
        1 FAMC @F1@
        1 FAMS @F2@
        0 @I2@ INDI
        1 NAME Richard Harding /Breen/ Sr
        1 SEX M
        1 FAMS @F1@
        0 @I3@ INDI
        1 NAME Donna /Breen/
        1 SEX F
        1 FAMS @F2@
        0 @I4@ INDI
        1 NAME Matt /Breen/
        1 SEX M
        1 FAMC @F2@
        0 @I5@ INDI
        1 NAME Tim /Breen/
        1 SEX M
        1 FAMC @F2@
        0 @F1@ FAM
        1 HUSB @I2@
        1 CHIL @I1@
        0 @F2@ FAM
        1 HUSB @I1@
        1 WIFE @I3@
        1 CHIL @I4@
        1 CHIL @I5@
        0 TRLR
        """)
    }

    private let rick = HallieTurnExecutor.Speakers(ownerName: "Rick Breen", archivistName: "Hallie Mae")

    @Test func myDadBecomesTheFatherFromTheTreeWhateverTheTranslatorDid() {
        for people in [["me"], ["my dad"], ["dad"], ["Rick Breen"], []] {
            let bound = Kin.rebind(people: people, question: "show me videos of my dad",
                                   speakers: rick, graph: graph())
            #expect(bound.failure == nil, Comment(rawValue: "\(people)"))
            #expect(bound.people == ["Richard Harding Breen Sr"], Comment(rawValue: "\(people)"))
            #expect(bound.notes == ["'my dad' = Richard Harding Breen Sr, father of Rick Breen in the family tree"])
        }
    }

    @Test func theOwnerIsFoundThroughTheCyberBrainAliasWhenTheTreeSpellsHimDifferently() throws {
        let tree = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Richard Harding /Breen/ Jr
        1 FAMC @F1@
        0 @I2@ INDI
        1 NAME Richard Harding /Breen/ Sr
        1 FAMS @F1@
        0 @F1@ FAM
        1 HUSB @I2@
        1 CHIL @I1@
        0 TRLR
        """)
        let index = try CyberBrainIndex(archive: CyberBrainArchive(
            archiveID: "x", displayName: "x",
            people: [CyberBrainPerson(id: "person.rick", gedcomPersonID: "@I1@",
                                      canonicalName: "Rick Breen", aliases: ["Dicky"])],
            sources: []))
        let bound = Kin.rebind(people: ["me"], question: "videos of my dad",
                               speakers: rick, graph: tree, cyberBrain: index)
        #expect(bound.failure == nil, Comment(rawValue: bound.failure ?? ""))
        #expect(bound.people == ["Richard Harding Breen Sr"])
        // Without the brain the shared owner chain (2026-08-26) still finds
        // him: "Rick Breen" ~ both Richards, the tree root (Jr) wins, and
        // the note says so.
        let withoutBrain = Kin.rebind(people: ["me"], question: "videos of my dad",
                                      speakers: rick, graph: tree)
        #expect(withoutBrain.failure == nil, Comment(rawValue: withoutBrain.failure ?? ""))
        #expect(withoutBrain.people == ["Richard Harding Breen Sr"])
        #expect(withoutBrain.notes.first?.contains("tree root") == true)
    }

    @Test func onTheGraphRouteMyDadIsTheFatherNotTheOwner() async throws {
        // Cycle 4: "did my dad have brothers or sisters" answered about
        // Rick (the owner) instead of Rick's father.
        let tree = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Rick /Breen/
        1 SEX M
        1 FAMC @F1@
        0 @I2@ INDI
        1 NAME Richard Harding /Breen/ Sr
        1 SEX M
        1 FAMC @F0@
        1 FAMS @F1@
        0 @I3@ INDI
        1 NAME Mary /Breen/
        1 SEX F
        1 FAMC @F0@
        0 @F0@ FAM
        1 CHIL @I2@
        1 CHIL @I3@
        0 @F1@ FAM
        1 HUSB @I2@
        1 CHIL @I1@
        0 TRLR
        """)
        let context = HallieTurnExecutor.Context(graph: tree, speakers: rick)
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "did my dad have brothers or sisters",
            ast: .graph(.init(people: ["me"], operation: .kinship, relation: .siblings)))
        let result = try await HallieTurnExecutor.execute(.init(intent: intent), context: context)
        #expect(result.outcome == .answered)
        #expect(result.prose == "Richard Harding Breen Sr's siblings: Mary Breen.", Comment(rawValue: result.prose))
        #expect(result.basisLine.contains("'my dad' = Richard Harding Breen Sr, father of Rick Breen in the family tree"))
    }

    @Test func myWifeAndOtherNamesStayInPlace() {
        let bound = Kin.rebind(people: ["Timmy", "me"], question: "Timmy with my wife at the cape",
                               speakers: rick, graph: graph())
        #expect(bound.people == ["Timmy", "Donna Breen"])
    }

    @Test func noKinshipPhraseMeansNoChange() {
        let bound = Kin.rebind(people: ["Donna"], question: "show me Donna at the Cape",
                               speakers: rick, graph: graph())
        #expect(bound == Kin.Rebinding(people: ["Donna"]))
        #expect(Kin.kinshipPhrase(in: "the dad jokes in that video") == nil)
    }

    @Test func declinesByNameWhenTheTreeCannotSay() {
        let noFather = Kin.rebind(people: ["me"], question: "videos of my mom",
                                  speakers: rick, graph: graph())
        #expect(noFather.failure == "The family tree doesn't list a mother for Rick Breen, so I can't work out who “my mom” is. If you tell me — “let me tell you about my mom” — I'll remember.")

        let twoSons = Kin.rebind(people: ["me"], question: "videos of my son",
                                 speakers: rick, graph: graph())
        #expect(twoSons.failure == "The family tree lists more than one son for Rick Breen: Matt Breen, Tim Breen. Which one do you mean?")

        let noOwner = Kin.rebind(people: ["me"], question: "videos of my dad",
                                 speakers: .none, graph: graph())
        #expect(noOwner.failure?.hasPrefix("I don't know who “my dad” is because no one has told me who is using the archive") == true)

        let noGraph = Kin.rebind(people: ["me"], question: "videos of my dad",
                                 speakers: rick, graph: nil)
        #expect(noGraph.failure?.contains("no family tree is loaded") == true)
    }
}
