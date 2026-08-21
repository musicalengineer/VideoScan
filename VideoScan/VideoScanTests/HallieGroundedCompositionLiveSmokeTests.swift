import Foundation
import Testing
@testable import VideoScan

// MARK: - Live smoke for the grounded composer (opt-in, never in CI)
//
// Runs only with HALLIE_COMPOSE_SMOKE=1 (xcodebuild: TEST_RUNNER_HALLIE_COMPOSE_SMOKE=1)
// against a local Ollama on 127.0.0.1. Prints the composed text and the
// verifier's decisions; asserts only the contract (displayed ⊆ verified,
// every displayed sentence maps to claims), never the wording.

@Suite("Hallie grounded composition — live smoke", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["HALLIE_COMPOSE_SMOKE"] == "1"))
struct HallieGroundedCompositionLiveSmokeTests {

    private func composer() -> HallieGroundedComposer {
        var brain = OllamaQueryTranslator()
        brain.host = ProcessInfo.processInfo.environment["HALLIE_COMPOSE_HOST"] ?? "127.0.0.1"
        if let model = ProcessInfo.processInfo.environment["HALLIE_COMPOSE_MODEL"],
           !model.isEmpty {
            brain.model = model
        }
        let fleet = OllamaFailoverTranslator(hosts: [brain.host], template: brain)
        return HallieGroundedComposer(personaName: "Hallie Mae", timeoutSeconds: 60) { system, user in
            try await fleet.composePlainText(system: system, user: user)
        }
    }

    private func report(_ label: String, plan: HallieAnswerPlan,
                        outcome: HallieGroundedComposer.Outcome) {
        print("=== LIVE SMOKE: \(label) ===")
        print("composedBy: \(outcome.composedBy.rawValue) (\(outcome.note))")
        print("display:    \(outcome.displayText)")
        print("transcript: \(outcome.transcriptText)")
        for dropped in outcome.dropped {
            print("dropped [\(dropped.reason.rawValue)]: \(dropped.text)")
        }
        print("fallback:   \(plan.fallbackText)")
        // Contract, not wording.
        if outcome.composedBy == .model {
            let verification = HallieCompositionVerifier.verify(
                outcome.transcriptText, plan: plan, personaName: "Hallie Mae")
            #expect(verification.displayText == outcome.displayText)
            #expect(verification.dropped.isEmpty)
            #expect(verification.kept.allSatisfy { !$0.claimIDs.isEmpty })
        }
    }

    @Test func threeClaimBiography() async {
        let plan = HallieAnswerPlan(
            route: .graph, shape: .biography, subject: "Ellen Breen",
            claims: [
                .init(id: "c1", text: "The imported family tree records 12 MAR 1920 as Ellen Breen's birth date.", evidenceIDs: ["gedcom:@I7@"]),
                .init(id: "c2", text: "The imported family tree records Ellen Breen's spouse as John Breen.", evidenceIDs: ["gedcom:@I7@"]),
                .init(id: "c3", text: "The imported family tree records Ellen Breen's children as Rick Breen, Mary Breen.", evidenceIDs: ["gedcom:@I7@"]),
            ],
            counts: [.init(label: "supporting sources", value: 1)],
            fallbackText: "Here is what the family archive currently supports about Ellen Breen. The imported family tree records 12 MAR 1920 as Ellen Breen's birth date. The imported family tree records Ellen Breen's spouse as John Breen. The imported family tree records Ellen Breen's children as Rick Breen, Mary Breen. This account is supported by 1 source, which I can show you.")
        let outcome = await composer().compose(
            plan: plan,
            history: [.init(user: "who is ellen?", assistant: "Which Ellen do you mean?")])
        report("3-claim biography", plan: plan, outcome: outcome)
    }

    @Test func fiveItemPresenceList() async {
        let files = ["1994_cape_beach.mov", "1994_cape_cottage.mov", "1995_cape_boat.mov",
                     "cape_sunset.mp4", "donna_cape_walk.mov"]
        let citations = files.enumerated().map { index, name in
            HallieTurnExecutor.Citation(
                recordID: UUID(), fullPath: "/isolated/\(name)", filename: name,
                playbackSeconds: index == 2 ? 12.5 : nil,
                bases: [])
        }
        let prose = "I found 5 catalog items matching that."
        let plan = HallieAnswerPlan.presenceList(
            route: .presence, prose: prose, totalMatchCount: 5, shownCount: 5,
            citations: citations)
        let outcome = await composer().compose(
            plan: plan,
            history: [.init(user: "show me donna down the cape", assistant: prose)])
        report("5-item presence list", plan: plan, outcome: outcome)
    }
}
