// DeletionAudit.swift
// The auditor's record of every run that moves files to the Trash (G2,
// Rick 2026-10-09: "where did my file go"). One per run — the junk lanes
// (Delete Junk's frozen snapshot, the Catalog's Move to Trash / ⌘⌫) and
// every Delete Duplicates job (bulk, resumed, reviewed — the Copies &
// Advice hand-off rides the reviewed path):
//
//   START    verb · who · scope · files and bytes requested
//   per file outcome (moved | held | failed | missing | offline | cancelled),
//            original path, size, the Trash location it now has (moved),
//            the keeper and its proof (duplicates), the reason
//   OUTCOME  totals per outcome · bytes moved · where the receipt is
//
// The lines go through the ONE sink the START / OUTCOME lines already use
// (the console + catalog.log via `model.log`, and videoscan.log). The
// RECEIPT is a CSV per run under ~/Library/Logs/VideoScan/deletions/ —
// one row per requested file, appended as each file settles (a crash
// keeps the rows done so far) and rewritten atomically at the end. It is
// the basis for a later Put Back.
//
// (For Rick: `DeletionReceipt` is a small class guarded by a lock — a C++
// object with a std::mutex — because rows may be appended from the job's
// main-actor turns while the file is open for appending.)

import Foundation

/// One requested file's outcome, in the audit's six words.
enum DeletionAuditOutcome: String, Sendable, CaseIterable {
    case moved, held, failed, missing, offline, cancelled
}

/// One row of the audit: one requested file.
struct DeletionAuditRow: Sendable, Equatable {
    var outcome: DeletionAuditOutcome
    var originalPath: String
    /// Where the file is now (moved only): the Trash's resulting location.
    var trashPath: String?
    var sizeBytes: Int64
    /// Duplicates: the copy kept, and how it was proven at the move.
    var keeperPath: String?
    var keeperProof: String?
    var reason: String

    static let csvHeader = "outcome,original_path,trash_path,size_bytes,keeper_path,keeper_proof,reason"

    var csvLine: String {
        [outcome.rawValue, originalPath, trashPath ?? "", String(sizeBytes), keeperPath ?? "", keeperProof ?? "", reason]
            .map(Self.csvField).joined(separator: ",")
    }

    /// RFC 4180: quoted when it holds a comma, a quote or a line break.
    static func csvField(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// "<prefix>moved /Volumes/X/a.mov (4 GB) → /Volumes/X/.Trashes/501/a.mov · keeper /…/k.mov (sha256:… read in full) — reason"
    func logLine(prefix: String) -> String {
        var line = "\(prefix)\(outcome.rawValue) \(originalPath) (\(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)))"
        if let trashPath { line += " → \(trashPath)" }
        if let keeperPath, !keeperPath.isEmpty {
            line += " · keeper \(keeperPath)" + (keeperProof.map { " (\($0))" } ?? "")
        }
        if !reason.isEmpty { line += " — \(reason)" }
        return line
    }
}

/// The per-run receipt file.
final class DeletionReceipt: @unchecked Sendable {
    enum Kind: String, Sendable { case junk, duplicates }

    let url: URL
    private let lock = NSLock()
    private var lines: [String] = [DeletionAuditRow.csvHeader]
    private var handle: FileHandle?

    /// ~/Library/Logs/VideoScan/deletions — under a test host, a
    /// per-process scratch folder (no test writes Rick's logs).
    nonisolated static var defaultDirectory: URL {
        if TestEnvironment.isTestHost {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("VideoScan-tests/deletions-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VideoScan/deletions", isDirectory: true)
    }

    /// "2026-10-09_214502_junk.csv"
    nonisolated static func fileName(kind: Kind, at date: Date, suffix: Int = 1) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: date) + "_\(kind.rawValue)" + (suffix > 1 ? "_\(suffix)" : "") + ".csv"
    }

    /// Creates the file with its header now (never over an existing one —
    /// a second run in the same second gets "_2"). A receipt that cannot
    /// be created still collects its rows; `finish` tries once more.
    init(kind: Kind, directory: URL = DeletionReceipt.defaultDirectory, now: Date = Date()) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var n = 1
        var candidate = directory.appendingPathComponent(Self.fileName(kind: kind, at: now))
        while fm.fileExists(atPath: candidate.path) {
            n += 1
            candidate = directory.appendingPathComponent(Self.fileName(kind: kind, at: now, suffix: n))
        }
        url = candidate
        if fm.createFile(atPath: url.path, contents: Data((DeletionAuditRow.csvHeader + "\n").utf8)) {
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
    }

    /// One row, appended to the file at once (a crash keeps it).
    func append(_ row: DeletionAuditRow) {
        lock.withLock {
            lines.append(row.csvLine)
            try? handle?.write(contentsOf: Data((row.csvLine + "\n").utf8))
        }
    }

    /// Every row so far (tests, the OUTCOME line).
    var rowCount: Int { lock.withLock { lines.count - 1 } }

    /// The whole receipt, rewritten atomically (temp file + rename by
    /// Foundation): the final file is complete or the progressive one stays.
    @discardableResult
    func finish() -> Bool {
        lock.withLock {
            try? handle?.close()
            handle = nil
            let text = lines.joined(separator: "\n") + "\n"
            return (try? Data(text.utf8).write(to: url, options: .atomic)) != nil
        }
    }
}

/// One run's audit: the START, per-file and OUTCOME lines through one sink,
/// and the receipt. Main actor: it is driven from the lanes' and the job's
/// main-actor turns.
@MainActor
final class DeletionAudit {
    let verb: String
    let linePrefix: String
    let receipt: DeletionReceipt
    private let sink: @MainActor (String) -> Void
    private(set) var counts: [DeletionAuditOutcome: Int] = [:]
    private(set) var bytesMoved: Int64 = 0

    /// `sink` = the one log sink (console + catalog.log, and videoscan.log).
    init(kind: DeletionReceipt.Kind, verb: String, linePrefix: String,
         sink: @escaping @MainActor (String) -> Void, directory: URL = DeletionReceipt.defaultDirectory) {
        self.verb = verb
        self.linePrefix = linePrefix
        self.sink = sink
        self.receipt = DeletionReceipt(kind: kind, directory: directory)
    }

    /// "[junk] START Move to Trash — by rickb · 3 selected · 3 files requested (12 KB)"
    func start(scope: String, requested: Int, bytes: Int64) {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        sink("\(linePrefix)START \(verb) — by \(NSUserName()) · \(scope) · \(requested) file\(requested == 1 ? "" : "s") requested (\(size))")
    }

    /// Requested files already written (a lane records each once).
    private var recordedIDs = Set<UUID>()

    /// One requested file, settled — once per id.
    func record(_ row: DeletionAuditRow, id: UUID) {
        guard recordedIDs.insert(id).inserted else { return }
        record(row)
    }

    /// One requested file, settled.
    func record(_ row: DeletionAuditRow) {
        counts[row.outcome, default: 0] += 1
        if row.outcome == .moved { bytesMoved += row.sizeBytes }
        receipt.append(row)
        sink(row.logLine(prefix: linePrefix))
    }

    /// "[junk] OUTCOME Move to Trash — moved 2 (8 KB) · held 1 · … · receipt: /…/x.csv"
    @discardableResult
    func finish() -> String {
        let written = receipt.finish()
        let size = ByteCountFormatter.string(fromByteCount: bytesMoved, countStyle: .file)
        var parts = ["moved \(counts[.moved, default: 0]) (\(size))"]
        for outcome in DeletionAuditOutcome.allCases where outcome != .moved {
            parts.append("\(outcome.rawValue) \(counts[outcome, default: 0])")
        }
        let line = "\(linePrefix)OUTCOME \(verb) — " + parts.joined(separator: " · ")
            + " · receipt: \(receipt.url.path)" + (written ? "" : " (could not be completed — the rows written so far are there)")
        sink(line)
        return line
    }
}

extension VideoScanModel {
    /// THE sink for the audit lines: the console + catalog.log (`log`) and
    /// videoscan.log — the way the START / OUTCOME lines already go.
    func deletionAuditSink(appLog other: (any LogSink)? = nil) -> @MainActor (String) -> Void {
        { [weak self] line in
            self?.log(line)
            (other ?? appLog).write(line)
        }
    }
}

extension DeletionAudit {
    /// A junk lane's end: every requested file not yet written (refused by
    /// the plan before any disk work, or decided before the loop), then the
    /// OUTCOME line. One row per requested file.
    @discardableResult
    func finish(_ result: VideoScanModel.JunkDeletionResult) -> String {
        for item in result.items {
            record(VideoScanModel.JunkDeletionResult.auditRow(item.record, item.outcome), id: item.record.id)
        }
        return finish()
    }
}
