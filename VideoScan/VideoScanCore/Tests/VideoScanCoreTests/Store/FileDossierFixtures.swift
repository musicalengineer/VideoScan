// FileDossierFixtures.swift — raw-SQL catalog fixtures for FileDossierTests
// (the file dossier view, phase 1). It lives in Store/ because only Store
// folders may import GRDB (CatalogStoreSensorTests); the Dossier suite sees
// plain functions. Every row is what the app's writers store (the commit
// door's tables, the JournalApplier's assertions); the triggers stay armed.
// Synthetic names, paths and digests only.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

enum DossierFixture {
    static func hex(_ n: Int) -> String { String(format: "%064x", n) }
    static func fileID(_ n: Int) -> String { String(format: "00000000-0000-0000-0000-%012X", n) }

    struct File {
        var n: Int
        var path: String
        var stream = "Video+Audio"
        var duration = 600.0
        var container = "DV (Digital Video)"
        var videoCodec = "dvvideo"
        var audioCodec = "pcm_s16le"
        var extra: [String: String] = ["resolution": "720x480", "frameRate": "29.97", "scanType": "bb",
                                       "audioSampleRate": "32000 Hz", "audioChannels": "2", "totalBitrate": "28800 kbps"]
        var modified: Int64? = 1_044_957_600            // 2003-02-11
        var embedded: Int64?
        var embeddedSource: String?
    }

    /// A catalog.sqlite at the current schema holding `files` (one content each).
    static func catalog(_ files: [File]) async throws -> StoreFixture {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.inTransaction {
                try db.execute(sql: "INSERT OR IGNORE INTO volumes (volume_uuid) VALUES ('')")
                for f in files { try insert(db, f) }
                return .commit
            }
        }
        return fixture
    }

    private static func insert(_ db: Database, _ f: File) throws {
        try db.cachedStatement(sql: "INSERT OR IGNORE INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, 100, 1700000000, 'rescan')")
            .execute(arguments: [hex(f.n)])
        let extra = String(data: try JSONSerialization.data(withJSONObject: f.extra, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
        let dir = (f.path as NSString).deletingLastPathComponent
        let name = (f.path as NSString).lastPathComponent
        try db.cachedStatement(sql: """
            INSERT INTO files (id, content_digest, volume_uuid, full_path, path_fold, filename, ext, directory, size_bytes,
                               digest_computed_at, digest_source, stream_type, duration_s, container, video_codec, audio_codec,
                               probe_extra, fs_modified_at, embedded_created_at, embedded_created_source,
                               lifecycle, archive_stage, volume_case_sensitive)
            VALUES (?, ?, '', ?, ?, ?, ?, ?, 100, 1, 'archiveFixity', ?, ?, ?, ?, ?, ?, ?, ?, ?, 'Cataloged', 'None', 0)
            """).execute(arguments: [fileID(f.n), hex(f.n), f.path, f.path.lowercased(), name, (name as NSString).pathExtension, dir,
                             f.stream, f.duration, f.container, f.videoCodec, f.audioCodec, extra, f.modified,
                             f.embedded, f.embedded.map { _ in f.embeddedSource ?? "format:creation_time" }])
    }

    /// The knowledge one content carries (each table as its writer stores it).
    struct Knowledge {
        var captions: [(kind: String, at: Double, text: String)] = []
        var captionModel: String?
        var transcript: String?
        var transcriptModel: String?
        var dossierBy: String?
        var inferred: (at: Int64?, confidence: Double?, source: String?, reason: String?)?
        var people: [(name: String, kind: String)] = []
        var userDate: String?
        /// (field, value, by, state, evidence JSON)
        var assertions: [(field: String, value: String, by: String, state: String, evidence: String)] = []
    }

    static func seed(_ fixture: StoreFixture, _ n: Int, _ k: Knowledge) throws {
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.inTransaction {
                try seed(db, n, k)
                return .commit
            }
        }
    }

    private static func seed(_ db: Database, _ n: Int, _ k: Knowledge) throws {
        let d = hex(n)
        var seq: [String: Int] = [:]
        for c in k.captions {
            let s = seq[c.kind, default: 0]
            seq[c.kind] = s + 1
            try db.cachedStatement(sql: "INSERT INTO captions (digest, kind, seq, at_s, text) VALUES (?, ?, ?, ?, ?)").execute(arguments: [d, c.kind, s, c.at, c.text])
        }
        if let model = k.captionModel {
            try db.cachedStatement(sql: "INSERT INTO caption_runs (digest, model, made_at) VALUES (?, ?, 1700000100)").execute(arguments: [d, model])
        }
        if let text = k.transcript {
            try db.cachedStatement(sql: "INSERT INTO transcripts (digest, text, model, made_at) VALUES (?, ?, ?, 1700000200)")
                .execute(arguments: [d, text, k.transcriptModel])
        }
        if let by = k.dossierBy {
            try db.cachedStatement(sql: "INSERT INTO dossiers (digest, processed_at, processed_by) VALUES (?, 1700000300, ?)").execute(arguments: [d, by])
        }
        if let i = k.inferred {
            try db.execute(sql: "INSERT INTO inferred_dates (digest, date_at, confidence, source, reason) VALUES (?, ?, ?, ?, ?)",
                           arguments: [d, i.at, i.confidence, i.source, i.reason])
        }
        for p in k.people {
            let confirmed = p.kind == "confirmed"
            try db.execute(sql: "INSERT INTO people_tags (digest, name, kind, confirmed_at, provenance) VALUES (?, ?, ?, ?, ?)",
                           arguments: [d, p.name, p.kind, confirmed ? 1700000400 : nil,
                                       ["detected", "suspected"].contains(p.kind) ? "bound" : nil])
        }
        if let date = k.userDate {
            try db.execute(sql: "INSERT INTO user_dates (digest, value, confidence) VALUES (?, ?, 'known')", arguments: [d, date])
        }
        // One run, one `at` (the era job stamps a run's window and fused rows alike).
        for a in k.assertions {
            try db.cachedStatement(sql: """
                INSERT INTO provenance_assertions (subject_kind, subject_id, field, value, state, by, at, confidence, evidence_json)
                VALUES ('content', ?, ?, ?, ?, ?, 1762000000, ?, ?)
                """).execute(arguments: [d, a.field, a.value, a.state, a.by, a.state == "inferred" ? 0.6 : nil, a.evidence])
        }
    }

    /// One raw statement with text arguments (a test's poison).
    static func execute(_ fixture: StoreFixture, _ sql: String, _ arguments: [String]) throws {
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.execute(sql: sql, arguments: StatementArguments(arguments))
        }
    }

    /// `count` DV files hex(1)…hex(count), each with 6 captions, a transcript,
    /// a dossier run and an `era.fused` (+ 2 window rows) — the scale seed.
    static func seedScale(_ fixture: StoreFixture, count: Int) throws {
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.inTransaction {
                try db.execute(sql: "INSERT OR IGNORE INTO volumes (volume_uuid) VALUES ('')")
                let by = "machine:qwen3-vl-8b-4bit/era-v1/window-60s@r3"
                for n in 1...count {
                    try insert(db, File(n: n, path: "/Vol/scale/\(n / 1000)/clip-\(n).dv"))
                    let lo = 1960 + n % 45
                    var k = Knowledge(captionModel: "qwen-test", transcript: "hello \(n)", transcriptModel: "whisper-medium",
                                      dossierBy: "vlm+whisper")
                    k.captions = (0..<6).map { (kind: "scene", at: Double($0) * 10, text: "scene \($0) of \(n)") }
                    k.assertions = [("era.yearRange", "\(lo)-\(lo + 4)", by, "inferred", #"{"frameTimesS":[0,7.5],"window":[0,60]}"#),
                                    ("era.yearRange", "\(lo)-\(lo + 4)", by, "inferred", #"{"frameTimesS":[60,67.5],"window":[60,120]}"#),
                                    ("era.fused", "\(lo)-\(lo + 4)", by, "inferred", #"{"validEraWindows":2,"windows":[[0,60],[60,120]]}"#)]
                    try seed(db, n, k)
                }
                return .commit
            }
        }
    }

    static func open(_ fixture: StoreFixture) async throws -> GRDBCatalogRepository {
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        return repository
    }

    /// The generation and the row counts the dossier read must leave untouched.
    static func fingerprint(_ fixture: StoreFixture) throws -> [Int] {
        try DatabaseQueue(path: fixture.url.path).read { db in
            try ["SELECT generation FROM generations WHERE id = 1", "SELECT count(*) FROM files", "SELECT count(*) FROM provenance_assertions",
                 "SELECT count(*) FROM captions"].map { try Int.fetchOne(db, sql: $0) ?? -1 }
        }
    }
}
