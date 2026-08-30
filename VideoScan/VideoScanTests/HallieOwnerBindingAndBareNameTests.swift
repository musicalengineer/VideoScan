// HallieOwnerBindingAndBareNameTests.swift
// Live miss #2 (docs/hallie_spot_test_misses_2026_08_28.md): "Can you find
// the closest common ancestor between me (Rick) and Donna?" → "Which rick
// do you mean?" with Catherine Auker (b. 1374) and Robert de Cralle
// (b. 1334) as chips. Two defects, two sensors:
//   (a) OWNER BINDING — "me (Rick)", "(Rick)", "myself, Rick" and the
//       owner's bare first name from the owner bind to the owner through
//       HallieOwnerResolver before any name search (detector + graph route).
//   (b) BARE-NAME MATCHER — a bare given name matches GIVEN names (primary
//       NAME record, Rick ↔ Richard), never a surname/alternate-name stub
//       "Rich"/"Dick"; namesakes are anchored (roots first), capped at 6,
//       and past the cap with no anchor the answer asks for a surname or
//       year instead of listing medieval strangers.
// LOGIC on the merged two-root fixture; SCALE on a synthetic 20k pedigree
// with hundreds of Richards and surnames that contain "rick"/"rich".

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Fixture (the merged two-root tree of HallieCommonAncestorTests)

private let rickPull = """
0 HEAD
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 BIRT
2 DATE 1959
1 FAMC @F1@
1 FAMS @F2@
1 _FSFTID GVQV-NW3
0 @I2@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 FAMS @F2@
1 _FSFTID G2CL-86B
0 @I3@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 FAMC @F3@
1 FAMS @F1@
1 _FSFTID RICK-DAD
0 @I4@ INDI
1 NAME George /Breen/
1 SEX M
1 FAMC @F4@
1 FAMS @F3@
1 _FSFTID RICK-GF1
0 @I5@ INDI
1 NAME Z /Common/
1 SEX M
1 BIRT
2 DATE 1840
1 FAMS @F4@
1 _FSFTID ZCOM-MON
0 @F1@ FAM
1 HUSB @I3@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I1@
1 WIFE @I2@
0 @F3@ FAM
1 HUSB @I4@
1 CHIL @I3@
0 @F4@ FAM
1 HUSB @I5@
1 CHIL @I4@
0 TRLR
"""

private let donnaPull = """
0 HEAD
0 @I1@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 BIRT
2 DATE 1959
1 FAMC @F1@
1 _FSFTID G2CL-86B
0 @I2@ INDI
1 NAME Walter /Hudson/
1 SEX M
1 FAMC @F2@
1 FAMS @F1@
1 _FSFTID DON1-DAD
0 @I3@ INDI
1 NAME Harold /Hudson/
1 SEX M
1 FAMC @F3@
1 FAMS @F2@
1 _FSFTID DON1-GF0
0 @I4@ INDI
1 NAME Mabel /Common/
1 SEX F
1 FAMC @F4@
1 FAMS @F3@
1 _FSFTID DON1-GGM
0 @I5@ INDI
1 NAME Z /Common/
1 SEX M
1 BIRT
2 DATE 1840
1 FAMS @F4@
1 _FSFTID ZCOM-MON
0 @F1@ FAM
1 HUSB @I2@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I3@
1 CHIL @I2@
0 @F3@ FAM
1 WIFE @I4@
1 CHIL @I3@
0 @F4@ FAM
1 HUSB @I5@
1 CHIL @I4@
0 TRLR
"""

private func mergedGraph() -> GedcomFamilyGraph {
    var a = GedcomFamilyGraph(gedcomText: rickPull); a.sourceFileName = "familysearch-tree-20generations.ged"
    var b = GedcomFamilyGraph(gedcomText: donnaPull); b.sourceFileName = "familysearch-donna-20generations.ged"
    var g = a.merged(with: b)
    g.sourceFileName = "familysearch-merged-20260827.ged"
    return g
}

private func context(_ graph: GedcomFamilyGraph, owner: String? = "Rick Breen") -> HallieTurnExecutor.Context {
    HallieTurnExecutor.Context(profiles: [], graph: graph,
                               speakers: .init(ownerName: owner, archivistName: nil, archivistPersonName: nil))
}

private let rickSentence = "Can you find the closest common ancestor between me (Rick) and Donna?"

/// The merged fixture's answer for Rick & Donna (their fathers' grandfather).
private func expectMarthaStyleAnswer(_ r: HallieTurnExecutor.Result?, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let r else { Issue.record("no answer", sourceLocation: sourceLocation); return }
    #expect(r.route == .graph, sourceLocation: sourceLocation)
    #expect(r.outcome == .answered, "got: \(r.prose)", sourceLocation: sourceLocation)
    // Either side order ("donna and me (rick)" leads with Donna).
    #expect(r.prose.contains("share 1 recorded ancestor; the nearest is Z Common"), "got: \(r.prose)", sourceLocation: sourceLocation)
    #expect(r.prose.contains("Richard Harding Breen Jr") && r.prose.contains("Donna Hudson"), "got: \(r.prose)", sourceLocation: sourceLocation)
    #expect(!r.prose.lowercased().hasPrefix("which"), sourceLocation: sourceLocation)
    #expect(!r.prose.localizedCaseInsensitiveContains("have no common ancestor"), sourceLocation: sourceLocation)
    #expect(!r.prose.localizedCaseInsensitiveContains("catalog items matching"), sourceLocation: sourceLocation)
}

// MARK: - (a) Owner binding — detector

@Suite("Owner binding — detector reads glosses and appositives")
struct HallieOwnerBindingDetectTests {
    typealias Q = HallieLineageQuestion

    @Test func ricksExactSentenceIsTheOwnerAndDonna() {
        #expect(Q.detect(rickSentence) == .commonAncestor(a: nil, b: "Donna"))
    }

    @Test func glossForms() {
        #expect(Q.detect("closest common ancestor of me (rick) and donna") == .commonAncestor(a: nil, b: "Donna"))
        #expect(Q.detect("common ancestor of rick (me) and donna") == .commonAncestor(a: nil, b: "Donna"))
        #expect(Q.detect("how are donna and me (rick) related") == .commonAncestor(a: "Donna", b: nil))
        #expect(Q.detect("are myself, rick and donna related") == .commonAncestor(a: nil, b: "Donna"))
        #expect(Q.detect("are myself and donna related") == .commonAncestor(a: nil, b: "Donna"))
        // A bare parenthesised name is that name; the resolver's
        // owner-spelling rule makes it the owner when the speaker is Rick.
        #expect(Q.detect("how are (rick) and donna related") == .commonAncestor(a: "Rick", b: "Donna"))
        #expect(Q.detect("closest common ancestor between (rick) and donna") == .commonAncestor(a: "Rick", b: "Donna"))
    }

    @Test func unchangedNegatives() {
        #expect(Q.detect("are me and myself related") == nil)
        #expect(Q.detect("videos of me (rick) and donna") != .commonAncestor(a: nil, b: "Donna"))
    }
}

// MARK: - (a) Owner binding — answers on the merged two-root fixture

@Suite("Owner binding — answers")
struct HallieOwnerBindingAnswerTests {
    let graph = mergedGraph()

    @Test func ricksExactSentenceIsAnsweredAtTheLocalProductionBoundary() throws {
        let turn = HallieTurnExecutor.preTranslation(
            question: rickSentence,
            playAfterAnswer: false,
            memory: .init(),
            isKnownPerson: { _ in false },
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context(graph)) }
        )
        guard case .answer(let result) = turn else {
            Issue.record("exact owner/common-ancestor prompt escaped the local graph route")
            return
        }
        expectMarthaStyleAnswer(result)
        #expect(result.queryDescription?.contains("common ancestor") == true)
    }

    @Test func glossFormsResolveToTheOwner() throws {
        for sentence in ["closest common ancestor of me (rick) and donna",
                         "common ancestor between (rick) and donna",
                         "are myself and donna related",
                         "how are donna and me (rick) related"] {
            let q = try #require(HallieLineageQuestion.detect(sentence), Comment(rawValue: sentence))
            expectMarthaStyleAnswer(HallieLineageAnswer.answer(q, context: context(graph)))
        }
    }

    @Test func bareRickFromSpeakerRickIsTheOwnerWithoutASearch() throws {
        // The lineage path: "rick" typed by the owner → the one matching root.
        let r = try #require(HallieLineageAnswer.answer(.commonAncestor(a: "rick", b: "donna"), context: context(graph)))
        expectMarthaStyleAnswer(r)
        #expect(r.basisLine.contains("“you” = Richard Harding Breen Jr"), "got: \(r.basisLine)")
    }

    @MainActor
    @Test func graphRelationshipRoutePinsTheOwnerBeforeSearching() async throws {
        // The translator's fallback path for the live sentence: person=rick,donna.
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: rickSentence,
            ast: .graph(.init(people: ["rick", "donna"], operation: .relationship)))
        let r = try await HallieTurnExecutor.execute(.init(intent: intent), context: context(graph))
        #expect(r.outcome == .answered, "got: \(r.prose)")
        #expect(!r.prose.hasPrefix("Which"))
        #expect(r.basisLine.contains("“you” = Richard Harding Breen Jr"), "got: \(r.basisLine)")
    }

    @MainActor
    @Test func unknownSpeakerStillAsksWithTypedCasingAndRootFirst() async throws {
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "how are Rick and Donna related?",
            ast: .graph(.init(people: ["Rick", "donna"], operation: .relationship)))
        let r = try await HallieTurnExecutor.execute(.init(intent: intent), context: context(graph, owner: nil))
        #expect(r.outcome == .needsClarification)
        #expect(r.prose.hasPrefix("Which Rick do you mean"), "got: \(r.prose)")
        let chips = try #require(r.clarification?.candidates)
        #expect(chips.count == 2)
        #expect(chips.first?.id == .gedcomPersonID("@I1@"), "the root (Jr) first, then Sr")
    }
}

// MARK: - (b) Bare-name matcher on a 20k pedigree

/// A binary pedigree of 20,000 people under two roots. Given names cycle
/// through real Richards AND the traps: surnames "Rich", "Dick", "Rickard",
/// "Merrick", "Patrick", "Frederick", and alternate-name stubs "Rich" /
/// "Richard" on every 7th person (the FamilySearch shape that produced
/// Catherine Auker live).
private enum BigTree {
    static let givens = ["Richard", "Catherine", "John", "Anne", "Rick", "Dick", "Rich",
                         "Patrick", "Frederick", "Elizabeth", "Robert", "Joan", "Ricky"]
    static let surnames = ["Rich", "Dick", "Auker", "Merrick", "Patrick", "Frederick",
                           "Cholmeley", "Piell", "de Cralle", "Rickard"]
    static let count = 20_000

    static func text() -> String {
        var lines: [String] = ["0 HEAD", "1 _VS_ROOT @I1@", "1 _VS_ROOT @I2@"]
        lines.reserveCapacity(count * 8)
        lines += ["0 @I1@ INDI", "1 NAME Richard Harding /Breen/ Jr", "1 SEX M", "1 BIRT", "2 DATE 1959",
                  "1 FAMC @F1@", "1 FAMS @F0@", "1 _FSFTID GVQV-NW3"]
        lines += ["0 @I2@ INDI", "1 NAME Donna /Hudson/", "1 SEX F", "1 BIRT", "2 DATE 1959",
                  "1 FAMS @F0@", "1 _FSFTID G2CL-86B"]
        for i in 3...count {
            let given = givens[i % givens.count]
            let surname = surnames[(i / givens.count) % surnames.count]
            lines.append("0 @I\(i)@ INDI")
            lines.append("1 NAME \(given) /\(surname)/")
            if i % 7 == 0 { lines.append("1 NAME \(i % 2 == 0 ? "Rich" : "Richard")") }
            lines.append("1 SEX \(i % 2 == 0 ? "M" : "F")")
            lines.append("1 BIRT")
            lines.append("2 DATE \(1300 + (i % 600))")
            lines.append("1 FAMC @F\(i / 2)@")
            lines.append("1 FAMS @F\(i)@")
        }
        lines += ["0 @F0@ FAM", "1 HUSB @I1@", "1 WIFE @I2@"]
        // Family k: parents 2k and 2k+1 (k ≥ 1), child k.
        for k in 1...(count / 2) {
            lines.append("0 @F\(k)@ FAM")
            if 2 * k <= count { lines.append("1 HUSB @I\(2 * k)@") }
            if 2 * k + 1 <= count { lines.append("1 WIFE @I\(2 * k + 1)@") }
            lines.append("1 CHIL @I\(k)@")
        }
        lines.append("0 TRLR")
        return lines.joined(separator: "\n")
    }

    static let graph: GedcomFamilyGraph = GedcomFamilyGraph(gedcomText: text())

    /// Expected hits for a bare "rick": primary given name Rick or Richard.
    static var expectedRicks: Int {
        1 + (3...count).filter { ["Richard", "Rick"].contains(givens[$0 % givens.count]) }.count
    }
}

@Suite("Bare-name matcher — 20k pedigree with rick/rich traps")
struct HallieBareNameMatcherScaleTests {
    let graph = BigTree.graph

    private func firstToken(_ p: GedcomFamilyGraph.Person) -> String {
        FamilyIdentityText.tokens(p.name).first ?? ""
    }

    @Test func treeShape() {
        #expect(graph.people.count == BigTree.count)
        #expect(graph.roots.map(\.id) == ["@I1@", "@I2@"])
        #expect(graph.people(namedLike: "rick").count > BigTree.expectedRicks, "the old loose match still over-reaches (surname Rich/Dick, alt-name stubs) — the route must not use it for a bare token")
    }

    @Test func givenNameLookupIsGivenNamesOnlyAndFast() {
        let start = Date()
        let hits = graph.people(givenName: "rick", expandDiminutives: true)
        let elapsed = Date().timeIntervalSince(start)
        #expect(hits.count == BigTree.expectedRicks, "got \(hits.count)")
        #expect(hits.allSatisfy { ["rick", "richard"].contains(firstToken($0)) })
        #expect(!hits.contains { $0.surname == "Rich" && firstToken($0) != "rick" && firstToken($0) != "richard" })
        #expect(!hits.contains { firstToken($0) == "dick" }, "Rick's father is Dick — never a sibling nickname")
        #expect(!hits.contains { firstToken($0) == "catherine" }, "no alternate-name stub 'Rich' brings a Catherine in")
        #expect(elapsed < 0.5, "bare given-name lookup took \(elapsed)s")
        // Linear equivalence.
        let forms = Set(GedcomFamilyGraph.givenNameForms(of: "rick"))
        let linear = graph.people.values.filter { GedcomFamilyGraph.personHasGivenName($0, forms: forms) }
        #expect(Set(linear.map(\.id)) == Set(hits.map(\.id)))
        // Formal → nicknames, exact → exact.
        #expect(GedcomFamilyGraph.givenNameForms(of: "richard").contains("rick"))
        #expect(GedcomFamilyGraph.givenNameForms(of: "rick") == ["rick", "richard"])
        #expect(graph.people(givenName: "rich", expandDiminutives: false).allSatisfy { firstToken($0) == "rich" })
    }

    @MainActor
    @Test func unknownSpeakerBareRickIsCappedRootsFirstNoNonRichard() async throws {
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "closest common ancestor between rick and donna",
            ast: .graph(.init(people: ["rick", "donna"], operation: .relationship)))
        let r = try await HallieTurnExecutor.execute(.init(intent: intent), context: context(graph, owner: nil))
        #expect(r.outcome == .needsClarification)
        #expect(r.prose.hasPrefix("Which Rick do you mean"), "got: \(r.prose)")
        #expect(r.prose.contains("more; add a surname or a birth year"), "got: \(r.prose)")
        let chips = try #require(r.clarification?.candidates)
        #expect(chips.count == HallieWhichOne.cap)
        #expect(chips.first?.id == .gedcomPersonID("@I1@"), "the root first")
        #expect(chips.allSatisfy { ["Rick", "Richard"].contains($0.canonicalName.split(separator: " ").first.map(String.init) ?? "") }, "got: \(chips.map(\.canonicalName))")
        #expect(r.basisLine.contains("home people first"))
    }

    @MainActor
    @Test func speakerRickBareRickOnTheBigTreeIsTheOwner() async throws {
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "closest common ancestor between rick and donna",
            ast: .graph(.init(people: ["rick", "donna"], operation: .relationship)))
        let r = try await HallieTurnExecutor.execute(.init(intent: intent), context: context(graph))
        #expect(r.outcome != .needsClarification, "got: \(r.prose)")
        #expect(r.basisLine.contains("“you” = Richard Harding Breen Jr"), "got: \(r.basisLine)")
    }

    @MainActor
    @Test func pastTheCapWithNoAnchorAsksForASurnameOrYear() async throws {
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "who is catherine?",
            ast: .graph(.init(people: ["catherine"], operation: .biography)))
        let r = try await HallieTurnExecutor.execute(.init(intent: intent), context: context(graph, owner: nil))
        #expect(r.outcome == .needsClarification)
        #expect(r.clarification == nil, "no chips for \(r.prose)")
        #expect(r.prose.contains("people named Catherine"), "got: \(r.prose)")
        #expect(r.prose.contains("Add a surname or a birth year"))
        // Lineage path, same rule.
        let l = try #require(HallieLineageAnswer.answer(.commonAncestor(a: "catherine", b: "donna"), context: context(graph, owner: nil)))
        #expect(l.outcome == .needsClarification)
        #expect(l.prose.contains("people named Catherine"), "got: \(l.prose)")
    }

    @MainActor
    @Test func singleSubjectRouteCapsTheChipsToo() async throws {
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "who is rick?",
            ast: .graph(.init(people: ["rick"], operation: .biography)))
        let r = try await HallieTurnExecutor.execute(.init(intent: intent), context: context(graph, owner: nil))
        #expect(r.outcome == .needsClarification)
        #expect(r.prose.hasPrefix("Which Rick do you mean"), "got: \(r.prose)")
        #expect((r.clarification?.candidates.count ?? 0) == HallieWhichOne.cap)
    }
}
