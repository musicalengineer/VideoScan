// CatalogStoreDurabilityCodex141Tests.swift
// Codex cycle #141 (docs/reviews/codex/codex-review-catalog-store-consistency-
// 2026-10-25.md), the Core-only findings 1 and 4 (finding 6 is on fix/store-durability-codex141, awaiting a ruling) — each seen RED before
// its fix:
//
//   | finding | test                                              | red (before)                                  | green (after) |
//   |---------|---------------------------------------------------|-----------------------------------------------|---------------|
//   | 1  P1   | archivalWriterUsesFullSynchronization             | PRAGMA synchronous on the WRITER read 1       | reads 2       |
//   |         |                                                   | (GRDB's WAL setup runs `synchronous=NORMAL`   |               |
//   |         |                                                   | after prepareDatabase; readers stayed FULL)   |               |
//   | 4  P2   | clearingTheLastCuratedValueStaysClearedAcrossRelaunch | the clear committed (user_notes 0), then the | .alreadyFilled|
//   |         |                                                   | relaunch's pass read .filled(rows: 1), the    | note "", 0    |
//   |         |                                                   | note came back and user_notes had 1 row       | rows          |
//   | 6  P2   | aNewerSchemaIsRefusedWithoutTheFileChanging       | refused, but the bytes differed: header 18/19 | byte-identical|
//   |         |                                                   | read 2/2 (WAL) and a -wal appeared — the pool | 1/1, no -wal  |
//   |         |                                                   | was built before the version check            |               |
//   | 4  P2   | clearingTheLastCuratedValueStaysClearedAcrossRelaunch | the clear committed (user_notes 0), then the | .alreadyFilled|
//   |         |                                                   | relaunch's pass read .filled(rows: 1), the    | note "", 0    |
//   |         |                                                   | note came back and user_notes had 1 row       | rows          |
//
// Closing pass (docs/reviews/codex/codex-review-store-durability-closing-
// 2026-10-25.md, cycle #142) — three residuals on F6, each seen RED:
//
//   | finding | test                                              | red (before)                                  | green (after) |
//   |---------|---------------------------------------------------|-----------------------------------------------|---------------|
//   | 6-1 P1  | anAdmissionGoneStaleBeforeThePoolIsRefused        | .readWrite — prepare(admitted: true) skipped   | .refused,     |
//   |         |                                                   | the version check; the bump after admission   | write refused |
//   |         |                                                   | (same inode) opened read-write                | "not open"    |
//
// Lives under Tests/…/Store/ because it opens the same file with a plain
// GRDB queue (the sensor allows `import GRDB` only here and in
// Sources/…/Store/). One condition per #expect.
//
// Suite (filter by SUITE): CatalogStoreDurabilityCodex141Tests

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("CatalogStoreDurabilityCodex141 — the writer's durability, refuse-before-WAL, the display pass marker")
struct CatalogStoreDurabilityCodex141Tests {

    /// A locked box the synchronous write body fills (for Rick: a mutex
    /// around one optional int; the body is `@Sendable`, so no captured var).
    private final class Reading: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int?
        func set(_ v: Int?) { lock.withLock { value = v } }
        func get() -> Int? { lock.withLock { value } }
    }

    // MARK: - Finding 1 (P1): the archival WRITER runs synchronous=FULL

    @Test func archivalWriterUsesFullSynchronization() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0, durability: .archival)
        defer { fixture.remove() }
        let repository = GRDBCatalogRepository(host: "writer-pragmas", durability: .archival)
        let opened = await repository.open(at: fixture.url)
        try #require(opened == .readWrite)
        let reading = Reading()
        let outcome = await repository.write(as: .ui) { transaction in
            guard let tx = transaction as? GRDBTransaction else { throw FixtureFailure(words: "not a GRDB transaction") }
            reading.set(try Int.fetchOne(tx.db, sql: "PRAGMA synchronous"))
        }
        #expect(outcome == .committed(generation: 1))
        #expect(reading.get() == 2, "the writer connection must be FULL (2); GRDB's WAL setup leaves it NORMAL (1)")
        await repository.close()
    }

    // MARK: - Finding 4 (P2): clearing the last curated value must not resurrect the imported one

    private static let volume = "11111111-1111-1111-1111-111111111111"
    private static let digestA = String(repeating: "a", count: 64)
    private static let fileID = "00000000-0000-4000-8000-000000000041"
    private static let runID = "R-codex141"
    private static let importedNote = "the lake house, imported"

    private static func importRun() -> CatalogRow.ImportRun {
        CatalogRow.ImportRun(runID: runID, startedAt: 1_700_000_000, sourceSHA256: String(repeating: "d", count: 64),
                             sourceGeneration: 5, integrityRunID: "IR-1", auditRunStartedAt: 1_699_990_000,
                             auditRunFinishedAt: 1_699_990_500, auditGeneration: 5, integrityStartedAt: 1_699_995_000,
                             integrityGeneration: 5)
    }

    private static func file(_ id: String, digest: String, path: String) -> CatalogRecordDTO.FileRow {
        CatalogRecordDTO.FileRow(
            id: id, contentDigest: digest, volumeUUID: volume, fullPath: path, pathFold: CatalogRecordDTO.pathFold(path),
            filename: (path as NSString).lastPathComponent, ext: "mov", directory: (path as NSString).deletingLastPathComponent,
            // A content fixity WITH its identity stamp: that is what gives the
            // loaded record a whole-file digest (VideoRecord+Loaded), so the
            // commit stores it rather than holding it as a pending row.
            sizeBytes: 100, fsCreatedAt: nil, fsModifiedAt: nil, stampDevice: 1, stampInode: 41, stampMtimeNs: 1_700_000_000_000_000_000,
            stampCtimeNs: 1_700_000_000_000_000_000, stampVolumeUUID: volume, digestComputedAt: 1_700_000_000, digestSource: .contentFixity,
            sampledHash: nil, sampledHashAt: nil, partialMD5: nil, streamType: "Video+Audio", durationS: 1, container: "mov",
            videoCodec: "", audioCodec: "", embeddedCreatedAt: nil, embeddedCreatedSource: nil, probeExtra: [:],
            scanHost: "", scannedAt: nil, scanRootLabel: "", bundleContainer: "", sourceHost: "", originalFullPath: nil,
            originVolume: nil, machineNotes: "", lifecycle: "Cataloged", archiveStage: "None",
            masterLocation: "", setAsideReason: nil, needsReformat: false, workspaceActive: false,
            removalState: nil, removalSince: nil, removalReason: nil, removalTrashPath: nil,
            removalTrashEmptiedAt: nil, removalLastSeen: nil, removalRevision: 0,
            auditSeenVolumeUUID: nil, auditSeenMountFrom: nil, auditSeenDeviceKey: nil, auditSeenAt: nil, cataloguedAt: nil)
    }

    /// A catalog whose ONLY curated value is one imported note on one file:
    /// the import run, the volume, the content, the file and the
    /// `knowledge_sources` row (the immutable evidence the display pass reads).
    private func seedOneFileWithOneImportedNote() async throws -> StoreFixture {
        let fixture = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        let repository = GRDBCatalogRepository(host: "codex141", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let outcome = await repository.write(as: .importRun) { tx in
            try tx.insertImportRun(Self.importRun())
            try tx.insertVolume(CatalogRecordDTO.VolumeRowDTO(volumeUUID: Self.volume, lastName: "A", mountType: "local", remoteServer: ""),
                                caseSensitive: false)
            try tx.insertContent(CatalogRecordDTO.ContentRow(digest: Self.digestA, algorithm: "sha256", byteCount: 100,
                                                             firstSeenAt: 1_700_000_000, firstSeenHow: .import))
            try tx.insertFile(Self.file(Self.fileID, digest: Self.digestA, path: "/Volumes/A/lake.mov"), volumeCaseSensitive: false)
            try tx.insertKnowledgeSource(CatalogRow.KnowledgeSource(
                importRun: Self.runID, sourceOrdinal: 0, jsonRowID: Self.fileID, digest: Self.digestA,
                value: .init(field: .userNotes, valueJSON: .string(Self.importedNote), setAt: nil)))
        }
        try #require(outcome == .committed(generation: 1))
        await repository.close()
        return fixture
    }

    /// Open, run the load (display pass + snapshot), build the one record.
    private func load(_ fixture: StoreFixture) async throws -> (CatalogLoad.Snapshot, VideoRecord) {
        let repository = GRDBCatalogRepository(host: "codex141", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let snapshot = try await CatalogLoad.read(repository)
        await repository.close()
        let row = try #require(snapshot.rows.first)
        return (snapshot, try VideoRecord(loaded: row))
    }

    private func userNotesRows(_ fixture: StoreFixture) throws -> Int {
        try DatabaseQueue(path: fixture.url.path).read { try Int.fetchOne($0, sql: "SELECT count(*) FROM user_notes") ?? 0 }
    }

    @Test func clearingTheLastCuratedValueStaysClearedAcrossRelaunch() async throws {
        let fixture = try await seedOneFileWithOneImportedNote()
        defer { fixture.remove() }

        // First load: the display pass derives the note from the evidence.
        let (first, record) = try await load(fixture)
        guard case .filled(let rows, _, _, _) = first.displayPass else {
            Issue.record("expected the display pass to fill, got \(first.displayPass)"); return
        }
        #expect(rows == 1)
        #expect(record.userNotes == Self.importedNote)

        // Rick clears the note; the commit lands and the display row goes.
        record.userNotes = ""
        let repository = GRDBCatalogRepository(host: "codex141", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let snapshot = VideoRecordDTO(record)
        let item = CatalogCommit.Item(id: record.id, snapshot: snapshot, fingerprint: CatalogChangeDetector.fingerprint(snapshot))
        let committed = await CatalogCommit.run(CatalogCommit.Plan(door: .save, items: [item]), on: repository)
        await repository.close()
        #expect(committed.isCommitted, Comment(rawValue: "\(committed)"))
        #expect(try userNotesRows(fixture) == 0)

        // Relaunch: the pass must NOT run again — the evidence is still there,
        // but Rick's clear is the newer truth.
        let (second, reloaded) = try await load(fixture)
        #expect(second.displayPass == .alreadyFilled, Comment(rawValue: "\(second.displayPass)"))
        #expect(reloaded.userNotes.isEmpty, "the imported note came back after the clear: \(reloaded.userNotes)")
        #expect(try userNotesRows(fixture) == 0, "a user_notes row reappeared from the immutable evidence")
    }

    // MARK: - Finding 6 (P2): a newer-schema file is refused BEFORE anything touches it

    /// A current fixture stamped one version ahead and put back in
    /// rollback-journal mode (no -wal / -shm beside it), so any touch by the
    /// open — the WAL switch, GRDB's init table — changes the file's bytes.
    private func newerSchemaFixtureInDeleteMode() async throws -> (StoreFixture, Int, Data) {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        let newer = GRDBCatalogRepository.currentSchemaVersion + 1
        let queue = try DatabaseQueue(path: fixture.url.path)
        try queue.inDatabase { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            try db.execute(sql: "UPDATE catalog_state SET schema_version = \(newer) WHERE singleton = 1")
            try db.execute(sql: "PRAGMA user_version = \(newer)")
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE")
        }
        try queue.close()
        // SQLite may leave an empty -shm behind the mode switch; in DELETE
        // mode it is meaningless. Scratch only (the fixture's own temp dir).
        let fm = FileManager.default
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: fixture.url.path + suffix) {
            try fm.removeItem(atPath: fixture.url.path + suffix)
        }
        return (fixture, newer, try Data(contentsOf: fixture.url))
    }

    @Test func aNewerSchemaIsRefusedWithoutTheFileChanging() async throws {
        let (fixture, newer, before) = try await newerSchemaFixtureInDeleteMode()
        defer { fixture.remove() }
        let repository = GRDBCatalogRepository(host: "admit-first", durability: .volatileForTests)
        let outcome = await repository.open(at: fixture.url)
        guard case .refused(let words) = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            await repository.close()
            return
        }
        #expect(words.contains("schema version \(newer) is newer"), Comment(rawValue: words))
        await repository.close()
        let after = try Data(contentsOf: fixture.url)
        #expect(after == before, "a refused file must be byte-identical — the open switched it to WAL or wrote GRDB's init table")
        #expect(after[18] == 1 && after[19] == 1, "header bytes 18/19 must still say rollback journal (1/1), not WAL (2/2)")
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path + "-wal"), "no -wal may appear beside a refused file")
    }

    // MARK: - Closing pass (codex #142) F6-1 (P1): an admission gone stale before the pool exists

    /// Admission says yes on a read-only connection that is then closed;
    /// the pool is a different connection. In between, another connection
    /// bumps the schema version in the SAME file (same inode, so the identity
    /// guard cannot see it). The open must still refuse: the version check
    /// is re-run on the pool's own connection.
    @Test func anAdmissionGoneStaleBeforeThePoolIsRefused() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 1)
        defer { fixture.remove() }
        let newer = GRDBCatalogRepository.currentSchemaVersion + 1
        let url = fixture.url
        let repository = GRDBCatalogRepository(host: "stale-admission", durability: .volatileForTests)
        await repository.injectAdmittedHook {
            let other = try DatabaseQueue(path: url.path)
            try other.write { db in
                try db.execute(sql: "UPDATE catalog_state SET schema_version = \(newer) WHERE singleton = 1")
                try db.execute(sql: "PRAGMA user_version = \(newer)")
            }
            try other.close()
        }
        let outcome = await repository.open(at: url)
        guard case .refused(let words) = outcome else {
            Issue.record("expected .refused for a schema bumped after admission, got \(outcome)")
            await repository.close()
            return
        }
        #expect(words.contains("schema version \(newer) is newer"), Comment(rawValue: words))
        let wrote = await repository.write(as: .ui) { _ in }
        #expect(wrote == .refused(reason: "not open"), "a stale admission left something writable: \(wrote)")
        await repository.close()
    }

    // MARK: - Finding 4 (P2): clearing the last curated value must not resurrect the imported one

    private static let volume = "11111111-1111-1111-1111-111111111111"
    private static let digestA = String(repeating: "a", count: 64)
    private static let fileID = "00000000-0000-4000-8000-000000000041"
    private static let runID = "R-codex141"
    private static let importedNote = "the lake house, imported"

    private static func importRun() -> CatalogRow.ImportRun {
        CatalogRow.ImportRun(runID: runID, startedAt: 1_700_000_000, sourceSHA256: String(repeating: "d", count: 64),
                             sourceGeneration: 5, integrityRunID: "IR-1", auditRunStartedAt: 1_699_990_000,
                             auditRunFinishedAt: 1_699_990_500, auditGeneration: 5, integrityStartedAt: 1_699_995_000,
                             integrityGeneration: 5)
    }

    private static func file(_ id: String, digest: String, path: String) -> CatalogRecordDTO.FileRow {
        CatalogRecordDTO.FileRow(
            id: id, contentDigest: digest, volumeUUID: volume, fullPath: path, pathFold: CatalogRecordDTO.pathFold(path),
            filename: (path as NSString).lastPathComponent, ext: "mov", directory: (path as NSString).deletingLastPathComponent,
            // A content fixity WITH its identity stamp: that is what gives the
            // loaded record a whole-file digest (VideoRecord+Loaded), so the
            // commit stores it rather than holding it as a pending row.
            sizeBytes: 100, fsCreatedAt: nil, fsModifiedAt: nil, stampDevice: 1, stampInode: 41, stampMtimeNs: 1_700_000_000_000_000_000,
            stampCtimeNs: 1_700_000_000_000_000_000, stampVolumeUUID: volume, digestComputedAt: 1_700_000_000, digestSource: .contentFixity,
            sampledHash: nil, sampledHashAt: nil, partialMD5: nil, streamType: "Video+Audio", durationS: 1, container: "mov",
            videoCodec: "", audioCodec: "", embeddedCreatedAt: nil, embeddedCreatedSource: nil, probeExtra: [:],
            scanHost: "", scannedAt: nil, scanRootLabel: "", bundleContainer: "", sourceHost: "", originalFullPath: nil,
            originVolume: nil, machineNotes: "", lifecycle: "Cataloged", archiveStage: "None",
            masterLocation: "", setAsideReason: nil, needsReformat: false, workspaceActive: false,
            removalState: nil, removalSince: nil, removalReason: nil, removalTrashPath: nil,
            removalTrashEmptiedAt: nil, removalLastSeen: nil, removalRevision: 0,
            auditSeenVolumeUUID: nil, auditSeenMountFrom: nil, auditSeenDeviceKey: nil, auditSeenAt: nil, cataloguedAt: nil)
    }

    /// A catalog whose ONLY curated value is one imported note on one file:
    /// the import run, the volume, the content, the file and the
    /// `knowledge_sources` row (the immutable evidence the display pass reads).
    private func seedOneFileWithOneImportedNote() async throws -> StoreFixture {
        let fixture = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        let repository = GRDBCatalogRepository(host: "codex141", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let outcome = await repository.write(as: .importRun) { tx in
            try tx.insertImportRun(Self.importRun())
            try tx.insertVolume(CatalogRecordDTO.VolumeRowDTO(volumeUUID: Self.volume, lastName: "A", mountType: "local", remoteServer: ""),
                                caseSensitive: false)
            try tx.insertContent(CatalogRecordDTO.ContentRow(digest: Self.digestA, algorithm: "sha256", byteCount: 100,
                                                             firstSeenAt: 1_700_000_000, firstSeenHow: .import))
            try tx.insertFile(Self.file(Self.fileID, digest: Self.digestA, path: "/Volumes/A/lake.mov"), volumeCaseSensitive: false)
            try tx.insertKnowledgeSource(CatalogRow.KnowledgeSource(
                importRun: Self.runID, sourceOrdinal: 0, jsonRowID: Self.fileID, digest: Self.digestA,
                value: .init(field: .userNotes, valueJSON: .string(Self.importedNote), setAt: nil)))
        }
        try #require(outcome == .committed(generation: 1))
        await repository.close()
        return fixture
    }

    /// Open, run the load (display pass + snapshot), build the one record.
    private func load(_ fixture: StoreFixture) async throws -> (CatalogLoad.Snapshot, VideoRecord) {
        let repository = GRDBCatalogRepository(host: "codex141", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let snapshot = try await CatalogLoad.read(repository)
        await repository.close()
        let row = try #require(snapshot.rows.first)
        return (snapshot, try VideoRecord(loaded: row))
    }

    private func userNotesRows(_ fixture: StoreFixture) throws -> Int {
        try DatabaseQueue(path: fixture.url.path).read { try Int.fetchOne($0, sql: "SELECT count(*) FROM user_notes") ?? 0 }
    }

    @Test func clearingTheLastCuratedValueStaysClearedAcrossRelaunch() async throws {
        let fixture = try await seedOneFileWithOneImportedNote()
        defer { fixture.remove() }

        // First load: the display pass derives the note from the evidence.
        let (first, record) = try await load(fixture)
        guard case .filled(let rows, _, _, _) = first.displayPass else {
            Issue.record("expected the display pass to fill, got \(first.displayPass)"); return
        }
        #expect(rows == 1)
        #expect(record.userNotes == Self.importedNote)

        // Rick clears the note; the commit lands and the display row goes.
        record.userNotes = ""
        let repository = GRDBCatalogRepository(host: "codex141", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let snapshot = VideoRecordDTO(record)
        let item = CatalogCommit.Item(id: record.id, snapshot: snapshot, fingerprint: CatalogChangeDetector.fingerprint(snapshot))
        let committed = await CatalogCommit.run(CatalogCommit.Plan(door: .save, items: [item]), on: repository)
        await repository.close()
        #expect(committed.isCommitted, Comment(rawValue: "\(committed)"))
        #expect(try userNotesRows(fixture) == 0)

        // Relaunch: the pass must NOT run again — the evidence is still there,
        // but Rick's clear is the newer truth.
        let (second, reloaded) = try await load(fixture)
        #expect(second.displayPass == .alreadyFilled, Comment(rawValue: "\(second.displayPass)"))
        #expect(reloaded.userNotes.isEmpty, "the imported note came back after the clear: \(reloaded.userNotes)")
        #expect(try userNotesRows(fixture) == 0, "a user_notes row reappeared from the immutable evidence")
    }
}
