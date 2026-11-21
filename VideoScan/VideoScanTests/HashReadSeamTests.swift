// HashReadSeamTests.swift
// The full-file hash READ seam itself (`ArchivePromoteEngine.readHook`,
// 2026-11-20), at the engine: what each injected fault does to the three
// `sha256` entry points and to copy → verify → publish, and the proof that
// production is unchanged when nothing is bound.
//
//   LOGIC     — EIO at byte N, a read that ends early, a partial read, one
//               flipped bit: the engine's answer to each.
//   UNCHANGED — hook nil ⇒ the reference digest at every chunk-boundary
//               size; a bound-but-silent hook sees every chunk once, in
//               file order, and the digest is still the reference digest.
//   TIME      — the nil-hook hash of 64 MiB against a plain serial
//               read + SHA-256 loop in this file (the "before" shape).
//   ISOLATION — the hook is task-local: a sibling task hashing the same
//               file at the same moment is not touched; a detached task
//               does not inherit it; the file on disk never changes.
//   SENSOR    — nothing in the app binds the hook (HashReadSeamSensorTests;
//               the serial hashers' consult: DedupeHashReadSeamSensorTests).
//
// Parallel-safe: temp sandboxes, task-local hook, no shared state.

import CryptoKit
import Foundation
import Testing
@testable import VideoScan

/// Deterministic bytes, 8 per step (≈ the pipeline suite's generator).
func hashSeamBlob(bytes: Int, seed: UInt64) -> Data {
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

func hashSeamReference(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@Suite("Hash read seam — the engine under an injected read fault")
struct HashReadSeamTests {

    typealias Engine = ArchivePromoteEngine
    static let chunk = ArchivePromoteEngine.pipelineChunkSize

    private func sandbox(_ label: String) throws -> MasterArchiveTestSupport.Sandbox {
        let sb = try MasterArchiveTestSupport.makeSandbox("hashseam_\(label)")
        try FileManager.default.createDirectory(at: sb.archiveRoot, withIntermediateDirectories: true)
        return sb
    }

    private func write(_ sb: MasterArchiveTestSupport.Sandbox, _ name: String, bytes: Int, seed: UInt64) throws -> (URL, Data) {
        let data = hashSeamBlob(bytes: bytes, seed: seed)
        let url = sb.sources.appendingPathComponent(name)
        try data.write(to: url)
        return (url, data)
    }

    private func leftovers(_ sb: MasterArchiveTestSupport.Sandbox) -> [String] {
        MasterArchiveTestSupport.archivedFiles(sb)
    }

    // MARK: Unchanged when nothing is bound

    static let sizes = [0, 1, chunk - 1, chunk, chunk * 2 + 1]

    @Test("UNCHANGED: hook nil ⇒ the reference digest; a silent hook sees every chunk once, in order, and the digest is the same",
          arguments: sizes)
    func nilAndSilentHookHashTheSameBytes(size: Int) throws {
        let sb = try sandbox("same"); defer { sb.cleanup() }
        let (url, data) = try write(sb, "test_same_\(size).bin", bytes: size, seed: UInt64(size) &+ 7)
        let expected = hashSeamReference(data)
        #expect(Engine.readHook == nil, "production default: nothing bound")
        #expect(try Engine.sha256(path: url.path) == expected)

        let observer = HashReadObserver()
        let observed = try Engine.$readHook.withValue(observer.hook) { try Engine.sha256(path: url.path) }
        #expect(observed == expected)
        var next: Int64 = 0
        for c in observer.chunks {
            #expect(c.offset == next, "chunks arrive in file order with no gap: \(observer.chunks)")
            #expect((1...Self.chunk).contains(c.count))
            next += Int64(c.count)
        }
        #expect(next == Int64(size), "every byte offered exactly once")
        #expect(observer.chunks.count == (size + Self.chunk - 1) / Self.chunk, "one consult per chunk, none at EOF")
    }

    @Test("TIME: the nil-hook hash of 64 MiB is in the same range as a plain serial read + SHA-256 loop (best of 3, wide margin)")
    func nilHookTimeIsComparable() throws {
        let sb = try sandbox("time"); defer { sb.cleanup() }
        let size = 64 << 20
        let (url, data) = try write(sb, "test_time.bin", bytes: size, seed: 99)
        let expected = hashSeamReference(data)

        /// The pre-pipeline shape: one thread, read(2) into one buffer, hash.
        func serial() throws -> String {
            let fd = open(url.path, O_RDONLY)
            try #require(fd >= 0)
            defer { close(fd) }
            let buf = UnsafeMutableRawPointer.allocate(byteCount: Self.chunk, alignment: 1 << 12)
            defer { buf.deallocate() }
            var hasher = SHA256()
            while true {
                let n = read(fd, buf, Self.chunk)
                if n <= 0 { break }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        func best(_ body: () throws -> String) rethrows -> Duration {
            var least = Duration.seconds(3600)
            for _ in 0..<3 {
                let clock = ContinuousClock()
                var digest = ""
                let took = try clock.measure { digest = try body() }
                #expect(digest == expected)
                least = min(least, took)
            }
            return least
        }
        let reference = try best(serial)
        let seamed = try best { try Engine.sha256(path: url.path) ?? "" }
        let observer = HashReadObserver()
        let hooked = try best { try Engine.$readHook.withValue(observer.hook) { try Engine.sha256(path: url.path) ?? "" } }
        print("[hash-seam] 64 MiB: serial reference \(reference), engine hook nil \(seamed), engine silent hook \(hooked)")
        // Generous on purpose: this is a guard against a per-byte cost
        // sneaking into the reader loop, not a benchmark.
        #expect(seamed <= reference * 3 + .milliseconds(500), "hook nil: \(seamed) vs serial \(reference)")
        #expect(hooked <= reference * 3 + .milliseconds(500), "silent hook: \(hooked) vs serial \(reference)")
    }

    // MARK: Each fault, at sha256

    @Test("EIO at byte N: sha256 throws the read error, no digest; the consumer saw exactly the N bytes before it",
          arguments: [Int64(0), 20_000, Int64(chunk) + 5])
    func eioThrows(at byte: Int64) throws {
        let sb = try sandbox("eio"); defer { sb.cleanup() }
        let (url, data) = try write(sb, "test_eio.bin", bytes: Self.chunk + 40_000, seed: 3)
        let fault = HashReadFault(.eio, pathSuffix: "test_eio.bin", atByte: byte)
        let h = try Engine.openSource(path: url.path); defer { h.close() }
        var seen: Int64 = 0
        #expect(throws: Engine.Failure.writeFailed("read errno \(EIO)")) {
            try fault.runSync { try Engine.sha256(fd: h.fd, progress: { seen = $0 }) }
        }
        #expect(fault.firedCount == 1)
        #expect(seen == byte, "the bytes before the failure were consumed, none after")
        #expect(try Engine.sha256(path: url.path) == hashSeamReference(data), "outside the scope the file hashes clean")
    }

    /// Pinned as it is today: the engine does not compare the bytes it
    /// consumed with the file's size, so it hands back a well-formed digest
    /// of the prefix. FixityRebind checks the count itself; prune and Verify
    /// Archive Copies do not, and for a file that CONTINUES past the
    /// expected bytes that is a false proof (P1 — see the known issue).
    @Test("a read that ends early: sha256 returns the digest of the PREFIX it was given, and says nothing")
    func prematureEOFYieldsAPrefixDigest() throws {
        let sb = try sandbox("short"); defer { sb.cleanup() }
        let (url, data) = try write(sb, "test_short.bin", bytes: Self.chunk + 40_000, seed: 4)
        let cut: Int64 = Int64(Self.chunk) + 100
        let fault = HashReadFault(.shortRead, pathSuffix: "test_short.bin", atByte: cut)
        var seen: Int64 = 0
        let h = try Engine.openSource(path: url.path); defer { h.close() }
        let digest = try fault.runSync { try Engine.sha256(fd: h.fd, progress: { seen = $0 }) }
        #expect(fault.firedCount == 1)
        #expect(seen == cut && seen < Int64(data.count), "the progress count is the only trace of the short read")
        #expect(digest == hashSeamReference(data.prefix(Int(cut))))
        #expect(digest != hashSeamReference(data))
        withKnownIssue("PARKED 2026-11-20 (P1 — ROOT CAUSE, re-ranked from P3 after Codex r1 #1): sha256(fd:) returns a well-formed digest for a read that ended before the size fstat reported. Consequences pinned elsewhere: a false PruneProof (HashReadFaultPruneTests.aShortReadOfALongerCopyMakesAFalseProof) and a false verified/restored in Verify Archive Copies (HashReadFaultVerifyArchiveTests.aShortReadOfALongerArchiveFileVerifies). Proposed: compare bytes consumed with st_size after the loop and throw a named read failure.") {
            #expect(throws: Engine.Failure.self) {
                _ = try HashReadFault(.shortRead, pathSuffix: "test_short.bin", atByte: cut)
                    .runSync { try Engine.sha256(path: url.path) }
            }
        }
    }

    @Test("an ordinary PARTIAL read (fewer bytes than asked, more to come) changes nothing: same digest")
    func partialReadIsHarmless() throws {
        let sb = try sandbox("partial"); defer { sb.cleanup() }
        let (url, data) = try write(sb, "test_partial.bin", bytes: Self.chunk + 40_000, seed: 5)
        final class Once: @unchecked Sendable { let lock = NSLock(); var done = false }
        let once = Once()
        let hook: Engine.ReadHook = { _, offset, _ in
            once.lock.withLock {
                guard !once.done, offset == 0 else { return nil }
                once.done = true
                return .shortRead(bytes: 777)
            }
        }
        let digest = try Engine.$readHook.withValue(hook) { try Engine.sha256(path: url.path) }
        #expect(once.done && digest == hashSeamReference(data))
    }

    @Test("one flipped bit: the digest is the digest of the flipped bytes — never the file's; the file is untouched")
    func bitFlipChangesTheDigest() throws {
        let sb = try sandbox("flip"); defer { sb.cleanup() }
        let (url, data) = try write(sb, "test_flip.bin", bytes: Self.chunk + 40_000, seed: 6)
        let at = Self.chunk + 123
        let fault = HashReadFault(.bitFlip, pathSuffix: "test_flip.bin", atByte: Int64(at))
        let digest = try fault.runSync { try Engine.sha256(path: url.path) }
        var flipped = data
        flipped[at] ^= 0x01
        #expect(fault.firedCount == 1)
        #expect(digest == hashSeamReference(flipped), "exactly one bit differs")
        #expect(digest != hashSeamReference(data))
        #expect(try Data(contentsOf: url) == data, "the fault lives in the read buffer; the file is not written")
    }

    @Test("the contained (dirfd) entry point goes through the same reader: a fault aimed at an archive file reaches sha256(root:relativePath:)")
    func containedReadIsSeamed() throws {
        let sb = try sandbox("contained"); defer { sb.cleanup() }
        let rel = "30_Video/Undated/test_contained.bin"
        let url = sb.archiveRoot.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = hashSeamBlob(bytes: 30_000, seed: 8)
        try data.write(to: url)
        let fault = HashReadFault(.eio, pathSuffix: "test_contained.bin", atByte: 10_000)
        #expect(throws: Engine.Failure.writeFailed("read errno \(EIO)")) {
            try fault.runSync { try Engine.sha256(root: sb.archiveRoot.path, relativePath: rel) }
        }
        #expect(fault.firedCount == 1)
    }

    // MARK: Isolation

    @Test("ISOLATION: the hook is task-local — a sibling task hashing the same file at the same moment gets the true digest; a child task inherits; a detached task does not")
    func theHookIsTaskLocal() async throws {
        let sb = try sandbox("iso"); defer { sb.cleanup() }
        let (url, data) = try write(sb, "test_iso.bin", bytes: Self.chunk * 2, seed: 9)
        let expected = hashSeamReference(data)
        let path = url.path
        let fault = HashReadFault(.bitFlip, pathSuffix: "test_iso.bin", atByte: 5, onPass: 0)
        try await withThrowingTaskGroup(of: (String, String?).self) { group in
            for i in 0..<4 {
                group.addTask { ("clean\(i)", try Engine.sha256(path: path)) }
                group.addTask {
                    try await Engine.$readHook.withValue(fault.hook) {
                        // A child task inherits the binding…
                        let inherited = try await Task { try Engine.sha256(path: path) }.value
                        // …a detached one does not (the documented caveat).
                        let detached = try await Task.detached { try Engine.sha256(path: path) }.value
                        #expect(detached == expected, "a detached task is outside the scope")
                        return ("faulted\(i)", inherited)
                    }
                }
            }
            for try await (label, digest) in group {
                if label.hasPrefix("clean") {
                    #expect(digest == expected, "\(label) was poisoned by a sibling's hook")
                } else {
                    #expect(digest != nil && digest != expected, "\(label) did not see its own hook")
                }
            }
        }
        #expect(fault.firedCount == 4, "only the four bound child reads were faulted: \(fault.firedCount)")
        #expect(Engine.readHook == nil)
    }

    // MARK: copy → verify → publish

    struct CopyCase: Sendable, CustomStringConvertible {
        let kind: HashReadFault.Kind
        /// true = the fault is in the SOURCE read (copy pass); false = in the
        /// read-back of the copy (the `.partial`).
        let inSource: Bool
        var description: String { "\(kind) in the \(inSource ? "source" : "copy") read" }
    }

    static let copyCases: [CopyCase] = HashReadFault.Kind.allCases.flatMap {
        [CopyCase(kind: $0, inSource: true), CopyCase(kind: $0, inSource: false)]
    }

    @Test("copyVerifyPublish under each fault: it throws a named failure, nothing is published, no partial is left, the source is untouched",
          arguments: copyCases)
    func copyVerifyPublishRefuses(_ c: CopyCase) throws {
        let sb = try sandbox("cvp"); defer { sb.cleanup() }
        let (url, data) = try write(sb, "test_cvp.bin", bytes: Self.chunk + 40_000, seed: 12)
        let expected = hashSeamReference(data)
        let rel = "30_Video/Undated/test_cvp.bin"
        let fault = c.inSource
            ? HashReadFault(c.kind, pathSuffix: "Sources/test_cvp.bin", atByte: Int64(Self.chunk) + 9)
            : HashReadFault(c.kind, pathSuffix: "test_cvp.bin.partial", atByte: Int64(Self.chunk) + 9)
        let handle = try Engine.openSource(path: url.path); defer { handle.close() }
        var thrown: Engine.Failure?
        do {
            _ = try fault.runSync {
                try Engine.copyVerifyPublish(source: handle, root: sb.archiveRoot.path, relativePath: rel,
                                             expectedSourceSHA: expected)
            }
            Issue.record("\(c): the copy was published")
        } catch let failure as Engine.Failure {
            thrown = failure
        }
        #expect(fault.firedCount == 1, "\(c): the fault did not reach its read")
        switch (c.kind, c.inSource) {
        case (.eio, true):
            #expect(thrown == .sourceUnreadable(url.path))
        case (.shortRead, true), (.bitFlip, true):
            #expect(thrown == .sourceChangedDuringCopy(url.path), "\(String(describing: thrown))")
        case (.eio, false):
            #expect(thrown == .writeFailed("read errno \(EIO)"))
        case (.shortRead, false), (.bitFlip, false):
            guard case .verifyMismatch(let want, let got)? = thrown else {
                Issue.record("\(c): \(String(describing: thrown))"); return
            }
            #expect(want == expected && got != expected)
        }
        #expect(leftovers(sb).isEmpty, "\(c): left in the archive: \(leftovers(sb))")
        #expect(try Data(contentsOf: url) == data)
    }

    /// Pinned, not parked: with no reference digest a single faulted read is
    /// by construction indistinguishable from the file's own bytes — the copy
    /// pass hashes and writes the SAME buffer, so the read-back agrees. This
    /// is why Promote always reads the source first and passes
    /// `expectedSourceSHA` (GH #190); `PromoteToArchiveJob` has no call
    /// without it (HashReadSeamSensorTests). That protects FRESH COPIES
    /// only: Promote's adoption branch makes no copy and no second source
    /// read (HashReadFaultPromoteTests.aFlippedProvingReadAdoptsAnotherFile, P1).
    @Test("LIMIT: without expectedSourceSHA a bit flipped in the one source read is published as verified — the caller's prior read is the only defence")
    func withoutAReferenceASourceFlipIsInvisible() throws {
        let sb = try sandbox("noref"); defer { sb.cleanup() }
        let (url, data) = try write(sb, "test_noref.bin", bytes: 50_000, seed: 13)
        let rel = "30_Video/Undated/test_noref.bin"
        let fault = HashReadFault(.bitFlip, pathSuffix: "Sources/test_noref.bin", atByte: 1_000)
        let handle = try Engine.openSource(path: url.path); defer { handle.close() }
        let result = try fault.runSync {
            try Engine.copyVerifyPublish(source: handle, root: sb.archiveRoot.path, relativePath: rel)
        }
        #expect(fault.firedCount == 1)
        #expect(result.sha256 != hashSeamReference(data))
        #expect(try Data(contentsOf: sb.archiveRoot.appendingPathComponent(rel)) != data)
    }
}

// MARK: - Sensor

@Suite("Hash read seam — nothing in the app binds the hook (source sensor)")
struct HashReadSeamSensorTests {

    /// 2026-11-21: the two serial hashers outside the engine consult the same
    /// hook (Delete Duplicates' `SignatureVerification.cancellableFullHash`,
    /// `ContentCopyProof.sha256`), and their detached callers carry it by
    /// value. The exact shape of each of those files is pinned by
    /// DedupeHashReadSeamSensorTests; here: the list is closed, and nothing
    /// binds the task-local.
    @Test("the app never BINDS readHook ($readHook appears nowhere), and it is named only in the engine and the four files that consult or carry it")
    func onlyTheEngineNamesTheHook() throws {
        var namers: [String] = []
        #expect(SourceTree.appSources.count > 500, "the sensor read the app tree")
        for entry in SourceTree.appSources {
            let text = try String(contentsOf: entry.url, encoding: .utf8)
            #expect(!text.contains("$readHook"), "\(entry.relative) binds the hash read hook — tests only")
            if text.contains("readHook") { namers.append((entry.relative as NSString).lastPathComponent) }
        }
        #expect(namers.sorted() == ["ArchivePromoteEngine.swift", "ContentCopyProof.swift", "SignatureVerification.swift",
                                    "VideoScanModel+Relocate.swift", "VideoScanModel+TrashSelection.swift"], "\(namers)")
    }

    @Test("in the engine the hook is read once, on the calling task, and handed to the reader thread by value")
    func theEngineReadsItOnce() throws {
        let code = try SourceTree.appCode(named: "ArchivePromoteEngine.swift")
        #expect(code.components(separatedBy: "@TaskLocal static var readHook: ReadHook? = nil").count - 1 == 1)
        #expect(code.components(separatedBy: "ring.startReader(fd: fd, hook: readHook)").count - 1 == 1)
        #expect(code.components(separatedBy: "readHook").count - 1 == 2, "declared once, read once")
        #expect(code.components(separatedBy: "startReader(").count - 1 == 2, "one reader, one start")
    }

    @Test("Promote never copies without the digest it read first (the only defence against a flip in the copy pass; it does not cover adoption)")
    func promoteAlwaysPassesTheExpectedDigest() throws {
        let steps = try SourceTree.appCode(named: "PromoteToArchiveJob+Steps.swift")
        #expect(steps.components(separatedBy: "copyOffMain(").count - 1 == 2, "one definition, one call")
        #expect(steps.contains("expectedSHA: digest,"))
        var callers: [String] = []
        for entry in SourceTree.appSources {
            let text = try String(contentsOf: entry.url, encoding: .utf8)
            if text.contains("copyVerifyPublish(") { callers.append((entry.relative as NSString).lastPathComponent) }
        }
        #expect(callers.sorted() == ["ArchivePromoteEngine.swift", "PromoteToArchiveJob+Steps.swift"], "\(callers)")
    }
}
