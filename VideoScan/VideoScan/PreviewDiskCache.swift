// PreviewDiskCache.swift
// Phase B piece 1 of the preview-perf work (2026-07-26): a persistent
// on-disk preview cache (L2) behind the in-memory NSCache (L1).
//
// Why: the 8 GB NSCache dies with the process — every relaunch re-rips
// one frame per browsed file, and the 237 GB FFV1 masters that Phase A
// routed to ffmpeg still cost a subprocess each. A 480-wide JPEG per
// record (~30–100 KB) makes previews effectively free across launches:
// the whole ~20k-record catalog fits in ~1–2 GB of disk.
//
// Lookup order (wired in VideoScanModel+Thumbnail / ThumbnailPrecache):
//   L1 NSCache → L2 this cache → generate (write-through to BOTH).
//
// Key design: SHA256 hex of "path|mtimeEpochSeconds|sizeBytes". Because
// the file's (mtime, size) are IN the key, a modified/repaired file
// simply misses and regenerates — no explicit invalidation protocol.
// Stale entries for old signatures linger until the size-cap prune
// reaps them (oldest-first); they are never served.
//
// Tier marking (Phase B piece 1, commit 2 consumes it): the payload
// filename is "<keyhash>-<tier>.jpg" where tier is "fast" (interactive
// single frame at t=0.5s) or "best" (content-scored background pick).
// Filename suffix — not a sidecar — so tier queries are one stat and
// the prune can't orphan a marker. `store` refuses to overwrite a
// "best" entry with a "fast" one (best never downgrades); lookup
// prefers best over fast when both exist.
//
// Thread-safety: lock-guarded `@unchecked Sendable` per the repo's
// "tiny box" convention (see ProcessRunner.DeadlineFlag,
// ThumbnailFailureStore). The lock serializes writers (store/prune);
// readers go lock-free because payloads appear atomically (temp file +
// rename in the same directory — a reader sees the whole JPEG or no
// file, never a torn write). For Rick: mutex around the mutators, and
// rename(2)'s atomicity doing the reader-side synchronization.
//
// Memory contract: no in-RAM index — the filesystem IS the index (one
// stat per lookup tier probe). Worst case per call: one encoded JPEG
// (≤ ~200 KB) + one decoded 480-wide bitmap (~0.5 MB), released on
// return. The prune holds one [URL + two attrs] array over the cache
// dir (~20k entries ≈ a few MB) at background QoS, then drops it.
// Disk is capped at `sizeCapBytes` (2 GB), enforced by the init-time
// prune — never on the hot path.

import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import os

/// File-scope so detached generation tasks can log without touching
/// actor-isolated state — same fix class as precacheLog/previewLog.
private let diskCacheLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                  category: "preview-disk-cache")

final class PreviewDiskCache: @unchecked Sendable {

    // MARK: - Tiers

    /// Payload quality tier — see the filename-suffix note in the file
    /// header. Raw value is the literal filename suffix.
    enum Tier: String, CaseIterable {
        /// Interactive path's single frame at t=0.5s — cheap, may be a
        /// blank VHS lead-in. Upgradeable.
        case fast
        /// Background best-frame pick (content-scored across candidate
        /// offsets, commit 2). Terminal — never overwritten by `fast`.
        case best
    }

    // MARK: - Policy constants

    /// Longest payload edge. Matches the L1 generators' 480-wide cap so
    /// re-encoding here never upscales.
    static let maxPayloadDimension = 480

    /// JPEG lossy quality. 0.8 is visually clean for a preview pane at
    /// this size and keeps typical payloads in the 30–100 KB range.
    static let jpegQuality: Double = 0.8

    /// On-disk footprint cap (2 GB ≈ 20k+ records with headroom).
    /// Enforced by the init-scheduled background prune, oldest first.
    static let sizeCapBytes: Int64 = 2 * 1024 * 1024 * 1024

    // MARK: - Roots

    /// Production cache directory:
    /// ~/Library/Application Support/VideoScan/preview-cache/
    /// Under a unit-test host this redirects to a per-process temp
    /// sandbox — same narrow gate as MetadataCache.defaultPath, and for
    /// the same reason (the Settings-pollution incident class): the
    /// ~200 test sites that construct VideoScanModel() must never touch
    /// the real cache. Only this DEFAULT redirects; init(rootURL:) with
    /// an explicit root gets exactly that root.
    static var productionRootURL: URL {
        let base: URL
        if isRunningTests {
            base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(
                    "VideoScanTests-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
        } else {
            base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
        }
        return base
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("preview-cache", isDirectory: true)
    }

    /// True when this process is a unit-test host. Multi-signal — see
    /// MetadataCache.isRunningTests (mirrored, not shared, because that
    /// one is private and this file may move to VideoScanCore later).
    private static var isRunningTests: Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if env["SWIFT_TESTING_ENABLED"] != nil { return true }
        if env["VS_UI_TEST"] == "1" { return true }
        if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            return true
        }
        return false
    }

    // MARK: - State

    /// Cache directory. Injectable so tests point at their own temp dir
    /// (isolation dimension of the feature-test checklist) — production
    /// callers pass `productionRootURL`.
    let rootURL: URL

    /// Serializes mutators (store's best-exists check + rename, prune's
    /// enumerate + reap). Readers are lock-free — see file header.
    private let lock = NSLock()

    /// Latch so at most one prune is ever scheduled per instance.
    private var pruneScheduled = false

    init(rootURL: URL) {
        self.rootURL = rootURL
        try? FileManager.default.createDirectory(at: rootURL,
                                                 withIntermediateDirectories: true)
        schedulePruneIfNeeded()
    }

    // MARK: - Keying (pure)

    /// Cache key: SHA256 hex of "path|mtimeEpochSeconds|sizeBytes".
    /// mtime truncates to whole seconds — sub-second precision differs
    /// across filesystems (SMB vs APFS) and a 1 s window can't matter
    /// for "did this media file change". Pure and static for tests.
    static func cacheKey(path: String, mtime: TimeInterval, size: Int64) -> String {
        let material = "\(path)|\(Int64(mtime))|\(size)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// (mtime, size) of the file at `path`, or nil when it can't be
    /// statted (vanished / dead volume). Callers skip the disk cache
    /// entirely on nil rather than keying on garbage. File I/O — call
    /// off the main actor (both wire-in sites run in detached tasks).
    static func fileSignature(atPath path: String) -> (mtime: TimeInterval, size: Int64)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return nil
        }
        return (mtime, size)
    }

    private func payloadURL(key: String, tier: Tier) -> URL {
        rootURL.appendingPathComponent("\(key)-\(tier.rawValue).jpg")
    }

    // MARK: - Lookup

    /// Best available payload for this exact (path, mtime, size), or nil
    /// on miss. A changed file misses automatically (signature is in the
    /// key). Prefers the `best` tier. Disk I/O — off the main actor.
    func lookup(path: String, mtime: TimeInterval, size: Int64) -> CGImage? {
        let key = Self.cacheKey(path: path, mtime: mtime, size: size)
        for tier in [Tier.best, Tier.fast] {
            let url = payloadURL(key: key, tier: tier)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                continue
            }
            return cg
        }
        return nil
    }

    /// Which tier (if any) is stored for this exact signature — `best`
    /// wins when both exist. One or two stats; lets the background pass
    /// skip records already upgraded without decoding anything.
    func storedTier(path: String, mtime: TimeInterval, size: Int64) -> Tier? {
        let key = Self.cacheKey(path: path, mtime: mtime, size: size)
        for tier in [Tier.best, Tier.fast] {
            if FileManager.default.fileExists(atPath: payloadURL(key: key, tier: tier).path) {
                return tier
            }
        }
        return nil
    }

    // MARK: - Store

    /// Write-through a generated frame. JPEG-encodes (≤480 longest edge,
    /// quality 0.8) to a temp file in the cache dir, then renames into
    /// place — atomic on APFS, so lock-free readers never see a torn
    /// payload. A `fast` store is silently dropped when a `best` entry
    /// already exists for the same key (best never downgrades); when a
    /// `best` store lands, the now-superseded `fast` payload is removed.
    /// Disk I/O — off the main actor.
    func store(_ image: CGImage,
               path: String,
               mtime: TimeInterval,
               size: Int64,
               tier: Tier) {
        let key = Self.cacheKey(path: path, mtime: mtime, size: size)
        let dest = payloadURL(key: key, tier: tier)
        let fm = FileManager.default

        lock.lock()
        defer { lock.unlock() }

        // Best never downgrades: an interactive fast frame arriving
        // after the background pass upgraded this file is a no-op.
        if tier == .fast,
           fm.fileExists(atPath: payloadURL(key: key, tier: .best).path) {
            return
        }

        guard let jpeg = Self.encodeJPEG(image) else {
            diskCacheLog.notice("JPEG encode failed for \((path as NSString).lastPathComponent, privacy: .public) — not cached")
            return
        }

        // Temp-in-same-dir + rename = atomic publish (rename(2) within
        // one volume). NSTemporaryDirectory() would risk a cross-volume
        // copy, which is NOT atomic.
        let tmp = rootURL.appendingPathComponent("tmp-\(UUID().uuidString)")
        do {
            try jpeg.write(to: tmp)
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        } catch {
            diskCacheLog.notice("Disk-cache write failed (\(error.localizedDescription, privacy: .public)) — preview still served from L1")
            try? fm.removeItem(at: tmp)
            return
        }

        if tier == .best {
            // Reap the superseded fast payload so the same frame isn't
            // stored twice (and lookup's best-preference stays moot).
            try? fm.removeItem(at: payloadURL(key: key, tier: .fast))
        }
    }

    /// Encode to JPEG at `jpegQuality`, downscaling to
    /// `maxPayloadDimension` on the longest edge if the source is
    /// larger (defensive — both generators already cap at 480).
    private static func encodeJPEG(_ image: CGImage) -> Data? {
        var source = image
        let longest = max(image.width, image.height)
        if longest > maxPayloadDimension {
            let scale = Double(maxPayloadDimension) / Double(longest)
            let w = max(1, Int(Double(image.width) * scale))
            let h = max(1, Int(Double(image.height) * scale))
            if let ctx = CGContext(data: nil, width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let scaled = ctx.makeImage() { source = scaled }
            }
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, source, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - Size-cap prune

    /// Schedule the over-cap prune exactly once, at background QoS —
    /// init calls this, so app launch pays nothing on the main thread
    /// and the hot lookup/store paths never prune.
    private func schedulePruneIfNeeded() {
        lock.lock()
        let alreadyScheduled = pruneScheduled
        pruneScheduled = true
        lock.unlock()
        guard !alreadyScheduled else { return }

        Task.detached(priority: .background) { [weak self] in
            self?.pruneNow()
        }
    }

    /// Reap oldest payloads (by file mtime — touched-on-write only, so
    /// this is insertion order) until the cache is back under
    /// `sizeCapBytes`. Also sweeps orphaned temp files from crashed
    /// writes. Synchronous; internal so tests can invoke it directly
    /// instead of racing the init-scheduled task.
    func pruneNow() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles) else {
            return
        }

        var payloads: [(url: URL, size: Int64, mtime: Date)] = []
        var total: Int64 = 0
        for url in entries {
            // Crashed-write leftovers: any age-old tmp file is garbage.
            if url.lastPathComponent.hasPrefix("tmp-") {
                try? fm.removeItem(at: url)
                continue
            }
            guard let vals = try? url.resourceValues(forKeys: Set(keys)),
                  let size = vals.fileSize,
                  let mtime = vals.contentModificationDate else { continue }
            payloads.append((url, Int64(size), mtime))
            total += Int64(size)
        }
        guard total > Self.sizeCapBytes else { return }

        lock.lock()
        defer { lock.unlock() }
        var reaped = 0
        for entry in payloads.sorted(by: { $0.mtime < $1.mtime }) {
            guard total > Self.sizeCapBytes else { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
            reaped += 1
        }
        diskCacheLog.info("Preview disk cache pruned \(reaped) oldest entries — now \(total / (1024 * 1024)) MB")
    }
}
