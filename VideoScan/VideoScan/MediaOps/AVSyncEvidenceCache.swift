// AVSyncEvidenceCache.swift
// ONE SENTENCE: keep each file's A/V sync signals for the app session, so one
// original compared against several processed versions is read once.
//
// Design: docs/design/av_sync_analysis.md §6 (Rick 2026-11-28: "1 and 2").
// The signals are small (≈ 17 MB per 2 hours of footage); reading them costs a
// full decode of the file (≈ 50 s for a 47-minute 30 GB ProRes file, drive-
// bound). A key names the CONTENT and the moment it was read: the whole-file
// SHA-256, the size and modification date seen just before the read, and the
// reader's identity (grid, thumbnail, signal version). A file whose size or
// date has changed is a different key — a miss, never a stale hit. Entries go
// in only after the job's after-read stat check passed.
//
// Owned by the MFO Center (one per app session; each test's Center has its
// own). In memory only, bounded by bytes, least recently used out first. Keeping
// signals across relaunches rides with the A/V sync results table (approved
// 2026-11-28, not yet built).
//
// (For Rick: a `final class` with an NSLock ≈ a C++ class whose every member
// function takes a std::mutex; `@unchecked Sendable` is our promise to the
// compiler that the lock makes it thread-safe.)

import Foundation
import VideoScanCore

final class AVSyncEvidenceCache: @unchecked Sendable {

    struct Key: Hashable, Sendable {
        let digest: String
        let size: Int64
        let modified: Date
        let readerIdentity: String
    }

    /// 512 MB ≈ 60 hours of footage's signals.
    static let defaultByteLimit = 512 * 1024 * 1024

    let byteLimit: Int
    private let lock = NSLock()
    private var entries: [Key: (evidence: AVSyncFileEvidence, bytes: Int, lastUse: UInt64)] = [:]
    private var clock: UInt64 = 0
    private var total = 0

    init(byteLimit: Int = AVSyncEvidenceCache.defaultByteLimit) {
        self.byteLimit = byteLimit
    }

    func evidence(for key: Key) -> AVSyncFileEvidence? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        clock += 1
        entry.lastUse = clock
        entries[key] = entry
        return entry.evidence
    }

    /// Keep `evidence` under `key`, evicting the least recently used entries
    /// until the total fits. An entry larger than the whole limit is not kept.
    func insert(_ evidence: AVSyncFileEvidence, for key: Key) {
        let bytes = Self.bytes(of: evidence)
        lock.lock(); defer { lock.unlock() }
        guard bytes <= byteLimit else { return }
        if let old = entries.removeValue(forKey: key) { total -= old.bytes }
        while total + bytes > byteLimit,
              let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            total -= oldest.value.bytes
            entries.removeValue(forKey: oldest.key)
        }
        clock += 1
        entries[key] = (evidence, bytes, clock)
        total += bytes
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return entries.isEmpty }
    var totalBytes: Int { lock.lock(); defer { lock.unlock() }; return total }

    /// The arrays' payload (the fixed-size fields are noise beside them).
    static func bytes(of evidence: AVSyncFileEvidence) -> Int {
        let s = evidence.signals, f = evidence.fingerprint
        return (s.onset.count + s.motion.count) * MemoryLayout<Float>.stride
            + s.cuts.count * MemoryLayout<Double>.stride
            + (f.hashes.count + f.times.count) * MemoryLayout<UInt32>.stride
            + f.activeSeconds.count
    }
}
