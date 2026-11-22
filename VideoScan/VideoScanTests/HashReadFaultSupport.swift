// HashReadFaultSupport.swift
// Test support for the full-file hash READ seam
// (`ArchivePromoteEngine.readHook`, 2026-11-20). One `HashReadFault` plans
// ONE fault — which file, which full read of it, at which byte, what goes
// wrong — and counts how often it fired, so a test can prove the fault
// really reached the read it was aimed at (a matrix cell whose fault never
// fired would pass for the wrong reason).
//
// Nothing here touches a file: the fault lives in the reader thread's
// buffer. Parallel-safe: the hook is task-local, each fault is its own
// object.
//
// (For Rick: ≈ a gmock action on `pread` — "the 2nd time this file is read
// from the top, fail with EIO at byte 20,000" — scoped to one test's task
// tree instead of installed process-wide.)

import Darwin
import Foundation
@testable import VideoScan

/// The hang guard on the fault suites' job-running tests. It is NOT a time
/// budget (no test here asserts on speed): it exists so a test that never
/// finishes is reported instead of stalling the run. Under the lane that
/// runs these suites (`-parallel-testing-enabled YES -test-iterations 5`,
/// every HashRead*/Dedupe* suite in ONE process) all job tests share the
/// main actor, and the last of them legitimately finishes ~120 s after the
/// run starts (measured 2026-11-21 on the M5 Ultra once GH #504's second
/// reads and Codex r1 closure tests landed), while each one alone takes
/// 2–21 s. Two minutes was then measuring the lane, not the test.
enum HashReadFaultLimits {
    static let hangGuardMinutes = 5
}

final class HashReadFault: @unchecked Sendable {

    enum Kind: String, Sendable, CaseIterable, CustomStringConvertible {
        /// read(2) fails with EIO at the byte (the drive fell off the bus).
        case eio
        /// The file "ends" at the byte: the read returns 0 before the size
        /// fstat promised (a truncating transport, a file cut under the read).
        case shortRead
        /// One bit of the byte reads back inverted; the file is untouched.
        case bitFlip
        var description: String { rawValue }
    }

    let kind: Kind
    let atByte: Int64
    /// 1-based: which full read (a read that starts at offset 0) of the
    /// matching file gets the fault. 0 = every read of it.
    let onPass: Int
    private let matches: @Sendable (String) -> Bool
    private let lock = NSLock()
    private var passes = 0
    private var fired = 0
    private var chunks = 0

    /// `pathSuffix` is compared against the descriptor's real path
    /// (F_GETPATH — "/private/var/…"), so give a tail: a filename, or
    /// "copies/a.mov" to tell two files with one name apart.
    init(_ kind: Kind, pathSuffix: String, atByte: Int64, onPass: Int = 1) {
        self.kind = kind
        self.atByte = atByte
        self.onPass = onPass
        self.matches = { $0.hasSuffix(pathSuffix) }
    }

    init(_ kind: Kind, where matches: @escaping @Sendable (String) -> Bool, atByte: Int64, onPass: Int = 1) {
        self.kind = kind
        self.atByte = atByte
        self.onPass = onPass
        self.matches = matches
    }

    /// How many times the fault itself was delivered.
    var firedCount: Int { lock.withLock { fired } }
    /// How many full reads of the matching file started.
    var passCount: Int { lock.withLock { passes } }
    /// How many chunks of the matching file the reader offered the hook.
    var chunkCount: Int { lock.withLock { chunks } }

    static func path(of fd: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) == 0 else { return nil }
        // Up to the first NUL, decoded as UTF-8 (String(cString:) on an array is deprecated).
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The hook to bind. Runs on the engine's reader thread.
    var hook: ArchivePromoteEngine.ReadHook {
        { [self] fd, offset, count in decide(fd: fd, offset: offset, count: count) }
    }

    private func decide(fd: Int32, offset: Int64, count: Int) -> ArchivePromoteEngine.ReadFault? {
        guard let path = Self.path(of: fd), matches(path) else { return nil }
        return lock.withLock {
            chunks += 1
            if offset == 0 { passes += 1 }
            guard onPass == 0 || passes == onPass else { return nil }
            guard atByte >= offset, atByte < offset + Int64(count) else { return nil }
            let inChunk = Int(atByte - offset)
            switch kind {
            case .bitFlip:
                fired += 1
                return .flip(byteInChunk: inChunk)
            case .eio:
                // Deliver the bytes before `atByte` first (an ordinary partial
                // read); the reader's next read starts exactly at `atByte`.
                guard inChunk == 0 else { return .shortRead(bytes: inChunk) }
                fired += 1
                return .errno(EIO)
            case .shortRead:
                guard inChunk == 0 else { return .shortRead(bytes: inChunk) }
                fired += 1
                return .shortRead(bytes: 0)
            }
        }
    }

    /// Run `body` with this fault bound for its task tree.
    /// No `isolation:` parameter: this target builds with nonisolated(nonsending) by default, so a
    /// plain `async` function already runs on its caller's actor, and `withValue` resolves to the
    /// current overload (the isolation-taking one is deprecated: warning ratchet, 2026-11-20).
    func run<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        try await ArchivePromoteEngine.$readHook.withValue(hook) { try await body() }
    }

    func runSync<T>(_ body: () throws -> T) rethrows -> T {
        try ArchivePromoteEngine.$readHook.withValue(hook) { try body() }
    }
}

/// A hook that changes nothing and records every chunk it was offered —
/// the proof that a bound-but-silent hook reads the same bytes in the same
/// order.
final class HashReadObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(offset: Int64, count: Int)] = []
    var chunks: [(offset: Int64, count: Int)] { lock.withLock { seen } }
    var hook: ArchivePromoteEngine.ReadHook {
        { [self] _, offset, count in
            lock.withLock { seen.append((offset, count)) }
            return nil
        }
    }
}

/// The model's console text once it holds `needle` (the console is flushed
/// on a 0.15 s debounce) — or whatever it holds after `timeoutMs`.
@MainActor
func hashFaultConsole(_ model: VideoScanModel, containing needle: String, timeoutMs: Int = 3_000) async -> String {
    var waited = 0
    while true {
        let text = model.dashboard.consoleLines.joined(separator: "\n")
        if text.contains(needle) || waited >= timeoutMs { return text }
        try? await Task.sleep(for: .milliseconds(25))
        waited += 25
    }
}
