// TrashWarnings.swift
// The Trash routine's settlement warnings, in the person's words — the ONE
// function every door passes a `JunkDeletionResult` through before it shows
// or logs the result (Codex #205: Cleanup, Prune and Discard used to read
// only `result.items`, so a kept concurrent marker read as clean success).
//
// The result is the single source: `groupNotes` / `groupNeedsAttention`
// (⌘⌫'s recovered A/V pairs) and `keptMarkerNotes` (a row another action
// re-marked while its file moved — kept, never overwritten, Codex #202/#204).
// Every presenter renders these lines; none re-derives them.
//
// Sensor: `TrashWarningsSensorTests` lists every production caller of
// `deleteConfirmedJunk` and fails if one does not pass its result here.
//
// Memory: O(warnings) — one short string per affected row; a run of 50,000
// files with every row re-marked is ~10 MB of text, the worst case.

import Foundation

struct TrashWarnings: Equatable, Sendable {
    /// Lines about groups of files (⌘⌫'s pairs: counts, SPLIT, changed).
    private(set) var groupNotes: [String] = []
    /// A group line the person must see even when every file moved.
    private(set) var groupNeedsAttention = false
    /// "<file> kept another action's marker (…) — it is in the Trash at <path>; …"
    private(set) var keptMarkerNotes: [String] = []

    init() {}

    /// Kept-marker sentences from an engine that is not the routine (Delete
    /// Duplicates' own settlement, Prune's per-copy lines) — rendered by the
    /// same functions.
    init(keptMarkerNotes: [String]) { self.keptMarkerNotes = keptMarkerNotes }

    /// The routine's warnings for one result.
    init(_ result: VideoScanModel.JunkDeletionResult) {
        groupNotes = result.groupNotes
        groupNeedsAttention = result.groupNeedsAttention
        keptMarkerNotes = result.keptMarkerNotes
    }

    /// A door that calls the routine once per file folds each result in.
    mutating func add(_ result: VideoScanModel.JunkDeletionResult) {
        let more = TrashWarnings(result)
        groupNotes += more.groupNotes
        groupNeedsAttention = groupNeedsAttention || more.groupNeedsAttention
        keptMarkerNotes += more.keptMarkerNotes
    }

    /// Every line the result view shows, group lines first.
    var lines: [String] { groupNotes + keptMarkerNotes }

    /// True when the result must be shown even though every file moved.
    var needsAttention: Bool { groupNeedsAttention || !keptMarkerNotes.isEmpty }

    /// A short clause for a one-line summary / subtitle, nil when clean:
    /// "the catalog changed during the move for 1 file — see below".
    var summaryClause: String? {
        let n = keptMarkerNotes.count
        guard n > 0 else { return nil }
        return "the catalog changed during the move for \(n) file\(n == 1 ? "" : "s") \u{2014} see below"
    }

    /// The clause with the sentences inline, for a one-line result that has
    /// no list below it (a job row's summary), nil when clean.
    func inlineClause(listed: Int = 5) -> String? {
        let n = keptMarkerNotes.count
        guard n > 0 else { return nil }
        return "the catalog changed during the move for \(n) file\(n == 1 ? "" : "s"): " + Self.listing(keptMarkerNotes, listed)
    }

    /// `line` with the inline clause appended (` · `), unchanged when clean —
    /// the terminal line of a job row (finished, stopped, suspended, failed).
    func appended(to line: String) -> String {
        [line, inlineClause()].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    /// The OUTCOME line's addition, nil when clean: the count and each
    /// row's sentence (which names the Trash path). Long runs list the
    /// first `listed` and say how many more the log names.
    func outcomeNote(listed: Int = 5) -> String? {
        let n = keptMarkerNotes.count
        guard n > 0 else { return nil }
        return "kept another action's marker \(n): " + Self.listing(keptMarkerNotes, listed)
    }

    /// The first `listed` sentences, then how many more the log names.
    private static func listing(_ notes: [String], _ listed: Int) -> String {
        var shown = notes.prefix(listed).joined(separator: "; ")
        if notes.count > listed { shown += "; and \(notes.count - listed) more (each named in the log)" }
        return shown
    }
}
