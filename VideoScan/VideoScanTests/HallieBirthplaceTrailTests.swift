// HallieBirthplaceTrailTests.swift
// LOGIC for the birthplace trail as Hallie speaks it (2026-09-02): the
// detector table (positives and the routes that must NOT move), the
// read-out list and its endings, the "N generations" answer with its
// path and chip, ties at the nearest generation, ambiguous historical
// names, paging through conversation memory bound to the tree, the
// pronoun subject and subject precedence (codex #1014). Pure: synthetic
// GEDCOM text, no files, no model.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private typealias Q = HallieLineageQuestion
private typealias Exec = HallieTurnExecutor

/// Rick (the owner) married to Donna. Rick's maternal line reaches
/// Scotland at generation 2; Donna's pedigree is the core fixture: the
/// maternal line leaves the US in Canada (gen 2) and reaches France at
/// gen 4 past an unrecorded birthplace; the paternal line has a
/// colonial-era name at gen 2 and reaches Ireland at gen 3.
private let tree = """
0 HEAD
0 @I20@ INDI
1 NAME Rick /Breen/
1 SEX M
1 BIRT
2 DATE 1959
2 PLAC Boston, Massachusetts, USA
1 FAMC @F20@
1 FAMS @F0@
0 @I21@ INDI
1 NAME Richard /Breen/ Sr
1 SEX M
1 BIRT
2 DATE 1929
2 PLAC Boston, Massachusetts, USA
1 FAMS @F20@
0 @I22@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 BIRT
2 DATE 1930
2 PLAC Lowell, Massachusetts, USA
1 FAMC @F22@
1 FAMS @F20@
0 @I23@ INDI
1 NAME Mary /McGill/
1 SEX F
1 BIRT
2 DATE 1904
2 PLAC Glasgow, Scotland
1 FAMS @F22@
0 @I1@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 BIRT
2 DATE 4 APR 1958
2 PLAC Brockton, Massachusetts, USA
1 FAMC @F1@
1 FAMS @F0@
0 @I2@ INDI
1 NAME Bill /Hudson/
1 SEX M
1 BIRT
2 DATE 1930
2 PLAC Wilmington, New Hanover, North Carolina
1 FAMC @F2@
1 FAMS @F1@
0 @I3@ INDI
1 NAME Elaine /Bowser/
1 SEX F
1 BIRT
2 DATE 1934
2 PLAC Stoughton, Massachusetts, USA
1 FAMC @F3@
1 FAMS @F1@
0 @I4@ INDI
1 NAME Sam /Hudson/
1 SEX M
1 BIRT
2 DATE 1900
2 PLAC Shrewsbury, Worcester, Massachusetts Bay Colony, British Colonial America
1 FAMC @F4@
1 FAMS @F2@
0 @I5@ INDI
1 NAME Ida /Hudson/
1 SEX F
1 BIRT
2 DATE 1902
1 FAMS @F2@
0 @I6@ INDI
1 NAME Fred /Bowser/
1 SEX M
1 BIRT
2 DATE 1905
2 PLAC KY
1 FAMS @F3@
0 @I7@ INDI
1 NAME Ethel /Cote/
1 SEX F
1 BIRT
2 DATE 1908
2 PLAC Stukley, Shefford, Quebec, Canada
1 FAMC @F5@
1 FAMS @F3@
0 @I8@ INDI
1 NAME Old /Hudson/
1 SEX M
1 BIRT
2 DATE 1870
2 PLAC County Antrim, Ireland
1 FAMS @F4@
0 @I9@ INDI
1 NAME Jean /Cote/
1 SEX M
1 BIRT
2 DATE 1878
1 FAMS @F5@
0 @I10@ INDI
1 NAME Marie /Cote/
1 SEX F
1 BIRT
2 DATE 1880
1 FAMC @F6@
1 FAMS @F5@
0 @I11@ INDI
1 NAME Anne /Cote/
1 SEX F
1 BIRT
2 DATE 1850
2 PLAC Normandy, France
1 FAMS @F6@
0 @F0@ FAM
1 HUSB @I20@
1 WIFE @I1@
0 @F20@ FAM
1 HUSB @I21@
1 WIFE @I22@
1 CHIL @I20@
0 @F22@ FAM
1 WIFE @I23@
1 CHIL @I22@
0 @F1@ FAM
1 HUSB @I2@
1 WIFE @I3@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I4@
1 WIFE @I5@
1 CHIL @I2@
0 @F3@ FAM
1 HUSB @I6@
1 WIFE @I7@
1 CHIL @I3@
0 @F4@ FAM
1 HUSB @I8@
1 CHIL @I4@
0 @F5@ FAM
1 HUSB @I9@
1 WIFE @I10@
1 CHIL @I7@
0 @F6@ FAM
1 WIFE @I11@
1 CHIL @I10@
0 TRLR
"""

private let outsideUS = LineageTrail.Stop.outsideCountry(BirthplaceClassifier.unitedStates)
private let europe = LineageTrail.Stop.continent(.europe)

/// A maternal chain `depth` generations deep (depth + 1 lines); the
/// anchor is `anchorName`, every birthplace `place(g)`.
private func chain(_ depth: Int, anchorName: String = "Gen0 Chain",
                   place: (Int) -> String? = { "Town\($0), Massachusetts, USA" }) -> GedcomFamilyGraph {
    var lines = ["0 HEAD"]
    for g in 0...depth {
        lines.append("0 @I\(g)@ INDI")
        lines.append("1 NAME \(g == 0 ? anchorName.replacingOccurrences(of: " ", with: " /") + "/" : "Gen\(g) /Chain/")")
        lines.append("1 SEX F")
        lines.append("1 BIRT")
        lines.append("2 DATE \(2000 - 25 * g)")
        if let p = place(g) { lines.append("2 PLAC \(p)") }
        if g < depth { lines.append("1 FAMC @F\(g)@") }
        if g > 0 { lines.append("1 FAMS @F\(g - 1)@") }
    }
    for g in 0..<depth {
        lines.append("0 @F\(g)@ FAM")
        lines.append("1 WIFE @I\(g + 1)@")
        lines.append("1 CHIL @I\(g)@")
    }
    lines.append("0 TRLR")
    return GedcomFamilyGraph(gedcomText: lines.joined(separator: "\n"))
}

/// Three generations: anchor @I1@, father @I2@ / mother @I3@, and the
/// four grandparents @I4@ (father's father), @I5@ (father's mother),
/// @I6@ (mother's father), @I7@ (mother's mother), with the PLAC given
/// (default Boston).
private func pedigree(_ place: [String: String]) -> GedcomFamilyGraph {
    func indi(_ id: String, _ name: String, _ sex: String, famc: String?, fams: String?) -> String {
        var s = "0 @\(id)@ INDI\n1 NAME \(name)\n1 SEX \(sex)\n1 BIRT\n2 DATE 1900\n"
        s += "2 PLAC \(place[id] ?? "Boston, Massachusetts, USA")\n"
        if let famc { s += "1 FAMC @\(famc)@\n" }
        if let fams { s += "1 FAMS @\(fams)@\n" }
        return s
    }
    let text = "0 HEAD\n"
        + indi("I1", "Anchor /Person/", "F", famc: "F1", fams: nil)
        + indi("I2", "Father /Person/", "M", famc: "F2", fams: "F1")
        + indi("I3", "Mother /Person/", "F", famc: "F3", fams: "F1")
        + indi("I4", "Frank /Person/", "M", famc: nil, fams: "F2")
        + indi("I5", "Fay /Person/", "F", famc: nil, fams: "F2")
        + indi("I6", "Milo /Person/", "M", famc: nil, fams: "F3")
        + indi("I7", "Mona /Person/", "F", famc: nil, fams: "F3")
        + "0 @F1@ FAM\n1 HUSB @I2@\n1 WIFE @I3@\n1 CHIL @I1@\n"
        + "0 @F2@ FAM\n1 HUSB @I4@\n1 WIFE @I5@\n1 CHIL @I2@\n"
        + "0 @F3@ FAM\n1 HUSB @I6@\n1 WIFE @I7@\n1 CHIL @I3@\n"
        + "0 TRLR"
    return GedcomFamilyGraph(gedcomText: text)
}

// MARK: - Detection

@Suite("Birthplace trail — detection")
struct HallieBirthplaceTrailDetectionTests {

    fileprivate static let positives: [(String, Q)] = [
        ("trace the birth locations of donna's maternal line",
         .birthplaceTrail(person: "Donna", line: .maternal, stop: .top, ask: .list)),
        ("birthplaces on donna's mother's side",
         .birthplaceTrail(person: "Donna", line: .maternal, stop: .top, ask: .list)),
        ("read out donna's maternal line birthplaces until you get outside the USA",
         .birthplaceTrail(person: "Donna", line: .maternal, stop: outsideUS, ask: .list)),
        ("can you trace the birth locations of donna's maternal line and read them out until you get outside the USA",
         .birthplaceTrail(person: "Donna", line: .maternal, stop: outsideUS, ask: .list)),
        ("how many generations back to find someone born in europe",
         .birthplaceTrail(person: nil, line: .allAncestors, stop: europe, ask: .firstMatch)),
        ("how many generations go back before you get to European birthplaces?",
         .birthplaceTrail(person: nil, line: .allAncestors, stop: europe, ask: .firstMatch)),
        ("Tell me how many generations you need to go back to find someone born in europe then tell me who and where.",
         .birthplaceTrail(person: nil, line: .allAncestors, stop: europe, ask: .firstMatch)),
        ("how far back until donna's ancestors were born in europe",
         .birthplaceTrail(person: "Donna", line: .allAncestors, stop: europe, ask: .firstMatch)),
        ("how far back until rick's ancestors were born overseas",
         .birthplaceTrail(person: "Rick", line: .allAncestors, stop: outsideUS, ask: .firstMatch)),
        ("how far back until my ancestors were born outside the us",
         .birthplaceTrail(person: nil, line: .allAncestors, stop: outsideUS, ask: .firstMatch)),
        ("where did donna's paternal line come from",
         .birthplaceTrail(person: "Donna", line: .paternal, stop: .top, ask: .list)),
        ("first ancestor of donna born outside america",
         .birthplaceTrail(person: "Donna", line: .allAncestors, stop: outsideUS, ask: .firstMatch)),
        ("list the birthplaces of rick breen's paternal line",
         .birthplaceTrail(person: "Rick Breen", line: .paternal, stop: .top, ask: .list)),
        ("read out her maternal line birthplaces",
         .birthplaceTrail(person: "Her", line: .maternal, stop: .top, ask: .list)),
        ("birth places of my mother's side back 6 generations",
         .birthplaceTrail(person: nil, line: .maternal, stop: .generations(6), ask: .list)),
        ("how many generations back to find someone on rick's maternal line born in europe",
         .birthplaceTrail(person: "Rick", line: .maternal, stop: europe, ask: .firstMatch)),
        ("trace my paternal line's birthplaces",
         .birthplaceTrail(person: nil, line: .paternal, stop: .top, ask: .list)),
        ("who was the first ancestor of mine born abroad",
         .birthplaceTrail(person: nil, line: .allAncestors, stop: outsideUS, ask: .firstMatch)),
        ("donna's father's side birthplaces until you reach europe",
         .birthplaceTrail(person: "Donna", line: .paternal, stop: europe, ask: .list)),
        // codex #1014 item 3: a name-capable verb in front of a name is
        // part of the name; an explicit name outranks a later pronoun.
        ("list the birthplaces of will breen's paternal line",
         .birthplaceTrail(person: "Will Breen", line: .paternal, stop: .top, ask: .list)),
        ("will you read out donna's maternal line birthplaces",
         .birthplaceTrail(person: "Donna", line: .maternal, stop: .top, ask: .list)),
        ("how many generations back on donna's maternal line until her ancestors were born in europe",
         .birthplaceTrail(person: "Donna", line: .maternal, stop: europe, ask: .firstMatch)),
        ("how many generations back to find someone in donna's roots born in europe",
         .birthplaceTrail(person: "Donna", line: .allAncestors, stop: europe, ask: .firstMatch)),
        ("how many generations until my ancestors come from europe",
         .birthplaceTrail(person: nil, line: .allAncestors, stop: europe, ask: .firstMatch)),
    ]

    @Test func positives() {
        for (question, expected) in Self.positives {
            #expect(Q.detect(question) == expected, Comment(rawValue: question))
        }
        #expect(Self.positives.count >= 12)
    }

    /// Sentences that must keep the route they had before the trail.
    static let negatives: [String] = [
        "where was donna born",
        "who is donna's mother",
        "how many generations are in the tree",
        "show donna's family tree",
        "show rick's maternal line back 5 generations",
        "where does the family come from",
        "trace the family back to ireland",
        "videos of people born in europe",
        "who was the first person born in massachusetts",
        "where was her maternal grandmother born",
        "how far back does the tree go",
        "trace the migration history of donna's maternal line",
        "trace the birth locations of donna and rick's maternal line",
        "was donna's mother born in europe",
        // codex #1014 item 3: a generations count with Europe but no
        // birth / ancestry cue is not a birthplace question.
        "how many generations back did donna travel to europe",
        "how many generations back did rick move to europe",
        "how far back did the family visit europe",
    ]

    fileprivate static func isTrail(_ q: Q?) -> Bool {
        if case .birthplaceTrail = q { return true }
        if case .birthplaceTrailPage = q { return true }
        return false
    }

    @Test func negativesKeepTheirRoutes() {
        for question in Self.negatives {
            #expect(!Self.isTrail(Q.detect(question)), Comment(rawValue: question))
        }
        #expect(Self.negatives.count >= 8)
        // The exact routes the neighbours keep.
        #expect(Q.detect("show rick's maternal line back 5 generations") == .ancestorLine(person: "Rick", line: .maternal, generations: 5))
        #expect(Q.detect("where does the family come from") == .originTrail(person: nil, country: nil, line: .both))
        #expect(Q.detect("trace the family back to ireland") == .originTrail(person: nil, country: "Ireland", line: .both))
        #expect(Q.detect("who was the first person born in massachusetts") == .superlative(kind: .firstBornIn(place: "Massachusetts"), scope: .wholeTree))
        #expect(Q.detect("where was donna born") == nil)
        #expect(Q.detect("how many generations are in the tree") == nil)
    }

    @Test func subjectExtraction() {
        #expect(Q.trailSubject(in: "trace the birth locations of donna's maternal line") == .named("Donna"))
        #expect(Q.trailSubject(in: "list the birthplaces of richard harding breen jr's paternal line") == .named("Richard Harding Breen Jr"))
        #expect(Q.trailSubject(in: "the birthplaces of aunt mary's maternal line") == .named("Mary"))
        #expect(Q.trailSubject(in: "her maternal line") == .pronoun("Her"))
        #expect(Q.trailSubject(in: "my mother's side") == .owner)
        #expect(Q.trailSubject(in: "first ancestor of me born abroad") == .owner)
        #expect(Q.trailSubject(in: "how many generations back to find someone born in europe") == .owner)
        #expect(Q.trailSubject(in: "the birth locations of donna and rick's maternal line") == .rejected)
        #expect(Q.trailGenerations(in: "back six generations") == 6)
        #expect(Q.trailGenerations(in: "back 30 generations") == LineageTrail.generationCap)
        #expect(Q.trailGenerations(in: "no count here") == nil)
    }

    /// codex #1014 item 3: precedence and names.
    @Test func explicitNameOutranksALaterPronounAndGivenNamesAreNeverStripped() {
        // A possessive name anywhere wins over a later "her".
        #expect(Q.trailSubject(in: "how many generations back on donna's maternal line until her ancestors were born in europe") == .named("Donna"))
        #expect(Q.trailSubject(in: "trace donna's paternal line and her ancestors' birthplaces") == .named("Donna"))
        // A pronoun with no name in the sentence is the previous subject.
        #expect(Q.trailSubject(in: "how far back until her ancestors were born in europe") == .pronoun("Her"))
        // A determiner-led window is not a name.
        #expect(Q.trailSubject(in: "birth places of my mother's side back 6 generations") == .owner)
        #expect(Q.trailSubject(in: "the birthplaces on his mother's side") == .pronoun("His"))
        // "Will" in front of a name word is the name; in front of filler
        // it is the verb.
        #expect(Q.trailSubject(in: "list the birthplaces of will breen's paternal line") == .named("Will Breen"))
        #expect(Q.trailSubject(in: "will you read out donna's maternal line birthplaces") == .named("Donna"))
        #expect(Q.trailSubject(in: "first ancestor of will breen born abroad") == .named("Will Breen"))
        // Ambiguous without capitals: kept whole; the resolver retries
        // without the verb when the tree has no "Will Donna".
        #expect(Q.trailSubject(in: "will donna's maternal line reach europe") == .named("Will Donna"))
        #expect(Q.stripFiller(["trace", "the", "line", "of", "will", "breen"]) == ["will", "breen"])
        #expect(Q.stripFiller(["will", "you", "trace", "donna"]) == ["donna"])
    }

    @Test func continuationParsesOnlyAListTrailAndBindsToTheTree() {
        let listed = "birthplace trail maternal stop=outside:United_States list: Donna Hudson [@I1@] tree=abc123 shown 1-12 of 16"
        #expect(Q.birthplaceTrailContinuation(queryDescription: listed)
                == .birthplaceTrailPage(personID: "@I1@", personName: "Donna Hudson", treeToken: "abc123",
                                        line: .maternal, stop: outsideUS, from: 13))
        let europeTrail = "birthplace trail allAncestors stop=continent:Europe list: Rick Breen [@I20@] tree=abc123 shown 1-3 of 3"
        #expect(Q.birthplaceTrailContinuation(queryDescription: europeTrail)
                == .birthplaceTrailPage(personID: "@I20@", personName: "Rick Breen", treeToken: "abc123",
                                        line: .allAncestors, stop: europe, from: 4))
        #expect(Q.birthplaceTrailContinuation(queryDescription: "birthplace trail maternal stop=top firstMatch: Donna Hudson [@I1@] tree=abc123 shown 1-3 of 3") == nil)
        // The pre-#1014 shape (no tree token) is never continued.
        #expect(Q.birthplaceTrailContinuation(queryDescription: "birthplace trail maternal stop=top list: Donna Hudson [@I1@] shown 1-12 of 16") == nil)
        #expect(Q.birthplaceTrailContinuation(queryDescription: "lineage maternal ×12: Donna Hudson") == nil)
        #expect(Q.birthplaceTrailContinuation(queryDescription: nil) == nil)
        #expect(ArchivistFollowUpResolver.isPagingPhrase("show more"))
        #expect(ArchivistFollowUpResolver.isPagingPhrase("Show me more"))
        #expect(ArchivistFollowUpResolver.isPagingPhrase("next page"))
        #expect(!ArchivistFollowUpResolver.isPagingPhrase("show donna"))

        // Joined two-question descriptions (codex #1014 item 4): the one
        // unfinished read-out is continued, whichever side it is on; two
        // unfinished read-outs are not.
        let other = "lineage: gedcom awareness"
        let finished = "birthplace trail paternal stop=top list: Donna Hudson [@I1@] tree=abc123 shown 1-4 of 4"
        let page13 = Q.birthplaceTrailPage(personID: "@I1@", personName: "Donna Hudson", treeToken: "abc123",
                                           line: .maternal, stop: outsideUS, from: 13)
        #expect(Q.birthplaceTrailContinuation(queryDescription: "two questions: \(listed) + \(other)") == page13)
        #expect(Q.birthplaceTrailContinuation(queryDescription: "two questions: \(other) + \(listed)") == page13)
        #expect(Q.birthplaceTrailContinuation(queryDescription: "two questions: \(listed) + deferred") == page13)
        #expect(Q.birthplaceTrailContinuation(queryDescription: "two questions: \(finished) + \(listed)") == page13)
        #expect(Q.birthplaceTrailContinuation(queryDescription: "two questions: \(listed) + \(listed)") == nil)
        #expect(Q.trailContinuationSegment(in: "two questions: \(listed) + \(listed)") == nil)
        #expect(Q.trailContinuationSegment(in: "two questions: \(finished) + \(finished)") == nil)
    }
}

// MARK: - Answers

@MainActor
@Suite("Birthplace trail — answers")
struct HallieBirthplaceTrailAnswerTests {
    let graph = GedcomFamilyGraph(gedcomText: tree)
    var token: String { HallieLineageAnswer.trailTreeToken(graph) }
    fileprivate var context: Exec.Context {
        Exec.Context(profiles: [], graph: graph,
                     speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
    }
    fileprivate func answer(_ question: String, memory: Exec.ConversationMemory = .init()) -> Exec.Result? {
        guard case .answer(let r) = Exec.preTranslation(
            question: question, playAfterAnswer: false, memory: memory, isKnownPerson: { _ in false },
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context) }) else { return nil }
        return r
    }
    fileprivate static func pre(_ q: String, graph: GedcomFamilyGraph, owner: String,
                                memory: Exec.ConversationMemory) -> Exec.Result? {
        let ctx = Exec.Context(profiles: [], graph: graph,
                               speakers: .init(ownerName: owner, archivistName: nil, archivistPersonName: nil))
        guard case .answer(let r) = Exec.preTranslation(
            question: q, playAfterAnswer: false, memory: memory, isKnownPerson: { _ in false },
            lineageAnswer: { HallieLineageAnswer.answer($0, context: ctx) }) else { return nil }
        return r
    }

    @Test func maternalReadOutStopsOutsideTheUnitedStates() throws {
        let r = try #require(answer("can you trace the birth locations of donna's maternal line and read them out until you get outside the USA"))
        #expect(r.route == .graph)
        #expect(r.outcome == .answered)
        #expect(r.prose == "Here are the birthplaces on Donna Hudson’s maternal line, 2 generations back: "
                + "1. Donna Hudson — 1958, Brockton, Massachusetts, USA. "
                + "2. Elaine Bowser — 1934, Stoughton, Massachusetts, USA. "
                + "3. Ethel Cote — 1908, Stukley, Shefford, Quebec, Canada (first born outside the United States). "
                + "Ethel Cote is the first on that line born outside the United States, so I stopped there.")
        #expect(r.queryDescription == "birthplace trail maternal stop=outside:United_States list: Donna Hudson [@I1@] tree=\(token) shown 1-3 of 3")
        #expect(r.basisLine.contains("colonial names mapped to today’s borders"))
        #expect(r.basisLine.contains("Walk: maternal line; stop: the first birth outside the United States."))
        #expect(r.catalogPersonName == "Donna Hudson")
        #expect(r.answerPlan?.shape == .fixed)
        #expect(r.offeredActions == [.openFamilyTreePerson(personID: "@I1@", personName: "Donna Hudson")])
        guard case .lineage(let card)? = r.attachments.first else { Issue.record("no card"); return }
        #expect(card.generations.map { $0.people[0].name } == ["Elaine Bowser", "Ethel Cote"])
        #expect(card.line == .maternal)
    }

    @Test func maternalReadOutToTheTopReportsTheMissingPlaceAndWhereTheLineEnds() throws {
        let r = try #require(answer("trace the birth locations of donna's maternal line"))
        #expect(r.prose.contains("4. Marie Cote — 1880, birthplace not recorded."))
        #expect(r.prose.contains("5. Anne Cote — 1850, Normandy, France."))
        #expect(r.prose.hasSuffix("The tree records no mother for Anne Cote, so that is where the line ends."))
        #expect(r.prose.contains("4 generations back"))
        #expect(r.queryDescription == "birthplace trail maternal stop=top list: Donna Hudson [@I1@] tree=\(token) shown 1-5 of 5")
    }

    @Test func paternalReadOutToEuropeMarksTheIrishBirth() throws {
        let r = try #require(answer("donna's father's side birthplaces until you reach europe"))
        #expect(r.prose.contains("3. Sam Hudson — 1900, Shrewsbury, Worcester, Massachusetts Bay Colony, British Colonial America."))
        #expect(r.prose.contains("4. Old Hudson — 1870, County Antrim, Ireland (first born in Europe)."))
        #expect(r.prose.hasSuffix("Old Hudson is the first on that line born in Europe, so I stopped there."))
    }

    @Test func aLineWithNoOneOutsideSaysSoAtTheTop() {
        let rick = graph.people["@I20@"]!
        let r = HallieLineageAnswer.trailAnswer(of: rick, isOwner: true, line: .paternal, stop: outsideUS, ask: .list,
                                                from: 1, graph: graph, basisNote: nil)
        #expect(r.prose.hasSuffix("No one on that line is recorded as born outside the United States. The tree records no father for Richard Breen Sr, so that is where the line ends."))
    }

    @Test func generationsQuestionDefaultsToTheOwnerAndNamesThePath() throws {
        let r = try #require(answer("Tell me how many generations you need to go back to find someone born in europe then tell me who and where."))
        #expect(r.outcome == .answered)
        #expect(r.prose == "Two generations. Mary McGill, born 1904 in Glasgow, Scotland, is the first ancestor born in Europe on any line: you → Eileen Latta → Mary McGill.")
        #expect(r.queryDescription == "birthplace trail allAncestors stop=continent:Europe firstMatch: Rick Breen [@I20@] tree=\(token) shown 1-3 of 3")
        // The first chip centers the tree on the ancestor; nothing is performed unasked.
        #expect(r.offeredActions.first == .openFamilyTreePerson(personID: "@I23@", personName: "Mary McGill"))
        #expect(!r.performsFirstOfferedAction)
        #expect(r.answerPlan?.shape == .fixed)
        guard case .lineage(let card)? = r.attachments.first else { Issue.record("no card"); return }
        #expect(card.generations.map { $0.people[0].name } == ["Eileen Latta", "Mary McGill"])
    }

    @Test func generationsQuestionAboutDonnaTakesTheNearestGenerationAndNotesTheColonialName() throws {
        let r = try #require(answer("how far back until donna's ancestors were born in europe"))
        #expect(r.prose == "Three generations. Old Hudson, born 1870 in County Antrim, Ireland, is the first ancestor born in Europe on any line: Donna Hudson → Bill Hudson → Sam Hudson → Old Hudson. (Sam Hudson’s “British Colonial America” is read as today’s United States.)")
        let outside = try #require(answer("first ancestor of donna born outside america"))
        #expect(outside.prose == "Two generations. Ethel Cote, born 1908 in Stukley, Shefford, Quebec, Canada, is the first ancestor born outside the United States on any line: Donna Hudson → Elaine Bowser → Ethel Cote.")
        let maternal = try #require(answer("how many generations back to find someone on donna's maternal line born in europe"))
        #expect(maternal.prose.hasPrefix("Four generations. Anne Cote, born 1850 in Normandy, France, is the first ancestor born in Europe on that line: Donna Hudson → Elaine Bowser → Ethel Cote → Marie Cote → Anne Cote."))
        // The explicit name outranks the later "her" (codex #1014 item 3).
        let precedence = try #require(answer("how many generations back on donna's maternal line until her ancestors were born in europe"))
        #expect(precedence.prose.hasPrefix("Four generations. Anne Cote, born 1850 in Normandy, France, is the first ancestor born in Europe on that line: Donna Hudson →"))
        // No cue at all: not a trail, and never the owner's walk.
        #expect(answer("how many generations back did donna travel to europe")?.queryDescription?.hasPrefix("birthplace trail") != true)
    }

    @Test func generationsQuestionWithNoMatchIsHonestAboutHowFarItWalked() {
        let donna = graph.people["@I1@"]!
        let r = HallieLineageAnswer.trailAnswer(of: donna, isOwner: false, line: .allAncestors, stop: .continent(.asia),
                                                ask: .firstMatch, from: 1, graph: graph, basisNote: nil)
        #expect(r.outcome == .answered)
        #expect(r.prose == "None of Donna Hudson’s recorded ancestors were born in Asia: I walked 4 generations and the tree ends at Anne Cote.")
        #expect(r.attachments.isEmpty)
    }

    @Test func noRecordedParentDeclinesLikeTheLineCard() throws {
        let r = try #require(answer("trace the birth locations of anne cote's maternal line"))
        #expect(r.outcome == .declined)
        #expect(r.prose == "The family tree doesn’t record Anne Cote’s mother, so I can’t trace that line.")
    }

    /// "Will Donna" is nobody; Donna is (codex #1014 item 3).
    @Test func aLeadingVerbThatIsAlsoANameIsRetriedWithoutIt() throws {
        let r = try #require(answer("will donna's maternal line reach europe"))
        #expect(r.outcome == .answered)
        #expect(r.catalogPersonName == "Donna Hudson")
        #expect(r.basisLine.contains("I read “Will Donna” as Donna."))
        #expect(r.prose.hasPrefix("Here are the birthplaces on Donna Hudson’s maternal line"))
        // A real Will is looked up as himself: the tree has none, so the
        // ordinary miss — never "Breen".
        let will = try #require(answer("list the birthplaces of will breen's paternal line"))
        #expect(will.outcome != .answered)
        #expect(will.prose.contains("Will Breen"))
        #expect(!will.prose.contains("“Breen”"))
    }

    @Test func pronounSubjectComesFromTheLastAnswer() throws {
        var memory = Exec.ConversationMemory()
        let first = try #require(answer("trace the birth locations of donna's maternal line"))
        memory.record(intent: nil, result: first, question: "trace the birth locations of donna's maternal line")
        #expect(memory.lastSubject == "Donna Hudson")
        let hers = try #require(answer("read out her paternal line birthplaces", memory: memory))
        #expect(hers.queryDescription == "birthplace trail paternal stop=top list: Donna Hudson [@I1@] tree=\(token) shown 1-4 of 4")
        #expect(hers.prose.contains("2. Bill Hudson — 1930, Wilmington, New Hanover, North Carolina."))
        // With nothing to stand for, Hallie asks — she never looks up "Her".
        let asked = try #require(answer("read out her paternal line birthplaces"))
        #expect(asked.outcome != .answered)
        #expect(!asked.prose.contains("Her"))
    }

    // MARK: Ties (codex #1014 item 2)

    @Test func twoAncestorsAtTheSameDistanceAreBothNamedAndNeitherIsTheFirst() {
        let g = pedigree(["I7": "Normandy, France", "I4": "County Antrim, Ireland"])
        let anchor = g.people["@I1@"]!
        let r = HallieLineageAnswer.trailAnswer(of: anchor, isOwner: false, line: .allAncestors, stop: europe,
                                                ask: .firstMatch, from: 1, graph: g, basisNote: nil)
        #expect(r.prose == "Two generations. Two ancestors born in Europe at that distance: "
                + "Frank Person (born 1900 in County Antrim, Ireland) and Mona Person (born 1900 in Normandy, France). "
                + "Paths: Anchor Person → Father Person → Frank Person; Anchor Person → Mother Person → Mona Person.")
        #expect(!r.prose.contains("the first ancestor"))
        #expect(r.offeredActions == [
            .openFamilyTreePerson(personID: "@I4@", personName: "Frank Person"),
            .openFamilyTreePerson(personID: "@I7@", personName: "Mona Person"),
            .openFamilyTreePerson(personID: "@I1@", personName: "Anchor Person"),
        ])
        guard case .lineage(let card)? = r.attachments.first else { Issue.record("no card"); return }
        #expect(card.title == "Anchor Person’s line to Frank Person (one of 2)")
    }

    @Test func fourTiesNameThreeAndCountTheRest() {
        let g = pedigree(["I4": "Cork, Ireland", "I5": "Glasgow, Scotland",
                          "I6": "Berlin, Prussia", "I7": "Normandy, France"])
        let anchor = g.people["@I1@"]!
        let r = HallieLineageAnswer.trailAnswer(of: anchor, isOwner: true, line: .allAncestors, stop: europe,
                                                ask: .firstMatch, from: 1, graph: g, basisNote: nil)
        #expect(r.prose == "Two generations. Four ancestors born in Europe at that distance: "
                + "Frank Person (born 1900 in Cork, Ireland), Fay Person (born 1900 in Glasgow, Scotland), Milo Person (born 1900 in Berlin, Prussia) and 1 more. "
                + "Paths: you → Father Person → Frank Person; you → Father Person → Fay Person; you → Mother Person → Milo Person.")
        #expect(r.offeredActions.count == 4)
        // A single match keeps the "first ancestor" sentence.
        let one = HallieLineageAnswer.trailAnswer(of: pedigree(["I7": "Normandy, France"]).people["@I1@"]!, isOwner: false,
                                                  line: .allAncestors, stop: europe, ask: .firstMatch, from: 1,
                                                  graph: pedigree(["I7": "Normandy, France"]), basisNote: nil)
        #expect(one.prose == "Two generations. Mona Person, born 1900 in Normandy, France, is the first ancestor born in Europe on any line: Anchor Person → Mother Person → Mona Person.")
    }

    // MARK: Ambiguous names (codex #1014 item 1)

    @Test func aBorderSpanningNameIsReadAsRecordedAndNotCounted() {
        let g = chain(4, anchorName: "Anna Chain") { gen in
            switch gen {
            case 0: return "Boston, Massachusetts, USA"
            case 1: return "Montreal, New France"
            case 2: return "Grand-Pré, Acadia"
            default: return "Cork, Ireland"
            }
        }
        let anna = g.people["@I0@"]!
        let list = HallieLineageAnswer.trailAnswer(of: anna, isOwner: false, line: .maternal, stop: outsideUS,
                                                   ask: .list, from: 1, graph: g, basisNote: nil)
        #expect(list.prose.contains("2. Gen1 Chain — 1975, Montreal, New France (borders changed; not counted)."))
        #expect(list.prose.contains("3. Gen2 Chain — 1950, Grand-Pré, Acadia (borders changed; not counted)."))
        #expect(list.prose.contains("4. Gen3 Chain — 1925, Cork, Ireland (first born outside the United States)."))
        #expect(list.prose.hasSuffix("Gen3 Chain is the first on that line born outside the United States, so I stopped there."))
        #expect(list.basisLine.contains("names that spanned today’s borders are reported but not counted"))

        let first = HallieLineageAnswer.trailAnswer(of: anna, isOwner: false, line: .maternal, stop: outsideUS,
                                                    ask: .firstMatch, from: 1, graph: g, basisNote: nil)
        #expect(first.prose == "Three generations. Gen3 Chain, born 1925 in Cork, Ireland, is the first ancestor born outside the United States on that line: Anna Chain → Gen1 Chain → Gen2 Chain → Gen3 Chain. (Gen1 Chain’s birthplace is recorded as “Montreal, New France” — borders changed; not counted.)")
    }

    // MARK: Paging

    /// 15 generations: 16 lines, so the read-out pages.
    static let longChain = chain(15)

    /// 13 and 14 lines fit one page (the slack); 15 lines page at twelve.
    @Test func aTrailJustOverAPageIsReadInOneBreath() {
        for (depth, onePage) in [(12, true), (13, true), (14, false)] {
            let g = chain(depth)
            let r = HallieLineageAnswer.trailAnswer(of: g.people["@I0@"]!, isOwner: false, line: .maternal, stop: .top,
                                                    ask: .list, from: 1, graph: g, basisNote: nil)
            #expect(r.prose.contains("\(depth + 1). Gen\(depth) Chain") == onePage, Comment(rawValue: "depth \(depth)"))
            #expect(r.prose.contains("say “show more” to continue") == !onePage, Comment(rawValue: "depth \(depth)"))
            #expect(r.queryDescription?.hasSuffix(onePage ? "shown 1-\(depth + 1) of \(depth + 1)" : "shown 1-12 of \(depth + 1)") == true)
        }
    }

    @Test func longTrailPagesThroughConversationMemory() throws {
        let long = Self.longChain
        let tok = HallieLineageAnswer.trailTreeToken(long)
        func pre(_ q: String, memory: Exec.ConversationMemory) -> Exec.Result? {
            Self.pre(q, graph: long, owner: "Gen0 Chain", memory: memory)
        }
        var memory = Exec.ConversationMemory()
        let question = "trace the birth locations of my maternal line"
        let page1 = try #require(pre(question, memory: memory))
        #expect(page1.prose.contains("12. Gen11 Chain — 1725, Town11, Massachusetts, USA."))
        #expect(!page1.prose.contains("13. "))
        #expect(page1.prose.hasSuffix("4 more generations further back — say “show more” to continue."))
        #expect(page1.queryDescription == "birthplace trail maternal stop=top list: Gen0 Chain [@I0@] tree=\(tok) shown 1-12 of 16")
        #expect(page1.offeredActions.contains(.ask(question: "show more", label: "Show more")))
        memory.record(intent: nil, result: page1, question: question)

        let page2 = try #require(pre("show more", memory: memory))
        #expect(page2.prose.hasPrefix("Continuing Gen0 Chain’s maternal line birthplaces, 13 to 16 of 16: 13. Gen12 Chain — 1700, Town12, Massachusetts, USA."))
        #expect(page2.prose.contains("16. Gen15 Chain — 1625, Town15, Massachusetts, USA."))
        #expect(page2.prose.hasSuffix("The tree records no mother for Gen15 Chain, so that is where the line ends."))
        #expect(page2.queryDescription == "birthplace trail maternal stop=top list: Gen0 Chain [@I0@] tree=\(tok) shown 13-16 of 16")
        #expect(!page2.offeredActions.contains(.ask(question: "show more", label: "Show more")))
        memory.record(intent: nil, result: page2, question: "show more")

        let done = try #require(pre("show more", memory: memory))
        #expect(done.prose.hasPrefix("That was the whole trail — 15 generations back from Gen0 Chain."))

        // "show more" with no trail behind it is not ours: the follow-up
        // lane keeps its own answer.
        let cold = pre("show more", memory: .init())
        #expect(cold?.queryDescription?.hasPrefix("birthplace trail") != true)
    }

    /// codex #1014 item 4: a reload that gives @I0@ to someone else, or a
    /// tree that changed under the same names, is refused — never paged.
    @Test func showMoreAfterTheTreeChangedIsRefused() throws {
        let long = Self.longChain
        var memory = Exec.ConversationMemory()
        let page1 = try #require(Self.pre("trace the birth locations of my maternal line", graph: long, owner: "Gen0 Chain", memory: memory))
        #expect(page1.offeredActions.contains(HallieLineageAnswer.trailShowMoreAction))
        memory.record(intent: nil, result: page1, question: "trace the birth locations of my maternal line")

        // Same pointer, another person.
        let reloaded = chain(15, anchorName: "Zed Chain")
        #expect(reloaded.people["@I0@"]?.name == "Zed Chain")
        let stale = try #require(Self.pre("show more", graph: reloaded, owner: "Zed Chain", memory: memory))
        #expect(stale.outcome == .declined)
        #expect(stale.prose == "That list is from an earlier tree; ask again.")
        #expect(stale.queryDescription == "birthplace trail page: tree changed (Gen0 Chain [@I0@])")

        // Same names, a different tree (one more generation): the token
        // differs, so the page is refused too.
        let grown = chain(16)
        #expect(grown.people["@I0@"]?.name == "Gen0 Chain")
        #expect(HallieLineageAnswer.trailTreeToken(grown) != HallieLineageAnswer.trailTreeToken(long))
        let changed = try #require(Self.pre("show more", graph: grown, owner: "Gen0 Chain", memory: memory))
        #expect(changed.prose == "That list is from an earlier tree; ask again.")

        // The same tree parsed again is the same tree: the page continues.
        let same = chain(15)
        #expect(HallieLineageAnswer.trailTreeToken(same) == HallieLineageAnswer.trailTreeToken(long))
        let page2 = try #require(Self.pre("show more", graph: same, owner: "Gen0 Chain", memory: memory))
        #expect(page2.prose.hasPrefix("Continuing Gen0 Chain’s maternal line birthplaces, 13 to 16 of 16:"))
    }

    /// The token prefers the file fingerprint, then the source hashes.
    @Test func treeTokenComesFromTheFingerprintWhenThereIsOne() {
        var g = chain(3)
        let contentToken = HallieLineageAnswer.trailTreeToken(g)
        g.sourceFingerprint = "0123456789abcdef0123456789abcdef"
        #expect(HallieLineageAnswer.trailTreeToken(g) == "0123456789abcdef")
        #expect(contentToken != "0123456789abcdef")
        #expect(!contentToken.isEmpty)
    }

    /// codex #1014 item 4: a two-question turn keeps "show more" working
    /// for the one unfinished trail in it, whichever half it is; two
    /// unfinished trails offer no "show more" at all.
    @Test func showMoreSurvivesAJoinedAnswerWithOneTrail() throws {
        let long = Self.longChain
        let tok = HallieLineageAnswer.trailTreeToken(long)
        for question in ["trace the birth locations of my maternal line? what is gedcom",
                         "what is gedcom? trace the birth locations of my maternal line"] {
            var memory = Exec.ConversationMemory()
            let joined = try #require(Self.pre(question, graph: long, owner: "Gen0 Chain", memory: memory))
            #expect(joined.queryDescription?.hasPrefix("two questions: ") == true, Comment(rawValue: question))
            #expect(joined.queryDescription?.contains("birthplace trail maternal stop=top list: Gen0 Chain [@I0@] tree=\(tok) shown 1-12 of 16") == true)
            #expect(joined.offeredActions.contains(HallieLineageAnswer.trailShowMoreAction), Comment(rawValue: question))
            memory.record(intent: nil, result: joined, question: question)
            let page2 = try #require(Self.pre("show more", graph: long, owner: "Gen0 Chain", memory: memory))
            #expect(page2.prose.hasPrefix("Continuing Gen0 Chain’s maternal line birthplaces, 13 to 16 of 16:"), Comment(rawValue: question))
        }
    }

    @Test func twoUnfinishedTrailsInOneTurnOfferNoShowMore() throws {
        // Anchor with a 15-deep maternal line AND a 15-deep paternal line.
        var lines = ["0 HEAD", "0 @I0@ INDI", "1 NAME Root /Chain/", "1 SEX F", "1 BIRT", "2 DATE 2000",
                     "2 PLAC Town0, Massachusetts, USA", "1 FAMC @F0@"]
        for side in ["P", "M"] {
            for g in 1...15 {
                lines.append("0 @\(side)\(g)@ INDI")
                lines.append("1 NAME \(side)\(g) /Chain/")
                lines.append("1 SEX \(side == "P" ? "M" : "F")")
                lines.append("1 BIRT")
                lines.append("2 DATE \(2000 - 25 * g)")
                lines.append("2 PLAC Town\(g), Massachusetts, USA")
                if g < 15 { lines.append("1 FAMC @F\(side)\(g)@") }
                lines.append("1 FAMS @\(g == 1 ? "F0" : "F\(side)\(g - 1)")@")
            }
        }
        lines.append(contentsOf: ["0 @F0@ FAM", "1 HUSB @P1@", "1 WIFE @M1@", "1 CHIL @I0@"])
        for side in ["P", "M"] {
            for g in 1..<15 {
                lines.append("0 @F\(side)\(g)@ FAM")
                lines.append(side == "P" ? "1 HUSB @P\(g + 1)@" : "1 WIFE @M\(g + 1)@")
                lines.append("1 CHIL @\(side)\(g)@")
            }
        }
        lines.append("0 TRLR")
        let both = GedcomFamilyGraph(gedcomText: lines.joined(separator: "\n"))
        var memory = Exec.ConversationMemory()
        let question = "trace the birth locations of my maternal line? trace the birth locations of my paternal line"
        let joined = try #require(Self.pre(question, graph: both, owner: "Root Chain", memory: memory))
        #expect(joined.queryDescription?.contains("maternal stop=top list: Root Chain [@I0@]") == true)
        #expect(joined.queryDescription?.contains("paternal stop=top list: Root Chain [@I0@]") == true)
        #expect(joined.prose.contains("say “show more” to continue"))
        #expect(!joined.offeredActions.contains(HallieLineageAnswer.trailShowMoreAction))
        memory.record(intent: nil, result: joined, question: question)
        // Not ours: no page is produced.
        let more = Self.pre("show more", graph: both, owner: "Root Chain", memory: memory)
        #expect(more?.queryDescription?.hasPrefix("birthplace trail") != true)
    }

    @Test func trailAnswersRecordTheirQueryDescriptionInMemory() throws {
        var memory = Exec.ConversationMemory()
        let r = try #require(answer("birthplaces on donna's mother's side"))
        memory.record(intent: nil, result: r, question: "birthplaces on donna's mother's side")
        #expect(memory.lastExchange?.queryDescription == r.queryDescription)
        // A complete trail continues to "that was the whole trail", never
        // to a stale page.
        let again = try #require(answer("show more", memory: memory))
        #expect(again.prose.hasPrefix("That was the whole trail — 4 generations back from Donna Hudson."))
    }
}
