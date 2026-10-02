// ArchiveDigestIndex.swift
// GH #190 (Rick approved 2026-10-02): "Promote never puts a second copy of
// the same bytes into the archive; it says which archived file already
// holds them."
//
// On 2026-09-01 the same 62.7 GB tape went in twice, 54 minutes apart,
// under two names (Christmas_1994_etc / Chrsitmas_1994_misc) from two source
// paths. Promote's idempotency was keyed on the SOURCE RECORD and on the
// destination NAME, so a byte-identical file from another path with another
// name sailed through.
//
// THE INDEX. sha256 → archive-relative path, built ONCE per Promote run:
//   1. the 00_Index manifest's rows (read off-main through the validated
//      descriptor chain, the same read Verify Copies uses);
//   2. the archive's fixity data: catalog archive copies inside this root
//      carrying a verified `archiveFixity` (a copy whose row was lost or
//      that an older tool placed).
// Lookups are O(1) — never a scan of the manifest per file (100k rows are
// pinned by the scale test).
//
// THE CLAIMS. What landed or is landing in THIS PROCESS since the index
// was read: `VideoScanModel.promoteDigestClaims[root][sha] = relPath`.
// Main-actor, so look-up-then-claim is atomic between two files of one
// batch and between two Promote jobs running at once (the archive's volume
// gate can be wider than one slot, and an unrestricted volume has none).
// A claim is taken BEFORE the journal intent and released if that file
// does not land; a landed claim stays for the life of the process (the
// bytes are in the archive — a later job whose index predates the landing
// must still see them). Per model, so a test's catalog never inherits
// another's claims.
//
// Malformed manifest rows are SKIPPED AND REPORTED (Rick's ruling for the
// Lock job, codex r1 #5): counted on the index and logged once per run. An
// index that cannot be opened or read at all REFUSES the run — Promote
// cannot prove the bytes are not already archived.
//
// (For Rick: a struct with `mutating` methods ≈ a C++ value type with
// non-const members; `[String: String]` ≈ std::unordered_map.)

import Foundation
import VideoScanCore

struct ArchiveDigestIndex: Sendable, Equatable {

    /// lowercase sha256 → archive-relative path. First writer wins (the
    /// manifest is read first, so its path is the one named).
    private(set) var relPathByDigest: [String: String] = [:]
    /// Manifest data rows that could not be read (short, no relpath, or a
    /// sha256 that is not 64 hex digits) — skipped and reported.
    private(set) var malformedRows = 0

    var count: Int { relPathByDigest.count }

    /// The archived file already holding `digest`, if any. O(1).
    func relPath(forDigest digest: String) -> String? {
        relPathByDigest[digest.lowercased()]
    }

    /// Record `digest` at `relPath` unless the index already names a file
    /// for it. Returns false for a non-digest (never indexed).
    @discardableResult
    mutating func insert(digest: String, relPath: String) -> Bool {
        let key = digest.lowercased()
        guard Self.isSHA256(key), !relPath.isEmpty else { return false }
        if relPathByDigest[key] == nil { relPathByDigest[key] = relPath }
        return true
    }

    /// 64 lowercase-or-uppercase hex digits.
    nonisolated static func isSHA256(_ s: String) -> Bool {
        let u = s.utf8
        guard u.count == 64 else { return false }
        return u.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) || ($0 >= 0x41 && $0 <= 0x46) }
    }

    // MARK: Manifest leg (pure parse + contained load)

    /// Pure manifest text → index. Header skipped (CRLF-safe line split).
    /// A row's relpath is data from disk (codex R4-A): one that is not
    /// lexically contained (`..`, absolute, empty components) names no
    /// archived file — skipped and counted, never indexed, so a poisoned
    /// row can neither name an outside path nor block a real promote.
    nonisolated static func parse(manifestText text: String) -> ArchiveDigestIndex {
        var index = ArchiveDigestIndex()
        for line in ArchiveIndexText.lines(text).dropFirst() {
            let raw = String(line)
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let f = ArchiveManifestCSV.fields(ofLine: raw)
            guard f.count >= 12, !f[ArchiveManifestCSV.relPathColumn].isEmpty,
                  isLexicallyContained(f[ArchiveManifestCSV.relPathColumn]),
                  index.insert(digest: f[ArchiveManifestCSV.sha256Column],
                               relPath: f[ArchiveManifestCSV.relPathColumn]) else {
                index.malformedRows += 1
                continue
            }
        }
        return index
    }

    /// The lexical half of `ArchivePromoteEngine.isContainedRelPath`, which
    /// alone decides containment for a relative path: not absolute, at least
    /// one folder plus a leaf, no empty / `.` / `..` component (stricter
    /// than `pathComponents`: `a//b` is refused). The index never OPENS a
    /// row's path — it only names it in a refusal — so the per-row URL
    /// standardization (≈ 17 µs, 1.7 s per 100k rows in Debug) is skipped.
    nonisolated static func isLexicallyContained(_ rel: String) -> Bool {
        guard !rel.isEmpty, !rel.hasPrefix("/") else { return false }
        let comps = rel.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        guard comps.count >= 2 else { return false }
        for c in comps {
            if c.isEmpty { return false }
            if c.count == 1, c.first == UInt8(ascii: ".") { return false }
            if c.count == 2, c.allSatisfy({ $0 == UInt8(ascii: ".") }) { return false }
        }
        return true
    }

    /// Read the manifest THROUGH the validated descriptor chain (dirfd,
    /// O_NOFOLLOW, regular file, known header) — never by bare path —
    /// then parse. Throws when it cannot be opened or is not UTF-8.
    nonisolated static func load(rootPath: String) throws -> ArchiveDigestIndex {
        let fd = try ArchivePromoteEngine.openIndexFile(
            root: rootPath, name: MasterArchiveLayout.manifestFilename,
            mustExist: true, expectedHeaders: MasterArchiveLayout.acceptedManifestHeaders)
        defer { close(fd) }
        let data = try ArchivePromoteEngine.readAll(fd: fd)
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw ArchivePromoteEngine.Failure.manifestInvalid(
                "\(MasterArchiveLayout.manifestFilename) is not valid UTF-8 — the archive index cannot be read to check for files already archived")
        }
        return parse(manifestText: text)
    }

    /// `load` off the main actor (a 100k-row manifest is tens of MB).
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func loadOffMain(rootPath: String) async throws -> ArchiveDigestIndex {
        try load(rootPath: rootPath)
    }

    // MARK: Fixity leg (catalog archive copies)

    /// Add every catalog archive copy INSIDE `root` that carries a verified
    /// whole-file digest whose byte count matches the record. Copies outside
    /// the root belong to another (or an older) archive and are ignored.
    /// Purged / set-aside / superseded records are deliberately KEPT: their
    /// bytes may still be on disk, and missing a duplicate is the unsafe
    /// direction (a false refusal names a path Rick can check by hand).
    /// O(records), once per run.
    @MainActor
    mutating func addArchiveCopies(_ records: [VideoRecord], root: String) {
        for r in records where r.derivationKind == ArchivePromotion.derivationKind || ArchivePathResolver.isInside(path: r.fullPath, root: root) {
            guard let f = r.archiveFixity, !f.digest.isEmpty, f.sizeBytes == r.sizeBytes,
                  let rel = VerifyArchiveCopiesJob.relPath(of: r.fullPath, underRoot: root),
                  !rel.hasPrefix(MasterArchiveLayout.indexFolder + "/") else { continue }
            insert(digest: f.digest, relPath: rel)
        }
    }
}

// MARK: - Process-wide claims (per model, per archive root)

extension VideoScanModel {

    /// The archived (or in-flight) file holding `digest` in `root` per this
    /// process's claims, if any. O(1).
    func promoteDigestClaim(_ digest: String, root: String) -> String? {
        promoteDigestClaims[PathScope.normalize(root)]?[digest.lowercased()]
    }

    /// Claim `digest` for `relPath` in `root`. Returns the EXISTING claim's
    /// path (and claims nothing) when another file already holds it.
    func claimPromoteDigest(_ digest: String, relPath: String, root: String) -> String? {
        let r = PathScope.normalize(root), d = digest.lowercased()
        if let held = promoteDigestClaims[r]?[d] { return held }
        promoteDigestClaims[r, default: [:]][d] = relPath
        return nil
    }

    /// Point an existing claim at its final path (or record a landing that
    /// had no claim — reconcile / adoption paths).
    func notePromotedDigest(_ digest: String, relPath: String, root: String) {
        promoteDigestClaims[PathScope.normalize(root), default: [:]][digest.lowercased()] = relPath
    }

    /// Release a claim this file took but did not land on. Only removes the
    /// claim when it still names `relPath` (never another file's claim).
    func releasePromoteDigest(_ digest: String, relPath: String, root: String) {
        let r = PathScope.normalize(root), d = digest.lowercased()
        guard promoteDigestClaims[r]?[d] == relPath else { return }
        promoteDigestClaims[r]?[d] = nil
    }
}
