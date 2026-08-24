// HallieAttributedTestimonyTests.swift
// Attributed family testimony in biographies (Rick 2026-08-24: "why is
// Hallie hesitant to describe Donna as a slim attractive woman…"): a
// told account keeps its teller's name through the plan, the composer
// prompt marks it, and confirmed document-backed claims stay unmarked.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Attributed testimony — plan and prompt")
struct HallieAttributedTestimonyTests {

    private func cyberPlan() -> CyberBrainAnswerPlan {
        CyberBrainAnswerPlan(
            subject: "Donna Breen",
            answerState: .answered,
            claims: [
                .init(id: "told.1",
                      text: "Donna is slim, attractive, with striking blonde hair.",
                      evidenceIDs: ["source.told-by-rick"],
                      confidence: .probable),
                .init(id: "doc.1",
                      text: "Donna was born in 1959.",
                      evidenceIDs: ["source.gedcom"],
                      confidence: .confirmed),
            ],
            uncertaintyStatements: [],
            sourceCitations: [
                .init(id: "source.told-by-rick", title: "Told by Rick Breen",
                      attribution: "Rick Breen", locator: nil),
                .init(id: "source.gedcom", title: "Family tree",
                      attribution: nil, locator: nil),
            ],
            suggestedFollowups: [],
            permittedActions: [],
            constraints: [.doNotAddUnsupportedFacts])
    }

    @Test func toldClaimsCarryTheirTellerAndConfirmedOnesDoNot() {
        let plan = HallieAnswerPlan.biography(cyberPlan(), fallbackText: "fb")
        #expect(plan.claims[0].attribution == "Rick Breen")
        #expect(plan.claims[0].text.contains("striking blonde hair"))
        #expect(plan.claims[1].attribution == nil)
    }

    @Test func promptMarksTestimonyClaimsForTheComposer() {
        let plan = HallieAnswerPlan.biography(cyberPlan(), fallbackText: "fb")
        let prompt = HallieGroundedComposer.userPrompt(plan: plan, history: [])
        #expect(prompt.contains("[c1] (as told by Rick Breen) Donna is slim"))
        #expect(prompt.contains("[c2] Donna was born in 1959."))
        #expect(!prompt.contains("(as told by) "))
    }
}
