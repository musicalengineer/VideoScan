// ArchivePromoteEnginePipelineTests.swift
// Regression net for the pipelined copy/verify passes
// (perf/promote-copy-pipeline, 2026-08-20). The pipelining is a pure
// performance change — these tests pin the behavioral contract that must
// NOT have moved: bit-identical SHA-256 across chunk-boundary sizes,
// per-chunk cancellation that leaves the destination clean, and
// monotonic phase-ordered progress callbacks.

import CryptoKit
import Foundation
import Testing
@testable import VideoScan

@Suite("ArchivePromoteEngine — pipelined copy/verify", .serialized)
struct ArchivePromoteEnginePipelineTests {

    // MARK: helpers

    /// Fast deterministic pseudo-random blob (xorshift64*, 8 bytes per
    /// step — MasterArchiveTestSupport.writeBlob is byte-at-a-time and
    /// too slow for the ~100 MB case).
    private func randomBlob(bytes: Int, seed: UInt64) -> Data {
        var state = seed &+ 0x9E3779B97F4A7C15
        var out = [UInt8](repeating: 0, count: bytes)
        out.withUnsafeMutableBytes { raw in
            var i = 0
            while i < bytes {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                let step = min(8, bytes - i)
                withUnsafeBytes(of: state) { word in
                    raw.baseAddress!.advanced(by: i).copyMemory(from: word.baseAddress!, byteCount: step)
                }
                i += step
            }
        }
        return Data(out)
    }

    /// One-shot reference digest, independent of the engine's chunking.
    private func referenceSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeArchiveSandbox(_ label: String) throws -> MasterArchiveTestSupport.Sandbox {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        try FileManager.default.createDirectory(at: sb.archiveRoot, withIntermediateDirectories: true)
        return sb
    }

    // MARK: digest equality across chunk boundaries

    /// Sizes chosen around the pipeline chunk: empty, single byte,
    /// chunk−1, exact chunk multiple, multiple+1, and ~100 MB (many
    /// chunks, exercises ring wrap-around dozens of times).
    static let boundarySizes: [Int] = [
        0,
        1,
        ArchivePromoteEngine.pipelineChunkSize - 1,
        ArchivePromoteEngine.pipelineChunkSize * 3,
        ArchivePromoteEngine.pipelineChunkSize * 3 + 1,
        100 * 1024 * 1024,
    ]

    @Test("sha256(fd:) and copyVerifyPublish match a one-shot reference hash at every boundary size",
          arguments: boundarySizes)
    func digestMatchesReference(size: Int) throws {
        let sb = try makeArchiveSandbox("pipe_digest")
        defer { sb.cleanup() }
        let data = randomBlob(bytes: size, seed: UInt64(size) &+ 0xBEEF)
        let src = sb.sources.appendingPathComponent("test_src_\(size).bin")
        try data.write(to: src)
        let expected = referenceSHA256(data)

        // Standalone streamed hash.
        #expect(try ArchivePromoteEngine.sha256(path: src.path) == expected)

        // Full copy → verify → publish; recorded digest must be the same
        // reference digest, and the published bytes must re-hash to it.
        let handle = try ArchivePromoteEngine.openSource(path: src.path)
        defer { handle.close() }
        let rel = "30_Video/Undated/test_dest_\(size).bin"
        let result = try ArchivePromoteEngine.copyVerifyPublish(
            source: handle, root: sb.archiveRoot.path, relativePath: rel)
        #expect(result.sha256 == expected)
        #expect(result.sizeBytes == Int64(size))
        let dest = sb.archiveRoot.appendingPathComponent(rel)
        #expect(try ArchivePromoteEngine.sha256(path: dest.path) == expected)
        #expect(referenceSHA256(try Data(contentsOf: dest)) == expected)
    }

    @Test("verifyBypassesPageCache (F_NOCACHE) changes nothing about the result")
    func noCacheFlagSameResult() throws {
        let sb = try makeArchiveSandbox("pipe_nocache")
        defer { sb.cleanup() }
        let size = ArchivePromoteEngine.pipelineChunkSize * 2 + 12345
        let data = randomBlob(bytes: size, seed: 0xCAFE)
        let src = sb.sources.appendingPathComponent("test_nc.bin")
        try data.write(to: src)
        let handle = try ArchivePromoteEngine.openSource(path: src.path)
        defer { handle.close() }
        let result = try ArchivePromoteEngine.copyVerifyPublish(
            source: handle, root: sb.archiveRoot.path,
            relativePath: "30_Video/Undated/test_nc.bin",
            verifyBypassesPageCache: true)
        #expect(result.sha256 == referenceSHA256(data))
        #expect(result.sizeBytes == Int64(size))
    }

    // MARK: cancellation

    @Test("cancel mid-COPY throws .cancelled and leaves no partial and no destination")
    func cancelMidCopyCleansUp() throws {
        let sb = try makeArchiveSandbox("pipe_cancel_copy")
        defer { sb.cleanup() }
        let size = ArchivePromoteEngine.pipelineChunkSize * 8   // 8 chunks
        try randomBlob(bytes: size, seed: 1).write(to: sb.sources.appendingPathComponent("test_c.bin"))
        let handle = try ArchivePromoteEngine.openSource(path: sb.sources.appendingPathComponent("test_c.bin").path)
        defer { handle.close() }
        let rel = "30_Video/Undated/test_c.bin"
        var copiedSoFar: Int64 = 0
        #expect(throws: ArchivePromoteEngine.Failure.cancelled) {
            try ArchivePromoteEngine.copyVerifyPublish(
                source: handle, root: sb.archiveRoot.path, relativePath: rel,
                progress: { copiedSoFar = $0 },
                shouldCancel: { copiedSoFar >= Int64(ArchivePromoteEngine.pipelineChunkSize * 2) })
        }
        #expect(copiedSoFar < Int64(size), "cancel must fire mid-copy, not after completion")
        let dir = sb.archiveRoot.appendingPathComponent("30_Video/Undated")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(leftovers.isEmpty, "cancel left files behind: \(leftovers)")
        // The engine's own partial-cleanup path agrees nothing is there.
        #expect(try ArchivePromoteEngine.removeContainedPartial(root: sb.archiveRoot.path, relativePath: rel) == false)
    }

    @Test("cancel mid-VERIFY throws .cancelled and leaves no partial and no destination")
    func cancelMidVerifyCleansUp() throws {
        let sb = try makeArchiveSandbox("pipe_cancel_verify")
        defer { sb.cleanup() }
        let size = ArchivePromoteEngine.pipelineChunkSize * 4
        try randomBlob(bytes: size, seed: 2).write(to: sb.sources.appendingPathComponent("test_v.bin"))
        let handle = try ArchivePromoteEngine.openSource(path: sb.sources.appendingPathComponent("test_v.bin").path)
        defer { handle.close() }
        var verifying = false
        #expect(throws: ArchivePromoteEngine.Failure.cancelled) {
            try ArchivePromoteEngine.copyVerifyPublish(
                source: handle, root: sb.archiveRoot.path,
                relativePath: "30_Video/Undated/test_v.bin",
                phaseProgress: { phase, _ in if phase == .verifying { verifying = true } },
                shouldCancel: { verifying })
        }
        #expect(verifying, "cancel was supposed to fire during the verify pass")
        let dir = sb.archiveRoot.appendingPathComponent("30_Video/Undated")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(leftovers.isEmpty, "cancel left files behind: \(leftovers)")
    }

    // MARK: verify compare + O_EXCL partial (N1008-T-Archive-F1)

    /// The bytes on the archive drive are damaged AFTER the copy wrote them
    /// (here: byte 0 of the partial flipped from the 2nd progress callback,
    /// through a second descriptor). The source is untouched, so only the
    /// verify read-back can tell — the copy must be refused, not published.
    @Test("N1008-F1: a partial damaged after it was written fails VERIFY (.verifyMismatch); no destination, no partial")
    func damagedPartialFailsVerify() throws {
        let sb = try makeArchiveSandbox("pipe_verify_mismatch")
        defer { sb.cleanup() }
        let size = ArchivePromoteEngine.pipelineChunkSize * 3          // 3 chunks → 3 progress callbacks
        let data = randomBlob(bytes: size, seed: 0xF1)
        let src = sb.sources.appendingPathComponent("test_vm.bin")
        try data.write(to: src)
        let handle = try ArchivePromoteEngine.openSource(path: src.path)
        defer { handle.close() }
        let rel = "30_Video/Undated/test_vm.bin"
        let dest = sb.archiveRoot.appendingPathComponent(rel)
        let partial = dest.path + ".partial"

        var calls = 0
        var flipped = false
        var thrown: Error?
        do {
            _ = try ArchivePromoteEngine.copyVerifyPublish(
                source: handle, root: sb.archiveRoot.path, relativePath: rel,
                progress: { _ in
                    calls += 1
                    guard calls == 2 else { return }
                    // pwrite(2) through our own fd: the engine's write offset is untouched.
                    let fd = open(partial, O_RDWR)
                    guard fd >= 0 else { return }
                    defer { close(fd) }
                    var b: UInt8 = 0
                    guard pread(fd, &b, 1, 0) == 1 else { return }
                    b ^= 0xFF
                    flipped = pwrite(fd, &b, 1, 0) == 1
                })
        } catch {
            thrown = error
        }
        #expect(flipped, "fixture: byte 0 of the partial was not flipped on the 2nd progress callback (calls=\(calls))")
        // (Swift: `if case .x(let a, let b) = value` ≈ a C++ std::get_if on a variant + structured binding.)
        if case .verifyMismatch(let expected, let actual)? = thrown as? ArchivePromoteEngine.Failure {
            #expect(expected == referenceSHA256(data), "expected = the SOURCE digest")
            #expect(actual != expected)
        } else {
            Issue.record("expected .verifyMismatch, got \(String(describing: thrown))")
        }
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dest.path), "a copy that failed verify was published")
        #expect(!fm.fileExists(atPath: partial), "the damaged partial was left behind")
    }

    /// The partial is opened O_CREAT|O_EXCL: a `.partial` already there (an
    /// in-flight copy, a crash leftover) is never adopted or overwritten.
    @Test("N1008-F1: a pre-existing <dest>.partial refuses the copy (.partialExists); its bytes are untouched")
    func existingPartialIsRefused() throws {
        let sb = try makeArchiveSandbox("pipe_partial_exists")
        defer { sb.cleanup() }
        let data = randomBlob(bytes: 64 * 1024, seed: 0xF1B)
        let src = sb.sources.appendingPathComponent("test_pe.bin")
        try data.write(to: src)
        let rel = "30_Video/Undated/test_pe.bin"
        let dest = sb.archiveRoot.appendingPathComponent(rel)
        let partial = URL(fileURLWithPath: dest.path + ".partial")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let planted = Data("planted partial — another copy owns me".utf8)
        try planted.write(to: partial)

        let handle = try ArchivePromoteEngine.openSource(path: src.path)
        defer { handle.close() }
        var thrown: Error?
        do {
            _ = try ArchivePromoteEngine.copyVerifyPublish(source: handle, root: sb.archiveRoot.path, relativePath: rel)
        } catch {
            thrown = error
        }
        if case .partialExists(let path)? = thrown as? ArchivePromoteEngine.Failure {
            #expect(path.hasSuffix("test_pe.bin.partial"), "\(path)")
        } else {
            Issue.record("expected .partialExists, got \(String(describing: thrown))")
        }
        #expect(try Data(contentsOf: partial) == planted, "the planted partial was overwritten")
        #expect(!FileManager.default.fileExists(atPath: dest.path), "nothing may be published")
    }

    // MARK: progress semantics

    @Test("progress is strictly monotonic, phase-ordered (all copying before any verifying), and both phases end at the file size")
    func progressMonotonicAndPhased() throws {
        let sb = try makeArchiveSandbox("pipe_progress")
        defer { sb.cleanup() }
        let size = ArchivePromoteEngine.pipelineChunkSize * 3 + (1 << 20) + 1   // multiple + remainder + 1
        try randomBlob(bytes: size, seed: 3).write(to: sb.sources.appendingPathComponent("test_p.bin"))
        let handle = try ArchivePromoteEngine.openSource(path: sb.sources.appendingPathComponent("test_p.bin").path)
        defer { handle.close() }

        var plainProgress: [Int64] = []
        var phases: [(ArchivePromoteEngine.ProgressPhase, Int64)] = []
        _ = try ArchivePromoteEngine.copyVerifyPublish(
            source: handle, root: sb.archiveRoot.path,
            relativePath: "30_Video/Undated/test_p.bin",
            progress: { plainProgress.append($0) },
            phaseProgress: { phases.append(($0, $1)) })

        // Plain progress: strictly increasing, ends at size (copy phase only, as before).
        #expect(!plainProgress.isEmpty)
        #expect(plainProgress == plainProgress.sorted())
        #expect(Set(plainProgress).count == plainProgress.count, "progress values must be strictly increasing")
        #expect(plainProgress.last == Int64(size))

        // Phases: copying values first, then verifying — never interleaved.
        let copyValues = phases.filter { $0.0 == .copying }.map(\.1)
        let verifyValues = phases.filter { $0.0 == .verifying }.map(\.1)
        if let firstVerify = phases.firstIndex(where: { $0.0 == .verifying }) {
            #expect(phases[..<firstVerify].allSatisfy { $0.0 == .copying })
            #expect(phases[firstVerify...].allSatisfy { $0.0 == .verifying })
        } else {
            Issue.record("no verifying phase reported")
        }
        #expect(copyValues == plainProgress, "plain progress and copying phase must be the same stream")
        for values in [copyValues, verifyValues] {
            #expect(values == values.sorted())
            #expect(Set(values).count == values.count)
            #expect(values.last == Int64(size))
        }
    }
}
