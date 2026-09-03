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

    /// Cycle-2 sensor: joined answers concatenate chip arrays. The directly
    /// requested navigation must survive on either side without turning an
    /// unrelated first chip into an auto-run action.
    @MainActor
    @Test func answeredCompoundKeepsTheExplicitActionInBothOrders() {
        let unrelated = HallieTurnExecutor.Result(
            route: .capability, outcome: .answered, prose: "Other answer.",
            basisLine: "Basis: fixture", queryDescription: nil, citations: [],
            catalogPersonName: nil,
            offeredActions: [.ask(question: "tell me more", label: "Tell me more")])
        let navigation = Navigation.answer(.archive)
        let joined = [
            HallieTurnExecutor.joinedTwoQuestionAnswer(unrelated, navigation),
            HallieTurnExecutor.joinedTwoQuestionAnswer(navigation, unrelated),
        ]

        for (index, result) in joined.enumerated() {
            #expect(result.performsFirstOfferedAction, "order \(index)")
            #expect(result.immediateOfferedAction == .openAppDestination(.archive),
                    "order \(index)")
            #expect(Navigation.immediateDestination(in: result) == .archive,
                    "order \(index)")
        }
        #expect(joined[0].offeredActions.first ==
                .ask(question: "tell me more", label: "Tell me more"),
                "the safe result must not depend on moving navigation to index zero")
    }

    @MainActor
    @Test func deferredCompoundKeepsTheRequestedNavigationAction() {
        guard case .answer(let result) = pre(
            "open the Archive tab? show me Donna in 1994") else {
            Issue.record("expected the navigation answer plus a deferred translated ask")
            return
        }
        #expect(result.offeredActions == [
            .openAppDestination(.archive),
            .ask(question: "show me Donna in 1994", label: "Show me Donna in 1994"),
        ])
        #expect(result.performsFirstOfferedAction)
        #expect(result.immediateOfferedAction == .openAppDestination(.archive))

        let defaults = UserDefaults(suiteName: "HallieAppNavigationTests.deferred")!
        defaults.set(77, forKey: "selectedTab")
        var opens = 0
        #expect(Navigation.acceptImmediateOffer(
            from: result, defaults: defaults, openMainWindow: { opens += 1 }))
        #expect(defaults.integer(forKey: "selectedTab") == Destination.archive.selectedTab)
        #expect(opens == 1)
    }

    /// Two direct tab requests cannot both be the final selected tab. The
    /// later clause wins, matching the final state the user asked to see.
    @Test func twoRequestedNavigationsSelectTheLaterClause() {
        for (first, second) in [(Destination.people, Destination.archive),
                                (Destination.archive, Destination.people)] {
            let result = HallieTurnExecutor.joinedTwoQuestionAnswer(
                Navigation.answer(first), Navigation.answer(second))
            #expect(result.immediateOfferedAction == .openAppDestination(second))
            #expect(Navigation.immediateDestination(in: result) == second)
            #expect(result.offeredActions == [
                .openAppDestination(first), .openAppDestination(second),
            ])
        }
    }

    @MainActor
    @Test func explicitIdentitySurvivesAReorderedOfferArray() {
        let result = HallieTurnExecutor.Result(
            route: .capability, outcome: .answered, prose: "Opening the Storage tab.",
            basisLine: "Basis: fixture", queryDescription: nil, citations: [],
            catalogPersonName: nil,
            offeredActions: [
                .ask(question: "unrelated", label: "Unrelated"),
                .openAppDestination(.storage),
            ],
            performsFirstOfferedAction: true,
            immediateOfferedAction: .openAppDestination(.storage))
        let defaults = UserDefaults(suiteName: "HallieAppNavigationTests.reordered")!
        defaults.set(77, forKey: "selectedTab")
        var opens = 0
        #expect(Navigation.acceptImmediateOffer(
            from: result, defaults: defaults, openMainWindow: { opens += 1 }))
        #expect(defaults.integer(forKey: "selectedTab") == Destination.storage.selectedTab)
        #expect(opens == 1)
    }
}
