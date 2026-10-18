// CatalogCutoverB25Tests.swift
// Cutover B2.5 — codex's B2.4 closing-pass findings
// (docs/reviews/codex/codex-review-cutover-b2-4-closing-pass-2026-10-18.md,
// "Codex answer"), written RED FIRST against 6e6717930:
//
//   P1  `placeRecord` dropped the old record's UNSAVED edits: edit the old
//       row's family music, then — before the 2 s debounce — land a
//       same-digest heir carrying a different family music; the heir's
//       value was kept, the old id purged, and the old edit never reached
//       `row_knowledge` (the log said only "family music"). Now placeRecord
//       commits the old record FIRST; when that commit cannot run (held,
//       blocked, refused) nothing is replaced — the new record lands beside
//       the old one and the log says NOT RECORDED. The log names every
//       conflicting value with BOTH values.
//   P1  an attestation removal matched the key without the label: A removes
//       x while B relabels x → the store's result depended on commit order.
//       Now in-memory copies end with the relabelled x in either order.
//
// Dimensions: LOGIC (codex's scenarios; the held store; both commit
// orders); ISOLATION (a sandbox catalog folder); SENSOR CatalogPurgeDoor
// SensorTests (placeRecord still calls the purge door); MEDIA N/A (no file
// is opened — the placeRecord callers' own suites cover the matrix); SCALE
// in Core (CatalogCommitScaleTests, unchanged pipeline).
//
// Suites (filter by SUITE): CatalogPlaceRecordUnsavedEditTests · CatalogAttestationRelabelTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - P1: placeRecord commits the old record before it replaces it

@Suite("Catalog placeRecord — the replaced record's unsaved edits are saved before anything is replaced", .serialized)
@MainActor
struct CatalogPlaceRecordUnsavedEditTests {

    static let oldMusic = FamilyMusicInfo(performer: "Tim", title: "Danny Boy", markedAt: Date(timeIntervalSince1970: 1_790_100_000))
    static let newMusic = FamilyMusicInfo(performer: "Matt", title: "Amazing Grace",
                                          markedAt: Date(timeIntervalSince1970: 1_790_100_100))
    static let reason = "a test job's output replaced the older record at its path"

    @Test("codex B2.4 F1 (exact): unsaved family music on the old row + a same-digest heir with different music → the old edit is in row_knowledge")
    func unsavedEditReachesHistory() async throws {
        let scene = try CutoverScene.make("b25_place_unsaved"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        healthy.familyMusic = Self.oldMusic                                 // edited; the debounce has not fired
        let heir = try scene.replacement(of: healthy, keepDigest: true)
        heir.familyMusic = Self.newMusic
        scene.model.placeRecord(heir, atPath: healthy.fullPath, reason: Self.reason)
        #expect(heir.familyMusic == Self.newMusic, "the heir keeps its own value")
        let history = try scene.sqliteRows("SELECT value_json FROM row_knowledge WHERE field = 'familyMusic' "
                                           + "AND file_id = '\(healthy.id.uuidString)'")
        #expect(history.contains { $0.contains("Danny Boy") })
    }

    @Test("codex B2.4 F1: the log line names the conflicting value with BOTH values")
    func logNamesBothValues() async throws {
        let scene = try CutoverScene.make("b25_place_words"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        healthy.familyMusic = Self.oldMusic
        let heir = try scene.replacement(of: healthy, keepDigest: true)
        heir.familyMusic = Self.newMusic
        scene.model.placeRecord(heir, atPath: healthy.fullPath, reason: Self.reason)
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("family music 'Danny Boy' by Tim"))
        #expect(log.contains("the new record has family music 'Amazing Grace' by Matt"))
    }

    @Test("the old record's commit cannot run (held): nothing is replaced — both stay live, NOT RECORDED, the edit is kept and saved later")
    func heldStoreReplacesNothing() async throws {
        let scene = try CutoverScene.make("b25_place_held"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        await scene.hold()
        healthy.starRating = 2
        let heir = try scene.replacement(of: healthy, keepDigest: true)
        scene.model.placeRecord(heir, atPath: healthy.fullPath, reason: Self.reason)
        #expect(scene.model.records.contains { $0 === healthy })
        #expect(scene.model.records.contains { $0 === heir })
        #expect(healthy.removal == nil)
        #expect(heir.starRating == 0, "nothing was inherited")
        #expect(scene.sandbox.catalogLogText().contains("NOT RECORDED"))
        scene.release()
        // The old record still holds the live path, so the store refuses the
        // new one there by its own rule (named once; it waits, refused not
        // lost — the existing NOT RECORDED shape). The save's truth is
        // therefore false; what matters here is the old row and its edit.
        _ = scene.model.saveCatalogNow()
        let reloaded = try await scene.sqliteLoad()
        let kept = try #require(reloaded.records.first { $0.id == healthy.id }, "the old row was purged")
        #expect(kept.starRating == 2)
        #expect(kept.removal == nil)
        #expect(reloaded.purgedCount == 0)
    }

    @Test("different digest: the old row's unsaved edit is saved too, then the row is retired replacedAtPath")
    func unsavedEditBeforeRetire() async throws {
        let scene = try CutoverScene.make("b25_place_retire"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        scene.model.setUserNotes("the lake house", for: healthy)            // unsaved
        let output = try scene.replacement(of: healthy, keepDigest: false)
        scene.model.placeRecord(output, atPath: healthy.fullPath, reason: Self.reason)
        let history = try scene.sqliteRows("SELECT value_json FROM row_knowledge WHERE field = 'userNotes' "
                                           + "AND file_id = '\(healthy.id.uuidString)'")
        #expect(history.contains { $0.contains("the lake house") })
        #expect(healthy.removal?.reason.rawValue == "replacedAtPath")
    }
}

// MARK: - P1: an attestation removal never takes another copy's relabel

@Suite("Catalog attestations — A removes x while B relabels x: the relabelled x survives in either order", .serialized)
@MainActor
struct CatalogAttestationRelabelTests {

    static let x = BackupAttestation(kind: .cloud, answer: .yes, label: "iCloud", attestedAt: Date(timeIntervalSince1970: 1_790_000_000))
    static let xRelabelled = BackupAttestation(kind: .cloud, answer: .yes, label: "iCloud (Donna's account)",
                                               attestedAt: Date(timeIntervalSince1970: 1_790_000_000))
    static let z = BackupAttestation(kind: .drive, answer: .yes, label: "the drive at Tim's",
                                     attestedAt: Date(timeIntervalSince1970: 1_790_000_100))

    @Test("codex B2.4 F2: from {x, z}, A removes x, B relabels x, one save → both copies {x′, z}; relaunch the same",
          arguments: [false, true])
    func removeVersusRelabel(bFirst: Bool) async throws {
        let scene = try CutoverScene.make("b25_attest_\(bFirst)"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let a = try scene.record(.curatedConflictA)
        let b = try scene.record(.curatedConflictB)
        a.backupAttestations = [Self.x, Self.z]
        #expect(scene.model.saveCatalogNow())
        #expect(b.backupAttestations == [Self.x, Self.z], "the first edit follows to the other copy")
        try scene.commitOrder(bFirst: bFirst)
        a.backupAttestations = [Self.z]
        b.backupAttestations = [Self.xRelabelled, Self.z]
        #expect(scene.model.saveCatalogNow())
        #expect(a.backupAttestations == [Self.xRelabelled, Self.z])
        #expect(b.backupAttestations == [Self.xRelabelled, Self.z])
        try await scene.relaunch()
        #expect(try scene.record(.curatedConflictA).backupAttestations == [Self.xRelabelled, Self.z])
    }
}

@MainActor
extension CutoverScene {

    /// Put copy B before copy A in `records` (a commit writes in records
    /// order) when `bFirst`; A before B otherwise.
    func commitOrder(bFirst: Bool) throws {
        let a = try #require(model.records.firstIndex { $0.id.uuidString == PoisonedCatalogFixture.id(.curatedConflictA) })
        let b = try #require(model.records.firstIndex { $0.id.uuidString == PoisonedCatalogFixture.id(.curatedConflictB) })
        guard (b > a) == bFirst else { return }
        model.records.swapAt(a, b)
    }
}
