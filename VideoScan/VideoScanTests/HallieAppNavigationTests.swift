import Foundation
import Testing
@testable import VideoScan

@Suite("Hallie app navigation")
struct HallieAppNavigationTests {
    typealias Navigation = HallieAppNavigation
    typealias Destination = HallieAppNavigation.Destination

    private func pre(_ question: String) -> HallieTurnExecutor.PreTranslation {
        HallieTurnExecutor.preTranslation(
            question: question,
            playAfterAnswer: false,
            memory: .init(),
            isKnownPerson: { _ in false })
    }

    @Test func everyDestinationAcceptsShowOpenAndTabWindow() {
        let destinations: [(String, Destination)] = [
            ("People", .people),
            ("Catalog", .catalog),
            ("Storage", .storage),
            ("Triage", .triage),
            ("Archive", .archive),
            ("Family Tree", .familyTree),
        ]
        for (name, expected) in destinations {
            for verb in ["show", "open"] {
                for surface in ["tab", "window"] {
                    #expect(Navigation.detect("\(verb) the \(name) \(surface)") == expected)
                    #expect(Navigation.detect("Hallie, \(verb) me the \(name) \(surface), please") == expected)
                }
            }
        }
    }

    @Test func directRequestProducesOneImmediateNavigationOffer() {
        guard case .answer(let result) = pre("open the Family Tree window") else {
            Issue.record("navigation ask was not answered before translation")
            return
        }
        #expect(result.route == .capability)
        #expect(result.outcome == .answered)
        #expect(result.prose == "Opening the Family Tree tab.")
        #expect(result.offeredActions == [.openAppDestination(.familyTree)])
        #expect(result.performsFirstOfferedAction)
        #expect(HallieTurnExecutor.offerLabel(result.offeredActions[0]) == "Open the Family Tree tab")
    }

    @Test func nonNavigationAndUnknownSurfacesAreNotClaimed() {
        for question in [
            "open the Settings tab",
            "show Donna in the archive",
            "who is in the People tab",
            "open Rick's family tree",
            "show the catalog videos",
            "open archive",
            "close the Archive tab",
        ] {
            #expect(Navigation.detect(question) == nil, Comment(rawValue: question))
        }
    }

    @MainActor
    @Test func acceptingEveryOfferSwitchesToItsStableTabAndRaisesMainWindow() {
        let defaults = UserDefaults(suiteName: "HallieAppNavigationTests.accept")!
        var opens = 0
        for destination in Destination.allCases {
            defaults.set(99, forKey: "selectedTab") // poisoned prior app state
            Navigation.accept(destination, defaults: defaults) { opens += 1 }
            #expect(defaults.integer(forKey: "selectedTab") == destination.selectedTab)
        }
        #expect(opens == Destination.allCases.count)
    }

    /// Isolation sensor: a current ordinary answer must not consult or
    /// perform an earlier navigation result retained by the transcript.
    @MainActor
    @Test func immediateAcceptanceUsesOnlyTheCurrentResult() {
        let defaults = UserDefaults(suiteName: "HallieAppNavigationTests.isolation")!
        defaults.set(77, forKey: "selectedTab")
        var opens = 0

        let stale = Navigation.answer(.archive)
        let current = HallieTurnExecutor.commandResult(.smalltalk(.thanks))
        #expect(stale.offeredActions == [.openAppDestination(.archive)])
        #expect(!Navigation.acceptImmediateOffer(
            from: current, defaults: defaults, openMainWindow: { opens += 1 }))
        #expect(defaults.integer(forKey: "selectedTab") == 77)
        #expect(opens == 0)

        #expect(Navigation.acceptImmediateOffer(
            from: stale, defaults: defaults, openMainWindow: { opens += 1 }))
        #expect(defaults.integer(forKey: "selectedTab") == 4)
        #expect(opens == 1)
    }
}
