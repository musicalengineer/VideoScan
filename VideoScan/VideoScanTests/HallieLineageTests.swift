// HallieLineageTests.swift
// LOGIC + ISOLATION + SCALE for the lineage routes and attachment cards
// (2026-08-22): PLAC parsing, ancestor / descendant walks, surname roots,
// origin trails, the question detector, and the deterministic answers
// with their cards. Pure: synthetic GEDCOM text, no files, no model.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let tree = """
0 HEAD
0 @I1@ INDI
1 NAME Rick /Breen/
1 SEX M
1 BIRT
2 DATE 1959
2 PLAC Boston, Massachusetts, USA
1 FAMC @F1@
1 FAMS @F5@
0 @I2@ INDI
1 NAME Richard /Breen/ Sr
1 SEX M
1 BIRT
2 DATE 1929
2 PLAC Boston, Massachusetts, USA
1 FAMC @F2@
1 FAMS @F1@
0 @I3@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 BIRT
2 DATE 1930
2 PLAC Lowell, Massachusetts, USA
1 FAMC @F3@
1 FAMS @F1@
0 @I4@ INDI
1 NAME David /Latta/
1 SEX M
1 BIRT
2 DATE 1902
2 PLAC Belfast, Ireland
1 FAMS @F3@
0 @I5@ INDI
1 NAME Mary /McGill/
1 SEX F
1 BIRT
2 DATE 1904
2 PLAC Glasgow, Scotland
1 FAMC @F4@
1 FAMS @F3@
0 @I6@ INDI
1 NAME Agnes /McGill/
1 SEX F
1 BIRT
2 DATE 1880
2 PLAC Derry, Ireland
1 FAMS @F4@
0 @I7@ INDI
1 NAME George /Breen/
1 SEX M
1 BIRT
2 DATE 1898
1 FAMS @F2@
0 @I8@ INDI
1 NAME Muriel /Lamb/
1 SEX F
1 FAMS @F2@
0 @I9@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 BIRT
2 DATE 1959
1 FAMS @F5@
0 @I10@ INDI
1 NAME Tim /Breen/
1 SEX M
1 BIRT
2 DATE 1985
1 FAMC @F5@
0 @F1@ FAM
1 HUSB @I2@
1 WIFE @I3@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I7@
1 WIFE @I8@
1 CHIL @I2@
0 @F3@ FAM
1 HUSB @I4@
1 WIFE @I5@
1 CHIL @I3@
0 @F4@ FAM
1 WIFE @I6@
1 CHIL @I5@
0 @F5@ FAM
1 HUSB @I1@
1 WIFE @I9@
1 CHIL @I10@
0 TRLR
"""

@Suite("Lineage — graph walks")
struct GedcomLineageTests {
    let graph = GedcomFamilyGraph(gedcomText: tree)
    var rick: GedcomFamilyGraph.Person { graph.people["@I1@"]! }

    @Test func placParsesForBirthOnly() {
        #expect(graph.people["@I4@"]?.birthPlace == "Belfast, Ireland")
        #expect(graph.people["@I4@"]?.deathPlace == nil)
        #expect(graph.people["@I8@"]?.birthPlace == nil)
    }

    @Test func maternalLineStopsWhereTheTreeStops() {
        let gens = graph.ancestorLine(of: rick, line: .maternal, generations: 5)
        #expect(gens.map(\.generation) == [1, 2, 3])
        #expect(gens.map { $0.people.map(\.name) } == [["Eileen Latta"], ["Mary McGill"], ["Agnes McGill"]])
    }

    @Test func paternalLineAndPedigree() {
        let pat = graph.ancestorLine(of: rick, line: .paternal, generations: 5)
        #expect(pat.map { $0.people.map(\.name) } == [["Richard Breen Sr"], ["George Breen"]])
        let both = graph.ancestorLine(of: rick, line: .both, generations: 2)
        #expect(both[0].people.count == 2)
        #expect(Set(both[1].people.map(\.name)) == ["George Breen", "Muriel Lamb", "David Latta", "Mary McGill"])
    }

    @Test func descendantsAndRoots() {
        let node = graph.descendants(of: graph.people["@I4@"]!, depth: 3)
        #expect(node.allPeople.map(\.name) == ["David Latta", "Eileen Latta", "Rick Breen", "Tim Breen"])
        #expect(node.spouses.map(\.name) == ["Mary McGill"])
        #expect(graph.rootAncestors(surname: "Latta").map(\.name) == ["David Latta"])
        #expect(graph.rootAncestors(surname: "McGill").map(\.name) == ["Agnes McGill"])
        #expect(graph.rootAncestors(surname: "Nobody").isEmpty)
    }

    @Test func originTrailFindsNearestIrishAncestorFirst() {
        let ireland = graph.originTrail(of: rick, country: "ireland")
        #expect(ireland.map(\.person.name) == ["David Latta", "Agnes McGill"])
        #expect(ireland.first?.generation == 2)
        #expect(graph.originTrail(of: rick, country: "England").isEmpty)
        // Whole-component match: "New England" must not match "England".
        #expect(GedcomFamilyGraph.place("Boston, New England", mentions: "england") == false)
        #expect(GedcomFamilyGraph.place("Cork, Ireland", mentions: "ireland"))
    }

    @Test func zeroGenerationRequestReturnsNoAncestors() {
        #expect(graph.ancestorLine(
            of: rick, line: .both, generations: 0).isEmpty)
    }

    @Test func deathPlaceIsNotPresentedAsOriginOrBirthPlace() throws {
        let g = GedcomFamilyGraph(gedcomText: """
        0 @I1@ INDI
        1 NAME Child /Stone/
        1 FAMC @F1@
        0 @I2@ INDI
        1 NAME Parent /Stone/
        1 DEAT
        2 PLAC Cork, Ireland
        1 FAMS @F1@
        0 @F1@ FAM
        1 HUSB @I2@
        1 CHIL @I1@
        0 TRLR
        """)
        let child = try #require(g.people["@I1@"])
        #expect(g.originTrail(of: child, country: "Ireland").isEmpty)
    }

    @Test func ancestorPathsKeepOnlyTheChainToTargets() {
        let agnes = graph.people["@I6@"]!, david = graph.people["@I4@"]!
        let gens = graph.ancestorPaths(from: rick, to: [agnes, david])
        #expect(gens.map { $0.people.map(\.name) } == [["Eileen Latta"], ["David Latta", "Mary McGill"], ["Agnes McGill"]])
        #expect(graph.ancestorPaths(from: rick, to: []).isEmpty)
    }

    @Test func nicknameAndPrefixMatching() {
        #expect(graph.people(matching: "rick breen").map(\.name) == ["Rick Breen"])
        // Diminutive: fred → frederick would apply on a tree that has one;
        // here "tim breen" resolves exactly, and a prefix ask like
        // "elle ronan" is rejected only when shorter than 3 letters.
        #expect(GedcomFamilyGraph.diminutives["fred"] == "frederick")
        #expect(graph.people(matching: "el ronan").isEmpty)
    }

    @Test func lineRestrictedTrailAndLoosePlaces() {
        let maternalIreland = graph.originTrail(of: rick, country: "ireland", line: .maternal)
        #expect(maternalIreland.map(\.person.name) == ["Agnes McGill"])
        let paternalIreland = graph.originTrail(of: rick, country: "ireland", line: .paternal)
        #expect(paternalIreland.isEmpty)
        #expect(GedcomFamilyGraph.place("Boston, Suffolk, Massachusetts, USA", mentions: "old puritan boston"))
        #expect(GedcomFamilyGraph.place("Boston, New England", mentions: "england") == false)
    }

    @Test func sourceMetadataOnlyFromFiles() {
        #expect(graph.sourceFileName == nil)
        #expect(graph.familyCount == 5)
    }
}

@Suite("Lineage — question detector")
struct HallieLineageDetectTests {
    typealias Q = HallieLineageQuestion

    @Test func maternalLineShapes() {
        #expect(Q.detect("show rick's maternal line back 5 generations") == .ancestorLine(person: "Rick", line: .maternal, generations: 5))
        #expect(Q.detect("Show me my mother's side back three generations") == .ancestorLine(person: nil, line: .maternal, generations: 3))
        #expect(Q.detect("donna's paternal line") == .ancestorLine(person: "Donna", line: .paternal, generations: 5))
        #expect(Q.detect("my ancestors back 4 generations") == .ancestorLine(person: nil, line: .both, generations: 4))
    }

    @Test func surnameTreeShapes() {
        #expect(Q.detect("show the family tree for the latta family") == .surnameTree(surname: "latta"))
        #expect(Q.detect("show the family tree for the current breen family") == .surnameTree(surname: "breen"))
        #expect(Q.detect("family tree starting with the lattas") == .surnameTree(surname: "lattas"))
        #expect(Q.detect("the hudson family tree") == .surnameTree(surname: "hudson"))
        #expect(Q.detect("family tree of the mcgills") == .surnameTree(surname: "mcgills"))
    }

    @Test func originAndGedcomShapes() {
        #expect(Q.detect("trace the family back to Ireland") == .originTrail(person: nil, country: "Ireland", line: .both))
        #expect(Q.detect("trace rick's ancestors back to england") == .originTrail(person: "Rick", country: "England", line: .both))
        #expect(Q.detect("where did the family come from?") == .originTrail(person: nil, country: nil, line: .both))
        #expect(Q.detect("trace my maternal links back to Ireland") == .originTrail(person: nil, country: "Ireland", line: .maternal))
        #expect(Q.detect("trace my paternal links to old puritan boston") == .originTrail(person: nil, country: "Old Puritan Boston", line: .paternal))
        #expect(Q.detect("trace our heritage back") == .originTrail(person: nil, country: nil, line: .both))
        #expect(Q.detect("can you find my family links back to england") == .originTrail(person: nil, country: "England", line: .both))
        #expect(Q.detect("follow rick's line back to scotland") == .originTrail(person: "Rick", country: "Scotland", line: .both))
        #expect(Q.detect("find videos of donna") == nil)
        #expect(Q.detect("find my family") == nil)
        #expect(Q.detect("trace this network route back to Ireland") == nil)
        #expect(Q.detect("family tree of the Ross family") == .surnameTree(surname: "ross"))
        #expect(Q.detect("family tree of the Davis family") == .surnameTree(surname: "davis"))
        #expect(Q.detect("family tree of the Hayes family") == .surnameTree(surname: "hayes"))
        #expect(Q.detect("what is gedcom?") == .gedcomAwareness)
        #expect(Q.detect("where does your family tree come from") == .gedcomAwareness)
    }

    @Test func notOurs() {
        #expect(Q.detect("show me Donna at the Cape in the 90s") == nil)
        #expect(Q.detect("who was rick's father") == nil)
        #expect(Q.detect("how many videos are there") == nil)
        #expect(Q.detect("tell me about David McGill") == nil)
    }
}

@MainActor
@Suite("Lineage — answers and cards")
struct HallieLineageAnswerTests {
    let graph = GedcomFamilyGraph(gedcomText: tree)
    var context: HallieTurnExecutor.Context {
        HallieTurnExecutor.Context(profiles: [], graph: graph, speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
    }

    @Test func maternalLineAnswerCarriesACard() throws {
        let r = try #require(HallieLineageAnswer.answer(.ancestorLine(person: "Rick", line: .maternal, generations: 5), context: context))
        #expect(r.outcome == .answered)
        #expect(r.prose.contains("Eileen Latta"))
        #expect(r.prose.contains("The tree stops there"))
        guard case .lineage(let card)? = r.attachments.first else { Issue.record("no lineage card"); return }
        #expect(card.generations.map(\.label) == ["mother", "grandmother", "great-grandmother"])
        #expect(card.reachedAll == false)
        #expect(HallieAttachmentText.lines(r.attachments).first?.contains("[lineage]") == true)
        #expect(r.offeredActions == [.openFamilyTreePerson(
            personID: "@I1@", personName: "Rick Breen")])
        #expect(HallieAttachmentText.lines(r.attachments)
            .contains { $0.contains("GEDCOM @I1@") })
    }

    @Test func ownerIsUsedWhenNoPersonNamed() throws {
        let r = try #require(HallieLineageAnswer.answer(.ancestorLine(person: nil, line: .paternal, generations: 2), context: context))
        #expect(r.prose.contains("Richard Breen Sr"))
        let noOwner = HallieTurnExecutor.Context(profiles: [], graph: graph, speakers: .none)
        let ask = try #require(HallieLineageAnswer.answer(.ancestorLine(person: nil, line: .paternal, generations: 2), context: noOwner))
        #expect(ask.outcome == .needsClarification)
    }

    @Test func surnameTreeAnswerOrFallsThrough() throws {
        let r = try #require(HallieLineageAnswer.answer(.surnameTree(surname: "latta"), context: context))
        #expect(r.prose.contains("starts with David Latta"))
        #expect(r.prose.contains("Belfast, Ireland"))
        guard case .tree(let card)? = r.attachments.first else { Issue.record("no tree card"); return }
        #expect(card.peopleCount == 4)
        #expect(r.offeredActions == [.openFamilyTreeSurname("Latta")])
        // A person, not a surname → nil so the normal route answers.
        #expect(HallieLineageAnswer.answer(.surnameTree(surname: "donna"), context: context) == nil)
    }

    @Test func spokenPluralSurnameResolvesOnlyAgainstTheGEDCOM() throws {
        let plural = try #require(HallieLineageAnswer.answer(
            .surnameTree(surname: "lattas"), context: context))
        #expect(plural.prose.contains("Latta family"))
        #expect(plural.queryDescription == "family tree: surname Latta")
        #expect(HallieLineageAnswer.resolvedSurname("mcgills", graph: graph) == "McGill")
        #expect(HallieLineageAnswer.resolvedSurname("Davis", graph: graph) == "Davis")
    }

    @Test func originTrailAnswers() throws {
        let r = try #require(HallieLineageAnswer.answer(.originTrail(person: nil, country: "Ireland", line: .both), context: context))
        #expect(r.outcome == .answered)
        #expect(r.prose.contains("David Latta"))
        #expect(r.prose.contains("Belfast, Ireland"))
        let none = try #require(HallieLineageAnswer.answer(.originTrail(person: nil, country: "Italy", line: .both), context: context))
        #expect(none.outcome == .declined)
        #expect(none.prose.contains("nobody born in Italy"))
    }

    @Test func whereDidTheFamilyComeFromAnswersByCountry() throws {
        let r = try #require(HallieLineageAnswer.answer(.originTrail(person: "Rick", country: nil, line: .both), context: context))
        #expect(r.outcome == .answered)
        #expect(r.prose.contains("Ireland (David Latta"))
        #expect(r.prose.contains("Scotland"))
        #expect(!r.prose.contains("Boston"))
        guard case .lineage(let card)? = r.attachments.first else { Issue.record("no trail card"); return }
        #expect(card.generations.flatMap(\.people).count <= 4)
        let us = HallieLineageAnswer.canonicalCountry("USA"); #expect(us.0 == "the United States" && us.1)
        #expect(HallieLineageAnswer.canonicalCountry("MA").1)
        #expect(HallieLineageAnswer.canonicalCountry("Northern Ireland").0 == "Ireland")
    }

    @Test func gedcomAwarenessIsHonestWithAndWithoutATree() {
        let with = HallieLineageAnswer.gedcomAwareness(graph)
        #expect(with.route == .capability)
        #expect(with.prose.contains("10 people and 5 families"))
        let without = HallieLineageAnswer.gedcomAwareness(nil)
        #expect(without.prose.contains("No family tree is loaded"))
    }

    @Test func attachmentsNeverReachThePlan() throws {
        let r = try #require(HallieLineageAnswer.answer(.ancestorLine(person: "Rick", line: .maternal, generations: 3), context: context))
        #expect(r.answerPlan == nil)
        #expect(r.adding(attachments: []).attachments.count == 1)
    }

    /// Scale: a 5,000-generation-deep chain walks in well under a second.
    @Test func deepChainWalksFast() {
        var text = "0 HEAD\n"
        let n = 5_000
        for i in 1...n {
            text += "0 @I\(i)@ INDI\n1 NAME P\(i) /Chain/\n1 SEX F\n"
            if i < n { text += "1 FAMC @F\(i)@\n" }
            if i > 1 { text += "1 FAMS @F\(i - 1)@\n" }
        }
        for i in 1..<n { text += "0 @F\(i)@ FAM\n1 WIFE @I\(i + 1)@\n1 CHIL @I\(i)@\n" }
        let g = GedcomFamilyGraph(gedcomText: text)
        let t0 = Date()
        let gens = g.ancestorLine(of: g.people["@I1@"]!, line: .maternal, generations: 12)
        let trail = g.originTrail(of: g.people["@I1@"]!, country: "Ireland")
        #expect(gens.count == 12)
        #expect(trail.isEmpty)
        #expect(Date().timeIntervalSince(t0) < 0.5)
    }

    // MARK: Get Family Tree (2026-08-25)

    @Test func fetchRequestsRouteToGetFamilyTree() {
        for text in ["get more of the family tree", "Hallie, download the family tree from FamilySearch",
                     "pull my tree from family search", "can you fetch more generations?",
                     "update the family tree", "get the gedcom from familysearch"] {
            #expect(HallieLineageQuestion.detect(text) == .getFamilyTree, Comment(rawValue: text))
        }
    }

    @Test func questionsAboutTheTreeAreNotFetches() {
        #expect(HallieLineageQuestion.detect("what is gedcom?") == .gedcomAwareness)
        #expect(HallieLineageQuestion.detect("show the family tree for the latta family") == .surnameTree(surname: "latta"))
        #expect(HallieLineageQuestion.detect("who are my ancestors") != .getFamilyTree)
        #expect(HallieLineageQuestion.detect("get me a photo of donna") != .getFamilyTree)
    }

    @Test func getFamilyTreeAnswerOffersTheSheetAndChangesNothing() {
        let result = HallieLineageAnswer.getFamilyTreeAnswer(nil)
        #expect(result.outcome == .answered)
        #expect(result.offeredActions == [.getFamilyTree])
        #expect(result.prose.contains("never here"), "the password rule is stated up front")
        #expect(result.basisLine.contains("nothing was downloaded"))
        #expect(HallieTurnExecutor.offerLabel(.getFamilyTree) == "Get Family Tree…")
    }
}
