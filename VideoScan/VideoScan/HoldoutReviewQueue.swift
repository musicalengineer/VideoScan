// HoldoutReviewQueue.swift
// Model layer for the in-app POI holdout review (Rick 2026-07-25).
//
// The blind-review queue is codex's sealed CSV artifact:
//
//     output/person-eval-private/<date>/rick-review-neutral.csv
//     header: reviewId,fullPath,rickConfirm(yes/no),notes
//
// A row with an empty rickConfirm is PENDING. Rick answers yes/no (plus
// optional notes) per video in the app; the answers write back into the
// SAME CSV so codex's grading tooling (tools/person-eval/
// apply_label_csv.py lineage) ingests it unchanged. This file therefore
// round-trips the CSV byte-for-byte in the style Python's csv.writer
// produced it: QUOTE_MINIMAL (quote only fields containing , " \r \n,
// doubling embedded quotes) and CRLF row terminators.
//
// CONTRACT (POI-leakage incident, team-channel 2026-07-25-1115):
//   1. This type carries NO model predictions, scores, candidate
//      signals, or detected-person data — reviewId/fullPath/answer/notes
//      only. The blindness sensor test pins that field set.
//   2. Answers go ONLY to the CSV (atomic temp-file + rename via
//      Data.write .atomic). Never to validation labels, catalog tags,
//      or any model/candidate state.
//
// Worst-case memory: the whole CSV is held in memory — 36 rows today,
// ~250 bytes/row. Even a pathological 100k-row queue is ~25 MB; no
// streaming needed at this scale.

import Combine   // ObservableObject/@Published for HoldoutReviewCenter
import Foundation

// MARK: - Row

/// One CSV data row. Deliberately blind: nothing here can leak a model
/// opinion into Rick's review. (Swift `struct` ≈ C++ value-type struct —
/// copied on assignment, no shared identity.)
struct HoldoutReviewRow: Equatable, Sendable {
    let reviewId: String
    let fullPath: String
    /// Raw cell content — "" (pending), "yes", "no", or whatever a hand
    /// edit left there. Kept verbatim so we never destroy a hand edit.
    var rickConfirm: String
    var notes: String
    /// Columns beyond the contract 4, preserved verbatim on write so a
    /// future schema extension survives an app-side round trip.
    var extraColumns: [String]

    var isPending: Bool {
        rickConfirm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var filename: String { (fullPath as NSString).lastPathComponent }
}

// MARK: - Queue

struct HoldoutReviewQueue: Equatable, Sendable {

    /// The live CSV on disk — answers write back here, nowhere else.
    let csvURL: URL
    /// Who this queue is about. The CSV is person-agnostic, so the name
    /// comes from an optional sidecar (see `discover`), default "Donna".
    let personName: String
    /// Header fields preserved verbatim (contract: first four are
    /// reviewId, fullPath, rickConfirm(yes/no), notes).
    let header: [String]
    private(set) var rows: [HoldoutReviewRow]

    static let csvFilename = "rick-review-neutral.csv"
    static let personSidecarFilename = "rick-review-neutral.person.txt"
    static let defaultPersonName = "Donna"
    static let expectedHeaderPrefix = ["reviewId", "fullPath", "rickConfirm(yes/no)", "notes"]

    /// Repo-root convention shared with POIStorage / ArcFaceEngine:
    /// the checkout lives at ~/dev/VideoScan.
    static var defaultRepoRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("dev/VideoScan", isDirectory: true)
    }

    var pendingCount: Int { rows.lazy.filter { $0.isPending }.count }
    var answeredCount: Int { rows.count - pendingCount }
    var firstPendingIndex: Int? { rows.firstIndex { $0.isPending } }

    /// Next pending row strictly after `idx`, wrapping to the front if
    /// needed. Excludes `idx` itself — so after answering row `idx` the
    /// caller lands on the next open question, and a Skip on the last
    /// remaining pending row returns nil (caller decides to stay put).
    func nextPendingIndex(after idx: Int) -> Int? {
        guard !rows.isEmpty else { return nil }
        let n = rows.count
        for step in 1..<max(n, 2) {
            let i = (idx + step) % n
            if i == idx { break }
            if rows[i].isPending { return i }
        }
        return nil
    }

    // MARK: Errors

    enum QueueError: LocalizedError, Equatable {
        case notUTF8
        case missingHeader
        case badHeader([String])
        case shortRow(line: Int)
        case unknownReviewId(String)

        var errorDescription: String? {
            switch self {
            case .notUTF8:              return "Review CSV is not UTF-8 text"
            case .missingHeader:        return "Review CSV is empty (no header row)"
            case .badHeader(let h):     return "Unexpected review CSV header: \(h.joined(separator: ","))"
            case .shortRow(let line):   return "Review CSV row \(line) has fewer than 4 columns"
            case .unknownReviewId(let id): return "reviewId \(id) is not in the queue"
            }
        }
    }

    // MARK: Load / discover

    /// Load a queue from an explicit CSV, resolving the person from the
    /// sidecar next to it (default "Donna" — today's queue is hers).
    static func load(csvURL: URL) throws -> HoldoutReviewQueue {
        let data = try Data(contentsOf: csvURL)
        guard let text = String(data: data, encoding: .utf8) else {
            throw QueueError.notUTF8
        }
        let records = parseCSVRecords(text)
        guard let header = records.first else { throw QueueError.missingHeader }
        guard header.count >= 4,
              Array(header.prefix(4)) == expectedHeaderPrefix else {
            throw QueueError.badHeader(header)
        }
        var rows: [HoldoutReviewRow] = []
        rows.reserveCapacity(records.count - 1)
        for (i, rec) in records.dropFirst().enumerated() {
            guard rec.count >= 4 else { throw QueueError.shortRow(line: i + 2) }
            rows.append(HoldoutReviewRow(
                reviewId: rec[0],
                fullPath: rec[1],
                rickConfirm: rec[2],
                notes: rec[3],
                extraColumns: Array(rec.dropFirst(4))
            ))
        }
        let sidecar = csvURL.deletingLastPathComponent()
            .appendingPathComponent(personSidecarFilename)
        let sidecarName = (try? String(contentsOf: sidecar, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return HoldoutReviewQueue(
            csvURL: csvURL,
            personName: sidecarName.isEmpty ? defaultPersonName : sidecarName,
            header: header,
            rows: rows
        )
    }

    /// Find the NEWEST queue under <repoRoot>/output/person-eval-private/.
    /// Directory names are dated YYYY-MM-DD, so lexicographic descending
    /// order == newest first. Returns nil (badge hidden) when there is no
    /// queue or it fails to parse — a broken queue must never crash the
    /// People UI.
    static func discover(repoRoot: URL = defaultRepoRoot) -> HoldoutReviewQueue? {
        let evalDir = repoRoot.appendingPathComponent(
            "output/person-eval-private", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: evalDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let dirs = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for dir in dirs {
            let csv = dir.appendingPathComponent(csvFilename)
            guard FileManager.default.fileExists(atPath: csv.path) else { continue }
            if let queue = try? load(csvURL: csv) { return queue }
        }
        return nil
    }

    // MARK: Answer write-back (write-through, atomic)

    /// Record Rick's answer for one row and persist the WHOLE CSV
    /// immediately (write-through — a crash after this call loses
    /// nothing). `.atomic` is Foundation's temp-file-in-same-directory +
    /// rename(2), so a reader never sees a torn file.
    mutating func recordAnswer(reviewId: String, confirm: String, notes: String) throws {
        guard let i = rows.firstIndex(where: { $0.reviewId == reviewId }) else {
            throw QueueError.unknownReviewId(reviewId)
        }
        rows[i].rickConfirm = confirm
        rows[i].notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        try serialized().write(to: csvURL, options: [.atomic])
    }

    // MARK: Serialization (Python csv.writer compatible)

    /// Emit the CSV exactly as Python's csv.writer(QUOTE_MINIMAL) does:
    /// CRLF row terminators (including after the last row), fields quoted
    /// only when they contain , " \r or \n, embedded quotes doubled.
    /// A load→serialize round trip of an untouched file is byte-identical.
    func serialized() -> Data {
        var out = Self.csvLine(header)
        for row in rows {
            out += Self.csvLine(
                [row.reviewId, row.fullPath, row.rickConfirm, row.notes]
                + row.extraColumns)
        }
        return Data(out.utf8)
    }

    static func csvLine(_ fields: [String]) -> String {
        fields.map(escapeCSVField).joined(separator: ",") + "\r\n"
    }

    static func escapeCSVField(_ field: String) -> String {
        // Scan unicode scalars, not Characters: Swift folds CRLF into a
        // SINGLE Character ("\r\n" grapheme cluster), so a Character-level
        // contains("\r") would miss it.
        let needsQuoting = field.unicodeScalars.contains {
            $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n"
        }
        guard needsQuoting else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Parsing

    /// Minimal RFC-4180 record parser: quoted fields may contain commas,
    /// doubled quotes, and newlines; rows end on CRLF or LF. A trailing
    /// terminator does not produce a phantom empty record.
    static func parseCSVRecords(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var sawAnything = false

        // Iterate Unicode scalars, not Character. Swift treats CRLF as one
        // extended grapheme cluster, which would make `c == "\r"` and
        // `c == "\n"` both false and collapse the entire CSV into one row.
        // Scalar iteration keeps the RFC-4180 delimiters distinct while
        // preserving arbitrary Unicode inside fields.
        var iter = text.unicodeScalars.makeIterator()
        var pushback: Unicode.Scalar?

        func nextScalar() -> Unicode.Scalar? {
            if let c = pushback { pushback = nil; return c }
            return iter.next()
        }
        func endField() { fields.append(field); field = "" }
        func endRecord() {
            endField()
            records.append(fields)
            fields = []
            sawAnything = false
        }

        while let c = nextScalar() {
            if inQuotes {
                if c == "\"" {
                    if let peek = nextScalar() {
                        if peek == "\"" { field.append("\"") }   // doubled quote
                        else { inQuotes = false; pushback = peek }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
                continue
            }
            switch c {
            case "\"":
                inQuotes = true
                sawAnything = true
            case ",":
                endField()
                sawAnything = true
            case "\r":
                // Swallow the LF of a CRLF pair if present.
                if let peek = nextScalar(), peek != "\n" { pushback = peek }
                endRecord()
            case "\n":
                endRecord()
            default:
                field.unicodeScalars.append(c)
                sawAnything = true
            }
        }
        // Final record without trailing terminator.
        if sawAnything || !field.isEmpty || !fields.isEmpty {
            endRecord()
        }
        return records
    }
}

// MARK: - Center (observable wrapper for the People UI)

/// Owns the discovered queue for badge visibility. Refreshed when the
/// People gallery appears and when the review sheet closes, so the badge
/// count tracks answers and disappears when the queue is done.
/// (`@MainActor` ≈ "all members run on the UI thread"; the disk scan
/// itself hops off-main inside refresh().)
@MainActor
final class HoldoutReviewCenter: ObservableObject {

    @Published private(set) var queue: HoldoutReviewQueue?

    private let repoRoot: URL

    init(repoRoot: URL = HoldoutReviewQueue.defaultRepoRoot) {
        self.repoRoot = repoRoot
    }

    /// Re-discover the newest queue. The directory listing + 36-row parse
    /// is tiny, but it's still file I/O — keep it off the main actor.
    /// (`@concurrent` forces the global executor; a plain `nonisolated
    /// async` would inherit the CALLER's actor under Approachable
    /// Concurrency — see the project's concurrency-trap memory.)
    func refresh() async {
        let root = repoRoot
        let found = await Self.discover(root: root)
        queue = found
    }

    @concurrent
    private static func discover(root: URL) async -> HoldoutReviewQueue? {
        HoldoutReviewQueue.discover(repoRoot: root)
    }

    /// The queue that should light the Review badge on `personName`'s
    /// card — non-nil only when the newest queue is for that person AND
    /// has at least one pending row.
    func pendingQueue(for personName: String) -> HoldoutReviewQueue? {
        guard let q = queue,
              q.pendingCount > 0,
              q.personName.caseInsensitiveCompare(personName) == .orderedSame
        else { return nil }
        return q
    }
}
