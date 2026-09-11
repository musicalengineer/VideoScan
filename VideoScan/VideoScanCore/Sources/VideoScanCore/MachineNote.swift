// MachineNote.swift
// VideoScanCore — authored machine notes (GH #176, Rick 2026-09-11):
// "author of notes was not clear. Now it will be clear: ffmpeg said,
// Rick said, user said, etc."
//
// Two fields, two authors:
//   VideoRecord.notes      — MACHINE text. Every line carries its author,
//                            either as a signed prefix ("ffprobe: …") or as
//                            one of the legacy self-describing shapes
//                            (File Journey stamps "Promote <ISO>: …",
//                            "Combined: …", "MXF header parsed (…").
//   VideoRecord.userNotes  — HUMAN text only. Nothing in the app writes
//                            machine text there (sensor:
//                            NotesAuthorshipSensorTests).
//
// This enum is the ONE classifier. UserNotesMigration.isMachineLine and
// ArchiveAngelCandidate.isMachineNoteLine both delegate here — the
// duplicated tables they used to carry were the reason 9,979 records
// ended up with ffprobe stderr in `userNotes` (the lazy notes→userNotes
// split only knew "[" lines, so "Unsupported codec with id …" looked
// human and was pumped across). Pure, no I/O.

import Foundation

public enum MachineNote {

    /// Fixed author vocabulary. The raw value is the signed prefix.
    public enum Author: String, CaseIterable, Sendable {
        case ffprobe   // ffprobe stderr captured during a scan probe
        case ffmpeg    // ffmpeg-driven MFO jobs (transcode, trim, balance…)
        case scan      // scan engine diagnostics (timeouts, sniff, MXF fallback)
        case combine   // Correlate/Combine spec notes
        case recipe    // Find-and-Tag person recipe results
        case promote   // Master Archive promotion stamps
        case cleanup   // duplicate cleanup provenance
        case angel     // Archive Angel (reserved — the Angel writes no machine text today)
    }

    // MARK: Writing

    /// "<author>: <text>". Multi-line text (ffprobe stderr) gets EVERY
    /// non-empty line signed, so a later line-based reader never sees an
    /// orphan continuation line. Leading/trailing whitespace per line is
    /// dropped ("    Last message repeated 2 times" → signed flush-left).
    public static func line(author: Author, text: String) -> String {
        text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "\(author.rawValue): \($0)" }
            .joined(separator: "\n")
    }

    /// Append `line` to a notes blob with the "\n" join every writer uses.
    /// Empty `line` is a no-op (never leaves a dangling newline).
    public static func append(_ line: String, to notes: String) -> String {
        guard !line.isEmpty else { return notes }
        return notes.isEmpty ? line : notes + "\n" + line
    }

    // MARK: Reading

    /// The author of `line`, or nil when a person could have written it.
    /// Recognizes BOTH the signed shape ("scan: …") and every legacy
    /// unsigned shape a machine writer has ever produced (tables below).
    /// Leading whitespace is ignored — ffprobe indents "Last message
    /// repeated N times". Case-insensitive on the legacy phrases; the
    /// signed prefix is exact (lowercase) so "Scan: the porch" stays human.
    public static func author(of line: Substring) -> String? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard !trimmed.isEmpty else { return nil }
        if let signed = signedAuthor(trimmed) { return signed }
        let key = trimmed.lowercased()
        if key.range(of: ffmpegLogHeader, options: .regularExpression) != nil { return Author.ffprobe.rawValue }
        if ffprobePhrases.contains(where: { key.hasPrefix($0) }) { return Author.ffprobe.rawValue }
        if scanPhrases.contains(where: { key.hasPrefix($0) }) { return Author.scan.rawValue }
        if key.hasPrefix("combined: ") { return Author.combine.rawValue }
        if key.hasPrefix("findperson(") { return Author.recipe.rawValue }
        if key.hasPrefix("copy at /") { return Author.cleanup.rawValue }
        if let verb = journeyStampVerb(trimmed) { return journeyAuthor[verb] ?? Author.scan.rawValue }
        return nil
    }

    public static func author(of line: String) -> String? { author(of: Substring(line)) }

    public static func isMachineLine(_ line: Substring) -> Bool { author(of: line) != nil }
    public static func isMachineLine(_ line: String) -> Bool { author(of: line) != nil }

    /// `line` as it should be stored in `notes`: nil for a human line;
    /// unchanged when it is already self-describing (signed prefix, File
    /// Journey stamp, "Combined: ", "MXF header parsed ("); otherwise
    /// "<recognized author>: <line>". Whitespace-trimmed. Applying it twice
    /// is the identity — the migration relies on that.
    public static func signed(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let author = author(of: Substring(trimmed)) else { return nil }
        if isSelfDescribing(Substring(trimmed)) { return trimmed }
        return "\(author): \(trimmed)"
    }

    // MARK: Tables (legacy unsigned shapes — every one seen in the live
    // catalog census of 2026-09-11 or produced by a writer in the tree)

    /// ffprobe/ffmpeg log line header: "[aac @ 0x7ac800a80] …",
    /// "[mov,mp4,m4a,3gp,3g2,mj2 @ 0x7e3018000] …", "[in#0/mov @ 0x…] …".
    /// A bare leading bracket is NOT enough — "[1984] Dad and Donna at
    /// Thanksgiving" is a human note (codex #1303).
    public static let ffmpegLogHeader = #"^\[[^\]\n]*@ 0x[0-9a-f]+\]"#

    /// ffprobe stderr lines that do not start with the "[…]" header
    /// (lowercased prefixes). Census 2026-09-11: 18,390 "Unsupported
    /// codec", 1,936 "Last message repeated", 435 "Could not open codec",
    /// 371 "Consider increasing the value".
    public static let ffprobePhrases: [String] = [
        "unsupported codec with id",
        "last message repeated",
        "could not open codec",
        "consider increasing the value",
        "invalid data found when processing",
        "moov atom not found",
        "could not find codec parameters",
    ]

    /// ScanEngine.humanReadableDiagnosis / probe-engine / ingest text
    /// (lowercased prefixes). Census: 409 "File could not be analyzed —",
    /// 13 "File is corrupt or incomplete", 2 "File contains invalid".
    public static let scanPhrases: [String] = [
        "file could not be analyzed",
        "file is corrupt or incomplete",
        "file contains invalid or unreadable data",
        "file appears to be cut short",
        "cannot read file — permission denied",
        "file read timed out",
        "file was discovered during scan but is no longer accessible",
        "probe cancelled before acquiring",
        "file probe exceeded",
        "content sniff found no media container signature",
        "neither ffprobe nor mxf header parser",
        "damaged mxf — ",
        "mxf header parsed (",
        "added as a document",
    ]

    /// File Journey stamp verb → author. The verbs themselves are owned by
    /// UserNotesMigration.journeyStampVerbs (lock-step with the writers).
    public static let journeyAuthor: [String: String] = [
        "Transcode":     Author.ffmpeg.rawValue,
        "Balance Audio": Author.ffmpeg.rawValue,
        "Cleanup":       Author.ffmpeg.rawValue,   // CleanupJob is an ffmpeg filter job
        "Reformat":      Author.ffmpeg.rawValue,
        "Trim":          Author.ffmpeg.rawValue,
        "Verify Audio":  Author.ffmpeg.rawValue,
        "Reconcile":     Author.scan.rawValue,
        "Migrate":       Author.scan.rawValue,
        "Confirm":       Author.scan.rawValue,
        "Promote":       Author.promote.rawValue,
    ]

    // MARK: Internals

    private static func signedAuthor(_ line: Substring) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let head = line[line.startIndex..<colon]
        guard Author(rawValue: String(head)) != nil else { return nil }
        let after = line.index(after: colon)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return String(head)
    }

    /// The verb when `line` is "<Verb> <ISO8601>…" for a known verb.
    private static func journeyStampVerb(_ line: Substring) -> String? {
        for verb in UserNotesMigration.journeyStampVerbs {
            let prefix = verb + " "
            guard line.hasPrefix(prefix) else { continue }
            if UserNotesMigration.hasISODatePrefix(line.dropFirst(prefix.count)) { return verb }
        }
        return nil
    }

    /// Lines whose existing text already names their author.
    private static func isSelfDescribing(_ line: Substring) -> Bool {
        if signedAuthor(line) != nil { return true }
        if journeyStampVerb(line) != nil { return true }
        if line.hasPrefix("Combined: ") { return true }
        if line.hasPrefix("MXF header parsed (") { return true }
        return false
    }
}

// MARK: - One-time userNotes repair (pure rule)

/// GH #176 repair: move machine lines OUT of `userNotes` back into
/// `notes`, signed. The model wrapper (VideoScanModel+NotesRepair) adds
/// the backup, the marker and the log line; this is the per-record rule
/// so it can be table-tested without a model.
public enum NotesRepair {

    public struct Change: Equatable, Sendable {
        public let notes: String
        public let userNotes: String
        public let movedLines: Int
        public init(notes: String, userNotes: String, movedLines: Int) {
            self.notes = notes; self.userNotes = userNotes; self.movedLines = movedLines
        }
    }

    /// nil when `userNotes` holds no machine line (nothing to do).
    /// Otherwise the repaired pair: machine lines appended to `notes`
    /// (signed via MachineNote.signed, skipped when `notes` already holds
    /// that exact line), human lines kept in order with their interior
    /// blank lines, whitespace-trimmed at the ends. Idempotent: the
    /// result never contains a machine line in `userNotes`, so a second
    /// call returns nil.
    public static func apply(notes: String, userNotes: String) -> Change? {
        guard !userNotes.isEmpty else { return nil }
        let lines = userNotes.split(separator: "\n", omittingEmptySubsequences: false)
        var human: [Substring] = []
        var machine: [String] = []
        for line in lines {
            if let signed = MachineNote.signed(String(line)) {
                machine.append(signed)
            } else {
                human.append(line)
            }
        }
        guard !machine.isEmpty else { return nil }
        var existing = Set(notes.split(separator: "\n").map(String.init))
        var newNotes = notes
        var moved = 0
        for m in machine {
            moved += 1
            guard !existing.contains(m) else { continue }
            newNotes = MachineNote.append(m, to: newNotes)
            existing.insert(m)
        }
        let newHuman = human.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Change(notes: newNotes, userNotes: newHuman, movedLines: moved)
    }
}
