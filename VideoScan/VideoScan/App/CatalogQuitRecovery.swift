// CatalogQuitRecovery.swift
// Codex 2026-10-17 round 2 P1 ("failed persistence still permits
// termination", docs/reviews/codex/codex-review-import-quit-path-hold-drain-2026-10-17.md).
// One sentence: when the quit cannot save the catalog, it asks first —
// Keep Open (the default) or Quit and Keep a Rescue Copy (GH #356, Rick's
// ruling 2026-10-21) — and a quit that goes ahead writes the changes that
// did not save to a recovery copy beside the catalog.
//
//   * Before the quit is decided (`finalCommitBeforeQuit`, from
//     applicationShouldTerminate): one final commit; if a job holds catalog
//     writes, wait up to `holdWait` (~10 s) for it to let go; if it still
//     fails, "VideoScan couldn't save N changes: <the committer's words>"
//     with [Keep Open] (default) and [Quit and Keep a Rescue Copy].
//   * Quit and Keep a Rescue Copy writes the copy THEN, while the quit can
//     still be cancelled, and approves the quit only once it is durable
//     (published with a full fsync, read back byte-equal). If the copy
//     fails too, the quit is CANCELLED: "couldn't save the changes or a
//     rescue copy — VideoScan stays open", the edits in memory (Codex #381
//     P1). willTerminate writes no second copy when nothing changed since.
//   * A cancelled quit (either way) reopens the caption / dossier shutdown
//     latch; work the quit already stopped is named in the alerts as not
//     restarted (Codex #381 P2).
//   * Under catalog.sqlite the copy holds ONLY the unsaved records (the
//     committer's delta) and the generation they were based on — never the
//     whole catalog (5 of 5 records when 1 changed, GH #356). Under the JSON
//     authority (no committer) it is still the whole in-memory catalog.
//
//   * The copy: `catalog.recovery-<yyyyMMdd-HHmmss>.json` beside
//     catalog.json — the store's own payload and encoder
//     (`CatalogStore.recoveryCopyWriter`), published with AtomicFilePublish
//     (`.fullFsync`), off the main actor and BOUNDED: a stalled volume
//     cannot hang the quit; past the bound the copy counts as failed.
//   * Never merged: the next launch says the copy is there (console +
//     catalog.log + videoscan.log) and how to use it; nothing reads it back.
//   * A READ-ONLY session (a viewer, or a launch that opened the catalog
//     read-only) saves nothing by design, so its quit writes NO copy
//     (M5 viewer, 2026-10-21: every viewer quit wrote an 80 MB copy, because
//     the refused commit read as "could not be saved: unknown").
//   * Under catalog.sqlite (the catalog.cutover latch beside the catalog)
//     the copy keeps the JSON catalog format — the only format a dump of the
//     in-memory records has today — but the words never say to rename it to
//     catalog.json: with the latch, catalog.json is not the catalog.
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

    /// How long the quit waits for saves already admitted to drain before it
    /// calls the writer stalled and skips the synchronous save. (Moved here
    /// from ImportToSQLiteQuit, retired 2026-10-20.)
    static let writerDeadline: TimeInterval = 30

    /// What the quit's save came to. (Moved here from ImportToSQLiteQuit,
    /// retired 2026-10-20.)
    enum SaveOutcome: Equatable {
        /// The catalog is durable with everything in memory.
        case saved
        /// It is not, but this copy beside it is.
        case recoveryCopy(URL)
        /// Neither landed: `words` say why; `changes` saves had not landed.
        case unsaved(words: String, changes: Int)
        /// The session is read-only (`words`): nothing to save, no copy.
        case readOnlySession(words: String)
    }

    nonisolated static let filePrefix = "catalog.recovery-"

    /// `catalog.recovery-<stamp>.json` beside `catalogURL` — `-2`, `-3` … when
    /// a copy of that second is already there (a copy before the quit and a
    /// fresher one at exit never overwrite each other).
    static func url(besideCatalog catalogURL: URL, now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = catalogURL.deletingLastPathComponent()
        let stem = filePrefix + formatter.string(from: now)
        var candidate = folder.appendingPathComponent(stem + ".json")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path), n < 1_000 {
            candidate = folder.appendingPathComponent("\(stem)-\(n).json")
            n += 1
        }
        return candidate
    }

    /// The quit path's last resort, for `applicationWillTerminate`
    /// (synchronous; the wait is bounded by a semaphore so a stalled volume
    /// cannot hold the exit). `because` is why the normal save did not
    /// happen; `changes` is how many saves had not landed. (The awaited
    /// twin, used only by Import to SQLite's quit settle, was retired with
    /// it 2026-10-20.)
    /// Private: `saveAtTermination` is the one caller, after its read-only gate.
    private static func writeCopyBlocking(model: VideoScanModel, because: String, changes: Int,
                                          within seconds: TimeInterval, rescued earlier: RescueCopy?) -> SaveOutcome {
        let catalogURL = URL(fileURLWithPath: model.catalogStore.fileLocation)
        let target = url(besideCatalog: catalogURL)
        let sqlite = latchNamesSQLite(besideCatalog: catalogURL)
        let rescued = rescueRecords(model)
        // Codex #381 P1: the copy was written (and read back) while the quit
        // could still be cancelled; when nothing changed since, it IS the
        // rescue — no second file.
        if let earlier, earlier.holds(rescued) {
            model.catalogQuitNote("OUTCOME recovery copy already written before the quit — \(earlier.url.path); "
                + "nothing changed since, so no second copy. " + useWords(sqlite: sqlite))
            return .recoveryCopy(earlier.url)
        }
        model.catalogQuitNote(startLine(model, rescued: rescued.count, because: because, target: target, sqlite: sqlite))
        let write = model.catalogStore.recoveryCopyWriter(records: rescued, generation: model.catalogGenerationForStamp)
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = write(target)
            done.signal()
        }
        let failure = done.wait(timeout: .now() + max(0, seconds)) == .success
            ? box.value : "it did not finish within \(seconds.quitWords) s"
        return outcome(model, failure: failure, target: target, because: because, changes: changes, sqlite: sqlite)
    }

    /// The catalog.cutover latch is beside the catalog: catalog.sqlite is
    /// the catalog and catalog.json is its frozen history copy. A file fact
    /// (one stat), so the quit and the next launch read it the same way.
    nonisolated static func latchNamesSQLite(besideCatalog catalogURL: URL) -> Bool {
        CatalogAuthority.latchNamesSQLite(in: catalogURL.deletingLastPathComponent())
    }

    /// What a person can do with a copy, by authority. Under catalog.sqlite
    /// nothing opens it as the catalog — it is the evidence of what did not
    /// save (the JSON catalog format).
    nonisolated static func useWords(sqlite: Bool) -> String {
        sqlite
            ? "It holds the changes that did not reach catalog.sqlite, in the older JSON catalog format; "
                + "catalog.sqlite is the catalog, so do NOT rename it to catalog.json — compare it, then move it away."
            : "To use it: quit, move catalog.json aside, rename the copy to catalog.json."
    }

    /// GH #356: what the copy holds — under catalog.sqlite only the records
    /// that did not save (the committer's delta); else the whole catalog.
    static func rescueRecords(_ model: VideoScanModel) -> [VideoRecord] {
        model.catalogCutover.committer?.unsavedRecords() ?? model.records
    }

    private static func startLine(_ model: VideoScanModel, rescued: Int, because: String, target: URL, sqlite: Bool) -> String {
        let what = model.catalogCutover.committer == nil
            ? "the in-memory catalog (\(rescued) records)"
            : "the \(rescued) unsaved record(s) of \(model.records.count), based on generation \(model.catalogGenerationForStamp),"
        return "START recovery copy — \(because); writing \(what) to "
            + "\(target.lastPathComponent) beside "
            + (sqlite ? "catalog.sqlite (the older JSON catalog format, atomic publish, full fsync)"
                      : "catalog.json (the catalog's own format, atomic publish, full fsync)")
    }

    private static func outcome(_ model: VideoScanModel, failure: String?, target: URL, because: String,
                                changes: Int, sqlite: Bool) -> SaveOutcome {
        if let failure {
            model.catalogQuitNote("OUTCOME recovery copy FAILED — \(failure); \(sqlite ? "catalog.sqlite" : "catalog.json") does not carry the last "
                + "\(changes) unsaved change(s)")
            return .unsaved(words: "\(because); the recovery copy also failed: \(failure)", changes: changes)
        }
        model.catalogQuitNote("OUTCOME recovery copy written — \(target.path). It is NOT merged into the catalog: "
            + "the next launch says it is there. " + useWords(sqlite: sqlite))
        return .recoveryCopy(target)
    }

    // MARK: - applicationWillTerminate

    /// The terminal save, CHECKED (codex round 2 P1): the writer must drain
    /// within the bound (else the synchronous save is skipped — it would
    /// block the main thread behind the stalled writer); a save that fails
    /// is followed by the recovery copy. Every branch is logged.
    /// `rescued`: the copy `finalCommitBeforeQuit` already wrote, if any.
    static func saveAtTermination(model: VideoScanModel,
                                  writerDeadline: TimeInterval = CatalogQuitRecovery.writerDeadline,
                                  rescued: RescueCopy? = nil) -> SaveOutcome {
        // A read-only session saves nothing by design — no copy (a viewer
        // never writes one). Its refused commit is not data at risk.
        let store = model.catalogStore
        let pending = store.savesNotLanded
        if let readOnly = model.readOnlyFacts.readOnlyWords {
            // Codex cycle #116 F1: a session that turned read-only after
            // accepting edits it could not commit still rescues them.
            if let why = model.unsavedFromWritableSession, (model.catalogCutover.committer?.changedRecordCount() ?? 1) > 0 {
                let words = "changes accepted while this session was writable did not reach catalog.sqlite (\(why)); now \(readOnly)"
                model.catalogQuitNote("app exit — \(words) — writing a recovery copy")
                return writeCopyBlocking(model: model, because: words, changes: max(pending, 1), within: writerDeadline, rescued: rescued)
            }
            model.catalogQuitNote("app exit — \(readOnly); nothing is saved this session, so no recovery copy is written")
            return .readOnlySession(words: readOnly)
        }
        guard store.writeQueueDrainsBlocking(within: writerDeadline) else {
            let words = "a catalog save has not finished within \(writerDeadline.quitWords) s (the writer is stalled)"
            model.catalogQuitNote("app exit — \(words); the synchronous save is SKIPPED — writing a recovery copy instead")
            return writeCopyBlocking(model: model, because: words, changes: max(pending, 1), within: writerDeadline, rescued: rescued)
        }
        if model.saveCatalogNow() { return .saved }
        let words = "the catalog could not be saved: \(failureWords(model))"
        model.catalogQuitNote("app exit — \(words) — writing a recovery copy")
        return writeCopyBlocking(model: model, because: words, changes: max(pending, 1), within: writerDeadline, rescued: rescued)
    }

    // MARK: - applicationShouldTerminate (GH #356)

    /// How long the quit waits for a job's hold on catalog writes to clear
    /// (Rick's ruling, 2026-10-21: "wait up to ~10 s").
    static let holdWait: TimeInterval = 10

    /// What the person is asked when the quit's final commit fails.
    struct QuitQuestion: Equatable {
        /// Records whose current state is durable nowhere in catalog.sqlite.
        let changes: Int
        /// The committer's words for why (never "unknown").
        let words: String
        /// Work the quit already stopped (file operations, a caption /
        /// dossier batch) — Keep Open does not restart it (Codex #381 P2).
        var stopped: [String] = []

        var message: String {
            changes == 0 ? "VideoScan couldn't save your last changes"
                : "VideoScan couldn't save \(changes) change\(changes == 1 ? "" : "s")"
        }

        var information: String {
            "\(words.prefix(1).uppercased())\(words.dropFirst()).\n\n"
                + "Keep Open leaves VideoScan running with the changes in memory, so you can fix the cause and save them. "
                + "Quit and Keep a Rescue Copy writes them to a file beside the catalog (catalog.recovery-….json); "
                + "they are not in the catalog, and the next launch says where the copy is."
                + CatalogQuitRecovery.stoppedWords(stopped)
        }
    }

    /// Codex #381 P1: the rescue copy could not be written, so the quit is
    /// cancelled — what the person is told.
    struct RescueFailure: Equatable {
        let changes: Int
        /// The commit's words and the copy's.
        let words: String
        var stopped: [String] = []

        var message: String { "VideoScan couldn't save the changes or a rescue copy — VideoScan stays open" }

        var information: String {
            "\(words.prefix(1).uppercased())\(words.dropFirst()).\n\n"
                + (changes == 1 ? "The change is" : changes == 0 ? "Your last changes are" : "The \(changes) changes are")
                + " kept in memory. Free space on the catalog's disk, or fix the cause above, then save or quit again."
                + CatalogQuitRecovery.stoppedWords(stopped)
        }
    }

    nonisolated static func stoppedWords(_ stopped: [String]) -> String {
        stopped.isEmpty ? "" : "\n\nStopped for the quit, and not restarted by staying open: \(stopped.joined(separator: "; "))."
    }

    enum QuitChoice: Equatable {
        case keepOpen
        case quitKeepingRescueCopy
    }

    /// A rescue copy written — fsync'd and read back — while the quit could
    /// still be cancelled, and exactly what it holds (id → fingerprint), so
    /// willTerminate writes no second copy when nothing changed since.
    struct RescueCopy: Equatable {
        let url: URL
        let prints: [UUID: CatalogChangeDetector.Fingerprint]

        init(url: URL, records: [VideoRecord]) {
            self.url = url
            prints = Self.prints(of: records)
        }

        func holds(_ records: [VideoRecord]) -> Bool { Self.prints(of: records) == prints }

        private static func prints(of records: [VideoRecord]) -> [UUID: CatalogChangeDetector.Fingerprint] {
            let fingerprints = CatalogChangeDetector.fingerprints(of: records.map(VideoRecordDTO.init))
            return Dictionary(zip(records.map(\.id), fingerprints), uniquingKeysWith: { first, _ in first })
        }
    }

    /// What the quit comes to, decided while it can still be cancelled.
    enum QuitDecision: Equatable {
        /// Saved, nothing at risk, or no committer: the quit goes on.
        case quit
        /// The person chose the rescue copy and it is durable: the quit goes on.
        case quitWithRescue(RescueCopy)
        /// Keep Open, or the rescue copy failed: VideoScan stays open.
        case stayOpen

        var proceeds: Bool { self != .stayOpen }
    }

    /// The quit's final commit, tried while the quit can still be cancelled.
    /// `.quit` = saved, nothing to save, or no committer; `.quitWithRescue` =
    /// the person chose Quit and Keep a Rescue Copy and the copy is written
    /// NOW — published with a full fsync and read back — before the quit is
    /// approved (Codex #381 P1); `.stayOpen` = Keep Open, or the copy could
    /// not be written (then `tell` says so: "couldn't save the changes or a
    /// rescue copy — VideoScan stays open"; the edits stay in memory).
    /// `ask` / `tell` are the alerts (`askWithAlert` / `tellWithAlert`);
    /// tests pass their own. `stopped`: work the quit already stopped, named
    /// in both alerts. Every branch is one line through the quit's sink.
    static func finalCommitBeforeQuit(model: VideoScanModel?, holdWait: TimeInterval = CatalogQuitRecovery.holdWait,
                                      rescueWithin: TimeInterval = CatalogQuitRecovery.writerDeadline,
                                      stopped: [String] = [],
                                      ask: (QuitQuestion) -> QuitChoice,
                                      tell: (RescueFailure) -> Void) async -> QuitDecision {
        guard let model, let committer = model.catalogCutover.committer else { return .quit }
        if quitNeedsNoQuestion(model: model) { return .quit }
        if committer.isHeldByJob {
            model.catalogQuitNote("quit — a job holds catalog writes; waiting up to \(holdWait.quitWords) s for it to let go")
            let deadline = Date().addingTimeInterval(holdWait)
            while committer.isHeldByJob, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if model.saveCatalogNow() {
                model.catalogQuitNote("quit — the hold cleared and the final commit landed")
                return .quit
            }
        }
        let question = QuitQuestion(changes: committer.changedRecordCount(), words: failureWords(model), stopped: stopped)
        model.catalogQuitNote("quit — \(question.message): \(question.words) — asking Keep Open / Quit and Keep a Rescue Copy")
        guard ask(question) == .quitKeepingRescueCopy else {
            model.catalogQuitNote("quit cancelled — Keep Open: the changes stay in memory")
            return .stayOpen
        }
        model.catalogQuitNote("quit — Quit and Keep a Rescue Copy: writing the unsaved changes to a recovery copy before the quit goes on")
        let because = "the catalog could not be saved: \(question.words)"
        let (written, copy) = await writeRescueBeforeQuit(model: model, because: because, changes: question.changes, within: rescueWithin)
        if case .recoveryCopy = written { return .quitWithRescue(copy) }
        // Anything but a durable copy cancels the quit (`outcome` gives only
        // .recoveryCopy or .unsaved; the default words are a backstop).
        var words = "\(because); the recovery copy was not written"
        if case .unsaved(let said, _) = written { words = said }
        let failure = RescueFailure(changes: question.changes, words: words, stopped: stopped)
        model.catalogQuitNote("quit cancelled — \(failure.message): \(words). The changes stay in memory.")
        tell(failure)
        return .stayOpen
    }

    /// The rescue copy, awaited (the main actor stays free: the encode and
    /// publish run on a global queue) and BOUNDED by `seconds` — a stalled
    /// volume counts as a failed copy and the quit is cancelled. A write
    /// that finishes after the bound leaves a file the words called failed:
    /// the conservative side (VideoScan stays open with the edits).
    /// The `RescueCopy` fingerprints are taken in the same main-actor turn
    /// as the payload, before the await — what the file holds, even if a
    /// record changes while the copy is written.
    /// Memory: the payload of the unsaved records only (GH #356) plus, for
    /// the read-back, one copy of its bytes — two × (unsaved records × ~2 KB).
    private static func writeRescueBeforeQuit(model: VideoScanModel, because: String, changes: Int,
                                              within seconds: TimeInterval) async -> (SaveOutcome, RescueCopy) {
        let catalogURL = URL(fileURLWithPath: model.catalogStore.fileLocation)
        let target = url(besideCatalog: catalogURL)
        let sqlite = latchNamesSQLite(besideCatalog: catalogURL)
        let rescued = rescueRecords(model)
        model.catalogQuitNote(startLine(model, rescued: rescued.count, because: because, target: target, sqlite: sqlite))
        let write = model.catalogStore.recoveryCopyWriter(records: rescued, generation: model.catalogGenerationForStamp)
        let copy = RescueCopy(url: target, records: rescued)
        // (For Rick: a future fulfilled by a worker thread or by a timer,
        // whichever is first — `OnceResume.race`.)
        let failure: String? = await OnceResume<String?>.race(within: seconds, timeout: "it did not finish within \(seconds.quitWords) s") { once in
            DispatchQueue.global(qos: .userInitiated).async { once.resume(write(target)) }
        }
        return (outcome(model, failure: failure, target: target, because: because, changes: changes, sqlite: sqlite), copy)
    }

    /// Synchronous fast path: true when the quit needs no question — the
    /// final commit landed, or a read-only session holds nothing it accepted
    /// while writable. (A failed commit leaves the committer blocked, so the
    /// slow path never writes a second time.)
    /// No model or no committer (the JSON authority): willTerminate's checked save decides.
    static func quitNeedsNoQuestion(model: VideoScanModel?) -> Bool {
        guard let model, let committer = model.catalogCutover.committer else { return true }
        if model.readOnlyFacts.readOnlyWords != nil {
            return model.unsavedFromWritableSession == nil || committer.changedRecordCount() == 0
        }
        return model.saveCatalogNow()
    }

    /// The production question: an alert, Keep Open the default (Return).
    static func askWithAlert(_ question: QuitQuestion) -> QuitChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = question.message
        alert.informativeText = question.information
        alert.addButton(withTitle: "Keep Open")
        alert.addButton(withTitle: "Quit and Keep a Rescue Copy")
        return alert.runModal() == .alertFirstButtonReturn ? .keepOpen : .quitKeepingRescueCopy
    }

    /// The production notice when the rescue copy failed: VideoScan stays open.
    static func tellWithAlert(_ failure: RescueFailure) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = failure.message
        alert.informativeText = failure.information
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// GH #359 (QA r2-2), at quit and ONLY after a file-stop: close the store
    /// so this session's -wal is checkpointed into catalog.sqlite (still the
    /// session's file — a latch-only stop) or quarantined (catalog.sqlite was
    /// replaced or moved — the replacement must never replay it), and say
    /// what happened through the one sink. Without a stop this is a no-op and
    /// the quit path is unchanged. Blocks the main thread for at most
    /// `seconds` (the quit's writer deadline, as `writeCopyBlocking` is
    /// bounded — QA r3): the close runs off the main actor; if it has not
    /// finished in time the quit goes on and the words say what to move away
    /// by hand. `close` is the test seam (a close that never returns).
    /// True when the store was stopped and a close was attempted.
    @discardableResult
    static func closeAfterFileStop(model: VideoScanModel, within seconds: TimeInterval = CatalogQuitRecovery.writerDeadline,
                                   close: @escaping @Sendable (any CatalogRepository) async -> Void = { await $0.close() }) -> Bool {
        guard let repository = model.catalogCutover.committer?.repository,
              let stop = repository.fileStopWords else { return false }
        let databasePath = model.catalogCutover.databaseURL?.path ?? "catalog.sqlite"
        model.catalogAuthorityNote("START closing catalog.sqlite at quit after the file check stopped saving — \(stop)")
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await close(repository)
            done.signal()
        }
        guard done.wait(timeout: .now() + max(0, seconds)) == .success else {
            noteTimedOutClose(model, repository, seconds: seconds, databasePath: databasePath)
            return true
        }
        let notes = repository.lastCloseNotes
        for line in notes { model.catalogAuthorityNote(line.replacingOccurrences(of: "Catalog store: ", with: "")) }
        model.catalogAuthorityNote("OUTCOME closed catalog.sqlite at quit — "
            + (notes.isEmpty ? "it is still this session's own file and was closed normally" : "see the quarantine lines above"))
        return true
    }

    /// codex #117 F3: the close did not finish in time. Only a catalog.sqlite
    /// CONFIRMED not to be this session's file lets the quit quarantine this
    /// session's -wal / -shm itself (by inode, without waiting for close).
    /// The same file (a latch-only stop) or an unreadable identity moves
    /// nothing — and the words never tell a person to move the live -wal.
    private static func noteTimedOutClose(_ model: VideoScanModel, _ repository: any CatalogRepository,
                                          seconds: TimeInterval, databasePath: String) {
        let head = "OUTCOME catalog.sqlite could not be closed within \(seconds.quitWords) s — "
        let name = (databasePath as NSString).lastPathComponent
        switch repository.quarantineAfterTimedOutClose() {
        case .quarantined(let lines):
            for line in lines { model.catalogAuthorityNote(line.replacingOccurrences(of: "Catalog store: ", with: "")) }
            model.catalogAuthorityNote(head + "\(name) at \(databasePath) is not this session's file, so this session's "
                + "-wal and -shm were quarantined now (see above): the file there cannot take them.")
        case .stillItsOwnFile, .notOpen:
            model.catalogAuthorityNote(head + "it is still this session's own file. Its own \(name)-wal holds committed "
                + "changes and will be applied at the next open; leave it where it is.")
        case .identityUnreadable(let why):
            model.catalogAuthorityNote(head + "its identity could not be read (\(why)), so nothing was moved. If it is this "
                + "session's file, its own \(name)-wal holds committed changes and will be applied at the next open.")
        }
    }

    /// Why the terminal save failed: under catalog.sqlite the committer's
    /// words (the JSON store's error is not the session's), else the store's.
    private static func failureWords(_ model: VideoScanModel) -> String {
        if let committer = model.catalogCutover.committer {
            return committer.saveRefusal() ?? "catalog.sqlite did not take the commit"
        }
        return model.catalogStore.lastWriteError?.persistentDescription ?? "unknown"
    }

    // MARK: - The next launch

    /// "N recovery cop(ies) …" when any `catalog.recovery-*.json` is beside
    /// the catalog; nil otherwise. A directory listing, nothing decoded.
    nonisolated static func launchNotice(catalogURL: URL) -> String? {
        let sqlite = latchNamesSQLite(besideCatalog: catalogURL)
        let folder = catalogURL.deletingLastPathComponent()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(".json") }.sorted()
        guard !names.isEmpty else { return nil }
        return "\(names.count) catalog recovery cop\(names.count == 1 ? "y" : "ies") from a quit that could not save "
            + "\(names.count == 1 ? "is" : "are") beside the catalog: \(names.joined(separator: ", ")). "
            + "Nothing was merged. "
            + (sqlite ? "catalog.sqlite is the catalog: a copy holds changes that did not save, in the older JSON catalog "
                        + "format — do NOT rename it to catalog.json; compare it, then move it away."
                      : "To use one: quit, move catalog.json aside, rename the copy to catalog.json; "
                        + "move the copy away once you have decided.")
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
