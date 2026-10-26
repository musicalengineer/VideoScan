// CatalogStoreDurabilityCodex141Tests.swift
// Codex cycle #141 (docs/reviews/codex/codex-review-catalog-store-consistency-
// 2026-10-25.md), findings 1, 4 and 6 — each seen RED before its fix:
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
//
// Closing pass (docs/reviews/codex/codex-review-store-durability-closing-
// 2026-10-25.md, cycle #142) — three residuals on F6, each seen RED:
//
//   | finding | test                                              | red (before)                                  | green (after) |
//   |---------|---------------------------------------------------|-----------------------------------------------|---------------|
//   | 6-1 P1  | anAdmissionGoneStaleBeforeThePoolIsRefused        | .readWrite — prepare(admitted: true) skipped   | .refused,     |
//   |         |                                                   | the version check; the bump after admission   | write refused |
//   |         |                                                   | (same inode) opened read-write                | "not open"    |
//   | 6-2 P2  | anUnverifiableExistingFileIsRefusedUntouched      | the hot -journal was played back (main file   | .refused      |
//   |         |                                                   | 544768 → 540672 bytes, -journal gone), the    | "could not be |
//   |         |                                                   | file switched to WAL (-wal/-shm appeared),    | verified…";   |
//   |         |                                                   | THEN refused on the version                   | dir identical |
//   |         | aReadOnlyFolderWithoutSidecarsNeverOpensForWriting| (pin, green from the start: the read-only     | not .readWrite|
//   |         |                                                   | folder corner the F6-2 rule must keep)        | dir identical |
//   | 6-3 P2  | aNewerSchemaWALFileIsRefusedWithItsMainFileAsFound| refused in the right words, main file         | refused; main |
//   |         | (was …WithItsFolderExactlyAsFound; #387 below)    | identical, but the folder gained -shm and a   | file and every|
//   |         |                                                   | -wal (12392 bytes: GRDB's issue-102 CREATE/   | file found    |
//   |         |                                                   | DROP, written by the pool on a bare WAL file) | identical     |
//
// #387 (Rick 2026-10-26, docs/DECISIONS.md): the read-only admission and its
// sidecar cleanup are gone — the checks run in the writer's first BEGIN
// IMMEDIATE, and a refusal deletes nothing (CatalogStoreOpenVerdictTests has
// Codex #144's four). What changed here: F6-1's hook now runs after the
// writer's checks and before the first write (same test, same assertions);
// F6-2's hot journal is refused from its bytes before any connection (same
// assertions); F6-3 no longer promises the FOLDER as found — a refused
// WAL-mode file with nothing beside it may gain an empty -wal and a -shm
// (Rick accepted that) — so it pins what is still promised: the main file's
// bytes, every file that was there, nothing removed, and the words.
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
        #expect(words.contains("VideoScan left catalog.sqlite as found"), Comment(rawValue: words))
        await repository.close()
        let after = try Data(contentsOf: fixture.url)
        #expect(after == before, "a refused file must be byte-identical — the open switched it to WAL or wrote GRDB's init table")
        #expect(after[18] == 1 && after[19] == 1, "header bytes 18/19 must still say rollback journal (1/1), not WAL (2/2)")
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path + "-wal"), "no -wal may appear beside a refused file")
    }

    // MARK: - Closing pass (codex #142) F6-1 (P1): an admission gone stale before the pool exists

    /// The checks pass; before the open's first write, another connection
    /// bumps the schema version in the SAME file (same inode, so the identity
    /// guard cannot see it). The open must still refuse. (#387: the hook now
    /// runs after the writer's checks — there is no separate admission — and
    /// the first write's `OpenVerdict.confirm` sees `data_version` move.)
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

    // MARK: - Closing pass (codex #142) F6-2 (P2): an unverifiable existing file never authorises a writer

    /// Every file in `directory` by name, with its bytes — the oracle for
    /// "left exactly as found": the entry SET and every file's content, not
    /// only the main file (codex #142 F6-3).
    private static func directorySnapshot(_ directory: URL) throws -> [String: Data] {
        var snapshot: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            snapshot[name] = try Data(contentsOf: directory.appendingPathComponent(name))
        }
        return snapshot
    }

    /// The newer-schema DELETE-mode fixture with a HOT rollback journal
    /// beside it: a process died mid-transaction after the journal reached
    /// the disk. Built by hand from a copy taken before one committed write
    /// (SQLite's documented format, fileformat.html §Rollback Journal): the
    /// journal holds every page the write changed, as it was BEFORE the
    /// write, so rolling it back restores the copy. The next read-write
    /// connection plays it back on open (lockingv3.html §Dealing with hot
    /// journals) — which is a write to the main file and a delete of the
    /// journal; a read-only connection refuses with SQLITE_READONLY_ROLLBACK.
    private func newerSchemaFixtureWithAHotJournal() async throws -> (StoreFixture, Int) {
        let (fixture, newer, pageImageBefore) = try await newerSchemaFixtureInDeleteMode()
        // One committed write after the copy, so the two images differ.
        let queue = try DatabaseQueue(path: fixture.url.path)
        try queue.inDatabase { db in
            // A new table: page 1 (sqlite_master) changes and a page is added.
            try db.execute(sql: "CREATE TABLE hot_journal_scratch (x INTEGER); INSERT INTO hot_journal_scratch VALUES (1)")
        }
        try queue.close()
        for suffix in ["-wal", "-shm", "-journal"] where FileManager.default.fileExists(atPath: fixture.url.path + suffix) {
            try FileManager.default.removeItem(atPath: fixture.url.path + suffix)
        }
        let after = try Data(contentsOf: fixture.url)
        try #require(after != pageImageBefore, "the write changed no page; the journal would be empty")
        try Self.writeHotJournal(beside: fixture.url, original: pageImageBefore, current: after)
        return (fixture, newer)
    }

    /// Big-endian 32-bit, as the journal format stores every number.
    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func writeHotJournal(beside database: URL, original: Data, current: Data) throws {
        var pageSize = Int(original[16]) << 8 | Int(original[17])
        if pageSize == 1 { pageSize = 65_536 }
        let pages = original.count / pageSize
        try #require(pages * pageSize == original.count)
        let nonce: UInt32 = 0x5EED_1234
        var records: [UInt8] = []
        var count: UInt32 = 0
        for page in 0..<pages {
            let range = (page * pageSize)..<((page + 1) * pageSize)
            let before = original.subdata(in: range)
            if current.count >= range.upperBound, current.subdata(in: range) == before { continue }
            // Record: page number, the page as it was, then the checksum —
            // the nonce plus every 200th byte counting down from the end.
            records += be32(UInt32(page + 1))
            records += before
            var checksum = nonce
            var offset = pageSize - 200
            while offset > 0 { checksum &+= UInt32(before[offset]); offset -= 200 }
            records += be32(checksum)
            count += 1
        }
        try #require(count > 0)
        let sector = 512
        var header: [UInt8] = [0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7]   // the journal magic
        header += be32(count)                       // records that follow
        header += be32(nonce)
        header += be32(UInt32(pages))               // size to truncate back to
        header += be32(UInt32(sector))
        header += be32(UInt32(pageSize))
        header += [UInt8](repeating: 0, count: sector - header.count)
        try Data(header + records).write(to: URL(fileURLWithPath: database.path + "-journal"))
    }

    @Test func anUnverifiableExistingFileIsRefusedUntouched() async throws {
        let (fixture, newer) = try await newerSchemaFixtureWithAHotJournal()
        defer { fixture.remove() }
        let before = try Self.directorySnapshot(fixture.directory)
        try #require(before.keys.contains("catalog.sqlite-journal"))
        let repository = GRDBCatalogRepository(host: "hot-journal", durability: .volatileForTests)
        let outcome = await repository.open(at: fixture.url)
        guard case .refused(let words) = outcome else {
            Issue.record("expected .refused for a newer-schema file with a hot journal, got \(outcome)")
            await repository.close()
            return
        }
        #expect(words.contains("could not be verified before opening"), Comment(rawValue: words))
        #expect(words.contains("nothing was written"), Comment(rawValue: words))
        _ = newer
        let wrote = await repository.write(as: .ui) { _ in }
        #expect(wrote == .refused(reason: "not open"), Comment(rawValue: "\(wrote)"))
        await repository.close()
        let after = try Self.directorySnapshot(fixture.directory)
        #expect(Set(after.keys) == Set(before.keys), "the directory's entries changed: \(after.keys.sorted()) vs \(before.keys.sorted())")
        for (name, bytes) in before {
            #expect(after[name] == bytes, "\(name) changed — the hot journal was rolled back or the file was switched to WAL")
        }
    }

    /// The read-only-folder corner the F6-2 rule must keep: a healthy
    /// WAL-mode catalog with its sidecars cleaned, in a folder that cannot
    /// be written. The writer cannot make the `-shm` it needs, so the door
    /// falls back to a read-only pool — and the system SQLite (3.54.0
    /// "aapl") answers CANTOPEN for ANY read-only open of a WAL-mode file
    /// without its `-wal` (GH #386). What the rule must keep: never read-write,
    /// read-only or refused in words, and the folder exactly as found. The
    /// sidecars-present variant opens read-only
    /// (GRDBCatalogRepositoryTests.aReadOnlyFolderNeverOpensForWriting).
    @Test func aReadOnlyFolderWithoutSidecarsNeverOpensForWriting() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        let fm = FileManager.default
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: fixture.url.path + suffix) {
            try fm.removeItem(atPath: fixture.url.path + suffix)
        }
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.directory.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.directory.path)
            fixture.remove()
        }
        let before = try Self.directorySnapshot(fixture.directory)
        let repository = GRDBCatalogRepository(host: "ro-folder", durability: .volatileForTests)
        let outcome = await repository.open(at: fixture.url)
        switch outcome {
        case .readWrite:
            Issue.record("a read-only folder opened read-write")
        case .readOnly(let words), .refused(let words):
            #expect(words.contains("is not writable") || words.contains("unable to open"), Comment(rawValue: words))
        }
        let wrote = await repository.write(as: .ui) { _ in }
        #expect(!wrote.isCommitted, "a write landed in a read-only folder: \(wrote)")
        await repository.close()
        let after = try Self.directorySnapshot(fixture.directory)
        #expect(after == before, "the read-only folder changed: \(after.keys.sorted()) vs \(before.keys.sorted())")
    }

    // MARK: - Closing pass (codex #142) F6-3 (P2), as ruled in #387: a refused WAL-mode file's main file is left as found

    /// A current fixture stamped one version ahead, left in WAL mode and
    /// closed cleanly with nothing beside it — Codex's case: the open has
    /// to make `-wal` / `-shm` to read it at all. #387: they stay (nothing
    /// is deleted); the main file and every file that was there must not
    /// change, and the words must say what may now be beside it.
    private func newerSchemaFixtureInWALModeWithoutSidecars() async throws -> (StoreFixture, Int) {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        let newer = GRDBCatalogRepository.currentSchemaVersion + 1
        let queue = try DatabaseQueue(path: fixture.url.path)
        try queue.inDatabase { db in
            try db.execute(sql: "UPDATE catalog_state SET schema_version = \(newer) WHERE singleton = 1")
            try db.execute(sql: "PRAGMA user_version = \(newer)")
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        try queue.close()
        let fm = FileManager.default
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: fixture.url.path + suffix) {
            if suffix == "-wal" {
                let size = (try fm.attributesOfItem(atPath: fixture.url.path + suffix)[.size] as? NSNumber)?.intValue ?? -1
                try #require(size == 0, "the -wal holds \(size) bytes — the checkpoint did not empty it")
            }
            try fm.removeItem(atPath: fixture.url.path + suffix)
        }
        let header = try Data(contentsOf: fixture.url).prefix(100)
        try #require(header[18] == 2 && header[19] == 2, "the fixture must be in WAL mode")
        return (fixture, newer)
    }

    @Test func aNewerSchemaWALFileIsRefusedWithItsMainFileAsFound() async throws {
        let (fixture, newer) = try await newerSchemaFixtureInWALModeWithoutSidecars()
        defer { fixture.remove() }
        let before = try Self.directorySnapshot(fixture.directory)
        try #require(!before.keys.contains("catalog.sqlite-wal") && !before.keys.contains("catalog.sqlite-shm"))
        let repository = GRDBCatalogRepository(host: "wal-sidecars", durability: .volatileForTests)
        let outcome = await repository.open(at: fixture.url)
        guard case .refused(let words) = outcome else {
            Issue.record("expected .refused for a newer schema, got \(outcome)")
            await repository.close()
            return
        }
        #expect(words.contains("schema version \(newer) is newer"), Comment(rawValue: words))
        #expect(words.contains("VideoScan left catalog.sqlite as found"), Comment(rawValue: words))
        #expect(words.contains("catalog.sqlite-wal and catalog.sqlite-shm may now be beside it"), Comment(rawValue: words))
        await repository.close()
        let after = try Self.directorySnapshot(fixture.directory)
        for (name, bytes) in before {
            #expect(after[name] == bytes, "\(name) changed or went missing beside a refused file")
        }
        let added = Set(after.keys).subtracting(before.keys)
        #expect(added.isSubset(of: ["catalog.sqlite-wal", "catalog.sqlite-shm"]), "the refused open added \(added.sorted())")
        #expect(after["catalog.sqlite-wal"].map(\.count) ?? 0 == 0, "the refused open wrote frames to the -wal")
    }
}
