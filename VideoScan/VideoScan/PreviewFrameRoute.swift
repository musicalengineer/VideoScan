// PreviewFrameRoute.swift
// Catalog preview perf fix (2026-07-26): route single-frame preview
// generation to the right decoder BEFORE any media object is created.
//
// The bug this kills: renderThumbnailCGImage was AVFoundation-only.
// AVFoundation has zero Matroska/FFV1 support, and its container
// sniffing can scan huge portions of a 20 GB digitized-tape master
// before giving up — the catalog preview pane stalled 30 s to over a
// minute per FFV1/MKV selection, then showed a spinner forever.
//
// The catalog record already knows the answer: `container` and
// `videoCodec` are ffprobe-stamped at scan time. So the route decision
// is a PURE function of cataloged metadata — same design as
// MediaOpener's QuickTime-vs-VLC decision (zero runtime probing,
// unit-testable without media files).
//
// Two pieces live here:
//   - PreviewFrameRouter — the pure route decision.
//   - ThumbnailFailureStore — the negative cache ("this file failed to
//     yield a frame; don't retry until it changes on disk").
// The I/O side (the actual AVFoundation / ffmpeg frame rips) stays in
// VideoScanModel+Thumbnail.swift.

import Foundation

// MARK: - Route decision (pure)

/// Which decoder the single-frame preview generator should use.
/// Swift's caseless-payload `enum` ≈ a C++ `enum class` — just a tag.
enum PreviewRoute: Equatable {
    /// AVFoundation fast path — hardware-assisted, right for the
    /// overwhelmingly common h264/hevc/prores catalog population.
    case avFoundation
    /// Straight to ffmpeg — AVFoundation would fail (or worse, grind
    /// through gigabytes of container sniffing first). Never touches
    /// an AVFoundation type.
    case ffmpegDirect
}

enum PreviewFrameRouter {

    /// Container tokens (substring match, lowercased) AVFoundation can't
    /// open. `container` holds ffprobe's `format_long_name` — mkv files
    /// arrive as "Matroska / WebM", hence substring matching rather than
    /// exact tokens (same reason MediaOpener keys off the extension).
    /// Kept as an editable constant so new hostile containers are a
    /// one-line addition.
    static let avfHostileContainerTokens: [String] = ["matroska", "webm"]

    /// ffprobe `codec_name` values (exact match, lowercased) that
    /// AVFoundation cannot decode — FFV1 archival essence plus the
    /// legacy/web codecs the needs-reformat work already cataloged.
    /// Exact spellings only; families with numbered variants go in
    /// `avfHostileVideoCodecPrefixes` below.
    static let avfHostileVideoCodecs: Set<String> = [
        "ffv1",     // digitized-tape master essence
        "svq3",     // Sorenson (early QuickTime)
        "cinepak",  // 1990s Apple/SuperMac
        "vp8", "vp9", "av1"  // WebM-era; no AVF decode on macOS
    ]

    /// Codec-name PREFIXES covering numbered families: ffprobe spells
    /// Indeo as indeo2/indeo3/indeo4/indeo5 and MS-MPEG4 as
    /// msmpeg4v1/msmpeg4v2/msmpeg4 — prefix matching catches every
    /// variant without enumerating them.
    static let avfHostileVideoCodecPrefixes: [String] = ["indeo", "msmpeg4"]

    /// The route decision. PURE — no I/O, no AVFoundation types, no
    /// logging — so it is trivially unit-testable and provably cannot
    /// touch the media file. Callers must consult this BEFORE creating
    /// any AVFoundation object (that's the whole fix: an mkv/ffv1 file
    /// must never instantiate an AVURLAsset).
    ///
    /// - Parameters:
    ///   - container: ffprobe `format_long_name` from the catalog record.
    ///   - videoCodec: ffprobe `codec_name` from the catalog record.
    ///   - needsReformat: the record's analyzer-confirmed "AVFoundation
    ///     can't decode this" flag — a dynamic backstop for codecs the
    ///     static lists don't know about.
    static func previewRoute(container: String,
                             videoCodec: String,
                             needsReformat: Bool) -> PreviewRoute {
        let cont = container.lowercased()
        if avfHostileContainerTokens.contains(where: { cont.contains($0) }) {
            return .ffmpegDirect
        }
        let codec = videoCodec.lowercased().trimmingCharacters(in: .whitespaces)
        if avfHostileVideoCodecs.contains(codec) {
            return .ffmpegDirect
        }
        if avfHostileVideoCodecPrefixes.contains(where: { codec.hasPrefix($0) }) {
            return .ffmpegDirect
        }
        if needsReformat {
            return .ffmpegDirect
        }
        return .avFoundation
    }
}

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
