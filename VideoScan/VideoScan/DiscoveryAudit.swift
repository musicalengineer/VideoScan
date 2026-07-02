// DiscoveryAudit.swift
// Per-scan discovery accounting — the "provable completeness" layer
// (discovery-completeness feature, 2026-07-02).
//
// Why: the 2026-06-30/07-01 LaCieWorkspace incident class was invisible
// precisely because discovery reported nothing about what it did NOT see.
// A scan that walks 181 of 5,694 files looks identical to a healthy scan
// unless someone counts the files enumerated, the files skipped per rule,
// and — critically — the directories the enumerator FAILED TO READ.
//
// Every scan now accumulates a DiscoveryAudit:
//   * one console/log summary block at end of scan (fa24921 etiquette —
//     never per-file lines),
//   * a machine-readable sidecar under ~/Library/Logs/VideoScan/
//     (scan-audit-<stamp>.json) carrying the counts plus per-path lists for
//     the MEDIA-CANDIDATE classes only (sniff-fail, ffprobe-fail,
//     unreadable directories — not every skipped .txt),
//   * and an honesty hook: enumeration errors force scanWasComplete=false,
//     so the completion merge takes the upsert-never-prune path.
//
// Memory (worst case): the three path lists are capped at
// `maxRecordedPaths` (5,000) entries each; at a generous ~300 bytes per
// path that bounds the collector at ~4.5 MB regardless of volume size.
// Counters keep counting past the cap; `pathListsTruncated` says so.

import Foundation
import os

let discoveryAuditLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "discoveryAudit")

// MARK: - DiscoveryAudit (immutable snapshot, Codable → sidecar JSON)

/// What one scan's discovery phase saw, admitted, and skipped — with
/// per-path detail for the classes that could plausibly be missed media.
struct DiscoveryAudit: Codable, Equatable, Sendable {
    /// The scanned root (target.searchPath).
    var scanRoot: String = ""
    /// Volume display name (root's basename) for human readers of the sidecar.
    var volumeName: String = ""
    var startedAt: Date?
    var finishedAt: Date?

    // ── Files ──
    /// Regular files the walker saw (readable regular files, all extensions).
    var filesEnumerated: Int = 0
    /// Files admitted to the probe pipeline (== the scan's "discovered" count).
    var filesAdmitted: Int = 0
    /// Records actually committed to the catalog by this scan.
    var filesCataloged: Int = 0

    // ── Files skipped, by rule (counts only — these classes are noise) ──
    /// Extension is on the known-non-media list (.txt, .jpg, .pdf, …) or is
    /// an unrecognized extension while "Scan Unrecognized File Types" is off.
    var skippedNonMediaExtension: Int = 0
    /// Audio extension seen while "Scan For Audio Files" is off.
    var skippedAudioExtensionOff: Int = 0
    /// No extension while "Scan Files With No Extension" is off.
    var skippedExtensionlessOff: Int = 0
    /// Under the small-file floor (1 MB) with "Skip Small Files" on.
    var skippedSmallFile: Int = 0

    // ── Directories skipped, by rule (counts only) ──
    /// Skip-listed directory names (system trees, dev caches, Finder meta).
    var skippedSystemTreeDirs: Int = 0
    /// Bundle-extension directories (.app, .photoslibrary, … per options).
    var skippedBundleDirs: Int = 0

    // ── Media-candidate classes (counts + paths — someone may ask "where
    //    did my file go?", and these are the only classes where the honest
    //    answer isn't obvious) ──
    /// Admitted extensionless/unknown-extension files whose first bytes
    /// matched no media signature — ffprobe was skipped.
    var sniffRejected: Int = 0
    /// Probed files gated out of the catalog (extensionless/unknown
    /// extension + ffprobe could not identify — the 11e7ad0 junk gate).
    var probeRejected: Int = 0
    /// Directories the enumerator could not read. NON-ZERO MEANS DISCOVERY
    /// WAS INCOMPLETE — finalize must not treat the scan as complete.
    var directoryEnumerationErrors: Int = 0
    /// Filesystem entries the walker saw but could not examine: a regular
    /// file without read permission, or an entry whose resource values could
    /// not be fetched at all (QA 2026-07-02 — previously a silent `continue`).
    /// VISIBILITY ONLY: these do NOT force scan-incomplete. Manager decision:
    /// the merge's per-record existence check already retains records whose
    /// files are still on disk, so an unprobed-but-present file can never be
    /// pruned — the audit just has to say it exists.
    var unreadableFiles: Int = 0

    var sniffRejectedPaths: [String] = []
    var probeRejectedPaths: [String] = []
    /// "path — error description" per unreadable directory.
    var unreadableDirectories: [String] = []
    /// Unreadable-entry paths (capped like the other lists; count stays exact).
    var unreadableFilePaths: [String] = []
    /// True when any per-path list hit the recording cap (counts stay exact).
    var pathListsTruncated: Bool = false

    /// True when this scan resumed from a checkpoint whose ORIGINAL walk hit
    /// directory-enumeration errors (ScanCheckpoint.walkHadEnumerationErrors,
    /// QA 2026-07-02). A resumed scan never re-walks, so the incompleteness
    /// carries over — finalize must treat the scan as not-complete (upsert,
    /// never prune) even though the resume itself saw no enumeration errors.
    var resumedFromIncompleteWalk: Bool = false

    /// Discovery honesty flag: false when any directory could not be read —
    /// by THIS walk, or by the original walk behind a resumed checkpoint.
    var discoveryComplete: Bool {
        directoryEnumerationErrors == 0 && !resumedFromIncompleteWalk
    }
}

// MARK: - DiscoveryAuditCollector (thread-safe accumulator)

/// Mutable accumulator shared by the walker (detached task), the probe task
/// group (off-actor), and the finalize path (main actor).
///
/// A locked class rather than an `actor` so the walker's tight enumeration
/// loop can record synchronously — no suspension point per file. For Rick:
/// this is exactly a C++ struct guarded by a std::mutex; @unchecked Sendable
/// is the compiler waiver that says "the lock is the synchronization".
final class DiscoveryAuditCollector: @unchecked Sendable {

    /// Per-path list cap — see the memory note in the file header.
    static let maxRecordedPaths = 5_000

    private let lock = NSLock()
    private var audit: DiscoveryAudit

    init(scanRoot: String, volumeName: String) {
        var a = DiscoveryAudit()
        a.scanRoot = scanRoot
        a.volumeName = volumeName
        a.startedAt = Date()
        audit = a
    }

    // Small helper: every mutation takes the lock around one closure.
    private func with(_ body: (inout DiscoveryAudit) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&audit)
    }

    private func append(_ path: String, to list: WritableKeyPath<DiscoveryAudit, [String]>) {
        with { a in
            if a[keyPath: list].count < Self.maxRecordedPaths {
                a[keyPath: list].append(path)
            } else {
                a.pathListsTruncated = true
            }
        }
    }

    // ── Walker hooks ──
    func fileEnumerated() { with { $0.filesEnumerated += 1 } }
    func fileAdmitted() { with { $0.filesAdmitted += 1 } }
    func skippedNonMediaExtension() { with { $0.skippedNonMediaExtension += 1 } }
    func skippedAudioExtensionOff() { with { $0.skippedAudioExtensionOff += 1 } }
    func skippedExtensionlessOff() { with { $0.skippedExtensionlessOff += 1 } }
    func skippedSmallFile() { with { $0.skippedSmallFile += 1 } }
    func skippedSystemTreeDir() { with { $0.skippedSystemTreeDirs += 1 } }
    func skippedBundleDir() { with { $0.skippedBundleDirs += 1 } }
    func directoryEnumerationFailed(path: String, error: Error) {
        with { $0.directoryEnumerationErrors += 1 }
        append("\(path) — \(error.localizedDescription)", to: \.unreadableDirectories)
    }
    func unreadableFile(path: String) {
        with { $0.unreadableFiles += 1 }
        append(path, to: \.unreadableFilePaths)
    }

    // ── Resume hook ──
    /// Carry the ORIGINAL walk's incompleteness into a resumed scan's audit
    /// (checkpoint honesty, QA 2026-07-02).
    func markResumedFromIncompleteWalk() {
        with { $0.resumedFromIncompleteWalk = true }
    }

    // ── Probe-engine hooks ──
    func sniffRejected(path: String) {
        with { $0.sniffRejected += 1 }
        append(path, to: \.sniffRejectedPaths)
    }
    func probeRejected(path: String) {
        with { $0.probeRejected += 1 }
        append(path, to: \.probeRejectedPaths)
    }

    /// Read-only peek used by finalize to decide scan completeness before
    /// taking the full snapshot.
    var directoryEnumerationErrors: Int {
        lock.lock()
        defer { lock.unlock() }
        return audit.directoryEnumerationErrors
    }

    /// Read-only completeness peek for finalize: true when THIS walk hit
    /// enumeration errors OR the checkpoint this scan resumed from recorded
    /// that the original walk did.
    var walkWasIncomplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return audit.directoryEnumerationErrors > 0 || audit.resumedFromIncompleteWalk
    }

    /// Stamp the end-of-scan facts and return the immutable audit.
    func finish(cataloged: Int) -> DiscoveryAudit {
        lock.lock()
        defer { lock.unlock() }
        audit.filesCataloged = cataloged
        audit.finishedAt = Date()
        return audit
    }
}

// MARK: - Sidecar writer

enum DiscoveryAuditSidecar {

    /// Write `audit` as pretty JSON to `directory`, named
    /// `scan-audit-<ISO8601 stamp>.json` (uniquified — two scans finishing
    /// in the same second must not clobber each other). Returns the path,
    /// or nil when the write failed.
    @discardableResult
    static func write(_ audit: DiscoveryAudit, to directory: URL) -> String? {
        let stamp = ISO8601DateFormatter().string(from: audit.finishedAt ?? Date())
            .replacingOccurrences(of: ":", with: "-")
        var url = directory.appendingPathComponent("scan-audit-\(stamp).json")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("scan-audit-\(stamp).\(n).json")
            n += 1
        }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(audit).write(to: url, options: .atomic)
            return url.path
        } catch {
            discoveryAuditLog.error("Failed to write scan-audit sidecar: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
