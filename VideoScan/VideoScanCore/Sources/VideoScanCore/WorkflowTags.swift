// WorkflowTags.swift
// Workflow-tag vocabulary + case-insensitive tag-set helpers, and the
// one-time notes → userNotes split rule (feature/tags-and-usernotes,
// 2026-07-23, Rick-approved design).
//
// Tags are lightweight workflow markers ("Follow Up", "Gold") that live
// on `VideoRecord.tags`. They are stored in canonical DISPLAY form and
// matched case-insensitively everywhere — the user should never end up
// with both "follow up" and "Follow Up" on the same catalog.
//
// Pure value logic only — no I/O, no actor isolation — so the same
// rules drive the context menu, the inspector chip row, search, and
// the unit tests with zero drift.

import Foundation

// MARK: - Workflow tags

public enum WorkflowTags {

    /// The quick-pick vocabulary offered in the context menu and the
    /// inspector's ⊕ menu. Order is the menu order. Custom free-form
    /// tags are allowed too — this list is a convenience, not a schema.
    public static let quickPicks: [String] = [
        "Follow Up",
        "Investigate",
        "Interesting",
        "Gold",
        "Fix Audio",
    ]

    /// Canonicalize a raw (possibly user-typed) tag: trim whitespace,
    /// and if it case-insensitively equals a quick-pick, snap to the
    /// quick-pick's display spelling ("follow up" → "Follow Up").
    /// Custom tags keep the user's spelling as typed (trimmed).
    /// Returns "" for whitespace-only input — callers must treat that
    /// as "nothing to add".
    public static func canonicalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let pick = quickPicks.first(where: {
            $0.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            return pick
        }
        return trimmed
    }

    /// Case-insensitive membership test — the ONLY way tag presence
    /// should ever be checked (mirrors how the search side matches).
    public static func contains(_ tags: [String], _ tag: String) -> Bool {
        tags.contains { $0.compare(tag, options: .caseInsensitive) == .orderedSame }
    }

    /// Add `raw` to `tags` (canonicalized, case-insensitively deduped).
    /// Returns the new array; no-op if the tag is already present or
    /// canonicalizes to "".
    public static func adding(_ raw: String, to tags: [String]) -> [String] {
        let tag = canonicalize(raw)
        guard !tag.isEmpty, !contains(tags, tag) else { return tags }
        return tags + [tag]
    }

    /// Remove `tag` from `tags`, case-insensitively.
    public static func removing(_ tag: String, from tags: [String]) -> [String] {
        tags.filter { $0.compare(tag, options: .caseInsensitive) != .orderedSame }
    }
}

// MARK: - notes → userNotes split (one-time lazy migration)

public enum UserNotesMigration {

    /// True if `line` is a MACHINE note line. Three shapes qualify,
    /// each derived from an actual writer in the codebase (QA fix
    /// 2026-07-23 — File Journey stamps must not migrate to userNotes):
    ///
    ///   1. "[" prefix — ffprobe/ffmpeg stderr probe notes
    ///      ("[mov,mp4,m4a @ 0x...] moov atom not found"), the shape
    ///      the approved design named. Writer: ScanEngine.swift
    ///      (`o.notes = stderrTrimmed`).
    ///   2. File Journey stamps: "<Verb> <ISO8601>: <detail>" — see
    ///      `isJourneyStampLine` for the verb list + writers.
    ///   3. Two literal machine prefixes with no stamp:
    ///      "Combined: "          (combined-record spec note,
    ///                             VideoScanModel+Combine.swift)
    ///      "MXF header parsed (" (ScanEngine.swift native-KLV fallback
    ///                             note, "MXF header parsed (ffprobe
    ///                             failed: ...)").
    public static func isMachineLine(_ line: Substring) -> Bool {
        if line.hasPrefix("[") { return true }
        if line.hasPrefix("Combined: ") { return true }
        if line.hasPrefix("MXF header parsed (") { return true }
        return isJourneyStampLine(line)
    }

    /// The verbs the MFO / relocate pipeline writes as File Journey
    /// stamps, each producing lines of the exact shape
    /// "<Verb> <ISO8601 stamp>: <detail>". DERIVED from the writers —
    /// keep this list in lock-step with them:
    ///
    ///   "Transcode"      TranscodeJob.swift (sourceNote/derivedNote)
    ///   "Balance Audio"  BalanceAudioJob.swift (sourceNote/derivedNote)
    ///   "Cleanup"        CleanupJob.swift (sourceNote/derivedNote)
    ///   "Reformat"       ReformatJob.swift (sourceNote/derivedNote)
    ///   "Trim"           TrimJob.swift (sourceNote/derivedNote)
    ///   "Verify Audio"   RebuildAudioJob.swift (sourceNote/derivedNote,
    ///                    GH #128)
    ///   "Reconcile"      VideoScanModel+Relocate.swift (reconcile
    ///                    buckets + formatSafelyRedundantNote)
    ///   "Migrate"        VideoScanModel+Relocate.swift (salvage /
    ///                    migrate stamps)
    ///   "Confirm"        VideoScanModel+RepairLifecycle.swift (repair
    ///                    confirmed / superseded stamps, GH #132)
    ///   "Promote"        PromoteToArchiveJob.swift / VideoScanModel+
    ///                    MasterArchive.swift (Master Archive promotion
    ///                    stamps on source + copy, 2026-08-15)
    public static let journeyStampVerbs: [String] = [
        "Transcode",
        "Balance Audio",
        "Cleanup",
        "Reformat",
        "Trim",
        "Verify Audio",
        "Reconcile",
        "Migrate",
        "Confirm",
        "Promote",
    ]

    /// True if `line` is a File Journey stamp: a known verb, a space,
    /// then an ISO8601 date ("YYYY-MM-DDT…"). STRUCTURAL match on
    /// purpose — the verb alone is not enough, because a human note
    /// like "Transcoded this myself in 2019" or "Trim this one later"
    /// must still count as human. Only the machine writers produce
    /// verb + space + ISO-date-with-'T', so requiring the date shape
    /// keeps real human notes migrating.
    public static func isJourneyStampLine(_ line: Substring) -> Bool {
        for verb in journeyStampVerbs {
            let prefix = verb + " "
            guard line.hasPrefix(prefix) else { continue }
            if hasISODatePrefix(line.dropFirst(prefix.count)) { return true }
        }
        return false
    }

    /// True if `s` begins with "YYYY-MM-DDT" — the head of every
    /// ISO8601DateFormatter stamp the writers above produce. ASCII-
    /// digit strict so lookalike text can't misclassify a human note
    /// as machine.
    static func hasISODatePrefix(_ s: Substring) -> Bool {
        let head = Array(s.prefix(11))
        guard head.count == 11 else { return false }
        for (i, ch) in head.enumerated() {
            switch i {
            case 4, 7:
                if ch != "-" { return false }
            case 10:
                if ch != "T" { return false }
            default:
                guard let a = ch.asciiValue, a >= 48, a <= 57 else { return false }
            }
        }
        return true
    }

    /// Split a legacy `notes` blob into (machine, human) halves,
    /// newline-line-based: machine lines (see `isMachineLine` — probe
    /// "[" lines, File Journey stamps, Combined/MXF-fallback literals)
    /// stay put, everything else is human text that belongs in
    /// `userNotes`.
    ///
    ///   * pure human note   → machine == "", human == notes
    ///   * pure machine note → machine == notes, human == ""
    ///   * mixed             → each side keeps its own lines, in order
    ///
    /// Line splitting preserves empty interior lines on the human side
    /// so multi-paragraph user notes survive intact.
    public static func split(notes: String) -> (machine: String, human: String) {
        guard !notes.isEmpty else { return ("", "") }
        let lines = notes.split(separator: "\n", omittingEmptySubsequences: false)
        var machine: [Substring] = []
        var human: [Substring] = []
        for line in lines {
            if isMachineLine(line) {
                machine.append(line)
            } else {
                human.append(line)
            }
        }
        // Trim pure-whitespace remainders: a human side that is only
        // blank separator lines (leftovers between machine lines) is
        // nothing worth migrating.
        let machineJoined = machine.joined(separator: "\n")
        let humanJoined = human.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (machineJoined, humanJoined)
    }

    /// Apply the one-time migration rule to a (notes, userNotes) pair.
    /// Returns nil when nothing should change (already migrated, empty
    /// notes, or nothing human to move); otherwise the new values.
    ///
    /// Idempotent by construction: after a move, `userNotes` is
    /// non-empty, so the `userNotes.isEmpty` gate never fires again for
    /// that record.
    public static func migrate(
        notes: String, userNotes: String
    ) -> (notes: String, userNotes: String)? {
        guard userNotes.isEmpty, !notes.isEmpty else { return nil }
        let (machine, human) = split(notes: notes)
        guard !human.isEmpty else { return nil }   // all machine — leave alone
        return (notes: machine, userNotes: human)
    }
}
