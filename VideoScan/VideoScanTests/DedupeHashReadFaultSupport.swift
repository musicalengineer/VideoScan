// DedupeHashReadFaultSupport.swift
// Test support for the read seam of the two SERIAL full-file hashers
// (2026-11-21): `SignatureVerification.cancellableFullHash` (Delete
// Duplicates) and `ContentCopyProof.sha256` (Relocate's adoption proof, the
// Trash "only copy" guard). They consult the SAME task-local hook as the
// archive hashers (`ArchivePromoteEngine.readHook`), so the planner is the
// same one — `HashReadFault` (HashReadFaultSupport.swift) — plus the fourth
// fault this matrix names separately: an ordinary PARTIAL read (fewer bytes
// than asked, more to come), which must change nothing.
//
// One `DedupeReadFault` plans ONE fault and counts how often it fired, so a
// matrix cell whose fault never reached its read fails instead of passing
// for the wrong reason.
//
// (For Rick: ≈ a gmock action on read(2), scoped to one test's task tree.)

import Darwin
import Foundation
@testable import VideoScan

enum DedupeFaultKind: String, Sendable, CaseIterable, CustomStringConvertible {
    /// read(2) fails with EIO mid-file.
    case eio
    /// The file "ends" before the size fstat promised.
    case prematureEOF
    /// One read returns fewer bytes than asked; the next read carries on.
    case partialRead
    /// One bit reads back inverted; the file is untouched.
    case bitFlip
    var description: String { rawValue }

    /// The three faults that leave a read UNPROVEN (a partial read is not one).
    static let unproving: [DedupeFaultKind] = [.eio, .prematureEOF, .bitFlip]
}

final class DedupeReadFault: @unchecked Sendable {
    let kind: DedupeFaultKind
    let atByte: Int64
    /// 1-based: which full read (one that starts at offset 0) of the matching
    /// file gets the fault. 0 = every read of it.
    let onPass: Int
    private let inner: HashReadFault?
    private let matches: @Sendable (String) -> Bool
    private let lock = NSLock()
    private var passes = 0
    private var fired = 0
    private var firedThisPass = false

    /// `matches` is asked with the descriptor's REAL path (F_GETPATH).
    init(_ kind: DedupeFaultKind, where matches: @escaping @Sendable (String) -> Bool, atByte: Int64, onPass: Int = 1) {
        self.kind = kind
        self.atByte = atByte
        self.onPass = onPass
        self.matches = matches
        switch kind {
        case .eio: inner = HashReadFault(.eio, where: matches, atByte: atByte, onPass: onPass)
        case .prematureEOF: inner = HashReadFault(.shortRead, where: matches, atByte: atByte, onPass: onPass)
        case .bitFlip: inner = HashReadFault(.bitFlip, where: matches, atByte: atByte, onPass: onPass)
        case .partialRead: inner = nil
        }
    }

    convenience init(_ kind: DedupeFaultKind, pathSuffix: String, atByte: Int64, onPass: Int = 1) {
        self.init(kind, where: { $0.hasSuffix(pathSuffix) }, atByte: atByte, onPass: onPass)
    }

    /// How many times the fault itself was delivered.
    var firedCount: Int { inner?.firedCount ?? lock.withLock { fired } }
    /// How many full reads of the matching file started (through the seam).
    var passCount: Int { inner?.passCount ?? lock.withLock { passes } }

    var hook: ArchivePromoteEngine.ReadHook {
        if let inner { return inner.hook }
        return { [self] fd, offset, count in partial(fd: fd, offset: offset, count: count) }
    }

    /// The block holding `atByte` is cut at `atByte` (once per planned pass);
    /// the reader's next read starts exactly there.
    private func partial(fd: Int32, offset: Int64, count: Int) -> ArchivePromoteEngine.ReadFault? {
        guard let path = HashReadFault.path(of: fd), matches(path) else { return nil }
        return lock.withLock {
            if offset == 0 { passes += 1; firedThisPass = false }
            guard onPass == 0 || passes == onPass, !firedThisPass else { return nil }
            guard atByte > offset, atByte < offset + Int64(count) else { return nil }
            firedThisPass = true
            fired += 1
            return .shortRead(bytes: Int(atByte - offset))
        }
    }

    /// Run `body` with this fault bound for its task tree.
    func run<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        try await ArchivePromoteEngine.$readHook.withValue(hook) { try await body() }
    }

    func runSync<T>(_ body: () throws -> T) rethrows -> T {
        try ArchivePromoteEngine.$readHook.withValue(hook) { try body() }
    }
}

/// Counts the full reads (through the seam) of the files a predicate names,
/// and changes nothing — "was this file read at all?".
final class DedupeReadCounter: @unchecked Sendable {
    private let matches: @Sendable (String) -> Bool
    private let lock = NSLock()
    private var passes = 0
    init(where matches: @escaping @Sendable (String) -> Bool) { self.matches = matches }
    var passCount: Int { lock.withLock { passes } }
    var hook: ArchivePromoteEngine.ReadHook {
        { [self] fd, offset, _ in
            if offset == 0, let path = HashReadFault.path(of: fd), matches(path) { lock.withLock { passes += 1 } }
            return nil
        }
    }
}

func dedupeSeamTempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_dedupeseam_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
