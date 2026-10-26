// AudioCatalogIndexTests.swift — the catalog-wide sound index
// (design provenance_retroactive_2026_10_26 §Phase A tests).
//   Logic     — every admitted landmark is posted exactly once and is
//               reachable from its own hash.
//   Truth     — sampled keys and other recipes are COUNTED, never indexed.
//   Isolation — a poisoned blob, an out-of-range hash, a poisoned / newer /
//               missing sidecar, the posting cap, and paging that never holds
//               the store's lock across pages.
//   Scale     — AudioCatalogIndexScaleTests (25 M landmarks, time + memory).

import Foundation
import SQLite3
import Testing
@testable import VideoScanCore

/// Crafted prints and scratch sidecars shared by the index and finder tests.
enum CatalogIndexFixtures {
    static func key(_ n: Int, sampled: Bool = false) -> AudioFingerprintStore.Key {
        let hex = String(repeating: String(format: "%02x", n % 256), count: 32)
        return AudioFingerprintStore.Key(contentDigest: (sampled ? "v1:" : "sha256:") + hex, sizeBytes: Int64(1_000 + n))
    }

    /// A print of `count` random landmarks (24-bit hashes, dt 1…63).
    static func randomPrint(count: Int, seed: UInt64, recipeID: UInt32 = AudioFingerprintParameters.default.recipeID,
                            seconds: Double = 300) -> AudioFingerprint {
        var rng = SplitMix64(seed: seed)
        var hashes = [UInt32](), times = [UInt32]()
        hashes.reserveCapacity(count); times.reserveCapacity(count)
        let frames = UInt64(seconds / 0.064)
        for _ in 0..<count {
            let f1 = Int(rng.next() % 512), f2 = Int(rng.next() % 512), dt = Int(1 + rng.next() % 63)
            hashes.append(AudioFingerprint.packHash(f1: f1, f2: f2, dt: dt))
            times.append(UInt32(rng.next() % max(1, frames)))
        }
        return AudioFingerprint(recipeID: recipeID, sampleRate: 8_000, hopSamples: 512, frameSize: 1_024,
                                durationSeconds: seconds, hashes: hashes, times: times)
    }

    /// A row source over fixed rows (the store's order is the caller's).
    static func rows(_ list: [(AudioFingerprintStore.Key, Result<AudioFingerprint, Error>)]) -> AudioCatalogIndex.RowSource {
        { body in
            for (key, result) in list { guard try body(key, result) else { return } }
        }
    }

    static func scratchDirectory(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_catalogindex_\(label)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Run `sql` against the sidecar file directly (poisoning a row).
    static func exec(_ sql: String, on file: URL) {
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
    }
}

@Suite("AudioCatalogIndex")
struct AudioCatalogIndexTests {
    typealias F = CatalogIndexFixtures

    @Test("every admitted landmark is posted once and reachable from its hash")
    func buildCountsEveryLandmarkOnce() throws {
        let prints = (0..<6).map { F.randomPrint(count: 200 + $0 * 37, seed: UInt64($0 + 1)) }
        let rows = prints.enumerated().map { (F.key($0.offset), Result<AudioFingerprint, Error>.success($0.element)) }
        let (index, report) = try AudioCatalogIndex.build(rows: F.rows(rows), expectedRows: rows.count)
        #expect(report.indexed == 6)
        #expect(report.landmarks == prints.reduce(0) { $0 + $1.landmarkCount })
        #expect(index.postingCount == report.landmarks)
        for (ordinal, print) in prints.enumerated() {
            var expected: [UInt32: [UInt32]] = [:]
            for (h, t) in zip(print.hashes, print.times) { expected[h, default: []].append(t) }
            for (hash, frames) in expected {
                let posted = index.postings(of: hash).filter { $0.document == UInt32(ordinal) }.map(\.frame)
                #expect(posted.sorted() == frames.sorted(), "hash \(hash) of doc \(ordinal)")
            }
        }
        #expect(!index.postings(of: 0).contains(.unfilled))
    }

    @Test("sampled keys and other recipes are counted, never indexed")
    func sampledKeysAndOtherRecipesAreCountedNotIndexed() throws {
        let good = F.randomPrint(count: 300, seed: 11)
        let sampled = F.randomPrint(count: 300, seed: 12)
        let foreign = F.randomPrint(count: 300, seed: 13, recipeID: 0xDEAD_BEEF)
        let short = F.randomPrint(count: 19, seed: 14)
        let rows: [(AudioFingerprintStore.Key, Result<AudioFingerprint, Error>)] = [
            (F.key(1), .success(good)), (F.key(2, sampled: true), .success(sampled)),
            (F.key(3), .success(foreign)), (F.key(4), .success(short)),
        ]
        let (index, report) = try AudioCatalogIndex.build(rows: F.rows(rows), expectedRows: rows.count)
        #expect(report.indexed == 1)
        #expect(report.notWholeFileKey == 1)
        #expect(report.otherRecipe == 1)
        #expect(report.tooFewLandmarks == 1)
        #expect(index.documents.map(\.key) == [F.key(1)])
        #expect(index.postingCount == good.landmarkCount)
        #expect(index.ordinal(of: F.key(2, sampled: true)) == nil)
        #expect(index.ordinal(of: F.key(3)) == nil)
    }

    @Test("a poisoned blob in the sidecar is counted and listed; every other print is indexed")
    func unreadableBlobIsCountedAndBuildContinues() throws {
        let dir = try F.scratchDirectory("poisonrow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try AudioFingerprintStore(directory: dir)
        try store.put((0..<5).map { .init(key: F.key($0), fingerprint: F.randomPrint(count: 100, seed: UInt64($0 + 20)), sourcePath: "test") })
        F.exec("UPDATE fingerprints SET blob = x'00010203' WHERE content_digest = '\(F.key(2).contentDigest)'",
               on: store.fileURL)
        let (index, report) = try AudioCatalogIndex.build(store: store)
        #expect(report.unreadable == 1)
        #expect(report.unreadableKeys == [F.key(2)])
        #expect(report.indexed == 4)
        #expect(index.ordinal(of: F.key(2)) == nil)
    }

    @Test("a hash beyond 24 bits refuses that print only")
    func hashBeyond24BitsRefusesThatPrintOnly() throws {
        let good = F.randomPrint(count: 100, seed: 31)
        let bad = AudioFingerprint(sampleRate: 8_000, hopSamples: 512, frameSize: 1_024, durationSeconds: 10,
                                   hashes: Array(repeating: 5, count: 30) + [1 << 24], times: Array(repeating: 1, count: 31))
        let rows: [(AudioFingerprintStore.Key, Result<AudioFingerprint, Error>)] = [(F.key(1), .success(bad)), (F.key(2), .success(good))]
        let (index, report) = try AudioCatalogIndex.build(rows: F.rows(rows), expectedRows: 2)
        #expect(report.unreadable == 1)
        #expect(report.unreadableKeys == [F.key(1)])
        #expect(report.indexed == 1)
        #expect(index.postings(of: 5).isEmpty)
    }

    @Test("a missing, poisoned or newer sidecar is refused before any build")
    func poisonedOrNewerSidecarRefusesBeforeBuild() throws {
        let missing = try F.scratchDirectory("missing")
        defer { try? FileManager.default.removeItem(at: missing) }
        #expect(throws: AudioCatalogIndex.BuildFailure.noSidecar(path: missing.path)) {
            _ = try AudioCatalogIndex.openSidecar(directory: missing)
        }
        // Refusing never creates the file.
        #expect(!FileManager.default.fileExists(atPath: missing.appendingPathComponent(AudioFingerprintStore.fileName).path))

        let poisoned = try F.scratchDirectory("notadb")
        defer { try? FileManager.default.removeItem(at: poisoned) }
        let file = poisoned.appendingPathComponent(AudioFingerprintStore.fileName)
        try Data(repeating: 0x41, count: 8_192).write(to: file)
        #expect(throws: AudioFingerprintStore.Failure.notADatabase(path: file.path)) {
            _ = try AudioCatalogIndex.openSidecar(directory: poisoned)
        }

        let newer = try F.scratchDirectory("newer")
        defer { try? FileManager.default.removeItem(at: newer) }
        do { _ = try AudioFingerprintStore(directory: newer) }
        F.exec("UPDATE schema SET version = \(AudioFingerprintStore.schemaVersion + 1)",
               on: newer.appendingPathComponent(AudioFingerprintStore.fileName))
        #expect(throws: AudioFingerprintStore.Failure.schemaNewer(found: AudioFingerprintStore.schemaVersion + 1,
                                                                   supported: AudioFingerprintStore.schemaVersion)) {
            _ = try AudioCatalogIndex.openSidecar(directory: newer)
        }
    }

    @Test("the build refuses past the posting cap, with the MB figure")
    func buildRefusesOverPostingCap() throws {
        let rows: [(AudioFingerprintStore.Key, Result<AudioFingerprint, Error>)] = [
            (F.key(1), .success(F.randomPrint(count: 1_001, seed: 41))),
        ]
        do {
            _ = try AudioCatalogIndex.build(rows: F.rows(rows), expectedRows: 1, maxPostings: 1_000)
            Issue.record("expected a refusal")
        } catch let failure as AudioCatalogIndex.BuildFailure {
            #expect(failure == .tooLarge(postings: 1_001, cap: 1_000, megabytes: AudioCatalogIndex.megabytes(forPostings: 1_001)))
            #expect(failure.description.contains("MB"))
        }
        // At the cap exactly: built.
        let (_, report) = try AudioCatalogIndex.build(rows: F.rows(rows), expectedRows: 1, maxPostings: 1_001)
        #expect(report.landmarks == 1_001)
    }

    @Test("paging never holds the store's lock across pages: a put completes mid-build")
    func pagingDoesNotHoldTheLockAcrossPages() throws {
        let dir = try F.scratchDirectory("paging")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try AudioFingerprintStore(directory: dir)
        try store.put((0..<20).map { .init(key: F.key($0), fingerprint: F.randomPrint(count: 50, seed: UInt64($0 + 60)), sourcePath: "test") })
        let putDone = DispatchSemaphore(value: 0)
        let attempted = LockedFlag()
        var putFinishedInTime = false
        var rowsSeen = 0
        try store.forEachFingerprint(pageSize: 4) { _, _ in
            rowsSeen += 1
            if rowsSeen == 6, !attempted.value {     // mid-iteration, between pages' locks
                attempted.value = true
                let entry = AudioFingerprintStore.Entry(key: F.key(200), fingerprint: F.randomPrint(count: 50, seed: 999),
                                                        sourcePath: "test")
                // A dedicated thread: the GCD pool can be saturated by the
                // suites running in parallel, which would time this out for
                // a reason that has nothing to do with the store's lock.
                Thread {
                    try? store.put([entry])
                    putDone.signal()
                }.start()
                putFinishedInTime = putDone.wait(timeout: .now() + 5) == .success
            }
            return true
        }
        #expect(putFinishedInTime, "a put from another thread must not wait for the whole iteration")
        #expect(try store.has(F.key(200)))
        #expect(rowsSeen >= 20)
    }

    /// Bytes + mtime of the main file and the -wal, and the inode of every
    /// sidecar file that exists (db, -wal, -shm).
    struct SidecarFacts: Equatable {
        var dbBytes = Data(), walBytes: Data?
        var dbModified = Date.distantPast, walModified: Date?
        var inodes: [String: Int] = [:]

        static func of(_ file: URL) throws -> SidecarFacts {
            let fm = FileManager.default
            var f = SidecarFacts()
            f.dbBytes = try Data(contentsOf: file)
            f.dbModified = try fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date ?? .distantPast
            if fm.fileExists(atPath: file.path + "-wal") {
                f.walBytes = try Data(contentsOf: URL(fileURLWithPath: file.path + "-wal"))
                f.walModified = try fm.attributesOfItem(atPath: file.path + "-wal")[.modificationDate] as? Date
            }
            for suffix in ["", "-wal", "-shm"] {
                if let ino = try? fm.attributesOfItem(atPath: file.path + suffix)[.systemFileNumber] as? Int {
                    f.inodes[suffix] = ino
                }
            }
            return f
        }
    }

    @Test("a read-only build changes nothing — bytes, mtime, inodes — even while a writer holds -wal frames")
    func readOnlyBuildChangesNothingEvenWithWALFrames() throws {
        let dir = try F.scratchDirectory("readonly")
        defer { try? FileManager.default.removeItem(at: dir) }
        // A writer that stays open (a running Fingerprint Sound): its rows
        // live in -wal frames, never checkpointed while we read.
        var openWriter: AudioFingerprintStore? = try AudioFingerprintStore(directory: dir)
        let file = try #require(openWriter).fileURL
        try openWriter?.put((0..<6).map { .init(key: F.key($0), fingerprint: F.randomPrint(count: 120, seed: UInt64($0 + 70)), sourcePath: "test") })
        let walSize = try FileManager.default.attributesOfItem(atPath: file.path + "-wal")[.size] as? Int ?? 0
        #expect(walSize > 0, "the fixture must have WAL frames")
        let before = try SidecarFacts.of(file)
        do {
            let reader = try AudioCatalogIndex.openSidecar(directory: dir)
            #expect(reader.isReadOnly)
            let (index, report) = try AudioCatalogIndex.build(store: reader)
            #expect(report.indexed == 6, "rows that exist only in -wal frames are read")
            #expect(try reader.fingerprint(for: F.key(3)) != nil)
            #expect(index.ordinal(of: F.key(5)) != nil)
            #expect(throws: (any Error).self) { try reader.put([.init(key: F.key(99), fingerprint: F.randomPrint(count: 30, seed: 1), sourcePath: "x")]) }
        }   // reader closed here
        #expect(try SidecarFacts.of(file) == before)

        // And after the writer closes (Apple's SQLite keeps a 0-byte -wal):
        // a read-only run still leaves every byte and inode as it was.
        openWriter = nil
        _ = openWriter
        let afterWriter = try SidecarFacts.of(file)
        do {
            let reader = try AudioCatalogIndex.openSidecar(directory: dir)
            #expect(try AudioCatalogIndex.build(store: reader).1.indexed == 6)
        }
        #expect(try SidecarFacts.of(file) == afterWriter)
    }

    @Test("a WAL sidecar whose -wal is missing is refused in plain words; no file is created")
    func readOnlyOpenRefusesAMissingWAL() throws {
        let dir = try F.scratchDirectory("nowal")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file: URL
        do {
            let writer = try AudioFingerprintStore(directory: dir)
            try writer.put([.init(key: F.key(1), fingerprint: F.randomPrint(count: 40, seed: 5), sourcePath: "test")])
            file = writer.fileURL
        }
        // Simulate "last closed by another program": no -wal, no -shm (test-owned scratch files).
        try? FileManager.default.removeItem(atPath: file.path + "-wal")
        try? FileManager.default.removeItem(atPath: file.path + "-shm")
        let before = try SidecarFacts.of(file)
        do {
            _ = try AudioCatalogIndex.openSidecar(directory: dir)
            Issue.record("expected a refusal")
        } catch let failure as AudioFingerprintStore.Failure {
            #expect(failure == .readOnlyNeedsWAL(path: file.path))
            #expect(failure.description.contains("write-ahead log"))
            #expect(failure.description.contains("Nothing was read or changed"))
        }
        #expect(try SidecarFacts.of(file) == before)
        #expect(!FileManager.default.fileExists(atPath: file.path + "-wal"))
    }

    @Test("isCancelled stops the build with CancellationError")
    func cancelStopsTheBuild() throws {
        let rows: [(AudioFingerprintStore.Key, Result<AudioFingerprint, Error>)] =
            (0..<3).map { (F.key($0), .success(F.randomPrint(count: 40, seed: UInt64($0)))) }
        #expect(throws: CancellationError.self) {
            _ = try AudioCatalogIndex.build(rows: F.rows(rows), expectedRows: 3, isCancelled: { true })
        }
    }
}

/// A Bool behind a lock (tests only).
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
