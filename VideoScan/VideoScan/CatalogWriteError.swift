//
//  CatalogWriteError.swift
//  VideoScan
//
//  Typed failures for catalog persistence, plus a durable journal of them.
//
//  Before this, every catalog save returned a bare `Bool` and the reason for
//  a refusal existed only as an NSLog line. That is how the 2026-08-14
//  clobber went unnoticed: the losing write was not even a failure — it
//  "succeeded" and silently destroyed 9,382 records of work.
//
//  Two requirements drive this file:
//    RETURNED  — callers get a typed reason, not just false.
//    RECORDED  — refusals and failures are appended to a journal on disk so
//                a clobber attempt is discoverable after the fact, by a human
//                or by a support bundle, without a debugger attached.
//

import Foundation
import os

private let writeErrorLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "CatalogWrite")

/// Why a catalog write did not happen, or did not happen safely.
enum CatalogWriteError: Error, Equatable, Sendable {

    /// Another process owns the catalog lock. This is the case Rick asked to
    /// be reported rather than swallowed: "someone tries to write but it is
    /// in use."
    case lockedByAnotherProcess(owner: CatalogLockOwner?)

    /// The on-disk generation moved past what this session loaded, so
    /// writing our copy would silently discard the other writer's work.
    /// This is the LOST-UPDATE guard, the one that would have caught 8/14
    /// — a lock alone would not have, because both writes were well-formed.
    /// Recovery is reconcile-then-retry, never blind retry.
    case staleGeneration(loaded: Int, onDisk: Int)

    /// load() refused the on-disk catalog (e.g. written by a newer build)
    /// and writing would destroy it — the quit-time save would replace a
    /// future-schema catalog with an empty current-schema one.
    case writesDisabled(String)

    /// Viewer-mode host; writes were never permitted here.
    case readOnlyViewer

    /// Encoding or the atomic write itself failed.
    case writeFailed(String)

    /// The file read back after writing does not match what we wrote.
    /// Catches truncation, a filesystem that lied about durability, and
    /// media errors that surface between write and read. The previous
    /// generation is still in catalog.json.prev when this fires.
    case verificationFailed(expectedSHA256: String, actualSHA256: String, bytes: Int)

    /// The lock file could not even be opened (permissions, missing dir).
    case lockUnavailable(String)

    var userFacingDescription: String {
        switch self {
        case .lockedByAnotherProcess(let owner):
            let who = owner?.describedBriefly ?? "another process"
            return "The catalog is in use by \(who). Your changes were not saved."
        case .staleGeneration(let loaded, let onDisk):
            return "The catalog on disk is at generation \(onDisk) but this session loaded generation \(loaded). Another writer changed it; saving now would discard their work. Reload/reconcile, then save."
        case .writesDisabled(let reason):
            return "Catalog saving is disabled for this session: \(reason)"
        case .readOnlyViewer:
            return "This machine is a viewer. The catalog is read-only here."
        case .writeFailed(let detail):
            return "Saving the catalog failed: \(detail)"
        case .lockUnavailable(let detail):
            return "Could not obtain the catalog lock: \(detail)"
        case .verificationFailed(let expected, let actual, let bytes):
            return "The catalog failed verification after writing \(bytes) bytes (expected SHA-256 \(expected.prefix(12))…, read back \(actual.prefix(12))…). The previous copy is intact in catalog.json.prev."
        }
    }

    /// Short stable tag for the journal and for metrics.
    var kind: String {
        switch self {
        case .lockedByAnotherProcess: return "locked"
        case .staleGeneration:        return "stale"
        case .readOnlyViewer:         return "readonly"
        case .writeFailed:            return "writeFailed"
        case .lockUnavailable:        return "lockUnavailable"
        case .verificationFailed:     return "verificationFailed"
        case .writesDisabled:         return "writesDisabled"
        }
    }

    /// Stable numeric code for logs, metrics, and support requests. Values
    /// are frozen — append new cases, never renumber existing ones.
    var code: Int {
        switch self {
        case .readOnlyViewer:          return 1
        case .lockedByAnotherProcess:  return 2
        case .staleGeneration:         return 3
        case .lockUnavailable:         return 4
        case .writeFailed:             return 5
        case .verificationFailed:      return 6
        case .writesDisabled:          return 7
        }
    }

    /// True when retrying later could plausibly succeed. `.staleGeneration`
    /// is deliberately NOT retryable: the in-memory copy must be reconciled
    /// against the newer file first, and a blind retry would reintroduce the
    /// very lost update this guard exists to prevent.
    var isTransient: Bool {
        switch self {
        case .lockedByAnotherProcess, .lockUnavailable: return true
        case .readOnlyViewer, .staleGeneration,
             .writeFailed, .verificationFailed,
             .writesDisabled:                           return false
        }
    }
}

/// Append-only record of write refusals and failures.
///
/// Deliberately dumb: one JSON object per line, opened and closed per append,
/// no in-memory buffering. A clobber attempt is exactly the moment you cannot
/// assume the process will survive to flush anything.
enum CatalogWriteJournal {

    struct Entry: Codable, Sendable {
        var at: Date
        var code: Int
        var kind: String
        var detail: String
        var pid: Int32
        var processName: String
        var hostname: String
    }

    /// Sits beside catalog.json so it travels with the catalog it describes.
    static func journalURL(besideCatalogAt catalogURL: URL) -> URL {
        catalogURL.deletingLastPathComponent()
                  .appendingPathComponent("catalog-write-errors.jsonl")
    }

    /// Record a refusal. Never throws — a journal that can fail loudly during
    /// error handling just replaces one problem with another.
    static func record(_ error: CatalogWriteError, catalogURL: URL) {
        let entry = Entry(
            at: Date(),
            code: error.code,
            kind: error.kind,
            detail: error.userFacingDescription,
            pid: getpid(),
            processName: ProcessInfo.processInfo.processName,
            hostname: ProcessInfo.processInfo.hostName
        )

        writeErrorLog.error("catalog write refused [code \(error.code, privacy: .public) \(error.kind, privacy: .public)]: \(error.userFacingDescription, privacy: .public)")

        let url = journalURL(besideCatalogAt: catalogURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)   // newline — one object per line

        rotateIfOversized(url)
        appendAtomically(data, to: url)
    }

    /// Rotation cap. One rotated generation (`.1`) is kept, so worst case
    /// on disk is ~2x this. Internal so tests can shrink it.
    static var maxBytes: Int = 1_000_000

    /// Rename `url` → `url.1` (replacing any older `.1`) once it exceeds
    /// `maxBytes`. Codex #385: the journal was unbounded — a wedged
    /// external writer retrying every 2 s could grow it without limit.
    private static func rotateIfOversized(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
              size > maxBytes else { return }
        let rotated = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }

    /// O_APPEND append. `seekToEnd` + `write` was two syscalls with a race
    /// between them: two processes (app + maintenance script, which is the
    /// exact scenario the journal exists for) could interleave and one line
    /// would clobber the other. With O_APPEND the kernel positions and
    /// writes atomically per call.
    private static func appendAtomically(_ data: Data, to url: URL) {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = data.withUnsafeBytes { buf in
            write(fd, buf.baseAddress, buf.count)
        }
    }

    /// Most recent entries, newest first. For a diagnostics panel or a
    /// support bundle.
    static func recent(_ limit: Int = 50, catalogURL: URL) -> [Entry] {
        let url = journalURL(besideCatalogAt: catalogURL)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n")
            .reversed()
            .prefix(limit)
            .compactMap { line in
                guard let d = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(Entry.self, from: d)
            }
    }
}
