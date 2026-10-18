// CatalogCutoverB26Tests.swift
// Cutover B2.6 — the same class as codex's B2.4 closing-pass finding 2
// (docs/reviews/codex/codex-review-cutover-b2-4-closing-pass-2026-10-18.md),
// for PEOPLE, written RED FIRST against 87c84b898: a people removal matched
// (name, kind) without the confirmation date, and a re-dated confirmation
// was an in-place upsert. A un-confirms Donna while B re-confirms her with a
// new date → the store's result depended on commit order. Now in-memory
// copies — and a relaunch — end with Donna at the new date in either order.
//
// Dimensions: LOGIC (both commit orders, relaunch); ISOLATION (a sandbox
// catalog folder); MEDIA N/A (no file is opened); SCALE in Core
// (CatalogCommitScaleTests, unchanged pipeline); SENSOR Core
// CatalogCommitB26Tests (the store rows themselves).
//
// Suites (filter by SUITE): CatalogPeopleRedateTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Catalog people — A un-confirms Donna, B re-confirms her with a new date: the re-dated Donna survives in either order", .serialized)
@MainActor
struct CatalogPeopleRedateTests {

    static let donna = ConfirmedTag(name: "Donna", confirmedAt: Date(timeIntervalSince1970: 1_790_000_000))
    static let donnaRedated = ConfirmedTag(name: "Donna", confirmedAt: Date(timeIntervalSince1970: 1_790_500_000))
    static let tim = ConfirmedTag(name: "Tim", confirmedAt: Date(timeIntervalSince1970: 1_790_000_100))

    @Test("from {Donna@t1, Tim}, A drops Donna, B re-dates Donna to t2, one save → both copies {Donna@t2, Tim}; relaunch the same",
          arguments: [false, true])
    func removeVersusRedate(bFirst: Bool) async throws {
        let scene = try CutoverScene.make("b26_people_\(bFirst)"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let a = try scene.record(.curatedConflictA)
        let b = try scene.record(.curatedConflictB)
        a.confirmedByUserPeople = [Self.donna, Self.tim]
        #expect(scene.model.saveCatalogNow())
        #expect(b.confirmedByUserPeople == [Self.donna, Self.tim], "the first edit follows to the other copy")
        try scene.commitOrder(bFirst: bFirst)
        a.confirmedByUserPeople = [Self.tim]
        b.confirmedByUserPeople = [Self.donnaRedated, Self.tim]
        #expect(scene.model.saveCatalogNow())
        #expect(a.confirmedByUserPeople == [Self.donnaRedated, Self.tim])
        #expect(b.confirmedByUserPeople == [Self.donnaRedated, Self.tim])
        try await scene.relaunch()
        #expect(try scene.record(.curatedConflictA).confirmedByUserPeople == [Self.donnaRedated, Self.tim])
    }
}
