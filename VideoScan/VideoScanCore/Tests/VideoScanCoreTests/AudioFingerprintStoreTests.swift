// AudioFingerprintStoreTests.swift — the sidecar and the stamp (Fingerprint
// Sound, 2026-10-14). Dimensions:
//   LOGIC     — put / get / has round trip; two records (same digest + size)
//               share one blob; a new engine version is a new row; the
//               schema version table; the stamp's `describes` rule (size,
//               digest of either kind, engine version); complete / partial.
//   CODABLE   — a record JSON WITHOUT the key decodes (old catalog) and
//               writes no key; a stamped record round-trips; an unreadable
//               stamp reads as absent, never fails the record.
//   ISOLATION — a read-only folder → named refusal; a poisoned file (garbage
//               bytes) → named refusal; a newer schema → named refusal; the
//               default directory on a test host is the sandbox, never
//               Rick's Application Support.
//   SCALE     — 2,000 puts in batches and 2,000 lookups inside a budget.

import Foundation
import Testing
@testable import VideoScanCore

private func scratch(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_afstore_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func fingerprint(seed: UInt32, count: Int = 100, seconds: Double = 12.5, complete: Bool = true) -> AudioFingerprint {
    AudioFingerprint(sampleRate: 8_000, hopSamples: 512, frameSize: 1_024, durationSeconds: seconds, complete: complete,
                     hashes: (0..<count).map { UInt32($0) &* 2_654_435_761 &+ seed },
                     times: (0..<count).map { UInt32($0 * 3) })
}

@Suite("Fingerprint Sound — sidecar store (logic)")
struct AudioFingerprintStoreLogicTests {

    @Test("put / summary / fingerprint / has round trip; absent key is nil")
    func roundTrip() throws {
        let dir = try scratch("rt"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try AudioFingerprintStore(directory: dir)
        let key = AudioFingerprintStore.Key(contentDigest: "sha256:abc", sizeBytes: 1_234)
        let fp = fingerprint(seed: 7)
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        try store.put([.init(key: key, fingerprint: fp, sourcePath: "/Volumes/V/a.mov", computedAt: when)])
        #expect(try store.has(key))
        #expect(try store.fingerprint(for: key) == fp)
        let s = try #require(try store.summary(for: key))
        #expect(s.landmarks == 100 && s.analyzedSeconds == 12.5 && s.sourcePath == "/Volumes/V/a.mov")
        #expect(s.bytes == fp.estimatedBytes && s.engineVersion == Int(AudioFingerprint.currentVersion))
        #expect(s.recipeID == fp.recipeID && s.recipeID == AudioFingerprintParameters.default.recipeID && s.complete)
        let partialKey = AudioFingerprintStore.Key(contentDigest: "sha256:partial", sizeBytes: 9)
        try store.put([.init(key: partialKey, fingerprint: fingerprint(seed: 8, seconds: 14_400, complete: false), sourcePath: "/p")])
        #expect(try store.summary(for: partialKey)?.complete == false, "complete is stored beside the blob, from the engine")
        #expect(abs(s.computedAt.timeIntervalSince(when)) < 0.001)
        #expect(try store.summary(for: .init(contentDigest: "sha256:abc", sizeBytes: 1)) == nil, "size is part of the key")
        #expect(try store.fingerprint(for: .init(contentDigest: "v1:abc", sizeBytes: 1_234)) == nil, "digest kind is part of the key")
        #expect(try store.count() == 2)
        #expect(store.fileURL.lastPathComponent == "audio-fingerprints.sqlite")
    }

    @Test("two records with the same digest + size share ONE row; a re-put replaces, never duplicates")
    func sharedRow() throws {
        let dir = try scratch("share"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try AudioFingerprintStore(directory: dir)
        let key = AudioFingerprintStore.Key(contentDigest: "sha256:same", sizeBytes: 99)
        try store.put([.init(key: key, fingerprint: fingerprint(seed: 1), sourcePath: "/a/copy1.mov")])
        try store.put([.init(key: key, fingerprint: fingerprint(seed: 1), sourcePath: "/b/copy2.mov")])
        #expect(try store.count() == 1)
        #expect(try store.summary(for: key)?.sourcePath == "/b/copy2.mov", "the last path wins (informational)")
    }

    @Test("a different engine version is a different row; the old one stays readable")
    func engineVersionIsPartOfTheKey() throws {
        let dir = try scratch("ver"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try AudioFingerprintStore(directory: dir)
        let key = AudioFingerprintStore.Key(contentDigest: "sha256:v", sizeBytes: 5)
        let old = AudioFingerprint(version: 0, sampleRate: 8_000, hopSamples: 512, frameSize: 1_024,
                                   durationSeconds: 1, hashes: [1], times: [0])
        try store.put([.init(key: key, fingerprint: old, sourcePath: "/x")])
        try store.put([.init(key: key, fingerprint: fingerprint(seed: 2), sourcePath: "/x")])
        #expect(try store.count() == 2)
        #expect(try store.has(key, engineVersion: 0))
        #expect(try store.has(key, engineVersion: Int(AudioFingerprint.currentVersion)))
        #expect(try store.fingerprint(for: key, engineVersion: 0) == nil, "a version-0 blob is not decodable by this build — nil, not a crash")
    }

    @Test("the schema version table is written on first open and read back; reopening keeps the rows")
    func schemaVersion() throws {
        let dir = try scratch("schema"); defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let store = try AudioFingerprintStore(directory: dir)
            #expect(try store.schemaVersionOnDisk() == AudioFingerprintStore.schemaVersion)
            try store.put([.init(key: .init(contentDigest: "v1:k", sizeBytes: 3), fingerprint: fingerprint(seed: 3), sourcePath: "/k")])
        }
        let again = try AudioFingerprintStore(directory: dir)
        #expect(try again.count() == 1)
        #expect(try again.schemaVersionOnDisk() == AudioFingerprintStore.schemaVersion)
    }

    @Test("a pre-release schema-1 file is dropped and re-created at the current schema (nothing was ever persisted under it)")
    func olderSchemaIsRecreated() throws {
        let dir = try scratch("older"); defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let store = try AudioFingerprintStore(directory: dir)
            try store.put([.init(key: .init(contentDigest: "v1:o", sizeBytes: 1), fingerprint: fingerprint(seed: 6), sourcePath: "/o")])
        }
        #expect(try AudioFingerprintStoreTestHook.setSchemaVersion(1, in: dir))
        let reopened = try AudioFingerprintStore(directory: dir)
        #expect(try reopened.schemaVersionOnDisk() == AudioFingerprintStore.schemaVersion)
        #expect(try reopened.count() == 0, "the old table is gone; rows are recomputed by the next run")
        try reopened.put([.init(key: .init(contentDigest: "v1:o", sizeBytes: 1), fingerprint: fingerprint(seed: 6), sourcePath: "/o")])
        #expect(try reopened.count() == 1)
    }

    @Test("a batch is one transaction: a damaged entry rolls the whole batch back")
    func batchIsAtomic() throws {
        let dir = try scratch("batch"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try AudioFingerprintStore(directory: dir)
        let entries = (0..<5).map {
            AudioFingerprintStore.Entry(key: .init(contentDigest: "sha256:\($0)", sizeBytes: 10), fingerprint: fingerprint(seed: UInt32($0)), sourcePath: "/\($0)")
        }
        try store.put(entries)
        #expect(try store.count() == 5)
        try store.put([])
        #expect(try store.count() == 5, "an empty batch is a no-op")
    }
}

@Suite("Fingerprint Sound — the stamp")
struct AudioFingerprintStampTests {

    @Test("describes: same size + a digest the record still carries (either kind) + this engine version")
    func describesRule() {
        let fp = fingerprint(seed: 9, seconds: 600)
        let stamp = AudioFingerprintStamp.fingerprinted(fp, contentDigest: "v1:sampled", sizeBytes: 1_000)
        #expect(!stamp.describes(sizeBytes: 1_000, digests: ["sha256:full", "v1:sampled"]),
                "gained a full hash later — the v1 key is not an identity (10 of 836 v1-equal pairs differed on 10/11); redone once under sha256")
        #expect(stamp.describes(sizeBytes: 1_000, digests: ["v1:sampled"]))
        let full = AudioFingerprintStamp.fingerprinted(fp, contentDigest: "sha256:full", sizeBytes: 1_000)
        #expect(full.describes(sizeBytes: 1_000, digests: ["sha256:full", "v1:sampled"]))
        #expect(!full.describes(sizeBytes: 1_000, digests: ["v1:sampled"]), "the full hash it was keyed on is gone")
        #expect(AudioFingerprintStamp.isFullDigest("sha256:full") && !AudioFingerprintStamp.isFullDigest("v1:sampled"))
        #expect(!stamp.describes(sizeBytes: 1_001, digests: ["v1:sampled"]), "size changed")
        #expect(!stamp.describes(sizeBytes: 1_000, digests: ["v1:other"]), "content changed")
        #expect(!stamp.describes(sizeBytes: 1_000, digests: []), "no digest at all")
        #expect(!stamp.describes(sizeBytes: 1_000, digests: ["v1:sampled"], engineVersion: Int(AudioFingerprint.currentVersion) + 1),
                "an engine bump redoes it")
        #expect(!stamp.describes(sizeBytes: 0, digests: ["v1:sampled"]), "a 0-byte record is never described")
        #expect(stamp.engineVersion == Int(AudioFingerprint.currentVersion), "never hard-coded")
    }

    @Test("analyzedSeconds and complete come from the engine's fingerprint, never recomputed")
    func completeness() {
        let whole = AudioFingerprintStamp.fingerprinted(fingerprint(seed: 1, seconds: 599.2), contentDigest: "v1:a", sizeBytes: 1)
        #expect(whole.complete && whole.analyzedSeconds == 599.2)
        let partial = AudioFingerprintStamp.fingerprinted(fingerprint(seed: 1, seconds: 14_400, complete: false), contentDigest: "v1:a", sizeBytes: 1)
        #expect(!partial.complete && partial.analyzedSeconds == 14_400 && partial.outcome == .fingerprinted)
        #expect(whole.engineVersion == Int(AudioFingerprint.currentVersion) && whole.engineVersion == 2, "format version 2 after the engine codex round")
        let silent = AudioFingerprintStamp.noAudio(contentDigest: "v1:a", sizeBytes: 1)
        #expect(silent.outcome == .noAudio && silent.complete && silent.landmarks == 0 && silent.bytes == 0)
    }

    @Test("digest spelling: full = sha256:<hex lowercased>; sampled = the scan's own v1: string; empty → nil")
    func digestSpelling() {
        #expect(AudioFingerprintStamp.fullDigest("ABCD") == "sha256:abcd")
        #expect(AudioFingerprintStamp.sampledDigest("v1:ff") == "v1:ff")
        #expect(AudioFingerprintStamp.sampledDigest("") == nil)
    }

    @Test("Codable: an old record JSON without the key decodes to nil and writes no key; a stamped record round-trips")
    func additiveCodable() throws {
        let plain = VideoRecord()
        plain.fullPath = "/Volumes/V/a.mov"; plain.filename = "a.mov"; plain.sizeBytes = 10
        let plainJSON = String(decoding: try JSONEncoder().encode(VideoRecordDTO(plain)), as: UTF8.self)
        #expect(!plainJSON.contains("audioFingerprint"))
        let back = try JSONDecoder().decode(VideoRecord.self, from: Data(plainJSON.utf8))
        #expect(back.audioFingerprint == nil)

        let r = VideoRecord()
        r.fullPath = "/Volumes/V/b.mov"; r.filename = "b.mov"; r.sizeBytes = 20
        r.audioFingerprint = AudioFingerprintStamp.fingerprinted(fingerprint(seed: 4, seconds: 42), contentDigest: "sha256:bb", sizeBytes: 20,
                                                                 computedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(VideoRecord.self, from: try encoder.encode(VideoRecordDTO(r)))
        #expect(round.audioFingerprint == r.audioFingerprint)
        #expect(round.snapshotClone().audioFingerprint == r.audioFingerprint, "clone carries it")
    }

    @Test("a stamp this build cannot read (a future outcome word) reads as absent; the record still loads")
    func unreadableStampIsAbsent() throws {
        let json = """
        {"id":"\(UUID().uuidString)","fullPath":"/Volumes/V/c.mov","filename":"c.mov","sizeBytes":5,
         "audioFingerprint":{"computedAt":1,"engineVersion":1,"contentDigest":"v1:x","sizeBytes":5,
                             "outcome":"fromTheFuture","analyzedSeconds":1,"complete":true,"landmarks":1,"bytes":8}}
        """
        let rec = try JSONDecoder().decode(VideoRecord.self, from: Data(json.utf8))
        #expect(rec.filename == "c.mov")
        #expect(rec.audioFingerprint == nil)
    }
}

@Suite("Fingerprint Sound — sidecar isolation: read-only, poisoned, newer, sandbox")
struct AudioFingerprintStoreIsolationTests {

    @Test("a read-only folder is refused by name before anything is written")
    func readOnlyFolderRefused() throws {
        let dir = try scratch("ro"); defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        guard FileManager.default.isWritableFile(atPath: dir.path) == false else { return }   // root: cannot make it read-only
        #expect(throws: AudioFingerprintStore.Failure.directoryNotWritable(path: dir.path)) {
            try AudioFingerprintStore(directory: dir)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(AudioFingerprintStore.fileName).path))
    }

    @Test("a poisoned file (garbage bytes where the database should be) is refused by name")
    func poisonedFileRefused() throws {
        let dir = try scratch("poison"); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(AudioFingerprintStore.fileName)
        let garbage = Data("this is not a database, it is a note from the future".utf8)
        try garbage.write(to: file)
        #expect(throws: AudioFingerprintStore.Failure.notADatabase(path: file.path)) {
            try AudioFingerprintStore(directory: dir)
        }
        #expect(try Data(contentsOf: file) == garbage, "the poisoned file is left exactly as found")
    }

    @Test("a sidecar written by a newer VideoScan is refused by name")
    func newerSchemaRefused() throws {
        let dir = try scratch("newer"); defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let store = try AudioFingerprintStore(directory: dir)
            try store.put([.init(key: .init(contentDigest: "v1:n", sizeBytes: 1), fingerprint: fingerprint(seed: 5), sourcePath: "/n")])
        }
        // Bump the version by hand (what a future build would have written).
        let bump = try AudioFingerprintStoreTestHook.setSchemaVersion(99, in: dir)
        #expect(bump)
        #expect(throws: AudioFingerprintStore.Failure.schemaNewer(found: 99, supported: AudioFingerprintStore.schemaVersion)) {
            try AudioFingerprintStore(directory: dir)
        }
    }

    @Test("on a test host the default directory is the per-process sandbox, never ~/Library/Application Support")
    func defaultDirectoryIsSandboxed() {
        let dir = AudioFingerprintStore.defaultDirectory.path
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? "/nowhere"
        #expect(!dir.hasPrefix(real), Comment(rawValue: dir))
        #expect(dir.contains("VideoScan-test-appsupport-"), Comment(rawValue: dir))
    }
}

@Suite("Fingerprint Sound — sidecar scale", .tags(.scale))
struct AudioFingerprintStoreScaleTests {

    /// 2,000 rows in 80 batches of 25 (the job's checkpoint size), then
    /// 2,000 summary lookups. Budget (Debug, M4 Max, ×3 headroom): 3 s.
    @Test func twoThousandRows() throws {
        let dir = try scratch("scale"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try AudioFingerprintStore(directory: dir)
        let clock = ContinuousClock()
        let start = clock.now
        for batch in 0..<80 {
            let entries = (0..<25).map { i -> AudioFingerprintStore.Entry in
                let n = batch * 25 + i
                return .init(key: .init(contentDigest: "sha256:\(n)", sizeBytes: Int64(n)), fingerprint: fingerprint(seed: UInt32(n), count: 500), sourcePath: "/f\(n)")
            }
            try store.put(entries)
        }
        var found = 0
        for n in 0..<2_000 where try store.has(.init(contentDigest: "sha256:\(n)", sizeBytes: Int64(n))) { found += 1 }
        let elapsed = clock.now - start
        #expect(found == 2_000)
        #expect(try store.count() == 2_000)
        #expect(elapsed < .seconds(3), "2,000 puts + 2,000 lookups took \(elapsed)")
    }
}

// MARK: - Test-side SQLite poke (what a future build would have written)

import SQLite3

enum AudioFingerprintStoreTestHook {
    /// Rewrite the schema version in an existing sidecar. True when the
    /// update ran.
    static func setSchemaVersion(_ version: Int, in directory: URL) throws -> Bool {
        var db: OpaquePointer?
        let path = directory.appendingPathComponent(AudioFingerprintStore.fileName).path
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { return false }
        defer { sqlite3_close(db) }
        return sqlite3_exec(db, "UPDATE schema SET version = \(version)", nil, nil, nil) == SQLITE_OK
    }
}
