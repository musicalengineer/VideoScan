// CatalogCutoverB24Tests.swift
// Cutover B2.4 — codex's last two findings on the SQLite write side
// (docs/reviews/codex/codex-review-cutover-b2-3-veto-explicit-purge-2026-10-18.md,
// "Codex answer"), written RED FIRST against 64ea21ac6:
//
//   P1  shared SETS across copies were order-dependent: two copies of one
//       content change their tags (or backup attestations) differently in
//       one save → the copy written last wins, in memory and after a
//       relaunch. Now each copy writes a DELTA against its own baseline and
//       every copy shows the set the store ENDS with.
//   P1  `placeRecord` purged a replaced row's curation: Balance Audio
//       reusing an available filename (the earlier balanced file was
//       removed) purged the curated row. Now: same whole-file digest → the
//       new record inherits the curated values first; different or unknown
//       digest → the old row is kept, removed from the catalog with reason
//       `replacedAtPath`, and one log line names what it carried.
//
// Dimensions: LOGIC (codex's scenarios, both kinds of set, both digest
// cases); MEDIA (the end-to-end Balance Audio run, mp4/h264+aac — the
// placeRecord callers' own media suites cover the matrix); ISOLATION (a
// sandbox catalog folder and a temp media folder); SENSOR CatalogPurgeDoor
// SensorTests (placeRecord still calls the purge door); SCALE in Core
// (CatalogCommitScaleTests, unchanged pipeline).
//
// Suites (filter by SUITE): CatalogSharedSetTests · CatalogPlaceRecordTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - P1: shared sets are per-copy deltas

@Suite("Catalog shared sets — copies edited differently in one save keep every addition and removal", .serialized)
@MainActor
struct CatalogSharedSetTests {

    static let x = BackupAttestation(kind: .cloud, answer: .yes, label: "iCloud", attestedAt: Date(timeIntervalSince1970: 1_790_000_000))
    static let z = BackupAttestation(kind: .drive, answer: .yes, label: "the drive at Tim's",
                                     attestedAt: Date(timeIntervalSince1970: 1_790_000_100))
    static let y = BackupAttestation(kind: .offsite, answer: .yes, label: "the bank box",
                                     attestedAt: Date(timeIntervalSince1970: 1_790_000_200))

    @Test("codex F2 (tags): A {base}→{base,a}, B {base}→{base,b}, one save → both copies {a,b,base}; relaunch the same")
    func tagsUnion() async throws {
        let scene = try CutoverScene.make("b24_tags"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let a = try scene.record(.curatedConflictA)
        let b = try scene.record(.curatedConflictB)
        a.tags = ["base"]
        #expect(scene.model.saveCatalogNow())
        #expect(b.tags == ["base"], "the first edit follows to the other copy")
        a.tags = ["base", "a"]
        b.tags = ["base", "b"]
        #expect(scene.model.saveCatalogNow())
        #expect(a.tags == ["a", "b", "base"])
        #expect(b.tags == ["a", "b", "base"])
        try await scene.relaunch()
        #expect(try scene.record(.curatedConflictA).tags == ["a", "b", "base"])
        #expect(try scene.record(.curatedConflictB).tags == ["a", "b", "base"])
    }

    @Test("codex F2 (attestations): from {x,z}, A removes x while B adds y → both copies {z,y}; relaunch the same")
    func attestationsDelta() async throws {
        let scene = try CutoverScene.make("b24_attest"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let a = try scene.record(.curatedConflictA)
        let b = try scene.record(.curatedConflictB)
        a.backupAttestations = [Self.x, Self.z]
        #expect(scene.model.saveCatalogNow())
        #expect(b.backupAttestations == [Self.x, Self.z], "the first edit follows to the other copy")
        a.backupAttestations = [Self.z]
        b.backupAttestations = [Self.x, Self.z, Self.y]
        #expect(scene.model.saveCatalogNow())
        #expect(a.backupAttestations == [Self.z, Self.y])
        #expect(b.backupAttestations == [Self.z, Self.y])
        try await scene.relaunch()
        #expect(try scene.record(.curatedConflictA).backupAttestations == [Self.z, Self.y])
        #expect(try scene.record(.curatedConflictB).backupAttestations == [Self.z, Self.y])
    }

    @Test("the same pattern for people (already a store delta): A confirms Donna, B confirms Matt → both copies show both")
    func peopleUnion() async throws {
        let scene = try CutoverScene.make("b24_people"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let a = try scene.record(.curatedConflictA)
        let b = try scene.record(.curatedConflictB)
        a.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: Date(timeIntervalSince1970: 1_790_500_000))]
        b.confirmedByUserPeople = [ConfirmedTag(name: "Matt", confirmedAt: Date(timeIntervalSince1970: 1_790_500_100))]
        #expect(scene.model.saveCatalogNow())
        #expect(a.confirmedByUserPeople.map(\.name) == ["Donna", "Matt"])
        #expect(b.confirmedByUserPeople.map(\.name) == ["Donna", "Matt"])
        try await scene.relaunch()
        #expect(try scene.record(.curatedConflictB).confirmedByUserPeople.map(\.name) == ["Donna", "Matt"])
    }
}

// MARK: - P1: placeRecord never purges a replaced row's curation

@Suite("Catalog placeRecord — a job's output at a path keeps the replaced row's curation", .serialized)
@MainActor
struct CatalogPlaceRecordTests {

    @Test("different (unknown) digest: the old row is removed from the catalog as replacedAtPath with its curation, never purged")
    func differentDigestKeepsOldRow() async throws {
        let scene = try CutoverScene.make("b24_place_diff"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        healthy.starRating = 2
        scene.model.setUserNotes("the lake house", for: healthy)
        #expect(scene.model.saveCatalogNow())
        let output = try scene.replacement(of: healthy, keepDigest: false)
        scene.model.placeRecord(output, atPath: healthy.fullPath, reason: "a test job's output replaced the older record at its path")
        #expect(scene.model.saveCatalogNow())
        let reloaded = try await scene.sqliteLoad()
        let kept = try #require(reloaded.records.first { $0.id == healthy.id }, "the replaced row was purged")
        #expect(kept.removal?.reason.rawValue == "replacedAtPath")
        #expect(kept.starRating == 2)
        #expect(kept.userNotes == "the lake house")
        #expect(reloaded.purgedCount == 0)
        #expect(scene.sandbox.catalogLogText().contains("had stars 2, notes 'the lake house' — kept in the catalog's history"))
    }

    @Test("same whole-file digest: the new record inherits every curated value before the old id is purged")
    func sameDigestInherits() async throws {
        let scene = try CutoverScene.make("b24_place_same"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        healthy.starRating = 2
        healthy.tags = ["Gold"]
        scene.model.setUserNotes("the lake house", for: healthy)
        #expect(scene.model.saveCatalogNow())
        let output = try scene.replacement(of: healthy, keepDigest: true)
        scene.model.placeRecord(output, atPath: healthy.fullPath, reason: "a test job's output replaced the older record at its path")
        #expect(output.starRating == 2)
        #expect(output.userNotes == "the lake house")
        #expect(output.tags == ["Gold"])
        #expect(scene.model.saveCatalogNow())
        let reloaded = try await scene.sqliteLoad()
        let landed = try #require(reloaded.records.first { $0.id == output.id })
        #expect(landed.starRating == 2)
        #expect(landed.userNotes == "the lake house")
        #expect(reloaded.purgedCount == 1)
    }

    @Test("codex (exact): curate + save clip_balanced, remove its file, rerun Balance Audio → old row replacedAtPath, curation intact, nothing purged",
          .timeLimit(.minutes(3)))
    func balanceAudioRerunKeepsCuration() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let scene = try CutoverScene.make("b24_balance"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let dir = try BalanceAudioTestMedia.makeScratchDir("b24_rerun")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try BalanceAudioTestMedia.generate(into: dir, channelCase: .leftOnly, wrapper: .mp4H264Aac)
        let analysis = try await AudioBalanceProbe.analyze(path: path)
        let source = makeBalanceSourceRecord(path: path, durationSeconds: analysis.shape.durationSeconds,
                                             audioCodec: analysis.shape.audioCodec)
        scene.model.records.append(source)

        let first = try await scene.balance(source, analysis)
        let earlier = try #require(scene.model.records.first { $0.fullPath == first.path })
        try scene.hashInFull(earlier)
        earlier.starRating = 2
        scene.model.setUserNotes("Grandma's 80th", for: earlier)
        #expect(scene.model.saveCatalogNow())
        #expect(try scene.sqliteRows("SELECT count(*) FROM files WHERE id = '\(earlier.id.uuidString)'") == ["1"])

        try FileManager.default.removeItem(at: first)                      // removed outside the app
        let second = try await scene.balance(source, analysis)
        #expect(second.path == first.path, "the available filename is reused")
        #expect(scene.model.saveCatalogNow())

        let marker = try scene.sqliteRows("SELECT removal_state || '|' || removal_reason FROM files WHERE id = '\(earlier.id.uuidString)'")
        #expect(marker == ["removedFromCatalog|replacedAtPath"])
        let reloaded = try await scene.sqliteLoad()
        let kept = try #require(reloaded.records.first { $0.id == earlier.id })
        #expect(kept.starRating == 2)
        #expect(kept.userNotes == "Grandma's 80th")
        #expect(reloaded.purgedCount == 0)
        #expect(scene.sandbox.catalogLogText().contains("notes 'Grandma's 80th' — kept in the catalog's history"))
    }
}

@MainActor
extension CutoverScene {

    /// What a job's output looks like when it lands at `source`'s path: a
    /// NEW id and no curated values; its whole-file hash kept (the same
    /// bytes) or dropped (a fresh probe that has not been hashed).
    func replacement(of source: VideoRecord, keepDigest: Bool) throws -> VideoRecord {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(VideoRecordDTO(source))) as? [String: Any])
        object["id"] = UUID().uuidString
        object["pairedWithID"] = nil
        object["starRating"] = 0
        object["userNotes"] = ""
        object["tags"] = [String]()
        if !keepDigest {
            object["contentFixity"] = nil
            object["archiveFixity"] = nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VideoRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// Run Balance Audio on `source` to the end; the published file.
    func balance(_ source: VideoRecord, _ analysis: AudioBalanceAnalysis) async throws -> URL {
        let job = BalanceAudioJob(record: source, analysis: analysis, model: model)
        job.start()
        await job.task?.value
        guard case .finished = job.state else { throw CutoverFailure(words: "job did not finish: \(job.state) — \(job.subtitle)") }
        return try #require(job.publishedURL)
    }

    /// Fill In Full Hashes for one record: its whole-file SHA-256 bound to its stamp.
    func hashInFull(_ record: VideoRecord) throws {
        let url = URL(fileURLWithPath: record.fullPath)
        let size = try #require((try FileManager.default.attributesOfItem(atPath: url.path))[.size] as? NSNumber).int64Value
        record.sizeBytes = size
        record.contentFixity = try #require(ContentFixity.captured(path: url.path, digest: try sha256(url), byteCount: size))
    }
}
