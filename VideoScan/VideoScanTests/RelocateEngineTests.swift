import Testing
import Foundation
import CryptoKit
@testable import VideoScan

// MARK: - RelocateEngineTests
//
// Drives RelocateEngine.runOne with real /tmp fixtures (no real volumes).
// Covers: happy path, dest-collision, preRead failure, sizeMismatch,
// hashMismatch, intermediate-directory creation, legacy-hash tolerance
// (empty expectedPartialMD5).
//
// Cheap and fast — all files are tiny and live in /tmp.

@MainActor
struct RelocateEngineTests {

    // MARK: - Helpers

    /// Build a temp directory under /tmp, register cleanup. Returns the URL.
    private func makeTmpDir(_ purpose: String) throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("vs-relocate-engine-\(purpose)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    /// Write `bytes` to `url`, return its size + partial-MD5.
    private func writeFixture(at url: URL, bytes: Int) throws -> (size: Int64, md5: String) {
        // Deterministic content so the hash is stable: byte i is i % 251.
        var buf = Data(count: bytes)
        for i in 0..<bytes { buf[i] = UInt8(i % 251) }
        try buf.write(to: url)
        let hash = FileHasher.partialMD5(path: url.path)
        return (Int64(bytes), hash)
    }

    // MARK: - Happy path

    @Test
    func happyPathCopiesAndVerifies() async throws {
        let tmp = try makeTmpDir("happy")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("src.bin")
        let (size, hash) = try writeFixture(at: src, bytes: 8 * 1024)
        let dest = tmp.appendingPathComponent("out/sub/dest.bin")

        let job = RelocateJob(
            recordID: UUID(),
            sourcePath: src.path,
            destPath: dest.path,
            expectedBytes: size,
            expectedPartialMD5: hash
        )
        let outcome = await RelocateEngine.runOne(job)
        if case .success(let actualBytes, let newHash, _) = outcome {
            #expect(actualBytes == size)
            #expect(newHash == hash)
            #expect(FileManager.default.fileExists(atPath: dest.path))
        } else {
            Issue.record("Expected .success, got \(outcome)")
        }
    }

    @Test
    func intermediateDirectoriesAreCreated() async throws {
        let tmp = try makeTmpDir("intermediate-dirs")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("src.bin")
        let (size, hash) = try writeFixture(at: src, bytes: 1024)
        // Three levels deep — none exist before runOne.
        let dest = tmp.appendingPathComponent("a/b/c/d/dest.bin")
        let job = RelocateJob(recordID: UUID(), sourcePath: src.path,
                              destPath: dest.path,
                              expectedBytes: size, expectedPartialMD5: hash)
        let outcome = await RelocateEngine.runOne(job)
        if case .success = outcome {
            #expect(FileManager.default.fileExists(atPath: dest.path))
        } else {
            Issue.record("Expected .success, got \(outcome)")
        }
    }

    // MARK: - preRead

    @Test
    func preReadFailsWhenSourceMissing() async throws {
        let tmp = try makeTmpDir("preread")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dest = tmp.appendingPathComponent("dest.bin")
        let job = RelocateJob(
            recordID: UUID(),
            sourcePath: "/tmp/does-not-exist-\(UUID().uuidString)",
            destPath: dest.path,
            expectedBytes: 100,
            expectedPartialMD5: "abcdef"
        )
        let outcome = await RelocateEngine.runOne(job)
        if case .salvageFailed(_, let stage) = outcome {
            #expect(stage == .preRead)
            #expect(!FileManager.default.fileExists(atPath: dest.path))
        } else {
            Issue.record("Expected preRead salvageFailed, got \(outcome)")
        }
    }

    @Test
    func emptySourceFileIsAcceptable() async throws {
        // Zero-byte files: probe `read` returns 0, not <0. Copy succeeds.
        let tmp = try makeTmpDir("empty")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("empty.bin")
        try Data().write(to: src)
        let dest = tmp.appendingPathComponent("out.bin")
        let job = RelocateJob(recordID: UUID(), sourcePath: src.path,
                              destPath: dest.path,
                              expectedBytes: 0, expectedPartialMD5: "")
        let outcome = await RelocateEngine.runOne(job)
        if case .success(let actualBytes, _, _) = outcome {
            #expect(actualBytes == 0)
        } else {
            Issue.record("Expected .success on 0-byte file, got \(outcome)")
        }
    }

    // MARK: - Destination collision

    @Test
    func destinationCollisionIsRejected() async throws {
        let tmp = try makeTmpDir("collision")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("src.bin")
        let (size, hash) = try writeFixture(at: src, bytes: 1024)
        let dest = tmp.appendingPathComponent("dest.bin")
        // Pre-existing file at dest path.
        try Data("squatter".utf8).write(to: dest)

        let job = RelocateJob(recordID: UUID(), sourcePath: src.path,
                              destPath: dest.path,
                              expectedBytes: size, expectedPartialMD5: hash)
        let outcome = await RelocateEngine.runOne(job)
        if case .salvageFailed(_, let stage) = outcome {
            #expect(stage == .copy)
            // Squatter must be untouched.
            let after = try Data(contentsOf: dest)
            #expect(after == Data("squatter".utf8))
        } else {
            Issue.record("Expected copy-stage salvageFailed on collision, got \(outcome)")
        }
    }

    // MARK: - sizeMismatch

    @Test
    func sizeMismatchSurfacesAsSalvageFailed() async throws {
        let tmp = try makeTmpDir("size")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("src.bin")
        let (_, hash) = try writeFixture(at: src, bytes: 1024)
        let dest = tmp.appendingPathComponent("dest.bin")
        // Lie about expected size — claim 9999 even though file is 1024.
        let job = RelocateJob(recordID: UUID(), sourcePath: src.path,
                              destPath: dest.path,
                              expectedBytes: 9999, expectedPartialMD5: hash)
        let outcome = await RelocateEngine.runOne(job)
        if case .salvageFailed(_, let stage) = outcome {
            #expect(stage == .sizeMismatch)
            // Dest file SHOULD still exist — engine leaves it for inspection.
            #expect(FileManager.default.fileExists(atPath: dest.path))
        } else {
            Issue.record("Expected sizeMismatch, got \(outcome)")
        }
    }

    // MARK: - hashMismatch

    @Test
    func hashMismatchSurfacesAsSalvageFailed() async throws {
        let tmp = try makeTmpDir("hash")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("src.bin")
        let (size, _) = try writeFixture(at: src, bytes: 1024)
        let dest = tmp.appendingPathComponent("dest.bin")
        // Lie about expected hash — provide a clearly bogus one.
        let job = RelocateJob(recordID: UUID(), sourcePath: src.path,
                              destPath: dest.path,
                              expectedBytes: size,
                              expectedPartialMD5: "ffffffffffffffffffffffffffffffff")
        let outcome = await RelocateEngine.runOne(job)
        if case .salvageFailed(_, let stage) = outcome {
            #expect(stage == .hashMismatch)
        } else {
            Issue.record("Expected hashMismatch, got \(outcome)")
        }
    }

    // MARK: - Legacy (empty expectedPartialMD5)

    @Test
    func emptyExpectedHashSkipsVerifyAndStillSucceeds() async throws {
        // Legacy records may have no stored hash. The engine should
        // size-verify only and return success.
        let tmp = try makeTmpDir("no-hash")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("src.bin")
        let (size, _) = try writeFixture(at: src, bytes: 256)
        let dest = tmp.appendingPathComponent("dest.bin")
        let job = RelocateJob(recordID: UUID(), sourcePath: src.path,
                              destPath: dest.path,
                              expectedBytes: size, expectedPartialMD5: "")
        let outcome = await RelocateEngine.runOne(job)
        if case .success(_, let newHash, _) = outcome {
            // Engine should still compute and return a fresh hash even
            // though it couldn't verify against an expected one.
            #expect(!newHash.isEmpty)
        } else {
            Issue.record("Expected .success on legacy record, got \(outcome)")
        }
    }
}
