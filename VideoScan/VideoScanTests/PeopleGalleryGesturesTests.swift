// PeopleGalleryGesturesTests.swift
// People tab: double-click a person card opens that person's editor —
// the SAME edit request the card's context-menu "Edit <name>…" builds,
// keyed by uuid so two people who share a name stay two people.

import Foundation
import Testing
@testable import VideoScan

@Suite("People gallery — card clicks")
struct PeopleGalleryGesturesTests {

    private func profile(_ name: String, uuid: UUID = UUID()) -> POIProfile {
        POIProfile(name: name, referencePath: "", uuid: uuid)
    }

    // (For Rick: `#expect` is Swift Testing's EXPECT_*; it records a
    // failure and keeps going, like gtest's non-fatal assertions.)

    @Test func doubleClickResolvesToTheMenuEditRequest() {
        let donna = profile("Donna")
        let menuRequest = PersonEditRequest(donna)
        let action = PeopleCardAction.resolve(.double, on: donna, isBeingScanned: false)
        #expect(action == .edit(menuRequest))
        guard case .edit(let request) = action else { return }
        #expect(request.profileUUID == donna.uuid)
        #expect(request.originalName == "Donna")
    }

    @Test func twoRichardsAreTwoDifferentEditRequests() {
        let senior = profile("Richard", uuid: UUID())
        let junior = profile("Richard", uuid: UUID())
        let seniorEdit = PeopleCardAction.resolve(.double, on: senior, isBeingScanned: false)
        let juniorEdit = PeopleCardAction.resolve(.double, on: junior, isBeingScanned: false)
        #expect(seniorEdit != juniorEdit, "same name, different people — the request must differ")
        #expect(seniorEdit == .edit(PersonEditRequest(senior)))
        #expect(juniorEdit == .edit(PersonEditRequest(junior)))
    }

    @Test func singleClickSelectsAndScanningRefusesBothClicks() {
        let tim = profile("Tim")
        #expect(PeopleCardAction.resolve(.single, on: tim, isBeingScanned: false) == .select)
        #expect(PeopleCardAction.resolve(.single, on: tim, isBeingScanned: true) == .refuseWhileScanning)
        #expect(PeopleCardAction.resolve(.double, on: tim, isBeingScanned: true) == .refuseWhileScanning)
    }
}
