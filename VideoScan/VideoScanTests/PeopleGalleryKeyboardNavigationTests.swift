// PeopleGalleryKeyboardNavigationTests.swift
// People tab: ← / → move the card selection in the DISPLAYED order,
// stop at the ends (no wrap), and land on the first card when nothing is
// selected. Selection is matched by uuid — two Richards are two cards.
//
// Dimensions (feature-test checklist): Logic — the pure index helper;
// Integration — the displayed order with two same-named profiles, and a
// filtered list where the selection is no longer displayed.

import Foundation
import Testing
@testable import VideoScan

@Suite("People gallery — arrow-key navigation")
struct PeopleGalleryKeyboardNavigationTests {

    private typealias Nav = PeopleGalleryNavigation

    // MARK: Logic — the pure index helper

    @Test func emptyGalleryIsANoOp() {
        #expect(Nav.targetIndex(current: nil, count: 0, step: .next) == nil)
        #expect(Nav.targetIndex(current: nil, count: 0, step: .previous) == nil)
        #expect(Nav.targetIndex(current: 0, count: 0, step: .next) == nil)
    }

    @Test func noSelectionLandsOnTheFirstCardEitherWay() {
        #expect(Nav.targetIndex(current: nil, count: 4, step: .next) == 0)
        #expect(Nav.targetIndex(current: nil, count: 4, step: .previous) == 0)
        // A stale index (selection filtered out) counts as no selection.
        #expect(Nav.targetIndex(current: 9, count: 4, step: .next) == 0)
        #expect(Nav.targetIndex(current: -1, count: 4, step: .previous) == 0)
    }

    @Test func stepsOneCardAndStopsAtTheEndsWithoutWrapping() {
        #expect(Nav.targetIndex(current: 1, count: 4, step: .next) == 2)
        #expect(Nav.targetIndex(current: 2, count: 4, step: .previous) == 1)
        #expect(Nav.targetIndex(current: 3, count: 4, step: .next) == nil, "→ on the last card: stop")
        #expect(Nav.targetIndex(current: 0, count: 4, step: .previous) == nil, "← on the first card: stop")
        #expect(Nav.targetIndex(current: 0, count: 1, step: .next) == nil)
        #expect(Nav.targetIndex(current: 0, count: 1, step: .previous) == nil)
    }

    // MARK: Integration — the displayed order, two Richards

    private func profile(_ name: String) -> POIProfile {
        POIProfile(name: name, referencePath: "", uuid: UUID())
    }

    @Test func walksTheDisplayedOrderByUUIDNotByName() {
        let donna = profile("Donna")
        let richardSr = profile("Richard")
        let richardJr = profile("Richard")
        let tim = profile("Tim")
        let displayed = [donna, richardSr, richardJr, tim]

        // → from Richard Sr must land on Richard Jr — the OTHER Richard.
        let fromSenior = Nav.neighbor(of: richardSr.uuid, in: displayed, step: .next)
        #expect(fromSenior?.uuid == richardJr.uuid)
        #expect(fromSenior?.uuid != richardSr.uuid)
        // ← from Richard Jr goes back to Sr, not to Donna.
        #expect(Nav.neighbor(of: richardJr.uuid, in: displayed, step: .previous)?.uuid == richardSr.uuid)
        // Ends stop.
        #expect(Nav.neighbor(of: tim.uuid, in: displayed, step: .next) == nil)
        #expect(Nav.neighbor(of: donna.uuid, in: displayed, step: .previous) == nil)
        // No selection → first card.
        #expect(Nav.neighbor(of: nil, in: displayed, step: .next)?.uuid == donna.uuid)
        #expect(Nav.neighbor(of: nil, in: displayed, step: .previous)?.uuid == donna.uuid)
    }

    @Test func aFilteredOutSelectionLandsOnTheFirstDisplayedCard() {
        let donna = profile("Donna")
        let richard = profile("Richard")
        let tim = profile("Tim")
        // "Show Missing GEDCOM" hid Donna; she is still the active profile.
        let displayed = [richard, tim]
        #expect(Nav.neighbor(of: donna.uuid, in: displayed, step: .next)?.uuid == richard.uuid)
        #expect(Nav.neighbor(of: donna.uuid, in: displayed, step: .previous)?.uuid == richard.uuid)
        #expect(Nav.neighbor(of: donna.uuid, in: [], step: .next) == nil)
    }
}
