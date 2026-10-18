// ImportToSQLiteQuit.swift
// Quitting while Import to SQLite holds the catalog's writes (codex
// 2026-10-17 P1, docs/reviews/codex/codex-review-one-job-import-write-hold-2026-10-17.md).
// One sentence: a quit during an import Stops it, waits (bounded) for it to
// let go of the catalog, then saves the edits it held — so nothing made
// during the run is lost. Kept out of ImportToSQLiteJob.swift on purpose:
// the job never saves the catalog itself (MOPS-16 sensor); the quit path
// does, once the hold is gone.

import Foundation

/// Quitting while Import to SQLite holds the catalog's writes (codex
/// 2026-10-17 P1). Every save made during the run was held — in memory
/// only — so a quit that saved at once would be refused and the edits lost.
/// The quit path (AppDelegate.applicationShouldTerminate, `.terminateLater`)
/// calls `settleAndSave`: Stop → await the job's end, bounded (the importer
/// rolls its transaction back; the job releases its hold) → the DURABLE
/// save of the held edits → reply. Past the bound the hold is released by
/// force and the edits are saved anyway; the import is abandoned (its open
/// transaction never commits — SQLite rolls it back) and the log says so.
/// (For Rick: join the worker with a timeout, then flush; on timeout, break
/// the lock it holds — the process is exiting — and flush regardless.)
@MainActor
enum ImportToSQLiteQuit {
    /// How long the quit waits for a Stopped import to end.
    static let deadline: TimeInterval = 30

    /// Returns whether the held edits durably reached catalog.json.
    @discardableResult
    static func settleAndSave(job: ImportToSQLiteJob?, model: VideoScanModel, deadline: TimeInterval = deadline) async -> Bool {
        if let job, job.state.isActive {
            model.importToSQLiteNote("quit — stopping the import; waiting up to \(Int(deadline)) s for it to roll back and let go of the catalog")
            job.cancel()
            if await job.waitForEnd(deadline: deadline) {
                model.importToSQLiteNote("quit — the import ended (\(endWords(job.state))); its hold is released; saving the held catalog edits")
            }
        }
        releaseHoldIfStillHeld(model: model, deadline: deadline)
        let saved = model.saveCatalogNow()
        model.importToSQLiteNote(saved
            ? "quit — the held catalog edits are saved (durable)"
            : "quit — the held catalog edits could NOT be saved: \(model.catalogStore.lastWriteError?.persistentDescription ?? "unknown")")
        return saved
    }

    /// The AppDelegate's entry, on every `.terminateLater` path: nothing to
    /// do when no import is running.
    static func settleForAppQuit(job: ImportToSQLiteJob?, model: VideoScanModel?) async {
        guard let job, let model else { return }
        appLog.write("quit: Import to SQLite is running — stopping it, then saving the catalog edits it held")
        await settleAndSave(job: job, model: model)
    }

    /// Past the bound (or on a path that skipped the wait, e.g.
    /// applicationWillTerminate alone): release the hold by force so the
    /// quit's save can land, and say so.
    static func releaseHoldIfStillHeld(model: VideoScanModel, deadline: TimeInterval) {
        guard model.catalogStore.writeHold != nil else { return }
        let held = model.catalogStore.releaseWriteHold()
        model.importToSQLiteNote("quit — the import did not end within \(Int(deadline)) s; its hold is released by force — "
            + "the import is abandoned (its open transaction never commits; SQLite rolls it back); "
            + "\(held) save(s) were held; saving the held catalog edits")
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
