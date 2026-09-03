// HallieAppNavigation.swift
// Deterministic, model-free app navigation for explicit requests such as
// "open the Archive tab". The result still carries an OfferedAction chip;
// because the user already asked for the action, the app accepts that first
// offer immediately through the same chip destination and selectedTab handoff.

import Foundation

enum HallieAppNavigation {
    enum Destination: String, CaseIterable, Sendable, Equatable {
        case people
        case catalog
        case storage
        case triage
        case archive
        case familyTree

        var title: String {
            switch self {
            case .people: return "People"
            case .catalog: return "Catalog"
            case .storage: return "Storage"
            case .triage: return "Triage"
            case .archive: return "Archive"
            case .familyTree: return "Family Tree"
            }
        }

        /// ContentView's stable tab tags. Storage intentionally remains 6;
        /// tag 3 is the retired Workbench compatibility value.
        var selectedTab: Int {
            switch self {
            case .people: return 0
            case .catalog: return 1
            case .triage: return 2
            case .archive: return 4
            case .familyTree: return 5
            case .storage: return 6
            }
        }

        fileprivate var words: [String] {
            switch self {
            case .familyTree: return ["family", "tree"]
            default: return [rawValue]
            }
        }
    }

    /// Match only an explicit app-surface command. Requiring `tab` or
    /// `window` keeps "show Donna in the archive" and "open Rick's family
    /// tree" on their established archive/lineage routes.
    static func detect(_ text: String) -> Destination? {
        var words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        while let first = words.first, ["hallie", "please", "hey", "ok", "okay"].contains(first) {
            words.removeFirst()
        }
        while words.last == "please" { words.removeLast() }
        guard let verb = words.first, verb == "show" || verb == "open" else { return nil }
        words.removeFirst()
        if words.first == "me" { words.removeFirst() }
        if words.first == "the" { words.removeFirst() }
        guard let surface = words.last, surface == "tab" || surface == "window" else { return nil }
        words.removeLast()
        return Destination.allCases.first { $0.words == words }
    }

    static func answer(_ destination: Destination) -> HallieTurnExecutor.Result {
        HallieTurnExecutor.Result(
            route: .capability,
            outcome: .answered,
            prose: "Opening the \(destination.title) tab.",
            basisLine: "Basis: explicit app-navigation request; no model call or catalog query.",
            queryDescription: "navigation \(destination.rawValue)",
            citations: [],
            catalogPersonName: nil,
            offeredActions: [.openAppDestination(destination)],
            performsFirstOfferedAction: true)
    }

    /// Accept a chip through the app's established AppStorage + main-window
    /// handoff. The injected closure makes the state transition testable
    /// without opening a window in unit tests.
    @MainActor
    static func accept(
        _ destination: Destination,
        defaults: UserDefaults = .standard,
        openMainWindow: @MainActor () -> Void
    ) {
        defaults.set(destination.selectedTab, forKey: "selectedTab")
        openMainWindow()
    }

    /// Auto-accept only the first action on THIS result. No pending or
    /// process-global offer is consulted, so an old transcript chip cannot
    /// be resurrected by a later non-navigation answer.
    @MainActor
    @discardableResult
    static func acceptImmediateOffer(
        from result: HallieTurnExecutor.Result,
        defaults: UserDefaults = .standard,
        openMainWindow: @MainActor () -> Void
    ) -> Bool {
        guard result.performsFirstOfferedAction,
              case .openAppDestination(let destination)? = result.offeredActions.first
        else { return false }
        accept(destination, defaults: defaults, openMainWindow: openMainWindow)
        return true
    }
}
