import Foundation
import Testing
@testable import VideoScan

/// "Mc Gill is Rick's great-great-grandfather" (live 2026-08-26) — an answer
/// may not open with a bare surname when the claims carry the full name.
struct HallieBareSurnameOpeningTests {
    private func plan(_ claim: String) -> HallieAnswerPlan {
        HallieAnswerPlan(route: .graph, shape: .fact,
                         claims: [.init(id: "c1", text: claim)],
                         fallbackText: claim)
    }

    @Test func surnamesOfFullNamesAreTheTailsOfCapitalizedRuns() {
        #expect(HallieCompositionVerifier.surnamesOfFullNames(in: "Ann McGill is Rick Breen's great-great-grandmother.")
                == ["mcgill", "breen"])
        #expect(HallieCompositionVerifier.surnamesOfFullNames(in: "Richard H. Breen Sr. was born in Boston.")
                == ["sr"])
        #expect(HallieCompositionVerifier.surnamesOfFullNames(in: "Donna is confirmed in 5 of them.").isEmpty)
        #expect(HallieCompositionVerifier.surnamesOfFullNames(in: "In Cape Cod, Thomas Breen; then Mary Sullivan Breen.")
                == ["cod", "breen"])
    }

    @Test func bareSurnameOpeningIsDroppedWithItsOwnReason() {
        let verification = HallieCompositionVerifier.verify(
            "McGill is Rick Breen's great-great-grandfather [c1].",
            plan: plan("Rick Breen's great-great-grandfather is Patrick McGill."),
            personaName: "Hallie Mae")
        #expect(verification.kept.isEmpty)
        #expect(verification.dropped.first?.reason == .bareSurnameOpening)

        let possessive = HallieCompositionVerifier.verify(
            "McGill's son is Rick Breen [c1].",
            plan: plan("Patrick McGill's son is Rick Breen."),
            personaName: "Hallie Mae")
        #expect(possessive.dropped.first?.reason == .bareSurnameOpening)
    }

    @Test func fullNamesGivenNamesAndFilenamesStillOpenSentences() {
        let full = HallieCompositionVerifier.verify(
            "Patrick McGill is Rick Breen's great-great-grandfather [c1].",
            plan: plan("Rick Breen's great-great-grandfather is Patrick McGill."),
            personaName: "Hallie Mae")
        #expect(full.kept.count == 1)

        let given = HallieCompositionVerifier.verify(
            "Patrick is Rick Breen's great-great-grandfather [c1].",
            plan: plan("Rick Breen's great-great-grandfather is Patrick McGill."),
            personaName: "Hallie Mae")
        #expect(given.kept.count == 1)

        // A surname that is never part of a longer name in the claims is fine.
        let lone = HallieCompositionVerifier.verify(
            "Breen is the family name [c1].",
            plan: plan("The family name is Breen."),
            personaName: "Hallie Mae")
        #expect(lone.kept.count == 1)

        // The capitalized word after the opener means it is not bare.
        let partial = HallieCompositionVerifier.verify(
            "Sullivan Breen married Thomas Breen [c1].",
            plan: plan("Mary Sullivan Breen married Thomas Breen."),
            personaName: "Hallie Mae")
        #expect(partial.dropped.first?.reason != .bareSurnameOpening)
    }
}
