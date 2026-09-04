// HallieFragmentGuardTests.swift
// LIVE MISS #10 (Rick, 2026-08-29 13:06): "tell me about Muriel Lamb". The
// reader saw
//   "Muriel Lamb was born in April 1902 in Quebec, Canada [c1]. , Mary
//    Elizabeth Smith, and Sewell Stone Parker [c2]. Muriel married George
//    Breen on October 17, 1925, and they had one child named Richard
//    Harding Breen Sr. [c3][c4]"
// and the log said
//   dropped: untagged — "She was the daughter of … Judson L…"
//   dropped: untagged — "."
//   dropped: c5 — reason: leakedNumber — "… 12,578 ancestors …"
//   coverage: plan=5 cited=4 restored=0 leaked=1 dropped=3
// Three defects in one turn: (a) the sentence splitter treated "L." and
// "Sr." as sentence ends, so the parents sentence lost its tag, a ", Mary …"
// tail shipped as a sentence, and the "." after "[c3][c4]" became a
// sentence of its own; (b) nothing rejected a sentence that opens with
// punctuation, and the fragment's tag counted as coverage for c2; (c)
// "12,578" tokenized as "12" + "578" against a plan that says "12578".
// Pure: stub phraser, no model, no files.

import Foundation
import Testing
@testable import VideoScan

struct HallieFragmentGuardTests {

    private static let murielTreeText = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Muriel /Lamb/
    1 SEX F
    1 BIRT
    2 DATE APR 1902
    2 PLAC Quebec, Canada
    1 FAMC @F1@
    1 FAMS @F2@
    0 @I2@ INDI
    1 NAME Edith Lucy /Parker/
    1 SEX F
    1 FAMC @F3@
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Frederick Burton /Lamb/
    1 SEX M
    1 FAMS @F1@
    0 @I4@ INDI
    1 NAME George /Breen/
    1 SEX M
    1 FAMS @F2@
    0 @I5@ INDI
    1 NAME Richard Harding /Breen/ Sr
    1 SEX M
    1 FAMC @F2@
    0 @I6@ INDI
    1 NAME Clarissa Horton /Schoolcraft/
    1 SEX F
    1 FAMS @F3@
    0 @I7@ INDI
    1 NAME Judson L. /Parker/
    1 SEX M
    1 FAMS @F3@
    0 @F1@ FAM
    1 HUSB @I3@
    1 WIFE @I2@
    1 CHIL @I1@
    0 @F2@ FAM
    1 HUSB @I4@
    1 WIFE @I1@
    1 MARR
    2 DATE 17 OCT 1925
    1 CHIL @I5@
    0 @F3@ FAM
    1 HUSB @I7@
    1 WIFE @I6@
    1 CHIL @I2@
    0 TRLR
    """

    // MARK: - The Muriel Lamb plan, as HallieBiographyCard states it

    private static let claimTexts = [
        "Muriel Lamb was born in April 1902 in Quebec, Canada.",
        "She was the child of Edith Lucy Parker and Frederick Burton Lamb; her recorded grandparents were Clarissa Horton Schoolcraft, Judson L. Parker, Mary Elizabeth Smith and Sewell Stone Parker.",
        // House format (`HallieDateStyle`) — this mirrors what
        // `HallieBiographyCard.marriageClause` actually builds from
        // "2 DATE 17 OCT 1925" above. The fixture said "17 OCT 1925" until
        // 2026-09-03; production has never shown the reader a raw GEDCOM
        // date, and the boundary test above now pins that.
        "She was married to George Breen (married 17 October 1925).",
        "She had 1 recorded child, Richard Harding Breen Sr.",
        "Her family tree includes 12578 recorded ancestors across 18 generations and 2 recorded descendants across 2 generations.",
    ]

    private func plan() -> HallieAnswerPlan {
        HallieAnswerPlan(
            route: .graph, shape: .biography, subject: "Muriel Lamb",
            claims: Self.claimTexts.enumerated().map {
                .init(id: "c\($0 + 1)", text: $1, evidenceIDs: ["@I1@"])
            },
            fallbackText: Self.claimTexts.joined(separator: " "))
    }

    // The live reply, reconstructed from what shipped and what was logged.
    private static let s1 = "Muriel Lamb was born in April 1902 in Quebec, Canada [c1]."
    private static let s2 = "She was the daughter of Edith Lucy Parker and Frederick Burton Lamb, with recorded grandparents including Clarissa Horton Schoolcraft, Judson L., Mary Elizabeth Smith, and Sewell Stone Parker [c2]."
    private static let s34 = "Muriel married George Breen on October 17, 1925, and they had one child named Richard Harding Breen Sr. [c3][c4]."
    private static let s5 = "Her family tree documents 12,578 ancestors across 18 generations and 2 descendants across 2 generations [c5]."

    private func compose(_ reply: String) async -> HallieGroundedComposer.Outcome {
        await HallieGroundedComposer(personaName: "Hallie Mae") { _, _ in reply }
            .compose(plan: plan(), history: [])
    }

    /// The translator is intentionally outside this deterministic fixture;
    /// it is model-backed. Inject its typed biography AST at the production
    /// executor boundary and pin the exact live prompt, graph route, and
    /// decisive facts. The corpus remains the manual end-to-end route check.
    @Test func murielLivePromptTypedBoundaryReturnsTheFullPositiveFactCard() async throws {
        let graph = GedcomFamilyGraph(gedcomText: Self.murielTreeText)
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "tell me about Muriel Lamb",
            ast: .graph(.init(people: ["Muriel Lamb"], operation: .biography))
        )
        let result = try await HallieTurnExecutor.execute(
            .init(intent: intent),
            context: .init(profiles: [], graph: graph)
        )

        #expect(result.route == .graph)
        #expect(result.outcome == .answered)
        #expect(result.catalogPersonName == "Muriel Lamb")
        for fact in [
            "Muriel Lamb was born April 1902 in Quebec, Canada",
            "Edith Lucy Parker",
            "Frederick Burton Lamb",
            "Clarissa Horton Schoolcraft",
            "Judson L. Parker",
            "married to George Breen",
            // The house format at the production boundary (2026-09-03).
            // The GEDCOM says "17 OCT 1925"; the reader is never shown
            // that, and this is what `claimTexts` below must mirror.
            "(married 17 October 1925)",
            "Richard Harding Breen Sr",
        ] {
            #expect(result.prose.contains(fact), Comment(rawValue: "missing \(fact): \(result.prose)"))
        }
        #expect(!result.prose.contains(". ,"))
        #expect(!result.prose.localizedCaseInsensitiveContains("Muriel was not married"))
        #expect(!result.prose.localizedCaseInsensitiveContains("catalog items matching"))
    }

    /// The whole live turn: every claim reaches the reader, nothing is a
    /// fragment, and the coverage line accounts for everything.
    ///
    /// AMENDED 2026-09-03. The 2026-08-29 reply carried a FOURTH defect
    /// nobody noticed at the time: `s34` renders the claim's "17 October
    /// 1925" as "October 17, 1925". Under the old rules a claim's date
    /// vouched for any rendering of the same day, so it shipped — and that
    /// same latitude is what produced four date formats and a misspelled
    /// month in one live answer five days later. It is now `.alteredDate`,
    /// and c3/c4 come back as the plan's own sentences. Every claim still
    /// reaches the reader; the model just does not get to re-type the date.
    @Test func murielLambLiveTurnShipsAllFiveClaimsWithoutFragments() async {
        let outcome = await compose([Self.s1, Self.s2, Self.s34, Self.s5].joined(separator: " "))
        #expect(outcome.composedBy == .model)
        #expect(outcome.dropped.map(\.reason) == [.alteredDate],
                Comment(rawValue: "\(outcome.dropped)"))
        #expect(outcome.restored.map(\.claimID) == ["c3", "c4"],
                Comment(rawValue: "\(outcome.restored)"))
        let sentences = HallieCompositionVerifier.splitSentences(outcome.transcriptText)
        #expect(sentences.map(HallieCompositionVerifier.claimTags) == [["c1"], ["c2"], ["c3"], ["c4"], ["c5"]],
                Comment(rawValue: outcome.transcriptText))
        // The reader still gets all five claims, and the date is the one
        // Swift rendered — not the one the model re-typed.
        #expect(outcome.displayText.contains("(married 17 October 1925)"),
                Comment(rawValue: outcome.displayText))
        #expect(!outcome.displayText.contains("October 17, 1925"))
        #expect(outcome.displayText.contains("Richard Harding Breen Sr"))
        // The three defects this suite was written for are unchanged.
        #expect(!outcome.displayText.contains(" , "))
        #expect(!outcome.displayText.contains("Sr.."))
        #expect(outcome.displayText.contains("12,578 ancestors"))
        let dropLines = HallieGroundedComposer.droppedLogLines(outcome.dropped, plan: plan())
        #expect(dropLines.count == 1)
        #expect(dropLines[0].contains("reason: alteredDate"), Comment(rawValue: dropLines[0]))
    }

    /// The same live turn with the date copied verbatim, which is what the
    /// composer now asks for: nothing dropped, nothing restored, and the
    /// clean coverage line the suite originally pinned.
    @Test func murielLambTurnWithTheDateCopiedVerbatimIsUntouched() async {
        let faithful = Self.s34.replacingOccurrences(
            of: "on October 17, 1925,", with: "on 17 October 1925,")
        let outcome = await compose([Self.s1, Self.s2, faithful, Self.s5].joined(separator: " "))
        #expect(outcome.dropped.isEmpty, Comment(rawValue: "\(outcome.dropped)"))
        #expect(outcome.restored.isEmpty, Comment(rawValue: "\(outcome.restored)"))
        let sentences = HallieCompositionVerifier.splitSentences(outcome.transcriptText)
        #expect(sentences.map(HallieCompositionVerifier.claimTags) == [["c1"], ["c2"], ["c3", "c4"], ["c5"]],
                Comment(rawValue: outcome.transcriptText))
        #expect(!outcome.displayText.contains(" , "))
        #expect(!outcome.displayText.contains("Sr.."))
        let lines = HallieGroundedComposer.verifyLogLines(outcome, plan: plan())
        #expect(lines == ["[hallie-verify] coverage: shape=biography plan=5 cited=5 restored=0 leaked=0 dropped=0"],
                Comment(rawValue: lines.joined(separator: "\n")))
        #expect(HallieGroundedComposer.droppedLogLines(outcome.dropped, plan: plan()).isEmpty)
    }

    /// (b) A fragment that still reaches the verifier — a sentence opening
    /// with a conjunction — is dropped as a fragment, does NOT count as
    /// citing its claim, and the coverage rule restores the plan's sentence.
    @Test func conjunctionFragmentIsDroppedAndItsClaimRestored() async {
        let fragment = "and they had one child named Richard Harding Breen Sr. [c4]."
        let outcome = await compose([Self.s1, Self.s2, fragment, Self.s5].joined(separator: " "))
        #expect(outcome.dropped == [.init(text: fragment, reason: .sentenceFragment)],
                Comment(rawValue: "\(outcome.dropped)"))
        #expect(outcome.restored.map(\.claimID) == ["c3", "c4"])
        #expect(outcome.transcriptText.contains("She had 1 recorded child, Richard Harding Breen Sr. [c4]"),
                Comment(rawValue: outcome.transcriptText))
        #expect(!outcome.displayText.contains("and they had one child"))
        let sentences = HallieCompositionVerifier.splitSentences(outcome.transcriptText)
        #expect(sentences.map(HallieCompositionVerifier.claimTags) == [["c1"], ["c2"], ["c3"], ["c4"], ["c5"]],
                Comment(rawValue: outcome.transcriptText))
        let lines = HallieGroundedComposer.verifyLogLines(outcome, plan: plan())
        #expect(lines.last == "[hallie-verify] coverage: shape=biography plan=5 cited=3 restored=2 leaked=0 dropped=1")
    }

    @Test func punctuationOpenedAndBareTagSentencesAreFragments() {
        let v = HallieCompositionVerifier.verify(
            Self.s1 + "\n, Mary Elizabeth Smith, and Sewell Stone Parker [c2].\n[c5]\n; and more [c3].",
            plan: plan(), personaName: "Hallie Mae")
        #expect(v.kept.map(\.claimIDs) == [["c1"]])
        #expect(v.dropped.map(\.reason) == [.sentenceFragment, .sentenceFragment, .sentenceFragment],
                Comment(rawValue: "\(v.dropped)"))
        #expect(HallieCompositionVerifier.isSentenceFragment("Or so they say."))
        #expect(HallieCompositionVerifier.isSentenceFragment("And they had one child."))
        #expect(!HallieCompositionVerifier.isSentenceFragment("\"Goldilocks\" is her nickname."))
        #expect(!HallieCompositionVerifier.isSentenceFragment("1925 was the year."))
        #expect(!HallieCompositionVerifier.isSentenceFragment("Andrew was there."))
        #expect(!HallieCompositionVerifier.isSentenceFragment("Orville was there."))
    }

    /// (c) "12,578" is "12578". Digits with a real comma-list stay apart.
    @Test func thousandsSeparatorsDoNotLeak() {
        #expect(HallieCompositionVerifier.foldingThousandsSeparators("12,578") == "12578")
        #expect(HallieCompositionVerifier.foldingThousandsSeparators("1,234,567 people") == "1234567 people")
        #expect(HallieCompositionVerifier.foldingThousandsSeparators("June 4, 1961") == "June 4, 1961")
        #expect(HallieCompositionVerifier.foldingThousandsSeparators("3,14") == "3,14")
        #expect(HallieCompositionVerifier.tokens(of: "12,578 ancestors") == ["12578", "ancestors"])
        let v = HallieCompositionVerifier.verify(Self.s5, plan: plan(), personaName: "Hallie Mae")
        #expect(v.dropped.isEmpty, Comment(rawValue: "\(v.dropped)"))
        #expect(v.kept.map(\.claimIDs) == [["c5"]])
        // The reverse: plan says "12,578", model says "12578".
        let commaPlan = HallieAnswerPlan(
            route: .graph, shape: .biography, subject: "Muriel Lamb",
            claims: [.init(id: "c1", text: "Her family tree includes 12,578 recorded ancestors.")],
            fallbackText: "")
        let reverse = HallieCompositionVerifier.verify(
            "Her family tree includes 12578 recorded ancestors [c1].",
            plan: commaPlan, personaName: "Hallie Mae")
        #expect(reverse.dropped.isEmpty)
        // A genuinely different number still leaks.
        let leaky = HallieCompositionVerifier.verify(
            "Her family tree documents 12,579 ancestors [c5].", plan: plan(), personaName: "Hallie Mae")
        #expect(leaky.dropped.map(\.reason) == [.leakedNumber])
    }

    // MARK: - (a) Splitter

    private let split = HallieCompositionVerifier.splitSentences

    @Test func initialsDoNotEndSentences() {
        #expect(split("Her grandparents were Judson L. Parker and Mary Smith [c2]. She married George [c3].") == [
            "Her grandparents were Judson L. Parker and Mary Smith [c2].",
            "She married George [c3].",
        ])
        #expect(split(Self.s2) == [Self.s2])
        #expect(split("Richard H. Breen filmed it [c1]. J. R. Breen did not [c2].") == [
            "Richard H. Breen filmed it [c1].", "J. R. Breen did not [c2].",
        ])
        // "I" is a word, not an initial.
        #expect(split("So did I. She did too [c1].") == ["So did I.", "She did too [c1]."])
        #expect(HallieCompositionVerifier.endsWithAbbreviation("Judson L"))
        #expect(!HallieCompositionVerifier.endsWithAbbreviation("So did I"))
        #expect(!HallieCompositionVerifier.endsWithAbbreviation("Casanov"))
        #expect(!HallieCompositionVerifier.endsWithAbbreviation("born in 1902 in Quebec, Canada [c1]"))
    }

    @Test func suffixesAndTitlesDoNotEndSentences() {
        #expect(split(Self.s34 + " Next [c5].") == [Self.s34, "Next [c5]."])
        #expect(split("Richard Breen Jr. is the son of Richard Breen Sr. [c1]") ==
                ["Richard Breen Jr. is the son of Richard Breen Sr. [c1]"])
        #expect(split("Mrs. Breen met Dr. Smith at St. Mary's [c1]. Mr. Breen was late [c2].") == [
            "Mrs. Breen met Dr. Smith at St. Mary's [c1].", "Mr. Breen was late [c2].",
        ])
        // An abbreviation may still close a sentence when its tags do and a
        // capitalised sentence follows.
        #expect(split("The son was Richard Breen Sr. [c1] He died in 1950 [c2].") == [
            "The son was Richard Breen Sr. [c1]", "He died in 1950 [c2].",
        ])
        // … or when the text ends there.
        #expect(split("The son was Richard Breen Sr. [c1]") == ["The son was Richard Breen Sr. [c1]"])
    }

    @Test func genealogyAbbreviationsAndMonthsDoNotEndSentences() {
        #expect(split("He was b. 1633 in Sudbury [c1]. He d. 1700 [c2].") == [
            "He was b. 1633 in Sudbury [c1].", "He d. 1700 [c2].",
        ])
        #expect(split("She married on Oct. 17, 1925 [c3]. He was born abt. 1900 [c1].") == [
            "She married on Oct. 17, 1925 [c3].", "He was born abt. 1900 [c1].",
        ])
        #expect(split("Born c. 1633, d. Dec. 1700 [c1].") == ["Born c. 1633, d. Dec. 1700 [c1]."])
        // "May" is a word first.
        #expect(split("She came in May. He left [c1].") == ["She came in May.", "He left [c1]."])
    }

    @Test func tagAfterTerminatorKeepsItsOwnTerminatorAndNeverYieldsALoneDot() {
        #expect(split("Yes. [c1]. No. [c2]") == ["Yes. [c1].", "No. [c2]"])
        #expect(split("They had one child, Richard Harding Breen Sr. [c3][c4]. Her tree is deep [c5].") == [
            "They had one child, Richard Harding Breen Sr. [c3][c4].", "Her tree is deep [c5].",
        ])
        for text in ["Yes. [c1].", "Yes. [c1] .", "Yes. .", ". Yes [c1]."] {
            #expect(!split(text).contains("."), Comment(rawValue: "\(split(text))"))
        }
        #expect(HallieCompositionVerifier.stripTags("Richard Harding Breen Sr. [c3][c4].") ==
                "Richard Harding Breen Sr.")
        #expect(HallieCompositionVerifier.stripTags("Yes. [c1]. No. [c2]") == "Yes. No.")
    }

    @Test func quotesStayWithTheirSentence() {
        #expect(split("She said \"hello.\" He left [c1].") == ["She said \"hello.\"", "He left [c1]."])
        #expect(split("“Goldilocks” was her nickname [c1]. \"Yes.\" [c2]") ==
                ["“Goldilocks” was her nickname [c1].", "\"Yes.\" [c2]"])
    }

    @Test func lowercaseAfterPeriodIsNotASentenceEnd() {
        #expect(split("He collected stamps, coins etc. and more [c1]. Then he stopped [c2].") == [
            "He collected stamps, coins etc. and more [c1].", "Then he stopped [c2].",
        ])
        // The existing guarantees still hold.
        #expect(split("It is at 12.5s in the clip [c2]. Really? Yes. [c1]\nNew line [c3]") == [
            "It is at 12.5s in the clip [c2].", "Really?", "Yes. [c1]", "New line [c3]",
        ])
        #expect(split("One of them is Cape_1993.mov [c1]. Another is a.mov [c2].") == [
            "One of them is Cape_1993.mov [c1].", "Another is a.mov [c2].",
        ])
    }

    /// Speech breathes where the verifier splits: an initial is not a breath.
    @Test func speakerSharesTheAbbreviationRule() {
        #expect(HallieSpeaker.sentences(
            "Her grandparents were Judson L. Parker and Mary Smith [c2]. She married George [c3].") == [
            "Her grandparents were Judson L. Parker and Mary Smith.",
            "She married George.",
        ])
        #expect(HallieSpeaker.sentences("Mrs. Breen was b. 1902 in Quebec. So did I. Done.") == [
            "Mrs. Breen was b. 1902 in Quebec.", "So did I.", "Done.",
        ])
    }
}
