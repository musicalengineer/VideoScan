// DedupeHashReadSeamTests.swift
// The READ seam of the two serial full-file hashers (2026-11-21), at the
// hashers themselves:
//   * `SignatureVerification.cancellableFullHash` — every full read Delete
//     Duplicates makes (keeper, duplicate, quarantine re-read, sibling). It is
//     private; `wholeFileFixity` is its thinnest public wrapper and is what
//     these tests call.
//   * `ContentCopyProof.sha256(path:expectedBytes:)` — the fresh hash behind
//     Relocate's adoption proof and the Trash "only copy" guard.
// Both now consult `ArchivePromoteEngine.readHook` (the hook the archive
// hashers already consult) once per block. Nothing else changed.
//
//   UNCHANGED — hook nil ⇒ the reference digest at every block-boundary
//               size; a bound-but-silent hook is offered every block once, in
//               file order, at the hasher's own block size (1 MiB), and the
//               digest, the block count and the number of cancellation polls
//               are the same as with no hook.
//   TIME      — the nil-hook hash of 64 MiB against a plain serial
//               read + SHA-256 loop in this file.
//   LOGIC     — outcome per hasher (✔ = what a hash that proves must do):
//
//       fault            cancellableFullHash          ContentCopyProof.sha256
//       EIO mid-file     no digest (.unreadable) ✔    nil ✔
//       premature EOF    no digest (.unreadable) ✔    nil ✔
//                        (NOT a prefix digest — both compare the bytes
//                         consumed with the size; the archive engine's
//                         sha256(fd:) does not, GH #504 root cause A)
//       partial read     the file's digest ✔          the file's digest ✔
//       bit flip         the digest of the FLIPPED    the digest of the
//                        bytes, bound to the file's   FLIPPED bytes
//                        stamp as its fixity          (one read is taken as
//                        (GH #504 root cause B)        truth, root cause B)
//
//       Codex shape A (keeper's bytes + a tail, the read ends at the
//       keeper's length): no digest from either hasher ✔.
//   ISOLATION — task-local: a sibling task hashing the same file at the same
//               moment gets the true digest; a detached task does not inherit
//               the hook, and `Hooks.carryingReadHook()` is what carries it
//               (and is the identity when nothing is bound).
//   SENSOR    — DedupeHashReadSeamSensorTests (below).
//
// Parallel-safe: temp folders, task-local hook, no shared state.

import CryptoKit
import Darwin
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// Counts the gate's own callbacks (blocks read, cancellation polls).
private final class GateCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks = 0
    private var polls = 0
    var blockCount: Int { lock.withLock { blocks } }
    var pollCount: Int { lock.withLock { polls } }
    var hooks: SignatureVerification.Hooks {
        SignatureVerification.Hooks(
            shouldCancel: { [self] in lock.withLock { polls += 1 }; return false },
            didReadBlock: { [self] _ in lock.withLock { blocks += 1 } })
    }
}

@Suite("Dedupe hash read seam — the two serial hashers under an injected read fault")
struct DedupeHashReadSeamTests {

    static let block = FileHasher.segmentSize          // cancellableFullHash's block
    static let proofBlock = 1 << 20                    // ContentCopyProof.sha256's read

    private func file(_ dir: URL, _ name: String, bytes: Int, seed: UInt64) throws -> (URL, Data) {
        let data = hashSeamBlob(bytes: bytes, seed: seed)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return (url, data)
    }

    /// The Delete Duplicates hasher's answer for one file.
    private func gateDigest(_ url: URL, hooks: SignatureVerification.Hooks = .live) -> String? {
        if case .fixity(let f) = SignatureVerification.wholeFileFixity(path: url.path, label: "sibling", hooks: hooks) {
            return f.digest
        }
        return nil
    }

    // MARK: Unchanged

    @Test("UNCHANGED: hook nil ⇒ the reference digest from both hashers; a silent hook is offered every block once, in order, at the hasher's own block size; same digest, same block count, same cancellation polls",
          arguments: [1, 4_097, (1 << 20) - 1, 1 << 20, (1 << 20) + 1, 3 * (1 << 20) + 17])
    func hookNilIsTheReferenceDigest(_ size: Int) throws {
        let dir = dedupeSeamTempDir("same"); defer { try? FileManager.default.removeItem(at: dir) }
        let (url, data) = try file(dir, "test_same_\(size).bin", bytes: size, seed: UInt64(size))
        let expected = hashSeamReference(data)
        #expect(Self.block == 1 << 20, "the block size the seam tests assume")

        // cancellableFullHash
        let plain = GateCounter()
        #expect(gateDigest(url, hooks: plain.hooks) == expected)
        let observer = HashReadObserver()
        let observed = GateCounter()
        let digest = ArchivePromoteEngine.$readHook.withValue(observer.hook) { gateDigest(url, hooks: observed.hooks) }
        #expect(digest == expected)
        var offset: Int64 = 0
        for chunk in observer.chunks {
            #expect(chunk.offset == offset && chunk.count > 0 && chunk.count <= Self.block)
            offset += Int64(chunk.count)
        }
        #expect(offset == Int64(size) && observer.chunks.count == (size + Self.block - 1) / Self.block)
        #expect(observed.blockCount == plain.blockCount && observed.blockCount == observer.chunks.count)
        #expect(observed.pollCount == plain.pollCount, "the hook adds or removes no cancellation point")

        // ContentCopyProof.sha256
        #expect(ContentCopyProof.sha256(path: url.path, expectedBytes: Int64(size)) == expected)
        let proofObserver = HashReadObserver()
        #expect(ContentCopyProof.sha256(path: url.path, expectedBytes: Int64(size), readHook: proofObserver.hook) == expected)
        offset = 0
        for chunk in proofObserver.chunks {
            #expect(chunk.offset == offset && chunk.count > 0 && chunk.count <= Self.proofBlock)
            offset += Int64(chunk.count)
        }
        #expect(offset == Int64(size) && proofObserver.chunks.count == (size + Self.proofBlock - 1) / Self.proofBlock)
        #expect(ContentCopyProof.sha256(path: url.path, expectedBytes: Int64(size) + 1) == nil, "a wrong expected size is still nil")
    }

    @Test("TIME: the nil-hook hash of 64 MiB by each hasher is in the same range as a plain serial read + SHA-256 loop (best of 3, wide margin)")
    func nilHookTimeIsComparable() throws {
        let dir = dedupeSeamTempDir("time"); defer { try? FileManager.default.removeItem(at: dir) }
        let size = 64 << 20
        let (url, data) = try file(dir, "test_time.bin", bytes: size, seed: 99)
        let expected = hashSeamReference(data)

        /// The hashers' own shape before the seam: read(2) 1 MiB at a time, hash.
        func serial() throws -> String {
            let fd = open(url.path, O_RDONLY)
            try #require(fd >= 0)
            defer { close(fd) }
            let buf = UnsafeMutableRawPointer.allocate(byteCount: Self.block, alignment: 16)
            defer { buf.deallocate() }
            var hasher = SHA256()
            while true {
                let n = read(fd, buf, Self.block)
                if n <= 0 { break }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        func best(_ body: () throws -> String) rethrows -> Duration {
            var least = Duration.seconds(3600)
            for _ in 0..<3 {
                var digest = ""
                let took = try ContinuousClock().measure { digest = try body() }
                #expect(digest == expected)
                least = min(least, took)
            }
            return least
        }
        let reference = try best(serial)
        let gate = best { gateDigest(url) ?? "" }
        let proof = best { ContentCopyProof.sha256(path: url.path, expectedBytes: Int64(size)) ?? "" }
        let observer = HashReadObserver()
        let gateHooked = best { ArchivePromoteEngine.$readHook.withValue(observer.hook) { gateDigest(url) ?? "" } }
        print("[dedupe-seam] 64 MiB: serial reference \(reference), cancellableFullHash hook nil \(gate), silent hook \(gateHooked), ContentCopyProof.sha256 hook nil \(proof)")
        // A guard against a per-byte cost sneaking into the loops, not a benchmark.
        #expect(gate <= reference * 3 + .milliseconds(500), "hook nil: \(gate) vs serial \(reference)")
        #expect(gateHooked <= reference * 3 + .milliseconds(500), "silent hook: \(gateHooked) vs serial \(reference)")
        #expect(proof <= reference * 3 + .milliseconds(500), "ContentCopyProof hook nil: \(proof) vs serial \(reference)")
    }

    // MARK: Each fault, at each hasher

    @Test("LOGIC: EIO and a premature EOF yield NO digest from either hasher; a partial read yields the file's digest; a flipped bit yields the digest of the flipped bytes; the file is untouched",
          arguments: DedupeFaultKind.allCases)
    func eachFaultAtEachHasher(_ kind: DedupeFaultKind) throws {
        let dir = dedupeSeamTempDir("logic_\(kind)"); defer { try? FileManager.default.removeItem(at: dir) }
        let size = 2 * Self.block + 40_000
        let (url, data) = try file(dir, "test_logic.bin", bytes: size, seed: 7)
        let expected = hashSeamReference(data)
        let at = Int64(Self.block + 12_345)
        var flipped = data
        flipped[Int(at)] ^= 0x01
        let flippedDigest = hashSeamReference(flipped)

        // --- cancellableFullHash, hook on the task.
        let gateFault = DedupeReadFault(kind, pathSuffix: "test_logic.bin", atByte: at)
        let outcome = gateFault.runSync { SignatureVerification.wholeFileFixity(path: url.path, label: "sibling") }
        #expect(gateFault.firedCount == 1, "\(kind): the fault never reached cancellableFullHash")
        // --- the same through `Hooks.readHook` (how a detached worker gets it).
        let carried = DedupeReadFault(kind, pathSuffix: "test_logic.bin", atByte: at)
        var hooks = SignatureVerification.Hooks.live
        hooks.readHook = carried.hook
        let carriedOutcome = SignatureVerification.wholeFileFixity(path: url.path, label: "sibling", hooks: hooks)
        #expect(carried.firedCount == 1, "\(kind): the fault never reached cancellableFullHash through Hooks.readHook")
        // --- ContentCopyProof.sha256
        let proofFault = DedupeReadFault(kind, pathSuffix: "test_logic.bin", atByte: at)
        let proofDigest = proofFault.runSync { ContentCopyProof.sha256(path: url.path, expectedBytes: Int64(size)) }
        #expect(proofFault.firedCount == 1, "\(kind): the fault never reached ContentCopyProof.sha256")
        print("[hash-matrix] hasher | \(kind) | cancellableFullHash \(outcome) | ContentCopyProof.sha256 \(proofDigest ?? "nil")")

        for o in [outcome, carriedOutcome] {
            switch kind {
            case .eio, .prematureEOF:
                #expect(o == .unreadable, "\(kind): \(o)")
            case .partialRead:
                if case .fixity(let f) = o { #expect(f.digest == expected) } else { Issue.record("\(kind): \(o)") }
            case .bitFlip:
                // One read, nothing to compare it with: the flipped digest IS
                // returned as this file's fixity (root cause B). What each
                // caller does with it is pinned in the matrix suites.
                if case .fixity(let f) = o {
                    #expect(f.digest == flippedDigest && f.digest != expected)
                } else { Issue.record("\(kind): \(o)") }
            }
        }
        switch kind {
        case .eio, .prematureEOF: #expect(proofDigest == nil)
        case .partialRead: #expect(proofDigest == expected)
        case .bitFlip: #expect(proofDigest == flippedDigest)
        }
        #expect(try Data(contentsOf: url) == data, "the fault lives in the read buffer, never in the file")
        // The same calls, clean.
        #expect(gateDigest(url) == expected)
        #expect(ContentCopyProof.sha256(path: url.path, expectedBytes: Int64(size)) == expected)
    }

    @Test("Codex shape A at the hashers: the keeper's bytes + a unique tail, the read ends at the keeper's length → NO digest from either hasher (never the keeper's prefix digest)")
    func aPrefixReadIsNeverADigest() throws {
        let dir = dedupeSeamTempDir("prefix"); defer { try? FileManager.default.removeItem(at: dir) }
        let keeperSize = Self.block + 5_000
        let keeper = hashSeamBlob(bytes: keeperSize, seed: 11)
        let longer = keeper + hashSeamBlob(bytes: 70_000, seed: 12)
        let url = dir.appendingPathComponent("test_longer.bin")
        try longer.write(to: url)
        let keeperDigest = hashSeamReference(keeper)

        let gateFault = DedupeReadFault(.prematureEOF, pathSuffix: "test_longer.bin", atByte: Int64(keeperSize))
        let outcome = gateFault.runSync { SignatureVerification.wholeFileFixity(path: url.path, label: "duplicate") }
        #expect(gateFault.firedCount == 1)
        #expect(outcome == .unreadable, "\(outcome)")
        if case .fixity(let f) = outcome { #expect(f.digest != keeperDigest, "a PREFIX digest equal to the keeper's") }

        let proofFault = DedupeReadFault(.prematureEOF, pathSuffix: "test_longer.bin", atByte: Int64(keeperSize))
        let digest = proofFault.runSync { ContentCopyProof.sha256(path: url.path, expectedBytes: Int64(longer.count)) }
        #expect(proofFault.firedCount == 1)
        #expect(digest == nil)
        // Asked for the KEEPER's size, the longer file is refused before any read.
        #expect(ContentCopyProof.sha256(path: url.path, expectedBytes: Int64(keeperSize)) == nil)
    }

    // MARK: Isolation

    @Test("ISOLATION: the hook is task-local — a sibling task hashing the same file at the same moment gets the true digest; a detached task does not inherit it; carryingReadHook() carries it, and is the identity when nothing is bound")
    func theHookIsTaskLocal() async throws {
        let dir = dedupeSeamTempDir("iso"); defer { try? FileManager.default.removeItem(at: dir) }
        let size = 2 * Self.block
        let (url, data) = try file(dir, "test_iso.bin", bytes: size, seed: 21)
        let expected = hashSeamReference(data)
        let path = url.path
        let fault = DedupeReadFault(.eio, pathSuffix: "test_iso.bin", atByte: 5_000, onPass: 0)

        // Nothing bound: the carrier is the identity.
        #expect(SignatureVerification.Hooks.live.carryingReadHook().readHook == nil)

        async let clean: String? = Task.detached {
            ContentCopyProof.sha256(path: path, expectedBytes: Int64(size))
        }.value
        let (faulted, detachedDigest, carriedOutcome) = await fault.run { () -> (String?, String?, SignatureVerification.WholeFileFixity) in
            let faulted = ContentCopyProof.sha256(path: path, expectedBytes: Int64(size))
            // A detached task inherits no task-locals: clean.
            let detached = await Task.detached { ContentCopyProof.sha256(path: path, expectedBytes: Int64(size)) }.value
            // …unless the hooks carry it by value, as the job's workers do.
            let hooks = SignatureVerification.Hooks.live.carryingReadHook()
            let carried = await Task.detached {
                SignatureVerification.wholeFileFixity(path: path, label: "duplicate", hooks: hooks)
            }.value
            return (faulted, detached, carried)
        }
        #expect(faulted == nil && fault.firedCount == 2)
        #expect(detachedDigest == expected, "a detached task saw the hook")
        #expect(carriedOutcome == .unreadable, "the carried hook did not reach the detached worker: \(carriedOutcome)")
        #expect(await clean == expected, "a sibling task was touched by another task's fault")
        #expect(try Data(contentsOf: url) == data)
    }
}

// MARK: - Sensor

@Suite("Dedupe hash read seam — the consult is the only change, and nothing in the app can bind it (source sensor)")
struct DedupeHashReadSeamSensorTests {

    private func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    @Test("every place the app ASSIGNS a readHook takes it from the task-local itself: nothing in the app can make a hook")
    func everyAssignmentIsTheTaskLocal() throws {
        let allowed: Set<String> = [
            "let readHook = hooks.readHook ?? ArchivePromoteEngine.readHook",   // cancellableFullHash
            "copy.readHook = bound",                                            // carryingReadHook()
            "let readHook = ArchivePromoteEngine.readHook",                     // Relocate ×2
            "private let readHook = ArchivePromoteEngine.readHook",             // CatalogTrashMoveProofs
        ]
        var seen: [String: Int] = [:]
        #expect(SourceTree.appSources.count > 500, "the sensor read the app tree")
        for entry in SourceTree.appSources {
            let text = try String(contentsOf: entry.url, encoding: .utf8)
            #expect(!text.contains("$readHook"), "\(entry.relative) binds the hash read hook — tests only")
            for line in text.components(separatedBy: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), code.contains("readHook = ") || code.contains("readHook: {") else { continue }
                #expect(allowed.contains(code), "\(entry.relative): `\(code)` — a read hook made or assigned outside the seam")
                seen[code, default: 0] += 1
            }
        }
        #expect(seen["let readHook = hooks.readHook ?? ArchivePromoteEngine.readHook"] == 1)
        #expect(seen["copy.readHook = bound"] == 1)
        #expect(seen["let readHook = ArchivePromoteEngine.readHook"] == 2)
        #expect(seen["private let readHook = ArchivePromoteEngine.readHook"] == 1)
    }

    @Test("SignatureVerification: one consult, guarded by the hook, in the one full-file read loop; the block size and the loop's cancellation poll are as they were")
    func theGateConsultsOnce() throws {
        let code = try SourceTree.appCode(named: "SignatureVerification.swift")
        #expect(count("applyReadFault(", in: code) == 1)
        #expect(code.contains("var count = read(fd, buffer, blockSize)"))
        #expect(count("if let readHook, count > 0 {", in: code) == 1)
        #expect(code.contains("blockSize: Int = FileHasher.segmentSize"))
        #expect(code.contains("guard !hooks.shouldCancel() else { return \"\" }"))
        #expect(code.contains("guard !hooks.shouldCancel(), total == expectedSize else { return \"\" }"),
                "bytes consumed are still compared with the size (a short read is never a digest)")
        #expect(code.contains("guard readHook == nil, let bound = ArchivePromoteEngine.readHook else { return self }"),
                "the carrier is the identity when nothing is bound")
        #expect(code.contains("static let live = Hooks(shouldCancel: { Task.isCancelled })"), ".live carries no read hook")
        #expect(count("private static func cancellableFullHash(", in: code) == 1, "still one hasher, still private")
    }

    @Test("ContentCopyProof: one consult, guarded by the hook; 1 MiB reads and the size check are as they were")
    func theProofConsultsOnce() throws {
        let code = try SourceTree.appCode(named: "ContentCopyProof.swift")
        #expect(count("applyReadFault(", in: code) == 1)
        #expect(count("if let readHook, !chunk.isEmpty {", in: code) == 1)
        #expect(code.contains("try handle.read(upToCount: 1 << 20)"))
        #expect(code.contains("guard total == expectedBytes else { return nil }"))
        #expect(count("readHook: ArchivePromoteEngine.ReadHook? = ArchivePromoteEngine.readHook", in: code) == 3,
                "sha256, holdsNow and proven default to the calling task's hook")
    }

    @Test("the engine's shared applier is called from the two serial hashers only; the job's two hashing workers carry the hook by value; the detached proof callers pass it in")
    func theCarriersAreInPlace() throws {
        var callers: [String] = []
        for entry in SourceTree.appSources {
            let text = try String(contentsOf: entry.url, encoding: .utf8)
            if text.contains("applyReadFault(") { callers.append((entry.relative as NSString).lastPathComponent) }
        }
        #expect(callers.sorted() == ["ArchivePromoteEngine.swift", "ContentCopyProof.swift", "SignatureVerification.swift"], "\(callers)")
        let job = try SourceTree.appCode(named: "DeleteDuplicatesJob.swift")
        #expect(count("[hooks = hooks.carryingReadHook()] in", in: job) == 2)
        #expect(count("{ [hooks] in", in: job) == 0, "a hashing worker that does not carry the hook is out of the tests' reach")
        let relocate = try SourceTree.appCode(named: "VideoScanModel+Relocate.swift")
        #expect(count("ContentCopyProof.proven(source: $1.source, copies: $1.copies, readHook: readHook)", in: relocate) == 2)
        let trash = try SourceTree.appCode(named: "VideoScanModel+TrashSelection.swift")
        #expect(count("ContentCopyProof.proven(source: source, copies: staying, readHook: readHook)", in: trash) == 1)
        // Every caller of the proof, app-wide, is one of those three.
        var provers = 0
        for entry in SourceTree.appSources {
            let text = try String(contentsOf: entry.url, encoding: .utf8)
            provers += count("ContentCopyProof.proven(", in: text)
        }
        #expect(provers == 3, "a new ContentCopyProof.proven caller: does it hop to Task.detached? then it must pass readHook")
    }
}
