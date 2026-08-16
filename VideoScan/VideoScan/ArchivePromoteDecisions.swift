//
//  ArchivePromoteDecisions.swift
//  VideoScan
//
//  `00_Index/.promote_decisions.jsonl` — the AUDIT trail of what Promote
//  decided NOT to do, one JSON line per skipped file per gesture. Rick
//  2026-08-16: he promoted five files, four landed, and nothing durable
//  said which one was refused or why — the promote journal only records
//  files that reach the copy path (it is a convergence mechanism, not an
//  audit log). Kept SEPARATE from `.promote_journal.jsonl` on purpose so
//  reconciliation never has to reason about non-work entries.
//
//  Best-effort: a failure to record a decision is logged, never blocks.
//

import Foundation

enum ArchivePromoteDecisions {
    static let filename = ".promote_decisions.jsonl"

    struct Entry: Codable, Sendable, Equatable {
        var at: Date
        var recordID: UUID
        var filename: String
        var sourcePath: String
        var decision: String          // "skipped"
        var reason: String            // ArchivePromotePlan.Skip label
        var detail: String?           // e.g. the existing archive relpath
    }

    /// Append one entry per skip. Also mirrors each decision to the app
    /// log so the console tells the story in words.
    nonisolated static func record(_ entries: [Entry], rootPath: String) -> Int {
        guard !entries.isEmpty else { return 0 }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for e in entries {
            guard let line = try? encoder.encode(e) else { continue }
            data.append(line); data.append(0x0A)
        }
        do {
            let fd = try ArchivePromoteEngine.openIndexFile(root: rootPath, name: filename, mustExist: false)
            defer { close(fd) }
            try ArchivePromoteEngine.appendDurable(fd: fd, data: data, full: false, label: "decisions append")
            return entries.count
        } catch {
            return 0
        }
    }

    /// Read back (for diagnostics / a future "what happened" panel).
    nonisolated static func all(rootPath: String) -> [Entry] {
        guard let fd = try? ArchivePromoteEngine.openIndexFile(root: rootPath, name: filename, mustExist: true) else { return [] }
        defer { close(fd) }
        guard let data = try? ArchivePromoteEngine.readAll(fd: fd) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
    }
}
