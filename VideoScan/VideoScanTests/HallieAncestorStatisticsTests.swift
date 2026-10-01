// HallieAncestorStatisticsTests.swift
// GH #214 / #200 / #218 (Rick approved 2026-10-01). Question → detect →
// answer → prose, on SYNTHETIC trees (public repo: every name is invented).
//
//   • "our / my ancestors" = the owner's AND the partner's lines, with a
//     per-side breakdown and the overlap named; "my own" / "my side" = the
//     owner alone; a named person = that person alone.
//   • every figure states its coverage (how many could be placed / dated).
//   • "earliest ancestor" without a birth word is a ranking (#200).
//   • relationships are NAMED from the lowest common ancestor, half- only
//     when the tree proves it, in-law through a spouse when there is no
//     blood, unknown people refused (#218).
//
// The stats tree is the Core suite's: Alan (owner) married Beth; their lines
// meet at Old Shared, who had Alan's great-grandfather Ed by Sal and Beth's
// father Hank by Joy.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let statsTree = """
0 HEAD
0 @A0@ INDI
1 NAME Alan /Test/
1 SEX M
1 BIRT
2 DATE 1959
2 PLAC Boston, Suffolk, Massachusetts, United States
1 FAMC @FA1@
1 FAMS @FAB@
0 @B0@ INDI
1 NAME Beth /Sample/
1 SEX F
1 BIRT
2 DATE 1961
2 PLAC Hartford, Connecticut, United States
1 FAMC @FB1@
1 FAMS @FAB@
0 @A1@ INDI
1 NAME Carl /Test/
1 SEX M
1 BIRT
2 DATE 1930
2 PLAC Cork, Ireland
1 DEAT
2 DATE 1999
1 FAMC @FA2@
1 FAMS @FA1@
0 @A2@ INDI
1 NAME Dora /Hill/
1 SEX F
1 BIRT
2 DATE 1932
2 PLAC Leeds, Yorkshire, England
1 DEAT
2 DATE 2020
1 FAMC @FA3@
1 FAMS @FA1@
0 @A3@ INDI
1 NAME Ed /Test/
1 SEX M
1 BIRT
2 DATE 1900
2 PLAC Paris, France
1 DEAT
2 DATE ABT 1960
1 FAMC @FA4@
1 FAMS @FA2@
0 @A4@ INDI
1 NAME Fay /Moss/
1 SEX F
1 BIRT
2 DATE 1902
1 DEAT
2 DATE 1999
1 FAMS @FA2@
0 @A5@ INDI
1 NAME Gil /Hill/
1 SEX M
1 BIRT
2 DATE 1890
2 PLAC Boston, Massachusetts
1 DEAT
2 DATE 2015
1 FAMS @FA3@
0 @A6@ INDI
1 NAME Hope /Vale/
1 SEX F
1 FAMS @FA3@
0 @S1@ INDI
1 NAME Old /Shared/
1 SEX M
1 BIRT
2 DATE 1870
2 PLAC Concord, Middlesex, Massachusetts, United States
1 DEAT
2 DATE 1940
1 FAMS @FA4@
1 FAMS @FB2@
0 @S2@ INDI
1 NAME Sal /Quill/
1 SEX F
1 BIRT
2 DATE 1860
2 PLAC Dublin, Ireland
1 FAMS @FA4@
0 @B1@ INDI
1 NAME Hank /Sample/
1 SEX M
1 BIRT
2 DATE 1931
2 PLAC Portland, Maine
1 DEAT
2 DATE 2001
1 FAMC @FB2@
1 FAMS @FB1@
0 @B2@ INDI
1 NAME Ida /Reed/
1 SEX F
1 BIRT
2 DATE 1933
2 PLAC Glasgow, Scotland
1 FAMS @FB1@
0 @S3@ INDI
1 NAME Joy /Lark/
1 SEX F
1 BIRT
2 DATE 1880
2 PLAC Toronto, Ontario, Canada
1 DEAT
2 DATE 1940
1 FAMS @FB2@
0 @FAB@ FAM
1 HUSB @A0@
1 WIFE @B0@
0 @FA1@ FAM
1 HUSB @A1@
1 WIFE @A2@
1 CHIL @A0@
0 @FA2@ FAM
1 HUSB @A3@
1 WIFE @A4@
1 CHIL @A1@
0 @FA3@ FAM
1 HUSB @A5@
1 WIFE @A6@
1 CHIL @A2@
0 @FA4@ FAM
1 HUSB @S1@
1 WIFE @S2@
1 CHIL @A3@
0 @FB1@ FAM
1 HUSB @B1@
1 WIFE @B2@
1 CHIL @B0@
0 @FB2@ FAM
1 HUSB @S1@
1 WIFE @S3@
1 CHIL @B1@
0 TRLR
"""

/// Kinship fixture: Paul (owner) and his sister Pia under Gramps + Gran;
/// Paul married Sue, whose sister Sis is Nell's mother; Pia's daughter Cora
/// married Seth and had Dan. Hal had Xavier by Wendy and Xena by Willa
/// (half-siblings); their children Yara and Yuri are half-first cousins.
private let kinTree = """
0 HEAD
0 @G1@ INDI
1 NAME Gramps /Root/
1 SEX M
1 FAMS @K1@
0 @G2@ INDI
1 NAME Gran /Root/
1 SEX F
1 FAMS @K1@
0 @P1@ INDI
1 NAME Paul /Root/
1 SEX M
1 FAMC @K1@
1 FAMS @K2@
0 @P2@ INDI
1 NAME Pia /Root/
1 SEX F
1 FAMC @K1@
1 FAMS @K3@
0 @S1X@ INDI
1 NAME Sue /Wed/
1 SEX F
1 FAMC @K5@
1 FAMS @K2@
0 @S2X@ INDI
1 NAME Stan /Other/
1 SEX M
1 FAMS @K3@
0 @C1@ INDI
1 NAME Cal /Root/
1 SEX M
1 FAMC @K2@
0 @C2@ INDI
1 NAME Cora /Other/
1 SEX F
1 FAMC @K3@
1 FAMS @K4@
0 @SPC2@ INDI
1 NAME Seth /Spouse/
1 SEX M
1 FAMS @K4@
0 @D2@ INDI
1 NAME Dan /Spouse/
1 SEX M
1 FAMC @K4@
0 @SP1@ INDI
1 NAME Sam /Wed/
1 SEX M
1 FAMS @K5@
0 @SP2@ INDI
1 NAME Sara /Wed/
1 SEX F
1 FAMS @K5@
0 @SIS@ INDI
1 NAME Sis /Wed/
1 SEX F
1 FAMC @K5@
1 FAMS @K6@
0 @N@ INDI
1 NAME Nell /Niece/
1 SEX F
1 FAMC @K6@
0 @H@ INDI
1 NAME Hal /Half/
1 SEX M
1 FAMS @K7@
1 FAMS @K8@
0 @W1@ INDI
1 NAME Wendy /One/
1 SEX F
1 FAMS @K7@
0 @W2@ INDI
1 NAME Willa /Two/
1 SEX F
1 FAMS @K8@
0 @X1@ INDI
1 NAME Xavier /Half/
1 SEX M
1 FAMC @K7@
1 FAMS @K9@
0 @X2@ INDI
1 NAME Xena /Half/
1 SEX F
1 FAMC @K8@
1 FAMS @K10@
0 @Y1@ INDI
1 NAME Yara /Half/
1 SEX F
1 FAMC @K9@
0 @Y2@ INDI
1 NAME Yuri /Half/
1 SEX M
1 FAMC @K10@
0 @K1@ FAM
1 HUSB @G1@
1 WIFE @G2@
1 CHIL @P1@
1 CHIL @P2@
0 @K2@ FAM
1 HUSB @P1@
1 WIFE @S1X@
1 CHIL @C1@
0 @K3@ FAM
1 HUSB @S2X@
1 WIFE @P2@
1 CHIL @C2@
0 @K4@ FAM
1 HUSB @SPC2@
1 WIFE @C2@
1 CHIL @D2@
0 @K5@ FAM
1 HUSB @SP1@
1 WIFE @SP2@
1 CHIL @S1X@
1 CHIL @SIS@
0 @K6@ FAM
1 WIFE @SIS@
1 CHIL @N@
0 @K7@ FAM
1 HUSB @H@
1 WIFE @W1@
1 CHIL @X1@
0 @K8@ FAM
1 HUSB @H@
1 WIFE @W2@
1 CHIL @X2@
0 @K9@ FAM
1 HUSB @X1@
1 CHIL @Y1@
0 @K10@ FAM
1 WIFE @X2@
1 CHIL @Y2@
0 TRLR
"""

@Suite("HallieAncestorStatistics")
struct HallieAncestorStatisticsTests {
    private typealias Exec = HallieTurnExecutor
    private typealias Q = HallieAncestorStatisticsQuestion

    private func answer(_ question: String, tree: String = statsTree, owner: String = "Alan Test") -> Exec.Result? {
        let context = Exec.Context(profiles: [], graph: GedcomFamilyGraph(gedcomText: tree),
                                   speakers: .init(ownerName: owner, archivistName: nil, archivistPersonName: nil))
        guard case .answer(let r) = Exec.preTranslation(
            question: question, playAfterAnswer: false, memory: .init(), isKnownPerson: { _ in false },
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context) }) else { return nil }
        return r
    }

    // MARK: Recognition

    @Test func rickSentencesAreRecognizedWithTheirScope() {
        #expect(Q.detect("how many of our ancestors were born in New England vs Old England?")
                == .birthplaces(who: .ours, places: [
                    .init(label: "New England", place: .regions([.newEngland])),
                    .init(label: "Old England", place: .regions([.england]))]))
        #expect(Q.detect("how many of my ancestors were born in new england, england, ireland or france")?.who == .ours,
                "Rick's 'my ancestors' is both lines (#214)")
        #expect(Q.detect("how many of my own ancestors were born in ireland")?.who == .owner)
        #expect(Q.detect("how many of donna's ancestors were born in ireland")?.who == .person("Donna"))
        #expect(Q.detect("how many ancestors of beth sample were born in ireland")?.who == .person("Beth Sample"))
        #expect(Q.detect("what was the average age at death of our ancestors") == .ageAtDeath(who: .ours))
        #expect(Q.detect("what is the average age at death on donna's side") == .ageAtDeath(who: .person("Donna")))
        #expect(Q.detect("what is our deepest line") == .deepestLine(who: .ours))
        #expect(Q.detect("how many generations back does our tree go") == .deepestLine(who: .ours))
        // #200 item 1 — no birth word.
        #expect(Q.detect("who is the earliest ancestor in my family tree") == .earliest(who: .ours))
        #expect(Q.detect("who is donna's earliest known ancestor") == .earliest(who: .person("Donna")))
    }

    @Test func constraintsItCannotHoldAbstain() {
        #expect(Q.detect("how many of our ancestors were born in massachusetts") == nil, "a state is the whole-tree route's recorded text")
        #expect(Q.detect("how many of our ancestors were born before 1800") == nil, "a time filter")
        #expect(Q.detect("how many of our ancestors were born in europe") == nil, "a continent")
        #expect(Q.detect("how many of our ancestors were born outside the us") == nil)
        #expect(Q.detect("how many of my maternal ancestors were born in ireland") == nil, "a side")
        #expect(Q.detect("how many of our ancestors were born in ruritania") == nil, "an unknown place")
        #expect(Q.detect("how many people in the tree were born in ireland") == nil, "not an ancestor scope")
        #expect(Q.detect("who was our first ancestor to come to america") == nil, "an immigration question")
        #expect(Q.detect("who is our earliest ancestor born in ireland") == nil, "the superlative reader's")
        #expect(Q.detect("what is the average lifespan of people in the tree") == nil)
        #expect(Q.detect("how many generations back to ireland") == nil, "the birthplace trail's")
        #expect(Q.detect("tell me about our ancestors") == nil)
    }

    @Test func routingPutsTheseBeforeTheWholeTreeRecognizer() {
        guard case .ancestorStatistics? = HallieLineageQuestion.detect("how many of our ancestors were born in new england vs old england") else {
            Issue.record("expected the ancestor-line route"); return
        }
        guard case .treeStatistics? = HallieLineageQuestion.detect("how many of our ancestors were born before 1900") else {
            Issue.record("a time filter stays with the whole-tree recognizer"); return
        }
        // REGRESSION (found 2026-10-01): the router's year-bound peel ate
        // "before 1800" before the statistics recognizer saw it, so the
        // count became everyone. The year must survive as a filter.
        guard case .treeStatistics(let tree)? = HallieLineageQuestion.detect("how many people were born before 1800") else {
            Issue.record("expected tree statistics"); return
        }
        #expect(tree.query.time.bornTo == 1799)
        guard case .treeStatistics(let ours)? = HallieLineageQuestion.detect("how many of our ancestors were born before 1900") else {
            Issue.record("expected tree statistics"); return
        }
        #expect(ours.query.time.bornTo == 1899)
        // The existing superlatives keep their phrasings.
        #expect(HallieLineageQuestion.detect("who is the oldest of my ancestors") == .superlative(kind: .earliestBorn, scope: .ancestorsOf(nil)))
    }

    // MARK: Answers — both sides, coverage stated

    @Test func newEnglandVsOldEnglandAcrossBothSides() throws {
        let r = try #require(answer("how many of our ancestors were born in New England vs Old England?"))
        #expect(r.outcome == .answered)
        #expect(r.prose.hasPrefix("Of our 11 recorded ancestors (your side 8, Beth’s side 4; 1 is on both), 9 have a birthplace I can place (your side 6 of 8, Beth’s side 4 of 4)."), Comment(rawValue: r.prose))
        #expect(r.prose.contains("New England: 3 (your side 2, Beth’s side 2)."), Comment(rawValue: r.prose))
        #expect(r.prose.contains("Old England: 1 (your side 1, Beth’s side 0)."), Comment(rawValue: r.prose))
        #expect(r.prose.contains("New England outnumbers Old England 3 to 1."), Comment(rawValue: r.prose))
        #expect(r.prose.contains("5 more were born somewhere else."), Comment(rawValue: r.prose))
        #expect(r.prose.contains("2 have no birthplace I can place"), Comment(rawValue: r.prose))
        #expect(r.basisLine.contains("Alan Test and Beth Sample"), Comment(rawValue: r.basisLine))
        #expect(r.basisLine.contains("your spouse"), Comment(rawValue: r.basisLine))
    }

    @Test func irelandAndFranceAndTheRest() throws {
        let r = try #require(answer("how many of my ancestors were born in ireland or france"))
        #expect(r.prose.contains("Ireland: 2 (your side 2, Beth’s side 0)."), Comment(rawValue: r.prose))
        #expect(r.prose.contains("France: 1 (your side 1, Beth’s side 0)."), Comment(rawValue: r.prose))
    }

    @Test func myOwnLineAndANamedPersonAreOneSide() throws {
        let mine = try #require(answer("how many of my own ancestors were born in ireland"))
        #expect(mine.prose.hasPrefix("2 of your 8 recorded ancestors were born in Ireland."), Comment(rawValue: mine.prose))
        #expect(mine.prose.contains("Of the 8, 6 have a birthplace I can place; 2 have no birthplace"), Comment(rawValue: mine.prose))
        let beth = try #require(answer("how many of beth's ancestors were born in new england"))
        #expect(beth.prose.hasPrefix("2 of Beth Sample’s 4 recorded ancestors were born in New England."), Comment(rawValue: beth.prose))
        // The owner's own name is the owner alone (#200).
        let alan = try #require(answer("how many of alan's ancestors were born in ireland"))
        #expect(alan.prose.hasPrefix("2 of your 8 recorded ancestors"), Comment(rawValue: alan.prose))
    }

    @Test func averageAgeAtDeathSaysWhatWasLeftOut() throws {
        let r = try #require(answer("what was the average age at death of our ancestors"))
        #expect(r.prose.hasPrefix("Across the 6 of our 11 recorded ancestors"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("the average age at death is 75.2 and the median 69.5 (your side 80.5 over 4, Beth’s side 66.2 over 3)."), Comment(rawValue: r.prose))
        #expect(r.prose.contains("The longest proven life is Fay Moss"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("who died at 96 or 97."), Comment(rawValue: r.prose))
        #expect(r.prose.contains("Left out: 3 with no birth or death date, 1 whose dates are too vague to pin an age, and 1 recorded age over 110"), Comment(rawValue: r.prose))
    }

    @Test func deepestLinePerSideWithTheLine() throws {
        let r = try #require(answer("what is our deepest line"))
        #expect(r.prose.contains("Your deepest recorded line goes back 3 generations, to Sal Quill"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("— your great-grandmother, through Ed Test → Carl Test."), Comment(rawValue: r.prose))
        #expect(r.prose.contains("1 other ancestor sits that far back too."), Comment(rawValue: r.prose))
        #expect(r.prose.contains("Beth’s deepest recorded line goes back 2 generations, to Old Shared"), Comment(rawValue: r.prose))
        #expect(r.offeredActions.contains(.openFamilyTreePerson(personID: "@S2@", personName: "Sal Quill")))
    }

    @Test func earliestAncestorWithoutABirthWord() throws {
        let r = try #require(answer("who is the earliest ancestor in my family tree"))
        #expect(r.prose.hasPrefix("The earliest recorded birth among our 11 recorded ancestors"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("is Sal Quill, born 1860 — your great-grandmother."), Comment(rawValue: r.prose))
        #expect(r.prose.contains("10 of the 11 have a birth year; the other 1 can’t be ranked."), Comment(rawValue: r.prose))
        #expect(r.prose.contains("On Beth’s side the earliest is Old Shared, born 1870."), Comment(rawValue: r.prose))
    }

    @Test func aTimeFilterGoesToTheWholeTreeEngineStillOverBothSides() throws {
        let r = try #require(answer("how many of our ancestors were born before 1900"))
        #expect(r.prose.hasPrefix("4 of our 11 recorded ancestors were born before 1900 (your side 3 of 8, Beth’s side 2 of 4)."), Comment(rawValue: r.prose))
    }

    @Test func unknownPeopleAreRefusedNotCounted() throws {
        let r = try #require(answer("how many of zebulon quackenbush's ancestors were born in ireland"))
        #expect(r.outcome != .answered, Comment(rawValue: r.prose))
        #expect(!r.prose.contains("recorded ancestors"), Comment(rawValue: r.prose))
    }

    @Test func noPartnerMeansTheOwnersLineAndSaysSo() throws {
        // Paul's tree: one spouse (Sue) — but ask from Cal, who has none.
        let r = try #require(answer("what is our deepest line", tree: kinTree, owner: "Cal Root"))
        #expect(r.prose.hasPrefix("Your deepest recorded line goes back 2 generations"), Comment(rawValue: r.prose))
        #expect(r.basisLine.contains("no spouse for you"), Comment(rawValue: r.basisLine))
    }

    // MARK: Relationship names (#218)

    @Test func howAmIRelatedNamesTheRelationship() throws {
        let r = try #require(answer("how am I related to Dan Spouse", tree: kinTree, owner: "Paul Root"))
        #expect(r.outcome == .answered)
        #expect(r.prose.contains("So Dan Spouse is your great-nephew."), Comment(rawValue: r.prose))
    }

    @Test func halfBloodIsNamedWithBothPartners() throws {
        let r = try #require(answer("how is Yuri Half related to Yara Half", tree: kinTree, owner: "Paul Root"))
        #expect(r.prose.contains("making them half-1st cousins."), Comment(rawValue: r.prose))
        #expect(r.prose.contains("So Yara Half is Yuri Half’s half-first cousin — the two lines come down from Hal Half through different partners, Willa Two and Wendy One."), Comment(rawValue: r.prose))
    }

    @Test func noBloodButAMarriageIsTheInLawPath() throws {
        let r = try #require(answer("how am I related to Nell Niece", tree: kinTree, owner: "Paul Root"))
        #expect(r.outcome == .answered)
        #expect(r.prose.hasPrefix("Nell Niece isn’t related to you by blood in the tree, but she is your wife Sue Wed’s niece."), Comment(rawValue: r.prose))
        // Seth has no parents in the tree, so blood kinship is unknown: the
        // honest decline stands and the marriage is its aside.
        let married = try #require(answer("how am I related to Seth Spouse", tree: kinTree, owner: "Paul Root"))
        #expect(married.outcome == .declined, Comment(rawValue: married.prose))
        #expect(married.prose.contains("isn’t in the tree yet"), Comment(rawValue: married.prose))
        #expect(married.prose.contains("(Seth Spouse is married to your niece, Cora Other.)"), Comment(rawValue: married.prose))
    }

    @Test func aPersonTheTreeDoesNotKnowIsNotGuessed() throws {
        let r = answer("how am I related to Zebulon Quackenbush", tree: kinTree, owner: "Paul Root")
        #expect(r == nil || r?.outcome != .answered, Comment(rawValue: r?.prose ?? "nil"))
    }

    // MARK: QA findings on 989d5a5c (2026-10-01), red-first

    /// P2-4: shapes the earliest / deepest readers cannot hold abstain.
    @Test func qaConstraintsTheEarliestAndDeepestShapesCannotHoldAbstain() {
        for q in [
            "who was our first ancestor to fight in the revolution",
            "who was the first ancestor to serve in the civil war",
            "who was our first ancestor to go to college",
            "who is our earliest ancestor we have a picture of",
            "who was our first ancestor with a will",
            "how many generations back does the quill line go",
            "how many generations back can we go on the lark side",
            "how many generations back does our line go in ireland",
            "who is the earliest ancestor of the quill family",
        ] {
            #expect(Q.detect(q) == nil, Comment(rawValue: "\(q) → \(String(describing: Q.detect(q)))"))
        }
    }

    /// P3-2: a kin or sex word is not a person's name — abstain on both
    /// statistics routes rather than count "My Mom" or the whole tree.
    @Test func kinAndSexWordsAreNotReadAsPeople() {
        for q in ["how many of my mom's ancestors were born in ireland",
                  "what is my mom's deepest line",
                  "how many of our female ancestors were born in ireland",
                  "what was the average age at death of my father's ancestors"] {
            #expect(Q.detect(q) == nil, Comment(rawValue: "\(q) → \(String(describing: Q.detect(q)))"))
            #expect(HallieTreeStatisticsQuestion.detect(q) == nil, Comment(rawValue: "whole-tree route: \(q)"))
        }
    }

    /// P3-3: two records of one spouse are ONE spouse; a spouse who is the
    /// tree's home person wins over an ex.
    @Test func partnerSelectionIgnoresDuplicateRecordsAndPrefersTheHomeRoot() throws {
        let dup = """
        0 HEAD
        0 @O@ INDI
        1 NAME Ole /Dup/
        1 SEX M
        1 FAMC @FP@
        1 FAMS @F1@
        1 FAMS @F2@
        0 @PA@ INDI
        1 NAME Pa /Dup/
        1 SEX M
        1 FAMS @FP@
        0 @S1@ INDI
        1 NAME Ina /Same/
        1 SEX F
        1 BIRT
        2 DATE 1950
        1 FAMS @F1@
        0 @S2@ INDI
        1 NAME Ina /Same/
        1 SEX F
        1 BIRT
        2 DATE 1950
        1 FAMS @F2@
        0 @FP@ FAM
        1 HUSB @PA@
        1 CHIL @O@
        0 @F1@ FAM
        1 HUSB @O@
        1 WIFE @S1@
        0 @F2@ FAM
        1 HUSB @O@
        1 WIFE @S2@
        0 TRLR
        """
        let r = try #require(answer("what is our deepest line", tree: dup, owner: "Ole Dup"))
        #expect(r.basisLine.contains("Ina Same, your spouse"), Comment(rawValue: r.basisLine))
        let ex = """
        0 HEAD
        1 _VS_ROOT @R@
        0 @O@ INDI
        1 NAME Ole /Wed/
        1 SEX M
        1 FAMC @FP@
        1 FAMS @F1@
        1 FAMS @F2@
        0 @PA@ INDI
        1 NAME Pa /Wed/
        1 SEX M
        1 FAMS @FP@
        0 @E@ INDI
        1 NAME Eve /Ex/
        1 SEX F
        1 FAMS @F1@
        0 @R@ INDI
        1 NAME Rae /Root/
        1 SEX F
        1 FAMS @F2@
        0 @FP@ FAM
        1 HUSB @PA@
        1 CHIL @O@
        0 @F1@ FAM
        1 HUSB @O@
        1 WIFE @E@
        0 @F2@ FAM
        1 HUSB @O@
        1 WIFE @R@
        0 TRLR
        """
        let r2 = try #require(answer("what is our deepest line", tree: ex, owner: "Ole Wed"))
        #expect(r2.basisLine.contains("Rae Root"), Comment(rawValue: r2.basisLine))
    }

    /// P3-4: a BEF / AFT birth is "before" / "after", never "around".
    @Test func boundedBirthDatesSayBeforeOrAfter() throws {
        let tree = """
        0 HEAD
        0 @K@ INDI
        1 NAME Kim /Bound/
        1 SEX F
        1 FAMC @F@
        0 @L@ INDI
        1 NAME Lou /Bound/
        1 SEX M
        1 BIRT
        2 DATE BEF 1700
        1 FAMS @F@
        0 @V@ INDI
        1 NAME Liv /Bound/
        1 SEX F
        1 BIRT
        2 DATE AFT 1720
        1 FAMS @F@
        0 @F@ FAM
        1 HUSB @L@
        1 WIFE @V@
        1 CHIL @K@
        0 TRLR
        """
        let r = try #require(answer("who is the earliest ancestor in my family tree", tree: tree, owner: "Kim Bound"))
        #expect(r.prose.contains("is Lou Bound, born before 1700"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("around"), Comment(rawValue: r.prose))
    }

    /// P3-5: the marriage answer has a pronoun ("he is married to …").
    @Test func theMarriageAnswerHasAPronoun() throws {
        let tree = """
        0 HEAD
        0 @A@ INDI
        1 NAME Ari /Out/
        1 SEX M
        1 FAMC @FA@
        0 @AP@ INDI
        1 NAME Abe /Out/
        1 SEX M
        1 FAMS @FA@
        0 @B@ INDI
        1 NAME Bo /In/
        1 SEX M
        1 FAMC @FB@
        1 FAMS @FS@
        0 @BP@ INDI
        1 NAME Bud /In/
        1 SEX M
        1 FAMS @FB@
        0 @D@ INDI
        1 NAME Dee /Out/
        1 SEX F
        1 FAMC @FA@
        1 FAMS @FD@
        0 @C@ INDI
        1 NAME Cy /Out/
        1 SEX F
        1 FAMC @FD@
        1 FAMS @FS@
        0 @FA@ FAM
        1 HUSB @AP@
        1 CHIL @A@
        1 CHIL @D@
        0 @FD@ FAM
        1 WIFE @D@
        1 CHIL @C@
        0 @FB@ FAM
        1 HUSB @BP@
        1 CHIL @B@
        0 @FS@ FAM
        1 HUSB @B@
        1 WIFE @C@
        0 TRLR
        """
        let r = try #require(answer("how am I related to Bo In", tree: tree, owner: "Ari Out"))
        #expect(r.prose.hasPrefix("Bo In isn’t related to you by blood in the tree, but he is married to your niece, Cy Out."), Comment(rawValue: r.prose))
    }
}
