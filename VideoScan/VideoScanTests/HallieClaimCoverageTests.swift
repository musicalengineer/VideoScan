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
}
