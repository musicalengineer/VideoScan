// JunkDeletionReport.swift
// What a Move to Trash run did, in the person's words — the ONE presenter
// that both Triage's result sheet and the Catalog's ⌘⌫ / row-menu alert
// render (design R6, 2026-10-09: every file that stayed reaches the UI
// with its reason; nothing is console-only). Pure: built once from the
// result when the run finishes, never in a view body.

import Foundation

struct JunkDeletionReport {
    /// One file that did NOT move, and why. (`id` = its position in the
    /// request, so a list of thousands can be lazy and stable.)
    struct Line: Identifiable, Equatable {
        let id: Int
        let filename: String
        let reason: String
    }

    let movedCount: Int
    /// Bytes moved to the Trash: the sum of the moved files' sizes
    /// (design R7). Never called "freed".
    let bytesMoved: Int64
    /// One sentence per non-empty bucket, in a fixed order: moved, held,
    /// couldn't move, already missing, offline, not reached.
    let summary: [String]
    /// EVERY file that did not move, in request order — never truncated.
    let lines: [Line]
    /// A SPLIT pair is a note even when every listed file "moved".
    /// Every settlement warning is surfaced, whatever the headline (Codex
    /// #201 F3): a SPLIT or a change during the move shows the alert even
    /// when every file moved.
    var hasNotes: Bool { !lines.isEmpty || groupNeedsAttention || keptMarker }
    /// A kept concurrent marker on any row (Codex #204) — every door.
    private let keptMarker: Bool
    /// The alert's title — from the result, never the reverse.
    var headline: String {
        lines.isEmpty && (groupNeedsAttention || keptMarker)
            ? "Move to Trash \u{2014} the catalog changed during the move"
            : "Move to Trash \u{2014} some files stayed"
    }
    private let groupNeedsAttention: Bool

    init(_ result: VideoScanModel.JunkDeletionResult) {
        var lines: [Line] = []
        for (i, item) in result.items.enumerated() {
            guard let reason = Self.reason(item.outcome) else { continue }
            lines.append(Line(id: i, filename: item.record.filename, reason: reason))
        }
        self.lines = lines
        self.movedCount = result.succeeded
        self.bytesMoved = result.bytesMoved
        self.summary = Self.summary(result)
        self.groupNeedsAttention = result.groupNeedsAttention
        self.keptMarker = !result.keptMarkerNotes.isEmpty
    }

    /// Why one file did not move; nil when it moved.
    static func reason(_ outcome: VideoScanModel.JunkFileOutcome) -> String? {
        switch outcome {
        case .moved: return nil
        case .held(let why): return why
        case .failed(let error): return "couldn't be moved: \(error.localizedDescription) — nothing was deleted"
        case .missing: return "was already gone — the catalog is updated"
        case .offline: return "its drive isn't connected — skipped; connect it and try again"
        case .cancelled: return "not reached — the run was stopped first"
        }
    }

    private static func summary(_ r: VideoScanModel.JunkDeletionResult) -> [String] {
        func files(_ n: Int) -> String { "\(n) file\(n == 1 ? "" : "s")" }
        var out: [String] = []
        if r.succeeded > 0 {
            out.append("Moved \(files(r.succeeded)) (\(Formatting.humanSize(r.bytesMoved))) to the Trash")
        }
        if !r.refused.isEmpty { out.append("\(files(r.refused.count)) held back") }
        if !r.failed.isEmpty { out.append("\(files(r.failed.count)) couldn't be moved") }
        if r.alreadyMissing > 0 { out.append("\(files(r.alreadyMissing)) already missing (catalog updated)") }
        if r.skippedOffline > 0 { out.append("\(files(r.skippedOffline)) skipped \u{2014} drive not connected") }
        if r.cancelled > 0 { out.append("\(files(r.cancelled)) not reached \u{2014} stopped") }
        if out.isEmpty { out.append("Nothing was selected") }
        return out + r.groupNotes + r.keptMarkerNotes
    }

    /// The whole list as plain text, one file per line (the Catalog
    /// alert's scrolling list; also what a person can copy).
    var linesText: String {
        lines.map { "\($0.filename) \u{2014} \($0.reason)" }.joined(separator: "\n")
    }
}
