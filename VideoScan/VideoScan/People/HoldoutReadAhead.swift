// HoldoutReadAhead.swift
// HDD read-ahead + spindle keepalive for the blind holdout review pane
// (fix/review-sheet-performance, 2026-07-26).
//
// The LaCie USB enclosure parks its heads after idle; the first touch of
// the next file then pays a 5–15 s spin-up (measured 2026-07-26 — the
// disk itself is fast: 216 MB/s sequential, ~20 ms seeks; the app's
// access pattern was the problem). Human-paced review gives the app
// seconds of free time per item; these two helpers spend it:
//
//   - HoldoutReviewPrefetcher — after each navigation, serially warm the
//     next few pending files (first ~2 MB + last ~2 MB — the tail covers
//     moov-at-end indexes) into the page cache, and pre-generate the
//     routed thumbnail for the NEXT item. STRICTLY one file at a time —
//     parallel seeks collapse HDD throughput — at utility QoS, cancelled
//     when the sheet closes. Files warmed once per session are skipped.
//
//   - HoldoutSpindleKeepalive — while the pane is open, read 64 KB at a
//     random-ish offset of the current file every ~50 s so the spindle
//     never parks mid-session.
//
// Both are lock-guarded @unchecked Sendable tiny boxes (repo convention,
// see ProcessRunner.DeadlineFlag) — for Rick: mutex-guarded state plus a
// worker task handle. Disk access is injectable (ReviewFileToucher) so
// tests can fake the disk.

import CoreGraphics
import Foundation
import os

private let readAheadLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                  category: "poi.holdout-readahead")

// MARK: - Injectable disk toucher

/// The only thing the prefetcher/keepalive may do to a file: read bytes
/// so the OS page cache (and the drive spindle) get warm. Protocol so
/// tests can substitute a fake and assert call order without any disk.
protocol ReviewFileToucher: Sendable {
    /// Read the first `headBytes` and last `tailBytes` of the file.
    func warmHeadAndTail(path: String, headBytes: Int, tailBytes: Int) throws
    /// Read `readBytes` at a random-ish offset (keepalive tick).
    func keepAliveTouch(path: String, readBytes: Int) throws
}

/// Real implementation — plain FileHandle reads. The read data is
/// discarded immediately; the side effect (page cache population, head
/// unpark) is the point. Transient memory: ≤ head+tail bytes (4 MB).
struct RealReviewFileToucher: ReviewFileToucher {

    func warmHeadAndTail(path: String, headBytes: Int, tailBytes: Int) throws {
        let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? fh.close() }
        _ = try fh.read(upToCount: headBytes)
        let size = try fh.seekToEnd()
        let tailStart = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try fh.seek(toOffset: tailStart)
        _ = try fh.read(upToCount: tailBytes)
    }

    func keepAliveTouch(path: String, readBytes: Int) throws {
        let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? fh.close() }
        let size = try fh.seekToEnd()
        let maxOffset = size > UInt64(readBytes) ? size - UInt64(readBytes) : 0
        let offset = maxOffset > 0 ? UInt64.random(in: 0...maxOffset) : 0
        try fh.seek(toOffset: offset)
        _ = try fh.read(upToCount: readBytes)
    }
}

// MARK: - Prefetcher

final class HoldoutReviewPrefetcher: @unchecked Sendable {

    /// First ~2 MB (container header, first GOPs) + last ~2 MB
    /// (moov-at-end index — the exact bytes AVF needs before it can do
    /// anything with a QuickTime/MP4 file).
    static let headBytes = 2 * 1024 * 1024
    static let tailBytes = 2 * 1024 * 1024
    /// How many upcoming pending rows each schedule() call warms.
    static let lookahead = 4

    /// One prefetch work item: the file plus the catalog media metadata
    /// the routed thumbnail renderer needs (nil = not in catalog).
    struct Entry: Sendable {
        let path: String
        let meta: HoldoutMediaMeta?
        /// Pre-generate the routed thumbnail too (only the NEXT item —
        /// one decode ahead is plenty; bytes-warming covers the rest).
        let wantsThumbnail: Bool
    }

    private let lock = NSLock()
    private var warmedThisSession: Set<String> = []
    private var thumbnails: [String: CGImage] = [:]
    /// FIFO insertion order for the small thumbnail cache's eviction.
    private var thumbnailOrder: [String] = []
    private var chain: Task<Void, Never>?

    /// Bound the pre-rendered thumbnail cache. Queue rows are ~36 today;
    /// the cap exists so the store CANNOT grow unbounded (memory rule).
    static let maxCachedThumbnails = 32

    private let toucher: any ReviewFileToucher
    private let renderThumbnail: @Sendable (String, HoldoutMediaMeta?) async -> CGImage?

    /// NOTE: the DEFAULT render closure calls the renderer directly with
    /// no negative-cache gate — production wiring (ConfirmPersonSheet.
    /// startHoldout) supplies a closure that consults the model's shared
    /// ThumbnailFailureStore first, so a known-bad next row doesn't
    /// re-attempt a full render on every navigation (QA 2026-07-26).
    /// The default exists for tests and keeps this file store-agnostic.
    init(toucher: any ReviewFileToucher = RealReviewFileToucher(),
         renderThumbnail: @escaping @Sendable (String, HoldoutMediaMeta?) async -> CGImage?
            = { await ReviewThumbnailRenderer.renderOrNil(path: $0, meta: $1) }) {
        self.toucher = toucher
        self.renderThumbnail = renderThumbnail
    }

    /// A pre-generated thumbnail for `path`, if read-ahead got to it.
    func cachedThumbnail(for path: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return thumbnails[path]
    }

    /// (Re)schedule read-ahead. Chained onto any still-running work so
    /// at most ONE file is being touched at any moment even across rapid
    /// navigation — cancellation is checked between files, and the new
    /// batch waits for the in-flight file rather than seeking against it.
    func schedule(entries: [Entry]) {
        lock.lock()
        let previous = chain
        previous?.cancel()
        let task = Task(priority: .utility) { [weak self] in
            _ = await previous?.value   // strict serialization across batches
            guard let self, !Task.isCancelled else { return }
            await self.run(entries: entries)
        }
        chain = task
        lock.unlock()
    }

    /// Sheet closed — stop touching the disk.
    func cancelAll() {
        lock.lock()
        chain?.cancel()
        chain = nil
        lock.unlock()
    }

    private func run(entries: [Entry]) async {
        for entry in entries {
            if Task.isCancelled { return }
            if !isWarmed(entry.path) {
                // Blocking reads pushed off any actor via the
                // @concurrent hop below; failures (offline volume,
                // deleted file) are logged and skipped — read-ahead is
                // best-effort by definition.
                await Self.warmOffActor(toucher: toucher, path: entry.path)
                markWarmed(entry.path)
            }
            if Task.isCancelled { return }
            if entry.wantsThumbnail, cachedThumbnail(for: entry.path) == nil {
                if let cg = await renderThumbnail(entry.path, entry.meta),
                   !Task.isCancelled {
                    storeThumbnail(cg, for: entry.path)
                }
            }
        }
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func warmOffActor(toucher: any ReviewFileToucher,
                                                 path: String) async {
        do {
            try toucher.warmHeadAndTail(path: path,
                                        headBytes: headBytes,
                                        tailBytes: tailBytes)
            readAheadLog.debug("warmed \((path as NSString).lastPathComponent, privacy: .public)")
        } catch {
            readAheadLog.debug("warm skipped for \((path as NSString).lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func isWarmed(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return warmedThisSession.contains(path)
    }

    private func markWarmed(_ path: String) {
        lock.lock()
        warmedThisSession.insert(path)
        lock.unlock()
    }

    private func storeThumbnail(_ cg: CGImage, for path: String) {
        lock.lock()
        if thumbnails[path] == nil { thumbnailOrder.append(path) }
        thumbnails[path] = cg
        while thumbnailOrder.count > Self.maxCachedThumbnails {
            thumbnails.removeValue(forKey: thumbnailOrder.removeFirst())
        }
        lock.unlock()
    }
}

// MARK: - Spindle keepalive

final class HoldoutSpindleKeepalive: @unchecked Sendable {

    /// WHY THIS EXISTS: the LaCie USB enclosure parks its heads after
    /// ~1 min idle and the next read then pays a 5–15 s spin-up stall
    /// (measured 2026-07-26). While Rick watches a video in QuickTime the
    /// app does no I/O, so without this the NEXT navigation always hit a
    /// parked disk. A 64 KB read at a random-ish offset of the current
    /// file every ~50 s (inside the 45–60 s park window) keeps the
    /// spindle awake for the whole human-paced session, at utility QoS,
    /// and stops the moment the sheet closes.
    static let intervalSeconds: Double = 50
    static let touchBytes = 64 * 1024

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var currentPath: String?
    private let toucher: any ReviewFileToucher
    private let interval: Double

    init(toucher: any ReviewFileToucher = RealReviewFileToucher(),
         intervalSeconds: Double = HoldoutSpindleKeepalive.intervalSeconds) {
        self.toucher = toucher
        self.interval = intervalSeconds
    }

    /// The file the next tick should touch — updated on every navigation
    /// (synchronous + lock-guarded so the UI can call it freely).
    func setCurrentPath(_ path: String?) {
        lock.lock()
        currentPath = path
        lock.unlock()
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }
        task = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.interval ?? Self.intervalSeconds))
                guard !Task.isCancelled, let self else { return }
                if let path = self.pathForTick() {
                    await Self.touchOffActor(toucher: self.toucher, path: path)
                }
            }
        }
    }

    func stop() {
        lock.lock()
        task?.cancel()
        task = nil
        lock.unlock()
    }

    private func pathForTick() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return currentPath
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func touchOffActor(toucher: any ReviewFileToucher,
                                                  path: String) async {
        do {
            try toucher.keepAliveTouch(path: path, readBytes: touchBytes)
        } catch {
            // Offline volume / deleted file — nothing to keep awake.
            readAheadLog.debug("keepalive touch skipped: \(error.localizedDescription, privacy: .public)")
        }
    }
}
