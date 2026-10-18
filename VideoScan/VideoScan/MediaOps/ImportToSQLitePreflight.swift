// ImportToSQLitePreflight.swift
// The app's own refusals BEFORE Import to SQLite does any work (Rick
// 2026-10-17): facts the Core importer cannot know — unsaved changes,
// another MFO job, a target already on disk.
//
// Since "one action verb" (Rick 2026-10-17 evening) the job runs its own
// Audit Catalog and Verify Catalog inside its write hold, so the two
// refusals about an older report or an audit without per-row results are
// gone: the job makes fresh ones. Open Delete Duplicates plans and Archive
// Angel batches still refuse — through the importer's gate (phase 3).
//
// PURE: the facts are gathered by the job (one small read, off the main
// actor); this type only judges them, so every refusal has a unit test and
// the words are pinned. Every condition that can say no is listed; the row
// shows them all, not just the first (the person fixes them in one pass).
//
// (For Rick: a struct of plain inputs and one function that returns a list
// of named refusals — a validator, no I/O.)

import Foundation
import VideoScanCore

struct ImportToSQLitePreflight: Sendable, Equatable {

    var mode: CatalogImporter.Mode
    var hasUnsavedChanges: Bool
    /// Titles of the other MFO jobs that are active right now.
    var runningJobs: [String]
    /// The catalog FILE's generation (its header) when the job started —
    /// named in the START line; the audit's own save moves it on.
    var catalogGeneration: Int
    /// catalog.sqlite already beside the catalog (judged in commit mode only).
    var targetExists: Bool

    /// One refusal: its kind (for tests and grouping) and its words (the row).
    struct Refusal: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case unsavedChanges, anotherJobRunning, targetExists
        }
        let kind: Kind
        let words: String
    }

    /// Every refusal, in the order a person would fix them: the app's own
    /// state first, then the target.
    var refusals: [Refusal] {
        var out: [Refusal] = []
        if hasUnsavedChanges {
            out.append(Refusal(kind: .unsavedChanges,
                               words: "the catalog has unsaved changes — wait a few seconds for the save, then try again"))
        }
        if !runningJobs.isEmpty {
            out.append(Refusal(kind: .anotherJobRunning,
                               words: "\(runningJobs.joined(separator: ", ")) is running — one job at a time while the catalog is read; "
                                   + "wait for it to finish (or stop it)"))
        }
        if mode == .commit, targetExists {
            out.append(Refusal(kind: .targetExists,
                               words: "catalog.sqlite already exists beside the catalog — move it aside first; nothing was written"))
        }
        return out
    }
}
