// BackgroundCatalogFixtures.swift — raw-SQL catalog fixtures for the
// Background suites (EraJobTests, JournalApplicationTests). It lives in
// Store/ because only Store folders may import GRDB (CatalogStoreSensorTests);
// the Background suites see plain functions.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

enum EraFixture {
    static func hex(_ n: Int) -> String { String(format: "%064x", n) }

    struct File {
        var n: Int
        var path: String
        var duration: Double = 120
        var stream = "Video+Audio"
        var removed = false
        var userYear: String?
        var embedded: Int64?
        var inferred: Int64?
    }

    /// A catalog.sqlite at schema 14 holding `files` (one content each).
    static func catalog(_ files: [File]) async throws -> StoreFixture {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.inTransaction {
                try db.execute(sql: "INSERT OR IGNORE INTO volumes (volume_uuid) VALUES ('')")
                for f in files {
                    try db.execute(sql: "INSERT OR IGNORE INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, 100, 1700000000, 'rescan')",
                                   arguments: [hex(f.n)])
                    let dir = (f.path as NSString).deletingLastPathComponent
                    try db.execute(sql: """
                        INSERT INTO files (id, content_digest, volume_uuid, full_path, path_fold, filename, ext, directory, size_bytes,
                                           digest_computed_at, digest_source, stream_type, duration_s, lifecycle, archive_stage,
                                           volume_case_sensitive, embedded_created_at, embedded_created_source,
                                           removal_state, removal_since, removal_reason)
                        VALUES (?, ?, '', ?, ?, ?, 'mov', ?, 100, 1, 'archiveFixity', ?, ?, 'Cataloged', 'None', 0, ?, ?, ?, ?, ?)
                        """, arguments: [String(format: "00000000-0000-0000-0000-%012X", f.n), hex(f.n), f.path, f.path.lowercased(),
                                         (f.path as NSString).lastPathComponent, dir, f.stream, f.duration,
                                         f.embedded, f.embedded.map { _ in "creation_time" },
                                         f.removed ? "removedFromCatalog" : nil, f.removed ? 1 : nil, f.removed ? "test" : nil])
                    if let y = f.userYear {
                        try db.execute(sql: "INSERT INTO user_dates (digest, value, confidence) VALUES (?, ?, 'known')", arguments: [hex(f.n), y])
                    }
                    if let i = f.inferred {
                        try db.execute(sql: "INSERT INTO inferred_dates (digest, date_at, confidence, source) VALUES (?, ?, 0.5, 'folder-year')",
                                       arguments: [hex(f.n), i])
                    }
                }
                return .commit
            }
        }
        return fixture
    }

    /// One raw statement with text arguments (a test's poison or seed).
    static func execute(_ fixture: StoreFixture, _ sql: String, _ arguments: [String]) throws {
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.execute(sql: sql, arguments: StatementArguments(arguments))
        }
    }

    /// `count` content rows hex(1)…hex(count), one transaction.
    static func seedContents(_ fixture: StoreFixture, count: Int) throws {
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.inTransaction {
                for n in 1...count {
                    try db.execute(sql: "INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, 100, 1700000000, 'rescan')",
                                   arguments: [hex(n)])
                }
                return .commit
            }
        }
    }

    static func stateRoot() throws -> URL { try BackgroundFixtures.scratch("era") }

    static func setup(_ fixture: StoreFixture, root: URL, jobID: JobID = JobID(), limit: Int? = nil, clipTimeout: Duration = .seconds(20),
                      log: URL? = nil, backoff: Backoff? = nil, readable: @escaping @Sendable (String) -> Bool = { _ in true },
                      afterAppend: (@Sendable (Int) async -> Void)? = nil) -> EraJob.Setup {
        EraJob.Setup(jobID: jobID, catalogURL: fixture.url, stateRoot: root,
                     worker: ClipWorkerFixture.configuration(clipTimeout: clipTimeout, log: log),
                     limit: limit, backoff: backoff, isReadable: readable, afterJournalAppend: afterAppend)
    }

    static func lines(_ root: URL) throws -> [ObservationLine] {
        let journal = ObservationJournal(directory: root.appendingPathComponent("journal", isDirectory: true))
        var out: [ObservationLine] = []
        for file in journal.dayFiles() {
            var offset = 0
            while true {
                let r = try journal.read(file: file, from: offset, maxLines: 4096)
                out += r.lines.compactMap { try? $0.result.get() }
                if r.lines.isEmpty { break }
                offset = r.nextOffset
            }
        }
        return out
    }
}

