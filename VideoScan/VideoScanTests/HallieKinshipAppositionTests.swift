// HallieKinshipAppositionTests.swift
// Live 2026-08-26 23:35Z: "Find rick's grandma muriel and tell me about
// her." → "A family-tree question must identify exactly one person."
// (route=graph, person=rick,muriel relation=grandmother). Two defects:
// the guard sentence reached the chat, and "kin word + name" was read as
// two people. ITEM 3 (23:35:29Z): "tell me about muriel lamb breen" → not
// found, because FamilySearch records women under the maiden name only.
//
// Fixture: FamilySearch-style, owner first and undated, two grandmothers
// (one Muriel), two uncles named William, a second Muriel married into a
// different surname.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let tree = """
0 HEAD
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 FAMC @F1@
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
1 DEAT
2 DATE 1970
1 FAMS @F2@
0 @I4@ INDI
1 NAME Muriel /Lamb/
1 SEX F
1 BIRT
2 DATE APR 1902
1 DEAT
2 DATE 1988
1 FAMS @F2@
0 @I5@ INDI
1 NAME Mary /Hudson/
1 SEX F
1 BIRT
2 DATE 1933
1 FAMC @F3@
1 FAMS @F1@
0 @I6@ INDI
1 NAME Carl /Hudson/
1 SEX M
1 BIRT
2 DATE 1900
1 FAMS @F3@
0 @I7@ INDI
1 NAME Edith /Parker/
1 SEX F
1 BIRT
2 DATE 1905
1 FAMS @F3@
0 @I8@ INDI
1 NAME William /Breen/
1 SEX M
1 BIRT
2 DATE 1928
1 FAMC @F2@
0 @I9@ INDI
1 NAME William /Hudson/
1 SEX M
1 BIRT
2 DATE 1935
1 FAMC @F3@
0 @I10@ INDI
1 NAME Frank /Hudson/
1 SEX M
1 BIRT
2 DATE 1938
1 FAMC @F3@
0 @I11@ INDI
1 NAME Muriel /Smith/
1 SEX F
1 BIRT
2 DATE 1910
1 FAMS @F4@
0 @I12@ INDI
1 NAME Tom /Jones/
1 SEX M
1 FAMS @F4@
0 @F1@ FAM
1 HUSB @I2@
1 WIFE @I5@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I3@
1 WIFE @I4@
1 CHIL @I2@
1 CHIL @I8@
0 @F3@ FAM
1 HUSB @I6@
1 WIFE @I7@
1 CHIL @I5@
1 CHIL @I9@
1 CHIL @I10@
0 @F4@ FAM
1 HUSB @I12@
1 WIFE @I11@
0 TRLR
"""

private let guardSentence = "A family-tree question must identify exactly one person."

@Suite("Hallie — kinship word + name apposition, married surnames", .serialized)
struct HallieKinshipAppositionTests {
    typealias Q = HallieLineageQuestion
    typealias Exec = HallieTurnExecutor
    typealias A = HallieKinshipApposition

    private let graph = GedcomFamilyGraph(gedcomText: tree)
    private var context: Exec.Context {
        Exec.Context(profiles: [.init(stableID: "rick", canonicalName: "Rick", aliases: ["Dad"])],
                     graph: graph,
                     speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae",
                                     archivistPersonName: nil))
    }
    private func pre(_ question: String) -> Exec.PreTranslation {
        Exec.preTranslation(
            question: question, playAfterAnswer: false, memory: .init(),
            isKnownPerson: { _ in false },
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context) })
    }
    private func run(_ question: String) async throws -> Exec.Result {
        switch pre(question) {
        case .run(let intent): return try await Exec.execute(.init(intent: intent), context: context)
        case .answer(let r): return r
        case .translate:
            Issue.record("“\(question)” went to the model translator"); throw CancellationError()
        }
    }
    private func graphTurn(_ people: [String], _ op: ArchivistQueryAST.Graph.Operation,
                           relation: ArchivistQueryAST.Graph.Relation? = nil) async throws -> Exec.Result {
        try await Exec.execute(
            .init(intent: .init(originalQuestion: people.joined(separator: " "),
                                ast: .graph(.init(people: people, operation: op, relation: relation)))),
            context: context)
    }

    // MARK: Parse — one place

    @Test func theShapeParsesAndNonShapesDoNot() {
        let live = A.parse("Find rick's grandma muriel and tell me about her.")
        #expect(live?.possessor == "Rick")
        #expect(live?.kin == .extended(.grandmother, side: nil))
        #expect(live?.name == "Muriel")
        #expect(A.parse("my uncle Bill")?.kin == .extended(.uncle, side: nil))
        #expect(A.parse("my uncle Bill")?.possessor == nil)
        #expect(A.parse("Donna's sister Nancy") == A(possessor: "Donna", kin: .single(.sister), relationWord: "sister", name: "Nancy"))
        #expect(A.parse("who was Rick's grandfather George Breen")?.name == "George Breen")
        #expect(A.parse("rick's maternal grandmother edith")?.kin == .extended(.grandmother, side: .maternal))
        #expect(A.parse("rick's great great great grandpa john")?.kin == .deep(depth: 5, sex: "M", side: nil))
        // Not the shape: no name, a phrase that goes on, a media ask, a
        // descendant word the walk cannot name, a second kin word.
        #expect(A.parse("tell me about rick's grandfather") == nil)
        #expect(A.parse("rick's grandfather on his paternal side") == nil)
        #expect(A.parse("show videos of donna's sister nancy") == nil)
        #expect(A.parse("rick's grandson tim") == nil)
        #expect(A.parse("rick's sister's son") == nil)
        #expect(A.parse("rick's maternal line back 5 generations") == nil)
        // The lineage front door and the older parsers agree.
        #expect(Q.detect("find rick's grandma muriel and tell me about her") == .kinshipNamed(live!))
        #expect(ArchivistQuestionParser.kinship("Donna's sister Nancy") == nil)
        #expect(ArchivistQuestionParser.general("tell me about rick's grandma muriel") == nil)
        #expect(ArchivistQuestionParser.kinship("show videos of Rick's father at Christmas") != nil)
    }

    @Test func theBiographyTailIsNotASecondQuestion() {
        #expect(Exec.splitTwoQuestions("Find rick's grandma muriel and tell me about her.") == nil)
        #expect(A.parse("find rick's grandma muriel, and tell me more about her")?.name == "Muriel")
        #expect(A.parse("rick's uncle bill and describe him")?.name == "Bill")
    }

    // MARK: Answers

    @Test func theLiveUtteranceIsABiographyOfThePaternalGrandmother() async throws {
        let r = try await run("Find rick's grandma muriel and tell me about her.")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.hasPrefix("Muriel Lamb (1902–1988) was Rick’s paternal grandmother."), Comment(rawValue: r.prose))
        #expect(r.prose.contains("married to George Breen"))
        #expect(!r.prose.contains(guardSentence))
        #expect(r.catalogPersonName == "Muriel Lamb")
        #expect(r.offeredActions == [.openFamilyTreePerson(personID: "@I4@", personName: "Muriel Lamb")])
        #expect(r.basisLine.contains("Edith Parker"), "the checked set is in the basis line")
    }

    @Test func twoUnclesNamedWilliamAskWhichOneByDiminutive() async throws {
        let r = try await run("my uncle Bill")
        #expect(r.outcome == .needsClarification, Comment(rawValue: r.prose))
        #expect(r.prose.contains("William Breen (b. 1928)"))
        #expect(r.prose.contains("William Hudson (b. 1935)"))
        #expect(!r.prose.contains("Frank"))
        #expect(r.offeredActions.count == 2)
        guard case .ask(let question, _) = r.offeredActions[0] else { Issue.record("expected ask chips"); return }
        #expect(question == "who is William Breen")
    }

    @Test func noMatchListsTheRealGrandmothersHonestly() async throws {
        let r = try await run("rick's grandma agnes")
        #expect(r.outcome == .declined)
        #expect(r.prose == "Rick’s grandmothers are Edith Parker and Muriel Lamb — I don't find an Agnes there.", Comment(rawValue: r.prose))
    }

    @Test func aFullNameAfterTheKinWordPicksExactlyOne() async throws {
        let r = try await run("Rick's grandfather George Breen")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.hasPrefix("George Breen (1898–1970) was Rick’s paternal grandfather."), Comment(rawValue: r.prose))
        let none = try await run("Rick's grandfather George Hudson")
        #expect(none.outcome == .declined)
        #expect(none.prose.contains("Carl Hudson and George Breen"), Comment(rawValue: none.prose))
    }

    @Test func aMissingRelationSetIsSaidByName() async throws {
        let r = try await run("rick's great great grandma agnes")
        #expect(r.outcome == .declined)
        #expect(r.prose.contains("can't reach a great-great-grandmother"), Comment(rawValue: r.prose))
    }

    // MARK: The model's two-people reading takes the same road

    @Test func theTranslatorsTwoPeopleKinshipIsTheSameAnswer() async throws {
        let r = try await graphTurn(["rick", "muriel"], .kinship, relation: .grandmother)
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.hasPrefix("Muriel Lamb (1902–1988) was Rick’s paternal grandmother."), Comment(rawValue: r.prose))
        #expect(!r.prose.contains(guardSentence))
        let mine = try await graphTurn(["me", "bill"], .kinship, relation: .uncle)
        #expect(mine.outcome == .needsClarification, Comment(rawValue: mine.prose))
    }

    @Test func aGenuinelyUnsupportedPeopleCountDeclinesInPlainWords() async throws {
        let r = try await graphTurn(["Chris River", "Casey Solo"], .biography)
        #expect(r.outcome == .declined)
        #expect(r.prose == "I wasn't sure which person you meant — Chris River or Casey Solo? Ask about one of them and I'll look them up.", Comment(rawValue: r.prose))
    }

    /// Sensor: no graph-executor prose constant is a validation sentence.
    @Test func noGuardSentenceIsAProseConstant() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sources = testsDir.deletingLastPathComponent().appendingPathComponent("VideoScan")
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path)
            .filter { $0.hasPrefix("ArchivistGraphExecutor") || $0.hasPrefix("HallieTurnExecutor") || $0.hasPrefix("HallieKinship") }
        let banned = ["must identify", "must specify", "needs a person's name", "needs two people", "must name exactly"]
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("prose:") || line.contains("text:") {
                for phrase in banned {
                    #expect(!line.contains(phrase), "\(file): \(line)")
                }
            }
        }
    }

    // MARK: ITEM 3 — married surnames in namedLike

    @Test func aWifeIsFoundUnderHerHusbandsSurname() {
        #expect(graph.people(namedLike: "muriel lamb breen").map(\.name) == ["Muriel Lamb"])
        #expect(graph.people(namedLike: "muriel breen").map(\.name) == ["Muriel Lamb"])
        #expect(graph.people(namedLike: "muriel lamb").map(\.name) == ["Muriel Lamb"])
        #expect(graph.people(namedLike: "muriel jones").map(\.name) == ["Muriel Smith"])
        #expect(graph.people(namedLike: "muriel").map(\.name) == ["Muriel Lamb", "Muriel Smith"])
        // A woman married into a different surname does not match.
        #expect(graph.people(namedLike: "muriel smith breen").isEmpty)
        // A man is never found by his wife's maiden name.
        #expect(graph.people(namedLike: "george lamb").isEmpty)
        #expect(graph.people(namedLike: "tom smith").isEmpty)
        // The surname alone is not every wife of that family.
        #expect(!graph.people(namedLike: "breen").contains { $0.name == "Muriel Lamb" })
        // The inverted index agrees with the linear scan.
        let index = GedcomFamilyGraph.NameIndex(graph: graph)
        for typed in ["muriel lamb breen", "muriel breen", "muriel jones", "george lamb", "breen", "muriel smith breen"] {
            #expect(index.people(namedLike: typed) == graph.people(namedLike: typed), Comment(rawValue: typed))
        }
    }

    @Test func theLiveMarriedNameUtterancesAnswerAndSayTheMaidenName() async throws {
        let full = try await graphTurn(["muriel lamb breen"], .biography)
        #expect(full.outcome == .answered, Comment(rawValue: full.prose))
        #expect(full.prose.hasPrefix("Muriel Lamb (Breen) was born April 1902"), Comment(rawValue: full.prose))
        #expect(full.prose.contains("married to George Breen"))
        #expect(full.basisLine.contains("by her married name (married George Breen)"), Comment(rawValue: full.basisLine))
        let maiden = try await graphTurn(["muriel lamb"], .biography)
        #expect(maiden.outcome == .answered)
        #expect(maiden.prose.hasPrefix("Muriel Lamb was born April 1902"), Comment(rawValue: maiden.prose))
        let wrong = try await graphTurn(["muriel smith breen"], .biography)
        #expect(wrong.outcome != .answered)
    }
}
