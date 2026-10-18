// ImportToSQLiteQuit.swift
// Quitting while Import to SQLite holds the catalog's writes (codex
// 2026-10-17 P1, docs/reviews/codex/codex-review-one-job-import-write-hold-2026-10-17.md;
// round 2: docs/reviews/codex/codex-review-import-quit-path-hold-drain-2026-10-17.md).
// One sentence: a quit during an import Stops it, waits (bounded) for it to
// let go of the catalog, then saves the edits it held — and if that save
// cannot land, writes a recovery copy, and if THAT cannot land, keeps the
// app open unless the person chooses to lose the changes.
// Kept out of ImportToSQLiteJob.swift on purpose: the job never saves the
// catalog itself (MOPS-16 sensor); the quit path does, once the hold is gone.
//
// Round 2 (codex, 2 P1 + 1 P2):
//   * P1 late COMMIT: the importer writes only a STAGING folder and
//     publishes onto catalog.sqlite through a gate Stop closes
//     (CatalogImporter+Staging, ImportStopFlag.claimPublish). A forced
//     release therefore cannot let a late COMMIT reach catalog.sqlite; the
//     log says which of the two happened.
//   * P1 failed persistence: `settleAndSave` returns a `SaveOutcome`;
//     `terminateReply` turns `.unsaved` into an alert whose default keeps
//     the app open.
//   * P2 stalled writer: before the synchronous save the quit asks the
//     store whether every admitted save drains within `writerDeadline`
//     (`waitForWriterToDrain`, awaited — the main thread is free). "Stalled"
//     = it did not; then the synchronous save is SKIPPED (it would block the
//     main thread on `writeQueue.sync` behind the stalled write) and the
//     recovery copy — written off `writeQueue` — is the save.
//
// (For Rick: join the worker with a timeout, then flush; on timeout, break
// the lock it holds — the process is exiting — and flush regardless; if the
// flush itself cannot reach the disk, dump to a side file; if even that
// fails, refuse to exit unless told to.)

import AppKit
import Foundation

@MainActor
enum ImportToSQLiteQuit {
    /// How long the quit waits for a Stopped import to end.
    static let deadline: TimeInterval = 30
    /// How long the quit waits for saves already admitted to drain before it
    /// calls the writer stalled and skips the synchronous save.
    static let writerDeadline: TimeInterval = 30

    /// What the quit's save came to. Only `.unsaved` stops a quit.
    enum SaveOutcome: Equatable {
        /// catalog.json is durable with everything in memory.
        case saved
        /// catalog.json is not, but this copy beside it is.
        case recoveryCopy(URL)
        /// Neither landed: `words` say why; `changes` saves had not landed.
        case unsaved(words: String, changes: Int)
    }

    /// Stop + bounded wait + forced release (when needed), then the save or
    /// its recovery copy. Never blocks the main thread behind the writer.
    static func settleAndSave(job: ImportToSQLiteJob?, model: VideoScanModel,
                              deadline: TimeInterval = deadline,
                              writerDeadline: TimeInterval = writerDeadline) async -> SaveOutcome {
        if let job, job.state.isActive {
            model.importToSQLiteNote("quit — stopping the import; waiting up to \(deadline.quitWords) s for it to roll back and let go of the catalog")
            job.cancel()
            if await job.waitForEnd(deadline: deadline) {
                model.importToSQLiteNote("quit — the import ended (\(endWords(job.state))); its hold is released; saving the held catalog edits")
            }
        }
        releaseHoldIfStillHeld(model: model, deadline: deadline, job: job)
        return await saveOrRecover(model: model, writerDeadline: writerDeadline)
    }

    /// The durable save — unless the writer is stalled — else the recovery copy.
    static func saveOrRecover(model: VideoScanModel, writerDeadline: TimeInterval) async -> SaveOutcome {
        let store = model.catalogStore
        let pending = store.savesNotLanded
        guard await store.waitForWriterToDrain(within: writerDeadline) else {
            let words = "a catalog save has not finished within \(writerDeadline.quitWords) s (the writer is stalled)"
            model.importToSQLiteNote("quit — \(words); the synchronous save is SKIPPED so the quit cannot hang behind it — writing a recovery copy instead")
            return await CatalogQuitRecovery.writeCopy(model: model, because: words, changes: max(pending, 1), within: writerDeadline)
        }
        if model.saveCatalogNow() {
            model.importToSQLiteNote("quit — the held catalog edits are saved (durable)")
            return .saved
        }
        let words = "the held catalog edits could NOT be saved: \(store.lastWriteError?.persistentDescription ?? "unknown")"
        model.importToSQLiteNote("quit — \(words) — writing a recovery copy")
        return await CatalogQuitRecovery.writeCopy(model: model, because: words, changes: max(pending, 1), within: writerDeadline)
    }

    /// The AppDelegate's entry, on every `.terminateLater` path: settle a
    /// running import and answer the terminate question. No import → no
    /// work here (willTerminate's checked save follows).
    static func settleForAppQuit(job: ImportToSQLiteJob?, model: VideoScanModel?) async -> NSApplication.TerminateReply {
        guard let job, let model else { return .terminateNow }
        appLog.write("quit: Import to SQLite is running — stopping it, then saving the catalog edits it held")
        let outcome = await settleAndSave(job: job, model: model)
        return terminateReply(for: outcome, model: model, ask: askToQuitAndLose)
    }

    /// `.saved` / `.recoveryCopy` quit; `.unsaved` asks — and the default
    /// answer keeps VideoScan open. `ask` returns true for "quit anyway".
    static func terminateReply(for outcome: SaveOutcome, model: VideoScanModel,
                               ask: (_ words: String, _ changes: Int) -> Bool) -> NSApplication.TerminateReply {
        guard case .unsaved(let words, let changes) = outcome else { return .terminateNow }
        let quit = ask(words, changes)
        model.catalogQuitNote(quit
            ? "quit — the person chose Quit and lose \(changes) unsaved change(s): \(words)"
            : "quit CANCELLED — VideoScan stays open with \(changes) unsaved change(s) in memory: \(words)")
        return quit ? .terminateNow : .terminateCancel
    }

    /// The alert: the store's words, "Keep VideoScan open" (default) or
    /// "Quit and lose N unsaved change(s)".
    static func askToQuitAndLose(words: String, changes: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "The catalog could not be saved"
        alert.informativeText = words + "\n\nNo recovery copy could be written either. Keep VideoScan open, "
            + "free some space or fix the disk, then quit again."
        alert.addButton(withTitle: "Keep VideoScan open")
        alert.addButton(withTitle: "Quit and lose \(changes) unsaved change\(changes == 1 ? "" : "s")")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Past the bound (or on a path that skipped the wait, e.g.
    /// applicationWillTerminate alone): release the hold by force so the
    /// quit's save can land, and say — truthfully — what the abandoned
    /// import can still do: Stop holds its publish gate, so it can no
    /// longer reach catalog.sqlite unless it had already begun publishing.
    static func releaseHoldIfStillHeld(model: VideoScanModel, deadline: TimeInterval, job: ImportToSQLiteJob? = nil) {
        guard model.catalogStore.writeHold != nil else { return }
        job?.cancel()
        let held = model.catalogStore.releaseWriteHold()
        let fate = job?.publishBegan == true
            ? "it had already begun publishing its verified import as catalog.sqlite, which Stop can no longer prevent"
            : "it writes only its staging folder (catalog.sqlite.importing-…) and Stop holds the publish gate, so "
                + "catalog.sqlite cannot appear — a COMMIT still in flight lands in staging, which the next import moves aside"
        model.importToSQLiteNote("quit — the import did not end within \(deadline.quitWords) s; its hold is released by force — "
            + "the import is abandoned: \(fate); \(held) save(s) were held; saving the held catalog edits")
    }

    /// The row's terminal state in the quit line's words.
    private static func endWords(_ state: MediaFileOperationState) -> String {
        switch state {
        case .cancelled, .cancelling: return "Stopped"
        case .finished: return "Done"
        case .failed: return "Failed"
        case .running: return "still running"
        }
    }
}
