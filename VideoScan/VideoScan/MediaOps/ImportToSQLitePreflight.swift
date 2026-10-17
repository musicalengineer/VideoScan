// ImportToSQLitePreflight.swift
// The app's own refusals BEFORE Import to SQLite does any work (Rick
// 2026-10-17): facts the Core importer cannot know (unsaved changes, another
// MFO job, a target already on disk) and the two gate conditions whose
// words a person should read in the row before the importer's own gate
// repeats them (the report's generation, the audit's per-row results).
//
// PURE: the facts are gathered by the job (a few small reads, off the main
// actor); this type only judges them, so every refusal has a unit test and
// the words are pinned. Every condition that can say no is listed; the row
// shows them all, not just the first (the person fixes them in one pass).
//
// (For Rick: a struct of plain inputs and one function that returns a list
// of named refusals — a validator, no I/O.)

import Foundation
import VideoScanCore

struct ImportToSQLitePreflight: Sendable, Equatable {

    /// What the strict reader found beside the catalog.
    enum Report: Sendable, Equatable {
        case missing
        case unreadable(String)
        /// The generation the report's findings describe (nil = an older report without one).
        case generation(Int?)
    }

    /// What catalog-audit.json carries.
    enum Audit: Sendable, Equatable {
        case missing
        case unreadable(String)
        /// Whether the marker has per-row results (an audit from before 2026-10-17 has none).
        case rows(Bool)
    }

    var mode: CatalogImporter.Mode
    var hasUnsavedChanges: Bool
    /// Titles of the other MFO jobs that are active right now.
    var runningJobs: [String]
    /// The catalog FILE's generation (its header) — what the importer will read.
    var catalogGeneration: Int
    var report: Report
    var audit: Audit
    /// catalog.sqlite already beside the catalog (judged in commit mode only).
    var targetExists: Bool

    /// One refusal: its kind (for tests and grouping) and its words (the row).
    struct Refusal: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case unsavedChanges, anotherJobRunning, reportMissing, reportUnreadable, reportStale
            case auditMissing, auditUnreadable, auditNoRowResults, targetExists
        }
        let kind: Kind
        let words: String
    }

    static let runAuditThenVerify = "run Audit Catalog, then Verify Catalog, then try again"

    /// Every refusal, in the order a person would fix them: the app's own
    /// state first, then the files, then the target.
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
        out += reportRefusals
        out += auditRefusals
        if mode == .commit, targetExists {
            out.append(Refusal(kind: .targetExists,
                               words: "catalog.sqlite already exists beside the catalog — move it aside first; nothing was written"))
        }
        return out
    }

    private var reportRefusals: [Refusal] {
        switch report {
        case .missing:
            return [Refusal(kind: .reportMissing, words: "no Verify Catalog report — \(Self.runAuditThenVerify)")]
        case .unreadable(let why):
            return [Refusal(kind: .reportUnreadable, words: "the Verify Catalog report can't be read (\(why)) — \(Self.runAuditThenVerify)")]
        case .generation(let described):
            guard described != catalogGeneration else { return [] }
            let what = described.map { "generation \($0)" } ?? "an unknown generation"
            return [Refusal(kind: .reportStale,
                            words: "the Verify Catalog report describes \(what); the catalog is at generation "
                                + "\(catalogGeneration) — \(Self.runAuditThenVerify)")]
        }
    }

    private var auditRefusals: [Refusal] {
        switch audit {
        case .missing:
            return [Refusal(kind: .auditMissing, words: "no Audit Catalog marker — \(Self.runAuditThenVerify)")]
        case .unreadable(let why):
            return [Refusal(kind: .auditUnreadable, words: "catalog-audit.json can't be read (\(why)) — \(Self.runAuditThenVerify)")]
        case .rows(let hasRows):
            guard !hasRows else { return [] }
            return [Refusal(kind: .auditNoRowResults,
                            words: "the last Audit Catalog carries no per-row results (a run from before this build) — "
                                + Self.runAuditThenVerify)]
        }
    }
}
