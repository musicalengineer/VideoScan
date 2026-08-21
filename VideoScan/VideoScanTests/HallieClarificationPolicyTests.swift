import Foundation
import Testing
@testable import VideoScan

// The stuck-clarification bug (Rick's 2026-08-21 eval): 25 consecutive turns
// answered "I need one of the listed names or numbers so I don't guess"
// because a pending clarification was only ever cleared by an explicit
// :cancel. These pin the rule that lets a person change the subject.

@Suite("Hallie clarification policy")
struct HallieClarificationPolicyTests {

    private let candidates = ["Tim", "Timmy"]

    /// The client's selector always wins — the policy never overrides a real
    /// selection.
    private func selector(_ accepting: String...) -> (String) -> String? {
        let accepted = Set(accepting.map { $0.lowercased() })
        return { reply in
            accepted.contains(reply.trimmingCharacters(in: .whitespaces).lowercased())
                ? "id:" + reply.lowercased() : nil
        }
    }

    @Test func aRealSelectionIsHonored() {
        let d = HallieClarificationPolicy.decide(
            reply: "2", candidates: candidates, select: selector("2"))
        #expect(d == .select("id:2"))
    }

    /// The live failure: a plainly different question must NOT be eaten.
    @Test func aNewQuestionAbandonsTheClarification() {
        for question in [
            "what was it like during the war",
            "how many videos do you have?",
            "show me Donna at the cape",
            "did you have cars when you were young",
            "tell me about my father",
        ] {
            let d = HallieClarificationPolicy.decide(
                reply: question, candidates: candidates, select: { _ in nil })
            #expect(d == .abandon, "should abandon for: \(question)")
        }
    }

    /// Someone still trying to pick gets asked again, not silently derailed.
    @Test func nearMissesRepromptRatherThanAbandon() {
        for attempt in ["5", "7", "Timm", "the second", ""] {
            let d = HallieClarificationPolicy.decide(
                reply: attempt, candidates: candidates, select: { _ in nil })
            #expect(d == .reprompt, "should reprompt for: '\(attempt)'")
        }
    }

    /// A longer sentence that still names a candidate is about the
    /// clarification, not a new subject.
    @Test func namingACandidateInASentenceReprompts() {
        let d = HallieClarificationPolicy.decide(
            reply: "I meant Timmy, the youngest one",
            candidates: candidates, select: { _ in nil })
        #expect(d == .reprompt)
    }

    /// Social turns are new turns — she should not demand a name in reply to
    /// "thanks".
    @Test func pleasantriesAbandon() {
        for social in ["thanks, that's kind of you", "never mind", "hi Hallie, how are you?"] {
            let d = HallieClarificationPolicy.decide(
                reply: social, candidates: candidates, select: { _ in nil })
            #expect(d == .abandon, "should abandon for: \(social)")
        }
    }

    /// Question marks mark a new turn even when short.
    @Test func shortQuestionsAbandon() {
        let d = HallieClarificationPolicy.decide(
            reply: "who?", candidates: candidates, select: { _ in nil })
        #expect(d == .abandon)
    }

    @Test func abandonNoteIsSaidOutLoud() {
        // She acknowledges dropping her own question rather than pretending
        // she never asked.
        #expect(!HallieClarificationPolicy.abandonNote.isEmpty)
    }
}

// MARK: - Eval pass 2 regressions (2026-08-21)

@Suite("Hallie — near-miss bounds and orphaned openings")
struct HallieNearMissAndOrphanTests {

    /// "find videos shot on the old camcorder" dropped its only keyword and
    /// offered "5877 items" — the whole catalog. An offer must be a NEAR miss.
    @Test func wholeCatalogIsNeverOfferedAsANearMiss() {
        #expect(!ArchivistPresenceExecutor.isUsefulNearMiss(count: 5877, of: 7313))
        #expect(!ArchivistPresenceExecutor.isUsefulNearMiss(count: 201, of: 7313))
        #expect(!ArchivistPresenceExecutor.isUsefulNearMiss(count: 60, of: 100))
        // A handful is always worth offering, whatever share it happens to be.
        #expect(ArchivistPresenceExecutor.isUsefulNearMiss(count: 2, of: 2))
    }

    @Test func genuineNearMissesAreStillOffered() {
        #expect(ArchivistPresenceExecutor.isUsefulNearMiss(count: 34, of: 7313))
        #expect(ArchivistPresenceExecutor.isUsefulNearMiss(count: 1, of: 7313))
        #expect(ArchivistPresenceExecutor.isUsefulNearMiss(count: 200, of: 7313))
    }

    /// The live case: sentence one was dropped and the answer became
    /// "The other is videocomplementoutput_2ffb.mov at 0.2s".
    @Test func answerMayNotOpenMidThought() {
        let plan = HallieAnswerPlan(
            route: .presence, shape: .list,
            claims: [
                .init(id: "c1", text: "I found 2 catalog items matching that."),
                .init(id: "c2", text: "Item 2: b.mov"),
            ],
            fallbackText: "I found 2 catalog items matching that.")
        let v = HallieCompositionVerifier.verify(
            "The other is b.mov [c2].", plan: plan, personaName: "Hallie")
        #expect(v.kept.isEmpty)
        #expect(v.dropped.contains { $0.reason == .orphanedContinuation })
    }

    /// A continuation is fine once something precedes it.
    @Test func continuationsAreFineAfterAFirstSentence() {
        let plan = HallieAnswerPlan(
            route: .presence, shape: .list,
            claims: [
                .init(id: "c1", text: "I found 2 catalog items matching that."),
                .init(id: "c2", text: "Item 2: b.mov"),
            ],
            fallbackText: "x")
        let v = HallieCompositionVerifier.verify(
            "There are 2 clips [c1]. The other is b.mov [c2].",
            plan: plan, personaName: "Hallie")
        #expect(v.kept.count == 2)
    }
}
