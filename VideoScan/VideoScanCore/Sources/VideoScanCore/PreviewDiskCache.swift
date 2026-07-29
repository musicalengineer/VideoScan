// PreviewDiskCache.swift (VideoScanCore)
// Phase B piece 1 of the preview-perf work (2026-07-26): a persistent
// on-disk preview cache (L2) behind the in-memory NSCache (L1).
//
// LIFTED into VideoScanCore (2026-07-28, Stage 1 of the out-of-process
// preview helper): this is the ONE on-disk cache implementation, now shared
// by the app AND the CLI helper so an entry the CLI writes is found under the
// exact key the app looks up (bit-identical cache is the hard requirement —
// reimplementing the writer would reintroduce the cache-key/format drift
// class we just fixed centralizing PreviewCacheFormat). The app keeps every
// existing `PreviewDiskCache.*` reference via `@_exported import VideoScanCore`;
// only the access level changed (internal → public) and a CROSS-PROCESS write
// lock was added (see below) — the on-disk behavior is otherwise identical,
// and the app's PreviewDiskCache*Tests continue to pin it.
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
// Filmstrip payloads (filmstrip preview, 2026-07-27): multi-frame
// strips for AVPlayer-unplayable formats live in the SAME directory as
// "<keyhash>-strip-<index>-of-<count>-<offsetMillis>.jpg". The offset
// rides in the filename so lookup can rebuild timestamps without a
// sidecar; the count field makes completeness checkable. lookupFilmstrip
// returns non-nil ONLY for a complete, consistent set (all indices
// 0..<count present, one count value) — partial/mismatched leftovers
// (crashed store, prune took some frames) are a miss and remain
// prune-eligible garbage. The size-cap prune enumerates by directory
// contents, not name shape, so strip files are covered automatically.
//
// Thread-safety: lock-guarded `@unchecked Sendable` per the repo's
// "tiny box" convention. In-process writers (store/prune) serialize on an
// NSLock; readers go lock-free because payloads appear atomically (temp
// file + rename in the same directory — a reader sees the whole JPEG or no
// file, never a torn write).
//
// CROSS-PROCESS safety (2026-07-28, Stage 1): the app and the CLI helper
// can BOTH be alive and BOTH write this cache. An in-process NSLock cannot
// coordinate two processes, so every writer additionally takes an ADVISORY
// FILE LOCK (flock LOCK_EX on a hidden ".write.lock" in the cache dir)
// around the mutation. The temp-file-then-rename publish stays atomic, so
// lock-free readers in either process still see whole payloads. The lock is
// best-effort: if the lockfile can't be opened the writer proceeds under the
// in-process NSLock alone (degrades to the pre-Stage-1 behavior rather than
// blocking). For Rick: flock(2) LOCK_EX is an inter-process mutex keyed on a
// file — the OS serializes the two processes' write sections.
//
// Memory contract: no in-RAM index — the filesystem IS the index (one
// stat per lookup tier probe; one directory listing per filmstrip
// probe, ~20k names ≈ a few ms + a few MB transient, off-main callers
// only). Worst case per call: one encoded JPEG (≤ ~200 KB) + one
// decoded 480-wide bitmap (~0.5 MB) for tier payloads, or ≤16 of each
// (~10 MB) for a filmstrip, released on return. The prune holds one
// [URL + two attrs] array over the cache dir (~20k entries ≈ a few MB)
// at background QoS, then drops it. Disk is capped at `sizeCapBytes`
// (2 GB), enforced by the init-time prune — never on the hot path.

import Foundation
import Darwin
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import os

/// File-scope so detached generation tasks can log without touching
/// actor-isolated state — same fix class as precacheLog/previewLog.
private let diskCacheLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                  category: "preview-disk-cache")

public final class PreviewDiskCache: @unchecked Sendable {

    // MARK: - Tiers

    /// Payload quality tier — see the filename-suffix note in the file
    /// header. The type + its filename grammar live in
    /// PreviewCacheFormat.swift as the shared app/CLI format contract;
    /// this alias keeps every existing `PreviewDiskCache.Tier` reference.
    public typealias Tier = PreviewCacheTier

    // MARK: - Policy constants

    /// Longest payload edge. Matches the L1 generators' 480-wide cap so
    /// re-encoding here never upscales.
    public static let maxPayloadDimension = 480

    /// JPEG lossy quality. 0.8 is visually clean for a preview pane at
    /// this size and keeps typical payloads in the 30–100 KB range.
    public static let jpegQuality: Double = 0.8

    /// On-disk footprint cap (2 GB ≈ 20k+ records with headroom).
    /// Enforced by the init-scheduled background prune, oldest first.
    public static let sizeCapBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Minimum age before the prune treats a tmp- file as a crashed-
    /// write orphan. A live store holds its temp file for milliseconds;
    /// 10 minutes is orders of magnitude past any legitimate lifetime
    /// while still sweeping real crash leftovers on the next launch.
    public static let tmpSweepMinAgeSeconds: TimeInterval = 600

    /// Filename of the advisory cross-process write lock (hidden dotfile so
    /// contentsOfDirectory(.skipsHiddenFiles) in currentListing/pruneNow
    /// never sees it).
    private static let writeLockName = ".write.lock"

    // MARK: - Roots

    /// Production cache directory:
    /// ~/Library/Application Support/VideoScan/preview-cache/
    /// Under a unit-test host this redirects to a per-process temp
    /// sandbox — same narrow gate as MetadataCache.defaultPath, and for
    /// the same reason (the Settings-pollution incident class): the
    /// ~200 test sites that construct VideoScanModel() must never touch
    /// the real cache. Only this DEFAULT redirects; init(rootURL:) with
    /// an explicit root gets exactly that root.
    public static var productionRootURL: URL {
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
    /// MetadataCache.isRunningTests (mirrored, not shared).
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
    public let rootURL: URL

    /// Serializes in-process mutators (store's best-exists check + rename,
    /// prune's enumerate + reap). Readers are lock-free — see file header.
    private let lock = NSLock()

    /// Latch so at most one prune is ever scheduled per instance.
    private var pruneScheduled = false

    public init(rootURL: URL) {
        self.rootURL = rootURL
        try? FileManager.default.createDirectory(at: rootURL,
                                                 withIntermediateDirectories: true)
        schedulePruneIfNeeded()
    }

    // MARK: - Cross-process write lock

    private var writeLockURL: URL { rootURL.appendingPathComponent(Self.writeLockName) }

    /// Run `body` while holding the advisory cross-process write lock (and
    /// nothing else). Best-effort: if the lockfile can't be opened the body
    /// still runs (caller's in-process NSLock is the fallback). flock is
    /// released on scope exit; close(2) would release it anyway, LOCK_UN is
    /// belt-and-suspenders.
    private func withInterProcessWriteLock<T>(_ body: () throws -> T) rethrows -> T {
        let fd = open(writeLockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return try body() }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    // MARK: - Keying (pure)

    /// Cache key: SHA256 hex of "path|mtimeEpochSeconds|sizeBytes".
    /// Forwards to VideoScanCore's `previewCacheKey` (golden-pinned).
    public static func cacheKey(path: String, mtime: TimeInterval, size: Int64) -> String {
        previewCacheKey(path: path, mtime: mtime, size: size)
    }

    /// (mtime, size) of the file at `path`, or nil when it can't be
    /// statted. Forwards to `previewFileSignature`. File I/O — off-main.
    public static func fileSignature(atPath path: String) -> (mtime: TimeInterval, size: Int64)? {
        previewFileSignature(atPath: path)
    }

    private func payloadURL(key: String, tier: Tier) -> URL {
        rootURL.appendingPathComponent(previewTierFilename(key: key, tier: tier))
    }

    /// Parse a tier payload filename back into its fields, or nil.
    public static func parseTierFilename(_ filename: String) -> (key: String, tier: Tier)? {
        previewParseTierFilename(filename)
    }

    // MARK: - Lookup

    /// Best available payload for this exact (path, mtime, size), or nil
    /// on miss. Prefers the `best` tier. Disk I/O — off the main actor.
    public func lookup(path: String, mtime: TimeInterval, size: Int64) -> CGImage? {
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
    /// wins when both exist.
    public func storedTier(path: String, mtime: TimeInterval, size: Int64) -> Tier? {
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
    ///
    /// Returns the bytes actually written to disk (0 on skip/failure) —
    /// the preview sweep accumulates this against `sizeCapBytes`.
    @discardableResult
    public func store(_ image: CGImage,
                      path: String,
                      mtime: TimeInterval,
                      size: Int64,
                      tier: Tier) -> Int64 {
        let key = Self.cacheKey(path: path, mtime: mtime, size: size)
        let dest = payloadURL(key: key, tier: tier)
        let fm = FileManager.default

        return withInterProcessWriteLock {
            lock.lock()
            defer { lock.unlock() }

            // Best never downgrades: an interactive fast frame arriving
            // after the background pass upgraded this file is a no-op.
            if tier == .fast,
               fm.fileExists(atPath: payloadURL(key: key, tier: .best).path) {
                return 0
            }

            guard let jpeg = Self.encodeJPEG(image) else {
                diskCacheLog.notice("JPEG encode failed for \((path as NSString).lastPathComponent, privacy: .public) — not cached")
                return 0
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
                return 0
            }

            if tier == .best {
                // Reap the superseded fast payload so the same frame isn't
                // stored twice (and lookup's best-preference stays moot).
                try? fm.removeItem(at: payloadURL(key: key, tier: .fast))
            }
            return Int64(jpeg.count)
        }
    }

    /// Encode to JPEG at `jpegQuality`, downscaling to
    /// `maxPayloadDimension` on the longest edge if the source is larger.
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

    // MARK: - Filmstrip payloads (filmstrip preview, 2026-07-27)

    /// Ceiling for a strip frame's offset, in milliseconds. Forwards to
    /// `previewMaxStripOffsetMillis`.
    public static let maxStripOffsetMillis = previewMaxStripOffsetMillis

    /// Strip payload filename. Forwards to `previewStripFilename`.
    public static func stripFilename(key: String, index: Int, count: Int,
                                     offsetMillis: Int) -> String {
        previewStripFilename(key: key, index: index, count: count,
                             offsetMillis: offsetMillis)
    }

    /// Parse a strip filename back into its fields, or nil.
    public static func parseStripFilename(_ filename: String)
        -> (key: String, index: Int, count: Int, offsetMillis: Int)? {
        previewParseStripFilename(filename)
    }

    /// Store a complete filmstrip for this exact (path, mtime, size).
    /// JPEGs are encoded OUTSIDE the lock (16 encodes are the expensive
    /// part), then written temp+rename per frame under it. Any encode
    /// failure aborts the whole store (never publish a set we know is
    /// short); a write failure mid-set leaves a PARTIAL set on disk,
    /// which lookup treats as a miss and the prune eventually reaps.
    /// Frames with a non-finite, negative, or insane offset are refused
    /// outright (the millisecond conversion below TRAPS on huge finite
    /// Doubles too). Whole-store abort. Disk I/O — off the main actor.
    ///
    /// Returns the total bytes written (0 on refusal/abort; a mid-set
    /// write failure returns the bytes that DID land).
    @discardableResult
    public func storeFilmstrip(_ frames: [(offsetSeconds: Double, image: CGImage)],
                               path: String,
                               mtime: TimeInterval,
                               size: Int64) -> Int64 {
        guard !frames.isEmpty,
              frames.allSatisfy({
                  $0.offsetSeconds.isFinite
                      && $0.offsetSeconds >= 0
                      && $0.offsetSeconds <= previewMaxSaneDurationSeconds
              }) else {
            return 0
        }
        let key = Self.cacheKey(path: path, mtime: mtime, size: size)
        let fm = FileManager.default

        var payloads: [(filename: String, data: Data)] = []
        payloads.reserveCapacity(frames.count)
        for (index, frame) in frames.enumerated() {
            // autoreleasepool per encode — media-loop memory rule; the
            // CG/ImageIO temporaries must not pile up across 16 frames.
            guard let jpeg = autoreleasepool(invoking: { Self.encodeJPEG(frame.image) }) else {
                diskCacheLog.notice("Filmstrip JPEG encode failed (frame \(index)) for \((path as NSString).lastPathComponent, privacy: .public) — strip not cached")
                return 0
            }
            let offsetMillis = Int((frame.offsetSeconds * 1000).rounded())
            payloads.append((Self.stripFilename(key: key, index: index,
                                                count: frames.count,
                                                offsetMillis: offsetMillis), jpeg))
        }

        return withInterProcessWriteLock {
            lock.lock()
            defer { lock.unlock() }

            // Remove any previous strip set for this key first — two
            // generations' files mixed under one key would make the
            // completeness check ambiguous forever.
            if let existing = try? fm.contentsOfDirectory(atPath: rootURL.path) {
                for name in existing where name.hasPrefix("\(key)-strip-") {
                    try? fm.removeItem(at: rootURL.appendingPathComponent(name))
                }
            }

            var written: Int64 = 0
            for payload in payloads {
                let tmp = rootURL.appendingPathComponent("tmp-\(UUID().uuidString)")
                do {
                    try payload.data.write(to: tmp)
                    _ = try fm.replaceItemAt(rootURL.appendingPathComponent(payload.filename),
                                             withItemAt: tmp)
                    written += Int64(payload.data.count)
                } catch {
                    diskCacheLog.notice("Filmstrip cache write failed (\(error.localizedDescription, privacy: .public)) — partial set left for prune")
                    try? fm.removeItem(at: tmp)
                    return written
                }
            }
            return written
        }
    }

    /// The cached filmstrip for this exact (path, mtime, size), ordered
    /// by index, or nil unless a COMPLETE consistent set exists. Decodes
    /// every frame. Disk I/O — off the main actor.
    public func lookupFilmstrip(path: String, mtime: TimeInterval, size: Int64)
        -> [(offsetSeconds: Double, image: CGImage)]? {
        let key = Self.cacheKey(path: path, mtime: mtime, size: size)
        guard let set = completeStripSet(forKey: key) else { return nil }
        var frames: [(offsetSeconds: Double, image: CGImage)] = []
        frames.reserveCapacity(set.count)
        for entry in set {
            guard let source = CGImageSourceCreateWithURL(entry.url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return nil
            }
            frames.append((Double(entry.offsetMillis) / 1000.0, cg))
        }
        return frames
    }

    /// True when a complete strip set exists for this signature —
    /// directory listing only, no decoding.
    public func hasCompleteFilmstrip(path: String, mtime: TimeInterval, size: Int64) -> Bool {
        completeStripSet(forKey: Self.cacheKey(path: path, mtime: mtime, size: size)) != nil
    }

    /// The complete, consistent strip file set for `key`, ordered by
    /// index — or nil for none/partial/inconsistent. Strict by design.
    private func completeStripSet(forKey key: String)
        -> [(offsetMillis: Int, url: URL)]? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: rootURL.path) else {
            return nil
        }
        let prefix = "\(key)-strip-"
        var byIndex: [Int: (offsetMillis: Int, url: URL)] = [:]
        var expectedCount: Int?
        for name in names where name.hasPrefix(prefix) {
            guard let parsed = Self.parseStripFilename(name), parsed.key == key else {
                return nil
            }
            if let expected = expectedCount, expected != parsed.count { return nil }
            expectedCount = parsed.count
            guard byIndex.updateValue((parsed.offsetMillis,
                                       rootURL.appendingPathComponent(name)),
                                      forKey: parsed.index) == nil else {
                return nil
            }
        }
        guard let count = expectedCount, byIndex.count == count else { return nil }
        // count distinct in-range indices ⇒ exactly 0..<count.
        return (0..<count).compactMap { byIndex[$0] }
    }

    // MARK: - One-listing probe (PreviewCache seam)

    /// ONE directory listing of the cache root as (filename, sizeBytes) —
    /// the scale invariant's single cache probe fed to
    /// PreviewSweepPlanner.buildCacheIndex. Moved here from the app-side
    /// PreviewSweepAdapters extension when the type moved to Core.
    public func currentListing() -> [(name: String, size: Int64)] {
        (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles).map { url in
                (url.lastPathComponent,
                 Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
            }) ?? []
    }

    // MARK: - Size-cap prune

    /// Schedule the over-cap prune exactly once, at background QoS.
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
    /// writes. Synchronous; public so tests can invoke it directly.
    public func pruneNow() {
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
            // Crashed-write leftovers — AGE-GATED: this sweep runs in the
            // enumeration phase, before the lock, so it could otherwise
            // race an in-flight store and delete the temp file that store
            // wrote milliseconds ago. Only tmp files past
            // tmpSweepMinAgeSeconds are provably orphans.
            if url.lastPathComponent.hasPrefix("tmp-") {
                if let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                   let mtime = vals.contentModificationDate,
                   Date().timeIntervalSince(mtime) > Self.tmpSweepMinAgeSeconds {
                    try? fm.removeItem(at: url)
                }
                continue
            }
            guard let vals = try? url.resourceValues(forKeys: Set(keys)),
                  let size = vals.fileSize,
                  let mtime = vals.contentModificationDate else { continue }
            payloads.append((url, Int64(size), mtime))
            total += Int64(size)
        }
        guard total > Self.sizeCapBytes else { return }

        withInterProcessWriteLock {
            lock.lock()
            defer { lock.unlock() }
            var reaped = 0
            for entry in payloads.sorted(by: { $0.mtime < $1.mtime }) {
                guard total > Self.sizeCapBytes else { break }
                // Only count bytes that actually left the disk.
                do {
                    try fm.removeItem(at: entry.url)
                    total -= entry.size
                    reaped += 1
                } catch {
                    diskCacheLog.notice("Prune could not remove \(entry.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            diskCacheLog.info("Preview disk cache pruned \(reaped) oldest entries — now \(total / (1024 * 1024)) MB")
        }
    }
}

// MARK: - PreviewCache seam conformance

/// The persistent disk cache IS the engine's `PreviewCache` (store /
/// storeFilmstrip / currentListing already match). Declared here in Core
/// now that the type lives in Core (moved from the app's
/// PreviewSweepAdapters extension, 2026-07-28 Stage 1).
extension PreviewDiskCache: PreviewCache {}
