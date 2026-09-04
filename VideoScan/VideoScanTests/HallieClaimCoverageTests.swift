// HallieClaimCoverageTests.swift
// LIVE MISS (Rick, 2026-08-29 11:10, main eb83efae): "tell me about matthew
// rice" — the 6-claim HallieBiographyCard plan came back from the phrasing
// model citing [c1][c2][c4][c5][c6]. c3 (siblings) was silently dropped;
// the verifier only removes, and the only restore rules knew about the
// list count sentence and life dates. Contract (deterministic composer
// 8/14, grounded composition 8/17): every claim in a fixed plan reaches the
// reader, cited, or is restored deterministically; the model may only
// phrase and order. This suite pins the coverage rule
// (HallieGroundedComposer.restoringMissingClaims): missing claims come back
// verbatim in PLAN ORDER; a reorder restores nothing; a leak-dropped claim
// stays out (leak wins); the biography budget never undercuts the claim
// count; app and shell see the same outcome and the same log lines.
// Pure: a stub phraser, no model, no files.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

struct HallieClaimCoverageTests {

    /// The Matthew Rice card as HallieBiographyCard states it (one claim
    /// per sentence, c1 vitals … c6 depth).
    private static let claimTexts = [
        "Matthew Rice was born on 28 February 1629 in Great Berkhampstead, Hertfordshire, England, and died before 29 November 1717 in Sudbury, Middlesex, Massachusetts Bay Colony.",
        "He was the child of Edmund Rice and Thomasine Frost; his recorded grandparents were Edward Frost I and Thomasina Belgrave.",
        "He had 2 recorded siblings, Henry Rice and Edward Rice.",
        "He married Martha Lamson on 7 July 1654.",
        "He had 2 recorded children, Isaac Rice and Patience Rice.",
        "His family tree includes 83 recorded ancestors across 11 generations and 27 recorded descendants across 11 generations.",
    ]

    private func plan(claimCount: Int = 6) -> HallieAnswerPlan {
        HallieAnswerPlan(
            route: .graph, shape: .biography, subject: "Matthew Rice",
            claims: Self.claimTexts.prefix(claimCount).enumerated().map {
                .init(id: "c\($0 + 1)", text: $1, evidenceIDs: ["@I1@"])
            },
            fallbackText: Self.claimTexts.prefix(claimCount).joined(separator: " "))
    }

    // The model's sentences, each a faithful phrasing of one claim.
    private static let s1 = "Matthew Rice was born on 28 February 1629 in Great Berkhampstead, Hertfordshire, England, and he died before 29 November 1717 in Sudbury, Middlesex, Massachusetts Bay Colony [c1]."
    private static let s2 = "He was the son of Edmund Rice and Thomasine Frost, with recorded grandparents Edward Frost I and Thomasina Belgrave [c2]."
    private static let s3 = "He had two recorded siblings, Henry Rice and Edward Rice [c3]."
    private static let s45 = "Matthew married Martha Lamson on 7 July 1654, and they had two children named Isaac Rice and Patience Rice [c4][c5]."
    private static let s6 = "His family tree includes 83 recorded ancestors across 11 generations and 27 recorded descendants across 11 generations [c6]."

    private func compose(_ plan: HallieAnswerPlan, _ reply: String,
                         history: [HallieGroundedComposer.HistoryTurn] = []) async
        -> HallieGroundedComposer.Outcome {
        await HallieGroundedComposer(personaName: "Hallie Mae") { _, _ in reply }
            .compose(plan: plan, history: history)
    }

    /// The live 2026-08-29 reply verbatim: c3 absent. It comes back as the
    /// plan's own sentence, tagged, between the parents and the marriage.
    @Test func omittedSiblingsClaimIsRestoredInPlanOrder() async {
        let live = [Self.s1, Self.s2, Self.s45, Self.s6].joined(separator: " ")
        let outcome = await compose(plan(), live)
        #expect(outcome.composedBy == .model)
        #expect(outcome.dropped.isEmpty, Comment(rawValue: "\(outcome.dropped)"))
        #expect(outcome.restored == [.init(claimID: "c3", reason: .missing)])
        #expect(outcome.transcriptText.contains("He had 2 recorded siblings, Henry Rice and Edward Rice. [c3]"),
                Comment(rawValue: outcome.transcriptText))
        #expect(outcome.displayText.contains("He had 2 recorded siblings, Henry Rice and Edward Rice."))
        let sentences = HallieCompositionVerifier.splitSentences(outcome.transcriptText)
        #expect(sentences.map(HallieCompositionVerifier.claimTags) == [["c1"], ["c2"], ["c3"], ["c4", "c5"], ["c6"]],
                Comment(rawValue: outcome.transcriptText))
        #expect(outcome.note == "model (claims restored: c3)")
    }

    @Test func twoOmittedClaimsAreBothRestoredInPlanOrder() async {
        let reply = [Self.s1, Self.s2, "Matthew married Martha Lamson on 7 July 1654 [c4].", Self.s6]
            .joined(separator: " ")
        let outcome = await compose(plan(), reply)
        #expect(outcome.restored.map(\.claimID) == ["c3", "c5"])
        let sentences = HallieCompositionVerifier.splitSentences(outcome.transcriptText)
        #expect(sentences.map(HallieCompositionVerifier.claimTags) == [["c1"], ["c2"], ["c3"], ["c4"], ["c5"], ["c6"]],
                Comment(rawValue: outcome.transcriptText))
        #expect(outcome.note == "model (claims restored: c3,c5)")
    }

    /// Ordering is the model's to choose: all six cited, nothing restored.
    @Test func reorderedButCompleteReplyRestoresNothing() async {
        let reply = [Self.s1, Self.s45, Self.s3, Self.s2, Self.s6].joined(separator: " ")
        let outcome = await compose(plan(), reply)
        #expect(outcome.restored.isEmpty)
        #expect(outcome.dropped.isEmpty, Comment(rawValue: "\(outcome.dropped)"))
        #expect(outcome.note == "model")
        let sentences = HallieCompositionVerifier.splitSentences(outcome.transcriptText)
        #expect(sentences.map(HallieCompositionVerifier.claimTags) == [["c1"], ["c4", "c5"], ["c3"], ["c2"], ["c6"]])
    }

    /// The model's siblings sentence invented a name. The verifier drops it
    /// as a leak, and the leak wins: c3 is NOT put back through the
    /// template, so a rejected sentence can never be laundered back in.
    @Test func leakDroppedClaimIsNotRestored() async {
        let leaky = "He had two recorded siblings, Henry Rice and Zebulon Rice [c3]."
        let reply = [Self.s1, Self.s2, leaky, Self.s45, Self.s6].joined(separator: " ")
        let outcome = await compose(plan(), reply)
        #expect(outcome.dropped.map(\.reason) == [.leakedName])
        #expect(outcome.restored.isEmpty)
        #expect(!outcome.transcriptText.contains("[c3]"), Comment(rawValue: outcome.transcriptText))
        #expect(!outcome.displayText.contains("Zebulon"))
        let lines = HallieGroundedComposer.verifyLogLines(outcome, plan: plan())
        #expect(lines == ["[hallie-verify] coverage: shape=biography plan=6 cited=5 restored=0 leaked=1 dropped=1"],
                Comment(rawValue: lines.joined(separator: "\n")))
    }

    /// A budget drop is a wording failure, not a leak: the claim is owed.
    /// The biography budget also never undercuts the claim count, so the
    /// verifier cannot be the reason a fact of a fixed plan goes missing.
    @Test func biographyBudgetCoversEveryClaim() async {
        #expect(plan().maxSentences == 6)
        #expect(plan(claimCount: 3).maxSentences == 6)
        var eight = Self.claimTexts
        eight.append("He is buried in Sudbury.")
        eight.append("His will was proved in 1717.")
        let big = HallieAnswerPlan(
            route: .graph, shape: .biography, subject: "Matthew Rice",
            claims: eight.enumerated().map { .init(id: "c\($0 + 1)", text: $1) },
            fallbackText: eight.joined(separator: " "))
        #expect(big.maxSentences == 8)
        // Model spends the budget on padding sentences; the last real
        // claim's sentence falls over the budget and is restored, not lost.
        let padded = ([Self.s1, Self.s2, Self.s3, Self.s45, Self.s6]
            + Array(repeating: "He was born in 1629 [c1].", count: 3)
            + ["He is buried in Sudbury [c7].", "His will was proved in 1717 [c8]."])
            .joined(separator: " ")
        let outcome = await compose(big, padded)
        #expect(outcome.dropped.map(\.reason) == [.overSentenceBudget, .overSentenceBudget])
        #expect(outcome.restored.map(\.claimID) == ["c7", "c8"])
        #expect(outcome.transcriptText.hasSuffix("He is buried in Sudbury. [c7] His will was proved in 1717. [c8]"),
                Comment(rawValue: outcome.transcriptText))
    }

    /// Lists are not governed: their item claims are shown as a list under
    /// the answer and the prompt tells the model NOT to enumerate them.
    @Test func listPlansAreNotCoverageRestored() async {
        let list = HallieAnswerPlan(
            route: .presence, shape: .list,
            claims: [.init(id: "c1", text: "I found 4 catalog items matching that."),
                     .init(id: "c2", text: "One of them is a.mov."),
                     .init(id: "c3", text: "Another of them is b.mov.")],
            fallbackText: "I found 4 catalog items matching that.")
        let outcome = await compose(list, "I found 4 catalog items matching that [c1].")
        #expect(outcome.restored.isEmpty)
        #expect(outcome.displayText == "I found 4 catalog items matching that.")
    }

    /// Log lines: one per restored claim, then the metric line the nightly
    /// eval counts. Both the app coordinator and the shell emit exactly
    /// these through the same function.
    @Test func verifyLogLinesNameTheClaimAndCarryTheCoverageMetric() async {
        let live = [Self.s1, Self.s2, Self.s45, Self.s6].joined(separator: " ")
        let outcome = await compose(plan(), live)
        let lines = HallieGroundedComposer.verifyLogLines(outcome, plan: plan())
        #expect(lines == [
            "[hallie-verify] restored: c3 — reason: missing — \"He had 2 recorded siblings, Henry Rice and Edward Rice.\"",
            "[hallie-verify] coverage: shape=biography plan=6 cited=5 restored=1 leaked=0 dropped=0",
        ], Comment(rawValue: lines.joined(separator: "\n")))
        // Template answers and non-biography shapes emit nothing.
        #expect(HallieGroundedComposer.verifyLogLines(.template(plan(), note: "x"), plan: plan()).isEmpty)
    }

    /// Shell (`--compose`, no history) and app (history offered) run the
    /// same composer; the coverage outcome does not depend on the surface.
    @Test func shellAndAppSurfacesProduceIdenticalCoverage() async {
        let live = [Self.s1, Self.s2, Self.s45, Self.s6].joined(separator: " ")
        let shell = await compose(plan(), live)
        let app = await compose(plan(), live,
                                history: [.init(user: "who was he?", assistant: "Matthew Rice.")])
        #expect(shell == app)
        #expect(HallieGroundedComposer.verifyLogLines(shell, plan: plan())
                == HallieGroundedComposer.verifyLogLines(app, plan: plan()))
    }

    // MARK: - Required-person coverage (live 2026-09-02)

    private func parentsPlan(
        required: [String] = ["Richard Harding Breen Sr", "Eileen Latta"]
    ) -> HallieAnswerPlan {
        // House format (`HallieDateStyle`, 2026-09-03) — this fixture is a
        // mirror of what `HallieBiographyCard.vitalsAside` actually builds,
        // and it had drifted to "February 22 1929" while production emitted
        // "22 February 1929".
        let fallback = "Rick's parents: Richard Harding Breen Sr, "
            + "born 22 February 1929 in Boston, died 22 June 2008 in Brockton, "
            + "and Eileen Latta, born 31 August 1930 in Chelsea, "
            + "died 3 March 2023 in Stoughton."
        return HallieAnswerPlan(
            route: .graph, shape: .fact,
            claims: [.init(
                id: "c1", text: fallback,
                // @I9@ is supporting provenance, not an answer person.
                evidenceIDs: ["@I2@", "@I3@", "@I9@"],
                requiredPersonNames: required,
                requiresCoverage: true)],
            fallbackText: fallback)
    }

    private func result(plan: HallieAnswerPlan) -> HallieTurnExecutor.Result {
        HallieTurnExecutor.Result(
            route: plan.route, outcome: .answered,
            prose: plan.fallbackText, basisLine: "Basis: fixture.",
            queryDescription: "fixture", citations: [],
            catalogPersonName: nil, answerPlan: plan)
    }

    private func listPlan() -> HallieAnswerPlan {
        HallieAnswerPlan(
            route: .presence, shape: .list,
            claims: [
                .init(id: "c1", text: "I found 2 catalog items matching that."),
                .init(id: "c2", text: "One of them is Cape.mov."),
            ],
            fallbackText: "I found 2 catalog items matching that.")
    }

    private func biographyPlan() -> HallieAnswerPlan {
        HallieAnswerPlan(
            route: .graph, shape: .biography, subject: "Rick Breen",
            claims: [
                .init(
                    id: "c1", text: "Rick Breen was born in Boston.",
                    requiredPersonNames: ["Rick Breen"],
                    requiresCoverage: true),
                .init(
                    id: "c2", text: "His parents were Richard Harding Breen Sr and Eileen Latta.",
                    requiredPersonNames: ["Richard Harding Breen Sr", "Eileen Latta"],
                    requiresCoverage: true),
            ],
            fallbackText: "Rick Breen was born in Boston. His parents were Richard Harding Breen Sr and Eileen Latta.")
    }

    /// Exact live failure: the model cited the compound parents claim but
    /// rendered only Eileen's half. A tag is not person coverage; the safe
    /// deterministic answer replaces it and names both parents.
    @Test func citedTwoParentClaimThatOmitsRichardFallsBackToExactPlan() async {
        let plan = parentsPlan()
        // The live reply, with its dates copied verbatim from the claim so
        // this case still isolates PERSON coverage. (The date corruption
        // that rode along in the original live text is now its own drop
        // reason and its own suite — HallieDeterministicDateTests.)
        let live = "His mother, Eileen Latta, was born on 31 August 1930, "
            + "in Chelsea, and passed away on 3 March 2023, in Stoughton [c1]."
        let verified = HallieCompositionVerifier.verify(
            live, plan: plan, personaName: "Hallie Mae")
        #expect(HallieCompositionVerifier.missingRequiredPersonNames(
            in: verified, plan: plan) == ["Richard Harding Breen Sr"])

        let outcome = await compose(plan, live)
        #expect(outcome.composedBy == .template)
        #expect(outcome.note == "template: required person omitted")
        #expect(outcome.displayText == plan.fallbackText)
        #expect(outcome.displayText.contains("Richard Harding Breen Sr"))
        #expect(outcome.displayText.contains("Eileen Latta"))
    }

    /// If the model omitted the whole relationship claim, the existing
    /// deterministic missing-claim repair is sufficient; no full fallback
    /// is needed after the restored sentence covers both people.
    @Test func whollyOmittedKinshipClaimIsRestoredBeforePersonCoverage() async {
        let plan = HallieAnswerPlan(
            route: .graph, shape: .fact,
            claims: [
                .init(
                    id: "c1",
                    text: "Rick's parents are Richard Harding Breen Sr and Eileen Latta.",
                    requiredPersonNames: ["Richard Harding Breen Sr", "Eileen Latta"],
                    requiresCoverage: true),
                .init(id: "c2", text: "The family tree records that relationship."),
            ],
            fallbackText: "Rick's parents are Richard Harding Breen Sr and Eileen Latta.")
        let outcome = await compose(plan, "The family tree records that relationship [c2].")
        #expect(outcome.composedBy == .model)
        #expect(outcome.restored == [.init(claimID: "c1", reason: .missing)])
        #expect(outcome.displayText.hasPrefix(
            "Rick's parents are Richard Harding Breen Sr and Eileen Latta."))
        #expect(outcome.note == "model (claims restored: c1)")
    }

    /// One required person is ordinary, and an extra provenance pointer is
    /// not silently promoted into a second required person.
    @Test func onePersonContractIgnoresIncidentalEvidencePeople() async {
        let plan = parentsPlan(required: ["Eileen Latta"])
        let reply = "Rick's mother is Eileen Latta [c1]."
        let outcome = await compose(plan, reply)
        #expect(outcome.composedBy == .model, Comment(rawValue: outcome.note))
        #expect(outcome.displayText == "Rick's mother is Eileen Latta.")
    }

    /// Isolation sensor: a missing name in one plan must not poison the next
    /// turn. Required names are immutable plan data, not shared verifier
    /// state or preferences.
    @Test func requiredPersonCoverageIsIsolatedPerPlan() async {
        let first = await compose(
            parentsPlan(), "Rick's mother is Eileen Latta [c1].")
        let second = await compose(
            parentsPlan(required: ["Eileen Latta"]),
            "Rick's mother is Eileen Latta [c1].")
        #expect(first.composedBy == .template)
        #expect(second.composedBy == .model)
        #expect(second.note == "model")
    }

    /// A flattened graph answer keeps its mandatory claim even when the
    /// following list lends the combined plan its `.list` shape. The list's
    /// omitted example is not restored.
    @Test func graphThenListRestoresOnlyTheGraphSegment() async {
        let joined = HallieTurnExecutor.joinedTwoQuestionAnswer(
            result(plan: parentsPlan()), result(plan: listPlan()))
        let plan = HallieAnswerPlan.derive(from: joined)
        let outcome = await compose(plan, "I found 2 catalog items matching that [c2].")
        #expect(outcome.composedBy == .model)
        #expect(outcome.restored.map(\.claimID) == ["c1"])
        #expect(outcome.displayText.contains("Richard Harding Breen Sr"))
        #expect(outcome.displayText.contains("Eileen Latta"))
        #expect(!outcome.displayText.contains("Cape.mov"))
    }

    /// Reversing the segments shifts the mandatory graph claim to c3 but
    /// does not change policy: c3 returns; list example c2 does not.
    @Test func listThenGraphRestoresOnlyTheGraphSegment() async {
        let joined = HallieTurnExecutor.joinedTwoQuestionAnswer(
            result(plan: listPlan()), result(plan: parentsPlan()))
        let plan = HallieAnswerPlan.derive(from: joined)
        let outcome = await compose(plan, "I found 2 catalog items matching that [c1].")
        #expect(outcome.composedBy == .model)
        #expect(outcome.restored.map(\.claimID) == ["c3"])
        #expect(outcome.displayText.contains("Richard Harding Breen Sr"))
        #expect(outcome.displayText.contains("Eileen Latta"))
        #expect(!outcome.displayText.contains("Cape.mov"))
    }

    /// The combined plan inherits `.biography` from its second segment, but
    /// that presentation shape must not promote optional list examples into
    /// mandatory biography claims. This is the exact reverse-order hole that
    /// a fact-shaped graph fixture cannot exercise.
    @Test func listThenBiographyRestoresOnlyBiographyClaims() async {
        let joined = HallieTurnExecutor.joinedTwoQuestionAnswer(
            result(plan: listPlan()), result(plan: biographyPlan()))
        let plan = HallieAnswerPlan.derive(from: joined)
        #expect(plan.shape == .biography)
        let outcome = await compose(
            plan,
            "I found 2 catalog items matching that [c1]. Rick Breen was born in Boston [c3].")
        #expect(outcome.composedBy == .model)
        #expect(outcome.restored.map(\.claimID) == ["c4"])
        #expect(outcome.displayText.contains("Richard Harding Breen Sr"))
        #expect(outcome.displayText.contains("Eileen Latta"))
        #expect(!outcome.displayText.contains("Cape.mov"))
    }

    /// The same claim-local policy holds when biography comes first and the
    /// joined plan inherits `.list` from the second segment.
    @Test func biographyThenListRestoresOnlyBiographyClaims() async {
        let joined = HallieTurnExecutor.joinedTwoQuestionAnswer(
            result(plan: biographyPlan()), result(plan: listPlan()))
        let plan = HallieAnswerPlan.derive(from: joined)
        #expect(plan.shape == .list)
        let outcome = await compose(
            plan,
            "Rick Breen was born in Boston [c1]. I found 2 catalog items matching that [c3].")
        #expect(outcome.composedBy == .model)
        #expect(outcome.restored.map(\.claimID) == ["c2"])
        #expect(outcome.displayText.contains("Richard Harding Breen Sr"))
        #expect(outcome.displayText.contains("Eileen Latta"))
        #expect(!outcome.displayText.contains("Cape.mov"))
    }

    /// A partial compound graph claim remains partial even beside a valid
    /// list segment. The whole joined deterministic answer is the safe
    /// fallback; changing the final route to `.presence` cannot bypass it.
    @Test func partialCitedGraphClaimInsideCombinedAnswerFallsBack() async {
        let joined = HallieTurnExecutor.joinedTwoQuestionAnswer(
            result(plan: parentsPlan()), result(plan: listPlan()))
        let plan = HallieAnswerPlan.derive(from: joined)
        let outcome = await compose(
            plan,
            "Eileen Latta was one of them [c1]. "
                + "I found 2 catalog items matching that [c2].")
        #expect(outcome.composedBy == .template)
        #expect(outcome.note == "template: required person omitted")
        #expect(outcome.displayText == joined.prose)
    }

    /// Full canonical names are the auditable contract. A model may not
    /// shorten "Eileen Latta" to "Eileen" and accidentally satisfy it;
    /// exact deterministic fallback is intentionally the safe policy.
    @Test func shortenedRequiredNameUsesSafeFallback() async {
        let plan = parentsPlan(required: ["Eileen Latta"])
        let outcome = await compose(plan, "Rick's mother is Eileen [c1].")
        #expect(outcome.composedBy == .template)
        #expect(outcome.note == "template: required person omitted")
        #expect(outcome.displayText == plan.fallbackText)
    }

    @Test func normalizedDuplicateRequiredNamesCollapseStably() {
        let plan = parentsPlan(required: [
            "Eileen Latta", "EILEEN LATTA", "  Eileen   Latta  ",
        ])
        #expect(plan.requiredPersonNames == ["Eileen Latta"])
    }

    /// The card says only twelve names and "1 more". The hidden thirteenth
    /// record supports the summary but is not a rendered-person obligation.
    /// (Since 9/02 a person has ONE primary parent family, so the >12 list
    /// is the subject's children, never grandparents.)
    @Test func biographyRequiredNamesStopAtTheRenderedChildLimit() throws {
        let childNames = [
            "Able", "Baker", "Charlie", "Dog", "Easy", "Fox", "George",
            "How", "Item", "Jig", "King", "Love", "Mike",
        ]
        var gedcom = """
        0 HEAD
        0 @I0@ INDI
        1 NAME Subject /Person/
        1 FAMS @FS@
        0 @FS@ FAM
        1 HUSB @I0@
        """
        for index in childNames.indices { gedcom += "\n1 CHIL @IC\(index)@" }
        for (index, name) in childNames.enumerated() {
            gedcom += """

            0 @IC\(index)@ INDI
            1 NAME \(name) /Family/
            1 FAMC @FS@
            """
        }
        gedcom += "\n0 TRLR\n"
        let graph = GedcomFamilyGraph(gedcomText: gedcom)
        let subject = try #require(graph.people["@I0@"])
        let children = graph.relatives(.children, of: subject)
        #expect(children.count == 13)
        let plan = HallieBiographyCard.card(for: subject, in: graph).plan
        let claim = try #require(plan.claims.first { $0.text.contains("The family tree records") })
        // The sentence names the subject too; the cap is on the LIST.
        let rendered = Set(claim.requiredPersonNames).subtracting([subject.name])
        #expect(rendered.count == HallieBiographyCard.maxListedNames)
        let all = Set(children.map(\.name))
        #expect(rendered.isSubset(of: all))
        #expect(claim.text.contains("and 1 more"))
        let hidden = try #require(all.subtracting(rendered).first)
        #expect(!HallieAnswerPlan.names(hidden, in: claim.text))
    }
}
