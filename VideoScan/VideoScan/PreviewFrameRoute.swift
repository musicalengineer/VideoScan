// PreviewFrameRoute.swift
// The negative cache for preview generation. The pure route decision
// (PreviewRoute / PreviewFrameRouter) moved to VideoScanCore
// (PreviewFrameRoute.swift there) so the app AND the planned
// out-of-process helper share ONE copy of the AVFoundation-vs-ffmpeg
// rules — see that file's header. This file keeps ThumbnailFailureStore,
// which is app-only state (not part of the route decision).
//
// The I/O side (the actual AVFoundation / ffmpeg frame rips) stays in
// VideoScanModel+Thumbnail.swift.

import Foundation

// MARK: - Negative cache

/// Remembers files that FAILED preview generation so neither the
/// interactive path nor the precacher pays the (deadline-bounded but
/// still seconds-long) failure cost twice. Keyed by fullPath; an entry
/// only suppresses retries while the file's (mtime, size) still match —
/// a repaired/replaced file retries automatically on next selection.
///
/// Thread-safety: lock-guarded `@unchecked Sendable` (the repo's "tiny
/// box" convention — see ProcessRunner.DeadlineFlag) rather than
/// @MainActor, because the precacher consults it from a detached task
/// and the stat() belongs OFF the main thread at prewarm scale.
/// For Rick: a mutex-guarded map + FIFO eviction queue.
///
/// Memory contract: capped at `maxEntries` (10 000), drop-oldest. Worst
/// case ≈ 10 000 × (path string ~200 B + 16 B of stat) ≈ 2–3 MB — noise
/// next to the 8 GB thumbnail cache, and bounded for arbitrarily long
/// sessions.
final class ThumbnailFailureStore: @unchecked Sendable {

    /// What we remember about the file at failure time. mtime is stored
    /// as seconds-since-1970; zeros mean "stat itself failed" (e.g. the
    /// file vanished mid-generation) — such an entry matches only while
    /// stat KEEPS failing, so the file reappearing triggers a retry.
    private struct Signature: Equatable {
        var mtime: TimeInterval
        var fileSize: Int64
    }

    /// FIFO-eviction bound. 10k failures is far beyond any plausible
    /// session (the whole catalog is ~20k records); the cap exists so
    /// the store CANNOT grow unbounded, per the memory discipline rule.
    static let maxEntries = 10_000

    private let lock = NSLock()
    private var entries: [String: Signature] = [:]
    /// Insertion order for drop-oldest eviction. Append-only alongside
    /// `entries`; a re-recorded path is NOT re-appended (its slot in the
    /// eviction order is good enough — exactness isn't worth the churn).
    private var insertionOrder: [String] = []

    /// Current on-disk signature, or zeros when the file can't be
    /// statted. Does file I/O — call off the main thread where possible
    /// (the precacher does; the interactive path pays one stat per
    /// selection, which is microseconds on a mounted volume and already
    /// gated behind VolumeReachability).
    private func currentSignature(forPath path: String) -> Signature {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return Signature(mtime: 0, fileSize: 0)
        }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return Signature(mtime: mtime, fileSize: size)
    }

    /// Record a generation failure for `path`. Stats the file so the
    /// entry self-invalidates if the file is later repaired/replaced.
    func recordFailure(forPath path: String) {
        let sig = currentSignature(forPath: path)
        lock.lock()
        defer { lock.unlock() }
        if entries[path] == nil {
            insertionOrder.append(path)
            // Drop-oldest past the cap. removeFirst on a 10k array is a
            // memmove — rare (only at cap) and cheap at this size.
            while insertionOrder.count > Self.maxEntries {
                entries.removeValue(forKey: insertionOrder.removeFirst())
            }
        }
        entries[path] = sig
    }

    /// True when `path` previously failed AND the file is unchanged on
    /// disk (mtime + size match). A changed/repaired file clears its own
    /// entry here and returns false so the caller retries normally.
    func isKnownFailure(atPath path: String) -> Bool {
        lock.lock()
        let recorded = entries[path]
        lock.unlock()
        guard let recorded else { return false }

        // Stat OUTSIDE the lock — file I/O must never serialize other
        // callers behind a slow volume.
        let current = currentSignature(forPath: path)
        if current == recorded { return true }

        // File changed since the failure — forget it so this attempt
        // (and future ones) proceed. The stale insertionOrder slot is
        // harmless: eviction just skips the missing key.
        lock.lock()
        entries.removeValue(forKey: path)
        lock.unlock()
        return false
    }

    /// Entry count, for tests/diagnostics.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
