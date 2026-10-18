// CatalogQuitRecovery.swift
// Codex 2026-10-17 round 2 P1 ("failed persistence still permits
// termination", docs/reviews/codex/codex-review-import-quit-path-hold-drain-2026-10-17.md).
// One sentence: when the quit cannot save the catalog, it writes the
// in-memory catalog to a recovery copy beside catalog.json, and if even
// that fails the app stays open unless the person chooses to lose the
// changes.
//
//   * The copy: `catalog.recovery-<yyyyMMdd-HHmmss>.json` beside
//     catalog.json — the store's own payload and encoder
//     (`CatalogStore.recoveryCopyWriter`), published with AtomicFilePublish
//     (`.fullFsync`), off the main actor and BOUNDED: a stalled volume
//     cannot hang the quit; past the bound the copy counts as failed.
//   * Never merged: the next launch says the copy is there (console +
//     catalog.log + videoscan.log) and how to use it; nothing reads it back.
//   * START / OUTCOME lines through one sink (`catalogQuitNote`).
//
// (For Rick: the last-ditch "dump core to a side file" a C++ app does when
// its normal save path fails at exit — except it is the real, loadable
// catalog format, and nothing auto-loads it.)

import AppKit
import Foundation
import VideoScanCore
import os

private let quitLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "catalogQuit")

/// Resumes its continuation exactly once, with whichever result arrives
/// first — the work's or the timer's. (For Rick: a one-shot latch guarded
/// by a mutex; the loser's resume is a no-op.)
final class OnceResume<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var early: Value?
    private var done = false

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        let ready: Value? = lock.withLock {
            guard let early else { self.continuation = continuation; return nil }
            return early
        }
        if let ready { continuation.resume(returning: ready) }
    }

    func resume(_ value: Value) {
        let waiting: CheckedContinuation<Value, Never>? = lock.withLock {
            guard !done else { return nil }
            done = true
            guard let continuation else { early = value; return nil }
            self.continuation = nil
            return continuation
        }
        waiting?.resume(returning: value)
    }

    /// Run `start` (which must eventually call `resume`), and give up with
    /// `timeout` after `seconds`. The caller is free the moment either fires.
    static func race(within seconds: TimeInterval, timeout: Value, _ start: (OnceResume<Value>) -> Void) async -> Value {
        let once = OnceResume<Value>()
        return await withCheckedContinuation { continuation in
            once.install(continuation)
            start(once)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0, seconds)) { once.resume(timeout) }
        }
    }
}

@MainActor
enum CatalogQuitRecovery {

    nonisolated static let filePrefix = "catalog.recovery-"

    /// `catalog.recovery-<stamp>.json` beside `catalogURL`.
    static func url(besideCatalog catalogURL: URL, now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return catalogURL.deletingLastPathComponent().appendingPathComponent(filePrefix + formatter.string(from: now) + ".json")
    }

    /// The quit path's last resort (awaited, bounded). `because` is why the
    /// normal save did not happen; `changes` is how many saves had not
    /// landed (the alert's N).
    static func writeCopy(model: VideoScanModel, because: String, changes: Int,
                          within seconds: TimeInterval) async -> ImportToSQLiteQuit.SaveOutcome {
        let target = url(besideCatalog: URL(fileURLWithPath: model.catalogStore.fileLocation))
        model.catalogQuitNote(startLine(model, because: because, target: target))
        let write = model.catalogStore.recoveryCopyWriter(records: model.records)
        let failure = await OnceResume<String?>.race(within: seconds, timeout: "it did not finish within \(seconds.quitWords) s") { once in
            DispatchQueue.global(qos: .userInitiated).async { once.resume(write(target)) }
        }
        return outcome(model, failure: failure, target: target, because: because, changes: changes)
    }

    /// The same, for `applicationWillTerminate` (synchronous; the wait is
    /// bounded by a semaphore so a stalled volume cannot hold the exit).
    static func writeCopyBlocking(model: VideoScanModel, because: String, changes: Int,
                                  within seconds: TimeInterval) -> ImportToSQLiteQuit.SaveOutcome {
        let target = url(besideCatalog: URL(fileURLWithPath: model.catalogStore.fileLocation))
        model.catalogQuitNote(startLine(model, because: because, target: target))
        let write = model.catalogStore.recoveryCopyWriter(records: model.records)
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = write(target)
            done.signal()
        }
        let failure = done.wait(timeout: .now() + max(0, seconds)) == .success
            ? box.value : "it did not finish within \(seconds.quitWords) s"
        return outcome(model, failure: failure, target: target, because: because, changes: changes)
    }

    private static func startLine(_ model: VideoScanModel, because: String, target: URL) -> String {
        "START recovery copy — \(because); writing the in-memory catalog (\(model.records.count) records) to "
            + "\(target.lastPathComponent) beside catalog.json (the catalog's own format, atomic publish, full fsync)"
    }

    private static func outcome(_ model: VideoScanModel, failure: String?, target: URL, because: String,
                                changes: Int) -> ImportToSQLiteQuit.SaveOutcome {
        if let failure {
            model.catalogQuitNote("OUTCOME recovery copy FAILED — \(failure); catalog.json does not carry the last "
                + "\(changes) unsaved change(s)")
            return .unsaved(words: "\(because); the recovery copy also failed: \(failure)", changes: changes)
        }
        model.catalogQuitNote("OUTCOME recovery copy written — \(target.path). It is NOT merged into the catalog: "
            + "the next launch says it is there. To use it: quit, move catalog.json aside, rename the copy to catalog.json.")
        return .recoveryCopy(target)
    }

    // MARK: - applicationWillTerminate

    /// The terminal save, CHECKED (codex round 2 P1): the writer must drain
    /// within the bound (else the synchronous save is skipped — it would
    /// block the main thread behind the stalled writer); a save that fails
    /// is followed by the recovery copy. Every branch is logged.
    static func saveAtTermination(model: VideoScanModel,
                                  writerDeadline: TimeInterval = ImportToSQLiteQuit.writerDeadline) -> ImportToSQLiteQuit.SaveOutcome {
        let store = model.catalogStore
        let pending = store.savesNotLanded
        guard store.writeQueueDrainsBlocking(within: writerDeadline) else {
            let words = "a catalog save has not finished within \(writerDeadline.quitWords) s (the writer is stalled)"
            model.catalogQuitNote("app exit — \(words); the synchronous save is SKIPPED — writing a recovery copy instead")
            return writeCopyBlocking(model: model, because: words, changes: max(pending, 1), within: writerDeadline)
        }
        if model.saveCatalogNow() { return .saved }
        let words = "the catalog could not be saved: \(store.lastWriteError?.persistentDescription ?? "unknown")"
        model.catalogQuitNote("app exit — \(words) — writing a recovery copy")
        return writeCopyBlocking(model: model, because: words, changes: max(pending, 1), within: writerDeadline)
    }

    // MARK: - The next launch

    /// "N recovery cop(ies) …" when any `catalog.recovery-*.json` is beside
    /// the catalog; nil otherwise. A directory listing, nothing decoded.
    nonisolated static func launchNotice(catalogURL: URL) -> String? {
        let folder = catalogURL.deletingLastPathComponent()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(".json") }.sorted()
        guard !names.isEmpty else { return nil }
        return "\(names.count) catalog recovery cop\(names.count == 1 ? "y" : "ies") from a quit that could not save "
            + "\(names.count == 1 ? "is" : "are") beside the catalog: \(names.joined(separator: ", ")). "
            + "Nothing was merged. To use one: quit, move catalog.json aside, rename the copy to catalog.json; "
            + "move the copy away once you have decided."
    }

    /// The single box the blocking write hands its result through.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}

extension TimeInterval {
    /// "30", "0.3" — a bound in the quit lines' words.
    var quitWords: String { String(format: "%g", self) }
}

extension VideoScanModel {

    /// The one sink for the quit's catalog lines: console + catalog.log,
    /// videoscan.log, the unified log.
    func catalogQuitNote(_ line: String) {
        log("Catalog quit: " + line)
        appLog.write("[catalog-quit] " + line)
        quitLog.notice("\(line, privacy: .public)")
    }

    /// At launch: say so when a recovery copy is beside the catalog (never merged).
    func announceCatalogRecoveryCopies() {
        guard let notice = CatalogQuitRecovery.launchNotice(catalogURL: URL(fileURLWithPath: catalogStore.fileLocation)) else { return }
        catalogQuitNote(notice)
    }
}
