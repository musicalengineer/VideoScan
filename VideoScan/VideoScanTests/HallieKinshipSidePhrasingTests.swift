// HallieKinshipSidePhrasingTests.swift
// Sensors for three live declines on 2026-08-26 (main b03d0b50):
//   1. "tell me about Rick Breen's great great grandpa on his paternal side"
//      → "I don't find “About Rick Breen's Great Great Grandpa On His” …"
//      (the lineage line regex ate "paternal side"; the possessor kept the
//      lead words).
//   2. "Tell me about rick's grandfather" → People-tab decline with "the
//      tree only goes up to people born in 1959, so Rick isn't in it yet"
//      (Rick IS in it as "Richard Harding /Breen/ Jr", undated — the
//      profile→graph bridge could not follow the diminutive).
//   3. "tell me about the family tree from rick breen all the way back to
//      1600" → "I don't find “rick breen” … covers people born up to 1959".
// FamilySearch-style fixture: home person first, Jr/Sr suffixes, middle
// names, NO birth date on the living owner.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let familySearchTree = """
0 HEAD
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 FAMC @F1@
1 FAMS @F5@
0 @I2@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 BIRT
2 DATE 12 MAR 1931
1 FAMC @F2@
1 FAMS @F1@
0 @I3@ INDI
1 NAME George /Breen/
1 SEX M
1 BIRT
2 DATE 1898
1 FAMC @F3@
1 FAMS @F2@
0 @I4@ INDI
1 NAME Patrick /Breen/
1 SEX M
1 BIRT
2 DATE 1870
1 FAMC @F4@
1 FAMS @F3@
0 @I5@ INDI
1 NAME John /Breen/
1 SEX M
1 BIRT
2 DATE 1850
2 PLAC Cork, Ireland
1 DEAT
2 DATE 1921
1 FAMS @F4@
0 @I6@ INDI
1 NAME Muriel /Lamb/
1 SEX F
1 FAMS @F2@
0 @I7@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 FAMC @F6@
1 FAMS @F5@
0 @I8@ INDI
1 NAME Elaine /Bowser/
1 SEX F
1 FAMC @F7@
1 FAMS @F6@
0 @I9@ INDI
1 NAME Ann /Smith/
1 SEX F
1 FAMS @F7@
0 @I10@ INDI
1 NAME Edith Lucy /Parker/
1 SEX F
1 BIRT
2 DATE 1875
0 @F1@ FAM
1 HUSB @I2@
1 WIFE @I6@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I3@
1 CHIL @I2@
0 @F3@ FAM
1 HUSB @I4@
1 CHIL @I3@
0 @F4@ FAM
1 HUSB @I5@
1 CHIL @I4@
0 @F5@ FAM
1 HUSB @I1@
1 WIFE @I7@
0 @F6@ FAM
1 WIFE @I8@
1 CHIL @I7@
0 @F7@ FAM
1 WIFE @I9@
1 CHIL @I8@
0 TRLR
"""

@Suite("Hallie — kinship phrases with a side, owner chain, no year heuristic", .serialized)
struct HallieKinshipSidePhrasingTests {
    typealias Q = HallieLineageQuestion
    typealias Exec = HallieTurnExecutor

    private let graph = GedcomFamilyGraph(gedcomText: familySearchTree)
    private let rickProfile = Exec.ProfileSnapshot(
        stableID: "rick", canonicalName: "Rick", aliases: ["Dicky", "Dad"])

    private var context: Exec.Context {
        Exec.Context(profiles: [rickProfile], graph: graph,
                     speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae",
                                     archivistPersonName: nil))
    }

    /// The model-free front door: what the executor is handed for a question.
    private func pre(_ question: String) -> Exec.PreTranslation {
        Exec.preTranslation(
            question: question, playAfterAnswer: false, memory: .init(),
            isKnownPerson: { _ in false },
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context) })
    }

    private func run(_ question: String) async throws -> Exec.Result {
        switch pre(question) {
        case .run(let intent):
            return try await Exec.execute(.init(intent: intent), context: context)
        case .answer(let result):
            return result
        case .translate:
            Issue.record("“\(question)” went to the model translator")
            throw CancellationError()
        }
    }

    // MARK: Live case 1 — great great grandpa on his paternal side

    @Test func theLiveUtteranceIsAKinshipQuestionNotAName() {
        #expect(Q.detect("tell me about Rick Breen's great great grandpa on his paternal side")
                == .kinship(person: "Rick Breen", relation: .greatGreatGrandfather, side: .paternal))
        #expect(Q.detect("who was Donna's maternal grandmother")
                == .kinship(person: "Donna", relation: .grandmother, side: .maternal))
        #expect(Q.detect("my great grandpa")
                == .kinship(person: nil, relation: .greatGrandfather, side: nil))
        #expect(Q.detect("Tell me about rick's grandfather")
                == .kinship(person: "Rick", relation: .grandfather, side: nil))
        #expect(Q.detect("what about donna's great-grandmother on her mother's side")
                == .kinship(person: "Donna", relation: .greatGrandmother, side: .maternal))
        // Not ours: a plain biography, a single-hop relation (translator
        // vocabulary), a descendant word the walk cannot name, and the
        // unchanged line shape.
        #expect(Q.detect("tell me about Edith Lucy Parker") == nil)
        #expect(Q.detect("who was rick's father") == nil)
        #expect(Q.detect("tell me about rick's grandson") == nil)
        #expect(Q.detect("rick's maternal line back 5 generations")
                == .ancestorLine(person: "Rick", line: .maternal, generations: 5))
        #expect(Q.detect("show me rick's paternal side")
                == .ancestorLine(person: "Rick", line: .paternal, generations: 5))
    }

    @Test func theKinshipQuestionBecomesAGraphIntentBeforeTranslation() throws {
        guard case .run(let intent) = pre("tell me about Rick Breen's great great grandpa on his paternal side") else {
            Issue.record("expected a local graph intent"); return
        }
        guard case .graph(let payload) = intent.ast else { Issue.record("expected graph"); return }
        #expect(payload.people == ["Rick Breen"])
        #expect(payload.operation == .kinship)
        #expect(payload.relation == .greatGreatGrandfather)
        #expect(payload.side == .paternal)
        // First-person → the "me" pronoun the preflight binds to the owner.
        guard case .run(let mine) = pre("my great grandpa"), case .graph(let p2) = mine.ast else {
            Issue.record("expected a local graph intent"); return
        }
        #expect(p2.people == ["me"])
        #expect(p2.relation == .greatGrandfather)
    }

    @Test func rickBreenResolvesThroughTheOwnerChainToTheDepthFourPaternalMale() async throws {
        let r = try await run("tell me about Rick Breen's great great grandpa on his paternal side")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("John Breen"))
        #expect(!r.prose.contains("Patrick Breen (") , "depth 3 must not be reported as depth 4")
        #expect(r.basisLine.contains("“you” = Richard Harding Breen Jr (tree root)"), Comment(rawValue: r.basisLine))
        #expect(!r.prose.contains("About Rick"))
    }

    // MARK: Live case 2 — profile "Rick" → tree "Richard Harding Breen Jr" (no BIRT)

    @Test func theProfileSpellingReachesTheUndatedTreeRecordAndAnswersTheGrandfather() async throws {
        let r = try await run("Tell me about rick's grandfather")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("George Breen"))
        #expect(!r.prose.contains("goes up to people born"))
        #expect(!r.prose.contains("isn't in it yet"))
        #expect(!r.prose.contains("can't trace"))
    }

    @Test func aStrangerStillDeclinesHonestlyWithoutTheYearSentence() async throws {
        let r = try await Exec.execute(
            .init(intent: .init(originalQuestion: "who is matt's grandfather",
                                ast: .graph(.init(people: ["matt"], operation: .kinship, relation: .grandfather)))),
            context: context)
        #expect(r.outcome != .answered)
        #expect(!r.prose.contains("born up to"))
        #expect(!r.prose.contains("goes up to people born"))
        #expect(!r.prose.contains("Richard"), "the owner chain never applies to someone else's name")
    }

    @Test func peopleTabTreeSentenceNeverReadsTheTreesReachFromAMaxBirthYear() {
        let sentence = Exec.PeopleTab.treeSentence(for: "Timmy", graph: graph)
        #expect(sentence == "I couldn't match Timmy to a record in the family tree I have.")
        #expect(Exec.FamilyKnowledgeSupplement.coverageNote(relation: .children, graph: graph) == nil)
    }

    // MARK: Live case 3 — "family tree from rick breen all the way back to 1600"

    @Test func aNamedStartAllTheWayBackIsAFullDepthAncestorWalk() throws {
        // "back to 1600" is now a year bound on the walk (ITEM 2, 2026-08-26).
        #expect(Q.detect("tell me about the family tree from rick breen all the way back to 1600")
                == .ancestorLine(person: "Rick Breen", line: .both, generations: Q.yearBoundGenerations, untilYear: 1600))
        #expect(Q.detect("tell me about the family tree from rick breen all the way back")
                == .ancestorLine(person: "Rick Breen", line: .both, generations: Q.maxGenerations))
        #expect(Q.detect("show the family tree of donna hudson as far back as you can go")
                == .ancestorLine(person: "Donna Hudson", line: .both, generations: Q.maxGenerations))
        #expect(Q.detect("family tree for the latta family all the way back")
                == .surnameTree(surname: "latta"))
        #expect(Q.detect("show the family tree for donna")
                == .surnameTree(surname: "donna"), "a bare person with no depth wish keeps its old route")
        let r = try #require(HallieLineageAnswer.answer(
            .ancestorLine(person: "Rick Breen", line: .both, generations: Q.maxGenerations), context: context))
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("John Breen"))
        #expect(!r.prose.contains("born up to"))
    }

    @Test func aTypedDiminutiveResolvesOnTheGraphRouteForBiographyToo() async throws {
        let r = try await Exec.execute(
            .init(intent: .init(originalQuestion: "who is rick breen",
                                ast: .graph(.init(people: ["rick breen"], operation: .biography)))),
            context: context)
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("Richard Harding Breen Jr"))
        #expect(!r.prose.contains("try a fuller name"))
    }

    // MARK: The shared owner chain

    @Test func ownerSpellingIsFirstNameAnchoredAndDiminutiveTolerant() {
        #expect(HallieOwnerResolver.isOwnerSpelling("rick", owner: "Rick Breen"))
        #expect(HallieOwnerResolver.isOwnerSpelling("Rick Breen", owner: "Rick Breen"))
        #expect(HallieOwnerResolver.isOwnerSpelling("richard breen jr", owner: "Rick Breen"))
        #expect(!HallieOwnerResolver.isOwnerSpelling("breen", owner: "Rick Breen"))
        #expect(!HallieOwnerResolver.isOwnerSpelling("rick lamb", owner: "Rick Breen"))
        #expect(!HallieOwnerResolver.isOwnerSpelling("donna", owner: "Rick Breen"))
        #expect(!HallieOwnerResolver.isOwnerSpelling("rick", owner: nil))
    }

    @Test func ownerChainPrefersTheRootAmongSeveralRichards() {
        guard case .one(let p, let note) = HallieOwnerResolver.resolve("Rick Breen", graph: graph) else {
            Issue.record("expected the root"); return
        }
        #expect(p.id == "@I1@")
        #expect(note.contains("tree root"))
        guard case .one(let george, _) = HallieOwnerResolver.resolve("geo breen", graph: graph) else {
            Issue.record("expected George"); return
        }
        #expect(george.name == "George Breen")
    }

    @Test func myDadRebindsThroughTheOwnerChainUnderFamilySearchSpelling() {
        let bound = Exec.SpeakerKinship.rebind(
            people: ["me"], question: "show me videos of my dad",
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae"),
            graph: graph)
        #expect(bound.failure == nil, Comment(rawValue: bound.failure ?? ""))
        #expect(bound.people == ["Richard Harding Breen Sr"])
        #expect(bound.notes.contains { $0.contains("tree root") })
    }

    @Test func theLegacyParserDoesNotReadTheKinshipPhraseAsABiography() {
        #expect(ArchivistQuestionParser.general("tell me about Rick Breen's great great grandpa on his paternal side") == nil)
        #expect(ArchivistQuestionParser.hasAncestorPossessive("who was Donna's maternal grandmother"))
        #expect(!ArchivistQuestionParser.hasAncestorPossessive("tell me about Edith Lucy Parker"))
        #expect(ArchivistQuestionParser.general("tell me about Edith Lucy Parker")
                == .biography(personText: "Edith Lucy Parker"))
    }
}
