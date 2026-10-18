// CatalogCutoverB27Tests.swift
// Cutover B2.7 — codex's B2.5 + B2.6 final closing pass
// (docs/reviews/codex/codex-review-cutover-b2-5-b2-6-final-closing-pass-2026-10-18.md):
// `placeRecord` swapped a SAME-ID record in immediately, skipping both the
// save-first protection and inheritance. A job holding a detached snapshot
// of a record (same id, path, digest) that lands it after the person edited
// the live record would drop that edit: it never reached SQLite or history.
// Now a same-id landing commits the live record first (history), keeps the
// live record's curated values on the incoming one (the person's word wins
// over a job's snapshot), and when the commit cannot run, the live record
// stays and the job's update is NOT RECORDED (refused, not lost).
//
// Dimensions: LOGIC (codex's scenario; the held store); ISOLATION (sandbox
// catalog); SENSOR CatalogPurgeDoorSensorTests (placeRecord is still the one
// landing door); MEDIA N/A; SCALE unchanged pipeline.
//
// Suite (filter by SUITE): CatalogPlaceRecordSameIDTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Catalog placeRecord — a same-id landing never drops the live record's unsaved edit", .serialized)
@MainActor
struct CatalogPlaceRecordSameIDTests {

    static let reason = "a test job's output landed on the record it was made from"

    /// A detached copy of `source` with the SAME id (a job's snapshot).
    private static func snapshot(of source: VideoRecord) throws -> VideoRecord {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VideoRecord.self, from: encoder.encode(VideoRecordDTO(source)))
    }

    @Test("codex (exact): a stale same-id snapshot lands after the live notes were edited → the edit survives in memory")
    func staleSnapshotKeepsTheEditInMemory() async throws {
        let scene = try CutoverScene.make("b27_same_id_memory"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let live = try scene.record(.healthy)
        let stale = try Self.snapshot(of: live)
        live.userNotes = "edited by a person just now"
        scene.model.placeRecord(stale, atPath: live.fullPath, reason: Self.reason)
        let now = try #require(scene.model.records.first { $0.id == live.id })
        #expect(now.userNotes == "edited by a person just now")
    }

    @Test("codex (exact): … and the edit survives a relaunch")
    func staleSnapshotKeepsTheEditAfterRelaunch() async throws {
        let scene = try CutoverScene.make("b27_same_id_relaunch"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let live = try scene.record(.healthy)
        let stale = try Self.snapshot(of: live)
        live.userNotes = "edited by a person just now"
        scene.model.placeRecord(stale, atPath: live.fullPath, reason: Self.reason)
        _ = scene.model.saveCatalogNow()
        #expect(try await scene.reloaded(.healthy).userNotes == "edited by a person just now")
    }

    @Test("the live record's commit cannot run (held): the live record stays, its edit kept; NOT RECORDED")
    func heldStoreKeepsTheLiveRecord() async throws {
        let scene = try CutoverScene.make("b27_same_id_held"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let live = try scene.record(.healthy)
        let stale = try Self.snapshot(of: live)
        await scene.hold()
        live.userNotes = "edited while held"
        scene.model.placeRecord(stale, atPath: live.fullPath, reason: Self.reason)
        let now = try #require(scene.model.records.first { $0.id == live.id })
        #expect(now === live)
        #expect(now.userNotes == "edited while held")
        #expect(scene.sandbox.catalogLogText().contains("NOT RECORDED"))
    }
}
