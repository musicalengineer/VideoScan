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

/// FamilySearch/getmyancestors spelling: the home person first, "Jr"/"Sr"
/// suffixes, middle names, and an ancestor Rick will ask about by name.
private func makeFamilySearchTree(rootFirst: Bool = true) -> String {
    let rick = """
    0 @I1@ INDI
    1 NAME Richard Harding /Breen/ Jr
    1 SEX M
    1 FAMC @F1@
    0 @I2@ INDI
    1 NAME Richard Harding /Breen/ Sr
    1 SEX M
    1 FAMC @F2@
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME George /Breen/
    1 SEX M
    1 FAMS @F2@
    """
    let edith = """
    0 @I4@ INDI
    1 NAME Edith Lucy /Parker/
    1 SEX F
    1 FAMC @F3@
    0 @I5@ INDI
    1 NAME Thomas /Parker/
    1 SEX M
    1 FAMS @F3@
    """
    let fams = """
    0 @F1@ FAM
    1 HUSB @I2@
    1 CHIL @I1@
    0 @F2@ FAM
    1 HUSB @I3@
    1 CHIL @I2@
    0 @F3@ FAM
    1 HUSB @I5@
    1 CHIL @I4@
    0 TRLR
    """
    // Multi-line literals carry no trailing newline — join explicitly.
    return (["0 HEAD"] + (rootFirst ? [rick, edith] : [edith, rick]) + [fams]).joined(separator: "\n")
}
private let familySearchTree = makeFamilySearchTree()

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
        // A kinship phrase in the possessive is NOT a line request (live
        // 2026-08-26: "great great grandpa on his paternal side").
        #expect(Q.detect("tell me about Rick Breen's great great grandpa on his paternal side")
                == .kinship(person: "Rick Breen", relation: .greatGreatGrandfather, side: .paternal))
        #expect(Q.possessor(in: "tell me about rick breen's") == "Rick Breen")
        #expect(Q.possessor(in: "about rick's") == "Rick")
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
        // Since 0d8cbf5c the detector names the person; the ANSWER returns nil
        // for anyone who could have been filmed, so the ask still reaches the
        // translator unchanged (pinned in HalliePhotographyFloorTests).
        #expect(Q.detect("find videos of donna") == .personVideos(person: "Donna"))
        #expect(Q.detect("find my family") == nil)
        #expect(Q.detect("trace this network route back to Ireland") == nil)
        #expect(Q.detect("family tree of the Ross family") == .surnameTree(surname: "ross"))
        #expect(Q.detect("family tree of the Davis family") == .surnameTree(surname: "davis"))
        #expect(Q.detect("family tree of the Hayes family") == .surnameTree(surname: "hayes"))
        #expect(Q.detect("what is gedcom?") == .gedcomAwareness)
        #expect(Q.detect("where does your family tree come from") == .gedcomAwareness)
    }

    /// Live 2026-08-26: all three declined with "I don't find “Rick Breen”"
    /// because "from <name>" was dropped and the owner fell through. The
    /// explicitly named target wins over the kinship apposition ("my great
    /// great grandmother X", "Richard Breen Sr great grandmother X" → X);
    /// "edit" is Rick's typo and is left for the resolver's prefix match.
    @Test func traceFromANamedPersonNamesThatPerson() {
        let deep = HallieLineageQuestion.maxGenerations
        #expect(Q.detect("trace the parker family tree from my great great grandmother edit lucy parker")
                == .ancestorLine(person: "Edit Lucy Parker", line: .both, generations: deep))
        #expect(Q.detect("trace the parker family tree from Richard Breen Sr great grandmother edit lucy parker")
                == .ancestorLine(person: "Edit Lucy Parker", line: .both, generations: deep))
        #expect(Q.detect("trace the parker family tree from edith lucy parker as far back as you can go")
                == .ancestorLine(person: "Edith Lucy Parker", line: .both, generations: deep))
        // Other prepositions, and a destination keeps the origin-trail shape.
        #expect(Q.detect("trace the family starting with david latta back to ireland")
                == .originTrail(person: "David Latta", country: "Ireland", line: .both))
        #expect(Q.detect("trace the ancestors of donna hudson back")
                == .ancestorLine(person: "Donna Hudson", line: .both, generations: deep))
        #expect(Q.detect("show the maternal line from donna back 3 generations")
                == .ancestorLine(person: "Donna", line: .maternal, generations: 3))
        // Possessive and unnamed forms are unchanged (regression).
        #expect(Q.detect("trace rick's ancestors back to england") == .originTrail(person: "Rick", country: "England", line: .both))
        #expect(Q.detect("trace the family back to Ireland") == .originTrail(person: nil, country: "Ireland", line: .both))
        #expect(Q.detect("trace the family tree of the lattas back to ireland") == .originTrail(person: nil, country: "Ireland", line: .both))
        #expect(Q.detect("trace our heritage back as far as you can") == .originTrail(person: nil, country: nil, line: .both))
    }

    @Test func namedTargetHelper() {
        #expect(Q.namedTarget(in: " from my great great grandmother edit lucy parker") == "Edit Lucy Parker")
        #expect(Q.namedTarget(in: "from rick's family") == "Rick")
        #expect(Q.namedTarget(in: "for me") == nil)
        #expect(Q.namedTarget(in: "of the breens") == nil)
        #expect(Q.namedTarget(in: "from my grandmother") == nil)
        #expect(Q.namedTarget(in: "no preposition here") == nil)
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

    /// FamilySearch spelling (live 2026-08-26): the owner is "Rick Breen"
    /// in settings but "Richard Harding /Breen/ Jr" in the tree, with a
    /// "Sr" beside him. No CyberBrain link → the tree root wins and says so.
    @Test func ownerFallsBackToTheTreeRootUnderFamilySearchSpelling() throws {
        let fs = GedcomFamilyGraph(gedcomText: familySearchTree)
        let ctx = HallieTurnExecutor.Context(profiles: [], graph: fs, speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
        let r = try #require(HallieLineageAnswer.answer(.ancestorLine(person: nil, line: .paternal, generations: 2), context: ctx))
        #expect(r.outcome == .answered)
        #expect(r.prose.contains("Richard Harding Breen Sr"))
        #expect(r.basisLine.contains("“you” = Richard Harding Breen Jr (tree root)"))
        #expect(r.offeredActions == [.openFamilyTreePerson(personID: "@I1@", personName: "Richard Harding Breen Jr")])
        // The owner's own name typed resolves the same way as "my".
        let typed = try #require(HallieLineageAnswer.answer(.ancestorLine(person: "Rick Breen", line: .paternal, generations: 2), context: ctx))
        #expect(typed.prose == r.prose)
        // A named target with Rick's typo resolves by unique prefix, not the owner chain.
        let edith = try #require(HallieLineageAnswer.answer(.ancestorLine(person: "Edit Lucy Parker", line: .both, generations: 12), context: ctx))
        #expect(edith.outcome == .answered)
        #expect(edith.prose.contains("Edith Lucy Parker"))
        #expect(edith.prose.contains("Thomas Parker"))
        #expect(!edith.basisLine.contains("“you”"))
    }

    @Test func ownerFallbackAsksWhichOneWhenTheRootIsNotACandidate() throws {
        // Same people, but the file starts with Edith — no root to prefer.
        let fs = GedcomFamilyGraph(gedcomText: makeFamilySearchTree(rootFirst: false))
        #expect(fs.rootPerson?.name == "Edith Lucy Parker")
        let ctx = HallieTurnExecutor.Context(profiles: [], graph: fs, speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
        let r = try #require(HallieLineageAnswer.answer(.ancestorLine(person: nil, line: .paternal, generations: 2), context: ctx))
        #expect(r.outcome == .needsClarification)
        #expect(r.prose.contains("Richard Harding Breen Jr"))
        #expect(r.prose.contains("Richard Harding Breen Sr"))
        // A stranger's name typed never takes the owner chain.
        let stranger = try #require(HallieLineageAnswer.answer(.ancestorLine(person: "Zelda Nobody", line: .both, generations: 2), context: ctx))
        #expect(stranger.outcome == .declined)
        #expect(!stranger.prose.contains("Richard"))
    }

    @Test func resolveOwnerChainDirectly() {
        let fs = GedcomFamilyGraph(gedcomText: familySearchTree)
        guard case .success(let p, let note) = HallieLineageAnswer.resolveOwner("Rick Breen", graph: fs) else { Issue.record("expected root"); return }
        #expect(p.id == "@I1@")
        #expect(note?.contains("tree root") == true)
        guard case .success(let q, let n2) = HallieLineageAnswer.resolveOwner("Nobody Here", graph: fs) else { Issue.record("expected root fallback"); return }
        #expect(q.id == "@I1@")
        #expect(n2?.contains("has no tree record") == true)
        #expect(HallieLineageAnswer.resolveOwner("Nobody", graph: GedcomFamilyGraph(gedcomText: "0 HEAD\n0 TRLR")) == .failure(nil))
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

    // MARK: GEDCOM provenance (live 2026-08-27, asked twice)

    /// "did we only get the gedcom for Rick" is a question about what we
    /// HAVE, not an imperative to download; the fetch verb sits inside an
    /// interrogative/past clause and must not reach the Get Family Tree
    /// pitch.
    @Test func interrogativeFetchClausesAreNotFetches() {
        let live = "can we trace the hudson line from donna or did we only get the gedcom for Rick?"
        #expect(HallieLineageQuestion.detect(live) != .getFamilyTree)
        #expect(HallieLineageQuestion.detect(live) == .gedcomProvenance(person: "Donna", surname: "hudson"))
        #expect(HallieLineageQuestion.detect("did we only get the gedcom for rick")
                == .gedcomProvenance(person: "Rick", surname: nil))
        #expect(HallieLineageQuestion.detect("have we pulled the tree for donna's side")
                == .gedcomProvenance(person: "Donna", surname: nil))
        #expect(HallieLineageQuestion.detect("do we have the gedcom for the hudsons")
                == .gedcomProvenance(person: nil, surname: "hudsons"))
        for text in ["did you get the family tree from familysearch yet", "have you downloaded the gedcom"] {
            #expect(HallieLineageQuestion.detect(text) != .getFamilyTree, Comment(rawValue: text))
        }
        // codex #754: multi-token names, and a name with a suffix.
        #expect(HallieLineageQuestion.detect("can we trace the hudson line from Richard Breen or did we only get the gedcom for Rick")
                == .gedcomProvenance(person: "Richard Breen", surname: "hudson"))
        #expect(HallieLineageQuestion.detect("did we only get the gedcom for richard harding breen jr")
                == .gedcomProvenance(person: "Richard Harding Breen", surname: nil),
                "three name tokens at most; the suffix is the resolver's business")
    }

    /// codex #754: with no person or surname named, the coverage shape
    /// steps aside — awareness reports the file's folder and date.
    @Test func bareWhereDidWeGetTheGedcomStaysOnAwareness() {
        #expect(HallieLineageQuestion.detect("where did we get the gedcom") == .gedcomAwareness)
        #expect(HallieLineageQuestion.detect("Where did we get the GEDCOM?") == .gedcomAwareness)
    }

    /// codex #754: the veto is per clause. A question joined to a request
    /// is still a request.
    @Test func mixedQuestionAndRequestStillFetches() {
        #expect(HallieLineageQuestion.detect("Do we have the GEDCOM, and can you fetch more ancestors?") == .getFamilyTree)
        #expect(HallieLineageQuestion.detect("do we have the gedcom and can you pull the tree from familysearch") == .getFamilyTree)
        #expect(HallieLineageQuestion.detect("Do we have the GEDCOM for Donna?") == .gedcomProvenance(person: "Donna", surname: nil))
    }

    @Test func imperativeFetchesStillRouteToGetFamilyTree() {
        for text in ["get the family tree", "pull more generations",
                     "can you fetch my ancestors from familysearch", "download the gedcom",
                     "could you get the gedcom for donna"] {
            #expect(HallieLineageQuestion.detect(text) == .getFamilyTree, Comment(rawValue: text))
        }
    }

    private func ctx(_ g: GedcomFamilyGraph?) -> HallieTurnExecutor.Context {
        HallieTurnExecutor.Context(profiles: [], graph: g, speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
    }

    @Test func gedcomProvenanceAnswerNamesTheSourceAndCounts() {
        let bare = HallieLineageAnswer.gedcomProvenance(person: nil, surname: nil, context: ctx(graph))
        #expect(bare.route == .graph)
        #expect(bare.outcome == .answered)
        #expect(bare.prose.contains("first record is Rick Breen"), "the root is stated as the assumption it is")
        #expect(bare.prose.contains("I assume it was pulled for Rick Breen"))
        #expect(bare.prose.contains("the file doesn’t say"))
        #expect(!bare.prose.contains("FamilySearch"), "no FS IDs in the fixture → no FamilySearch claim")
        #expect(!bare.prose.contains("rooted"))
        #expect(bare.basisLine.contains("ASSUMED"))
        #expect(bare.prose.contains("comes from a GEDCOM file"), "in-memory graph has no file name")

        // codex #754: a graph that knows its file names it.
        var named = GedcomFamilyGraph(gedcomText: tree)
        named.sourceFileName = "Breen_ancestry_2026-08-25.ged"
        let namedAnswer = HallieLineageAnswer.gedcomProvenance(person: nil, surname: "latta", context: ctx(named))
        #expect(namedAnswer.prose.contains("the GEDCOM file “Breen_ancestry_2026-08-25.ged”"))
        #expect(bare.offeredActions.isEmpty)
        #expect(HallieLineageAnswer.gedcomProvenance(person: nil, surname: nil, context: ctx(nil)).outcome == .declined)

        // Zero surname, connected person: Rick has parents, no Zylstras anywhere.
        let zero = HallieLineageAnswer.gedcomProvenance(person: "Rick", surname: "zylstra", context: ctx(graph))
        #expect(zero.prose.contains("I can trace"))
        #expect(zero.prose.contains("No one in it carries the surname Zylstra"))
        #expect(zero.offeredActions.isEmpty, "the walk succeeded; nothing to fetch")

        // Bare surname, no person: a count, never a traceability claim.
        let count = HallieLineageAnswer.gedcomProvenance(person: nil, surname: "latta", context: ctx(graph))
        #expect(count.prose.contains("carry the surname Latta"))
        #expect(!count.prose.contains("I can trace"))
    }

    /// codex on 0508bdab: surname presence is not a path. The fixture's
    /// Donna Hudson has no parents (as the real one does tonight), and a
    /// second, unrelated Hudson sits elsewhere in the tree. The answer
    /// must not claim her line is traceable; with parents attached it may.
    @Test func gedcomProvenanceNeverClaimsTraceabilityFromSurnameAlone() {
        let strayHudson = tree + """

        0 @I90@ INDI
        1 NAME Ezekiel /Hudson/
        1 SEX M
        1 BIRT
        2 DATE 1840
        """
        let disconnected = GedcomFamilyGraph(gedcomText: strayHudson)
        #expect(disconnected.people(withSurname: "hudson").count == 2)
        let r = HallieLineageAnswer.gedcomProvenance(person: "Donna", surname: "hudson", context: ctx(disconnected))
        #expect(r.prose.contains("Donna is in it"))
        #expect(!r.prose.contains("I can trace"), "no parents → no traceability claim")
        #expect(r.prose.contains("no parents attached"))
        #expect(r.prose.contains("Hudson line stops there"))
        #expect(r.prose.contains("stops there in this tree"))
        #expect(!r.prose.contains("rooted"))
        // The offer is honest about what the sheet does: since 2026-08-27
        // it can Replace OR Add to current tree (merge by FamilySearch ID).
        #expect(r.prose.contains("replace the current tree with it or add it to the current tree by FamilySearch ID"), "the offer is honest about what the sheet does")
        #expect(r.prose.contains("starting a pull from Donna’s record there and adding it"))
        #expect(!r.prose.contains("I can add"), "never promises the tree already has the missing side")
        #expect(r.prose.contains("other Hudson in the tree isn’t connected to Donna"))
        #expect(r.offeredActions == [.getFamilyTree])

        // Attach parents to Donna and the walk earns the claim.
        let withFAMC = strayHudson.replacingOccurrences(of: "1 NAME Donna /Hudson/\n1 SEX F",
                                                         with: "1 NAME Donna /Hudson/\n1 SEX F\n1 FAMC @F90@")
        #expect(withFAMC != strayHudson)
        let connected = GedcomFamilyGraph(gedcomText: withFAMC + """

        0 @I91@ INDI
        1 NAME Walter /Hudson/
        1 SEX M
        1 FAMS @F90@
        0 @I92@ INDI
        1 NAME Ruth /Perry/
        1 SEX F
        1 FAMS @F90@
        0 @F90@ FAM
        1 HUSB @I91@
        1 WIFE @I92@
        1 CHIL @I9@
        """)
        let c = HallieLineageAnswer.gedcomProvenance(person: "Donna", surname: "hudson", context: ctx(connected))
        #expect(c.prose.contains("I can trace 1 generation back from Donna"))
        #expect(c.prose.contains("1 of her recorded ancestors carries the surname Hudson"))
        #expect(c.prose.contains("other Hudson in the tree isn’t among her recorded ancestors"))
        #expect(!c.prose.contains("no parents attached"))
        #expect(c.offeredActions.isEmpty)
    }

    /// codex #754 end-to-end sensor: the live sentence, detector →
    /// answer, on the fixture graph. Never the download pitch again.
    @Test func liveSentenceEndToEndGivesProvenanceNotThePitch() {
        let live = "can we trace the hudson line from donna or did we only get the gedcom for Rick?"
        let q = HallieLineageQuestion.detect(live)
        #expect(q == .gedcomProvenance(person: "Donna", surname: "hudson"))
        let ctx = HallieTurnExecutor.Context(profiles: [], graph: graph,
                                             speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
        let r = HallieLineageAnswer.answer(q!, context: ctx)
        #expect(r?.route == .graph)
        #expect(r?.outcome == .answered)
        #expect(r?.prose.contains("choose how many ancestor steps") == false, "the Get Family Tree pitch")
        #expect(r?.prose.contains("first record is Rick Breen") == true)
        #expect(r?.prose.contains("Donna is in it: Donna Hudson") == true)
        #expect(r?.prose.contains("no parents attached") == true)
        #expect(r?.prose.contains("I can trace") == false)
    }

    /// SCALE (codex #754): the composer scans all people twice and walks
    /// a 60-generation pedigree from every namesake. 100k-person binary
    /// pedigree, one answer, under a second. Parsing is outside the clock.
    @Test func gedcomProvenanceAnswersA100kPersonTreeUnderASecond() {
        var lines = ["0 HEAD"]
        let n = 100_000
        for i in 1...n {
            // i's parents are 2i and 2i+1 (a full binary pedigree), so the
            // walk from anyone near the top reaches ~n/2 records.
            let surname: String
            switch i {
            case 1: surname = "Breen"
            case 3: surname = "Hudson"
            default: surname = i % 200 == 0 ? "Hudson" : "Person\(i % 97)"
            }
            let given = i == 3 ? "Donna" : "Given\(i)"
            lines.append("0 @I\(i)@ INDI")
            lines.append("1 NAME \(given) /\(surname)/")
            lines.append("1 SEX \(i % 2 == 0 ? "M" : "F")")
            lines.append("1 BIRT")
            lines.append("2 DATE \(2000 - 25 * Int(log2(Double(i))))")
            if 2 * i + 1 <= n { lines.append("1 FAMC @F\(i)@") }
            if i > 1 { lines.append("1 FAMS @F\(i / 2)@") }
        }
        for i in 1...n where 2 * i + 1 <= n {
            lines.append("0 @F\(i)@ FAM")
            lines.append("1 HUSB @I\(2 * i)@")
            lines.append("1 WIFE @I\(2 * i + 1)@")
            lines.append("1 CHIL @I\(i)@")
        }
        lines.append("0 TRLR")
        let big = GedcomFamilyGraph(gedcomText: lines.joined(separator: "\n"))
        #expect(big.people.count == n)

        // Build the TreeIndex (CSR) BEFORE starting the answer clock. This mirrors
        // production: the graph Hallie answers against always arrives with its index
        // already built — FamilyGraphFileLoader.parseAndPromote does `_ = graph.index`
        // off-thread, and compiled artifacts carry the index. A text-parsed graph here
        // is lazy, so without this line the ~2.5 s Debug index build would land inside
        // the answer window and the sensor would measure a cost production never pays.
        // The build cost is still watched — separately, with its own Debug budget
        // (measured 2.8 s Debug on M4 Max, 2026-08-28; 5 s leaves room for the M1).
        let tIndex = Date()
        _ = big.index
        let indexElapsed = Date().timeIntervalSince(tIndex)
        #expect(indexElapsed < 5.0, "lazy TreeIndex build for 100k people took \(indexElapsed)s (Debug budget 5 s; measured ~2.8 s on M4 Max)")

        let t0 = Date()
        let r = HallieLineageAnswer.gedcomProvenance(person: "Donna", surname: "hudson", context: ctx(big))
        let elapsed = Date().timeIntervalSince(t0)
        #expect(elapsed < 1.0, "one provenance answer on 100k people (index pre-built) took \(elapsed)s")
        #expect(r.prose.contains("I can trace 15 generations back from Donna"), Comment(rawValue: String(r.prose.prefix(400))))
        #expect(r.prose.contains("of her recorded ancestors carry the surname Hudson"))
        #expect(r.prose.contains("aren’t among her recorded ancestors"), "stray Hudsons are named, not claimed")
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
