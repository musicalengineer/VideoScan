// ArchiveRefile.swift
// Update an ARCHIVED file's name and/or date (Rick's ruling 2026-09-27:
// right-click ▸ Update… — two editable things, Name and Date). The folder
// follows the date through Promote's own placement function; the user never
// picks a folder. The case that started it: a Thanksgiving tape dated 1884
// by a typo sat in 30_Video/1880-1889/1884/.
//
// This file is the PURE layer and the FILESYSTEM engine; the model glue is
// VideoScanModel+ArchiveUpdate.swift and the sheet ArchiveUpdateSheet.swift.
// (Internal names keep "Refile" — the engine that moves the file.)
//
//   ArchiveRefile        — placement (`updatedRelPath`, from Promote's own
//                          folder / filename-prefix / slug rules), the sheet's labels, the
//                          manifest reads, the row-targeted manifest rewrite.
//   ArchiveRefileEngine  — the change, in order:
//     (a) refuse BEFORE any mutation: the grant does not cover it, archive
//         offline / read-only, a path not plain, target exists on disk or in
//         the manifest, source missing, source digest ≠ manifest digest;
//     (b) ONE same-volume rename — renameatx_np(RENAME_EXCL), dirfd-relative,
//         never copy + delete (EXDEV refuses);
//     (c) the file at the new path must be the same inode AND hash to the
//         manifest digest — otherwise it is renamed back;
//     (d) the manifest row (relpath, record_date, date_confidence) and the
//         journals' exact old-path values are rewritten under a #204 marker
//         backup via ArchiveIndexRename.apply, holding the 00_Index lock
//         (ArchiveIndexLock) through publish and rollback;
//     (f) any failure after the move → the file is renamed back (only if it
//         is still the original, by identity), every touched index file is
//         restored; unproven recovery keeps the backup and says so.
//   A name + date change is ONE move; a known/estimated-only change updates
//   the index row without moving anything.
//
//   LOCKED FILES (Rick 2026-09-27): an archived file carries UF_IMMUTABLE
//   (ArchiveFileLock). A move clears it on the source as the FIRST mutation
//   (inside the index transaction — a file that is locked and cannot be
//   unlocked is REFUSED, nothing changed), renames, and re-sets it on the
//   target. Every rollback re-locks the original where it is. Update ALWAYS
//   ends with the file locked, or says it is not ("file is not locked" —
//   `Done.lockProblem`, a warning outcome, logged loudly); never lost.

// Memory (worst case): the manifest's bytes twice (read + rewritten copy)
// plus each journal's bytes twice during the index rewrite (the
// ArchiveIndexRename budget: ~280 MB at 100k promotions, capped at 256 MB
// per file — a larger file refuses); the fixity hashes stream through
// ArchivePromoteEngine's 3 × 8 MiB ring. Nothing grows with the media size.
//
// (For Rick: `enum` with no cases = a C++ namespace of free functions;
// `Result<T, E>` ≈ std::expected<T, E>.)

import Darwin
import Foundation
import os
import VideoScanCore

let refileLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "refile")

enum ArchiveRefile {

    // MARK: Placement — one function, Promote's

    /// The slug part of an archive filename: "1884-xx-xx_DadThanksgiving.mov"
    /// → "DadThanksgiving". A name without the archive's date prefix is
    /// returned as its stem, unchanged.
    static func currentName(ofFilename filename: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        let c = Array(stem.utf8)
        func dx(_ b: UInt8) -> Bool { (b >= 0x30 && b <= 0x39) || b == 0x78 }   // 0-9 or 'x'
        guard c.count > 11,
              dx(c[0]), dx(c[1]), dx(c[2]), dx(c[3]), c[4] == 0x2D,
              dx(c[5]), dx(c[6]), c[7] == 0x2D,
              dx(c[8]), dx(c[9]), c[10] == 0x5F else { return stem }
        return String(decoding: c[11...], as: UTF8.self)
    }

    /// Where an Update puts the file — and it changes ONLY what was changed
    /// (Archive Update review r2 #4–#6):
    ///   • nothing about name or date changed → the EXACT current path;
    ///   • name only → same folder, same date prefix, the new name's slug;
    ///   • date changed → Promote's folder for that date
    ///     (`ArchivePathResolver.folder`) and its filename prefix
    ///     (`filenamePrefix`), with the new name's slug or the current name
    ///     kept VERBATIM (never re-slugged, so a collision suffix survives).
    /// The extension is always kept exactly. `newName` / `newHint` nil = keep.
    static func updatedRelPath(fromRelPath: String, streamType: StreamType, currentName: String,
                               newName: String?, newHint: ArchiveDateHint?) -> String {
        guard newName != nil || newHint != nil else { return fromRelPath }
        let filename = (fromRelPath as NSString).lastPathComponent
        let ext = (filename as NSString).pathExtension
        let dot = ext.isEmpty ? "" : "." + ext
        let stem = newName.map { ArchivePathResolver.slug(from: $0) } ?? currentName
        guard let hint = newHint else {
            let oldStem = (filename as NSString).deletingPathExtension
            let prefix = String(oldStem.dropLast(currentName.count))            // "1884-xx-xx_" or ""
            return (fromRelPath as NSString).deletingLastPathComponent + "/" + prefix + stem + dot
        }
        let f = facts(streamType: streamType, filename: filename, ext: ext, hint: hint)
        let folder = ArchivePathResolver.folder(for: f.streamType, hint: hint, medium: f.medium)
        return folder + "/" + hint.filenamePrefix + "_" + stem + dot
    }

    /// The facts the filing-year guard reads for a refile target.
    static func facts(streamType: StreamType, filename: String, ext: String,
                      hint: ArchiveDateHint) -> ArchivePathResolver.RecordFacts {
        ArchivePathResolver.RecordFacts(streamType: streamType, filename: filename, ext: ext,
                                        dateHint: hint, dateIsLowConfidence: false)
    }

    /// Year / month / day typed on the sheet → a hint, or nil when the
    /// combination is not a real date (month 13, 30 Feb, a day without a
    /// month). Validated by the same grammar as the Inspector's date field.
    static func hint(year: Int, month: Int?, day: Int?) -> ArchiveDateHint? {
        if day != nil && month == nil { return nil }
        var text = String(format: "%04d", year)
        if let month { text += String(format: "-%02d", month) }
        if let day { text += String(format: "-%02d", day) }
        guard let canonical = UserDateEntry.canonicalize(text) else { return nil }
        return hint(fromUserDate: canonical)
    }

    /// A canonical user date ("1984" / "1984-11" / "1984-11-14") as a hint.
    static func hint(fromUserDate canonical: String) -> ArchiveDateHint? {
        guard let (y, m, d) = UserDateEntry.components(of: canonical) else { return nil }
        if let m, let d { return .day(year: y, month: m, day: d) }
        if let m { return .month(year: y, month: m) }
        return .year(y)
    }

    /// The canonical user date for a hint (nil for decade / unknown — the
    /// user-date grammar has no decade form).
    static func userDate(for hint: ArchiveDateHint) -> String? {
        switch hint {
        case .day(let y, let m, let d): return String(format: "%04d-%02d-%02d", y, m, d)
        case .month(let y, let m):      return String(format: "%04d-%02d", y, m)
        case .year(let y):              return String(format: "%04d", y)
        case .decade, .unknown:         return nil
        }
    }

    // MARK: Folders and labels (for the Update sheet's "what will change" list)

    /// "30_Video/1880-1889/1884/1884-xx-xx_Dad.mov" → "1880-1889/1884".
    static func folder(ofRelPath relPath: String) -> String {
        let comps = relPath.split(separator: "/").map(String.init)
        return comps.count >= 3 ? comps[1..<(comps.count - 1)].joined(separator: "/") : ""
    }

    /// "1984" / "November 1984" / "14 Nov 1984" / "the 1980s" / "undated".
    static func datedLabel(_ hint: ArchiveDateHint) -> String {
        switch hint {
        case .decade(let s): return "the \(s)s"
        case .unknown: return "undated"
        default:
            return userDate(for: hint).map(UserDateEntry.friendlyDisplay) ?? hint.manifestDate
        }
    }

    /// The manifest's `record_date` cell ("1884-xx-xx", "1984-11-xx",
    /// "1984-11-14", "1880s", "") back to a hint.
    static func hint(fromManifestDate text: String) -> ArchiveDateHint {
        if text.hasSuffix("s"), let start = Int(text.dropLast()), text.count == 5 { return .decade(startYear: start) }
        let parts = text.split(separator: "-").map(String.init)
        guard let y = parts.first.flatMap({ Int($0) }), parts.first?.count == 4 else { return .unknown }
        guard parts.count > 1, let m = Int(parts[1]) else { return .year(y) }
        guard parts.count > 2, let d = Int(parts[2]) else { return .month(year: y, month: m) }
        return .day(year: y, month: m, day: d)
    }


    // MARK: Manifest reads (descriptor-relative, validated)

    struct ManifestReadFailure: Error, Equatable, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    /// What Refile needs from one manifest row.
    struct ManifestRow: Sendable, Equatable {
        let promotedAt: Date?
        let relPath: String
        let sha256: String
        let recordDate: String
        let dateConfidence: String
    }

    static func manifestRows(rootPath: String) -> Result<[ManifestRow], ManifestReadFailure> {
        let fd: Int32
        do {
            fd = try ArchivePromoteEngine.openIndexFile(root: rootPath, name: MasterArchiveLayout.manifestFilename,
                                                        mustExist: true,
                                                        expectedHeaders: MasterArchiveLayout.acceptedManifestHeaders)
        } catch {
            return .failure(ManifestReadFailure(reason: "the archive manifest could not be read (\(ArchiveAttestationJournal.describe(error)))"))
        }
        defer { close(fd) }
        guard let data = try? ArchivePromoteEngine.readAll(fd: fd, limit: ArchiveIndexRename.readLimit + 1),
              data.count <= ArchiveIndexRename.readLimit,
              let text = String(data: data, encoding: .utf8) else {
            return .failure(ManifestReadFailure(reason: "the archive manifest is unreadable or larger than \(ArchiveIndexRename.readLimit >> 20) MB"))
        }
        return .success(parseRows(text))
    }

    static func parseRows(_ text: String) -> [ManifestRow] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var rows: [ManifestRow] = []
        for line in ArchiveIndexText.lines(text).dropFirst() {   // header (CRLF-safe)
            let f = ArchiveManifestCSV.fields(ofLine: String(line))
            guard f.count >= ArchiveManifestCSV.columnCountLegacy, !f[1].isEmpty else { continue }
            rows.append(ManifestRow(promotedAt: iso.date(from: f[0]), relPath: f[1], sha256: f[2],
                                    recordDate: f[8], dateConfidence: f[9]))
        }
        return rows
    }

    // MARK: The row-targeted manifest rewrite

    /// Rewrite, in every data row whose `archive_relpath` is `from`: the
    /// relpath (→ `to`), `record_date` and `date_confidence`. Every other
    /// byte of the file is kept exactly (untouched lines byte-identical,
    /// untouched cells too — the same splice ArchiveIndexRename uses). A row
    /// with broken quoting that could match refuses (throws).
    static func rewriteManifestRows(_ bytes: [UInt8], from: String, to: String,
                                    recordDate: String, dateConfidence: String) throws -> (bytes: [UInt8], changedLines: Int) {
        let needle = Array(from.replacingOccurrences(of: "\"", with: "\"\"").utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 256)
        var changed = 0
        var start = 0
        var lineNumber = 1
        let file = MasterArchiveLayout.manifestFilename
        while start <= bytes.count {
            let end = ArchiveIndexRename.byteIndex(of: 0x0A, in: bytes[start...]) ?? bytes.count
            var line = bytes[start..<end]
            var replaced: [UInt8]?
            if lineNumber > 1, !line.isEmpty, ArchiveIndexRename.containsBytes(needle, in: line) {
                var suffix: ArraySlice<UInt8> = []
                if line.last == 0x0D {
                    suffix = line[(line.endIndex - 1)...]
                    line = line[..<(line.endIndex - 1)]
                }
                let cells = try ArchiveIndexRename.csvCells(line, file: file, line: lineNumber)
                if cells.count >= ArchiveManifestCSV.columnCountLegacy,
                   ArchiveIndexRename.csvDecode(line[cells[ArchiveManifestCSV.relPathColumn]]) == from {
                    let edits: [(Range<Int>, [UInt8])] = [
                        (cells[ArchiveManifestCSV.relPathColumn], Array(ArchiveManifestCSV.escape(to).utf8)),
                        (cells[8], Array(ArchiveManifestCSV.escape(recordDate).utf8)),
                        (cells[9], Array(ArchiveManifestCSV.escape(dateConfidence).utf8)),
                    ]
                    replaced = ArchiveIndexRename.splice(Array(line), base: line.startIndex, edits: edits) + Array(suffix)
                    changed += 1
                }
            }
            if let replaced {
                out.append(contentsOf: replaced)
            } else {
                out.append(contentsOf: bytes[start..<end])
            }
            if end == bytes.count { break }
            out.append(0x0A)
            start = end + 1
            lineNumber += 1
        }
        return (changed > 0 ? out : bytes, changed)
    }
}

// MARK: - The engine

enum ArchiveRefileEngine {

    /// What the move needs. All archive-relative paths.
    struct Request: Sendable, Equatable {
        let rootPath: String
        let fromRelPath: String
        let toRelPath: String
        /// For log lines only.
        let filename: String
        /// The manifest cells the row gets (ArchiveDateHint.manifestDate
        /// and the date_confidence vocabulary).
        let recordDate: String
        let dateConfidence: String
        /// What the sheet SAW in the manifest row's date cells. If the row
        /// says something else now, the sheet is stale and the update is
        /// refused — it never writes a cell it did not show (r3 #1). nil =
        /// no check (callers that do not come from a sheet).
        var expectedRecordDate: String? = nil
        var expectedDateConfidence: String? = nil
    }

    /// Test seams — production is `.live`. (`@Sendable` closures ≈
    /// std::function objects the compiler has checked are safe to hand
    /// to another thread.)
    struct Seams: Sendable {
        /// Streamed SHA-256 of an archive-relative file through the dirfd
        /// O_NOFOLLOW chain; nil = absent.
        var hashFile: @Sendable (_ root: String, _ relPath: String) throws -> String?
        /// statfs MNT_RDONLY on the archive root.
        var isVolumeReadOnly: @Sendable (_ root: String) -> Bool
        /// Publishes one rewritten index file (AtomicFilePublish, full fsync).
        var indexPublisher: @Sendable (Data, URL) throws -> Void
        /// Writes one backup file (same publish).
        var backupWriter: @Sendable (Data, URL) throws -> Void
        /// fsync(2) of a folder after the move / after the move back
        /// (0 = durable). Production = the engine's barrier.
        var directoryFsync: @Sendable (_ dirfd: Int32, _ phase: FsyncPhase) -> Int32 = { fd, _ in
            ArchivePromoteEngine.barriers.fsync(fd)
        }
        /// Runs after every preflight check passed and before the index
        /// lock is taken — a test's window for "another writer lands now".
        var afterPreflight: @Sendable () -> Void = {}
        /// The user-immutable flag (production = live fchflags).
        var fileLock: ArchiveFileLock.Seams = .live

        static let live = Seams(
            hashFile: { root, rel in try ArchivePromoteEngine.sha256(root: root, relativePath: rel) },
            isVolumeReadOnly: { root in ArchiveRefileEngine.liveIsReadOnly(root) },
            indexPublisher: { data, url in try ArchiveIndexRename.livePublish(data, to: url) },
            backupWriter: { data, url in try ArchiveIndexRename.livePublish(data, to: url) })
    }

    enum FsyncPhase: Sendable { case afterMove, afterMoveBack }

    nonisolated static func liveIsReadOnly(_ path: String) -> Bool {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return false }   // unreachable → the open refuses as offline
        return (fs.f_flags & UInt32(MNT_RDONLY)) != 0
    }

    struct Done: Sendable, Equatable {
        let fromRelPath: String
        let toRelPath: String
        let sha256: String
        let backupDir: String?
        let indexFilesChanged: Int
        let linesChanged: Int
        let promotedAt: Date?
        /// nil = the file is locked at `toRelPath`; else why it is NOT
        /// ("updated, not relocked" — a warning, never a rollback).
        var lockProblem: String? = nil
    }

    enum Outcome: Sendable, Equatable {
        /// Moved, verified, index updated.
        case refiled(Done)
        /// Refused before anything was changed. (A target folder that had
        /// to be created for a move that then failed may remain, empty.)
        case refused(String)
        /// Something had changed and was put back: the file is at `from`,
        /// the index files are their old bytes.
        case rolledBack(String)
        /// Putting it back ALSO failed — mixed state, every path in the text.
        /// `originalRelPath` = where the archived original IS, found by
        /// identity (nil = not found at either path).
        case mixedState(String, originalRelPath: String?)
        /// Put back (file at `from`, index files hold their old bytes) but
        /// the folder flush after the move back FAILED: not confirmed
        /// durable. The index backup is kept. Codex review #4.
        case incompleteRecovery(String)
    }

    /// The move back renamed the file, but a folder fsync failed.
    struct RecoveryNotDurable: Error, CustomStringConvertible {
        let description: String
    }

    /// (c) failed and the move back is not confirmed durable — apply keeps
    /// the backup for this one.
    private struct IncompleteRecovery: ArchiveIndexRename.BackupDisposition {
        let why: String
        var backupIsSafeToDiscard: Bool { false }
    }

    /// Errors the move step throws through ArchiveIndexRename.apply.
    private enum StepError: ArchiveIndexRename.BackupDisposition {
        case refusedBeforeMove(String)
        case rolledBack(String)
        case notRolledBack(String)

        /// Refused before the rename, or renamed back with both folders
        /// flushed: nothing changed. A failed move back is NOT.
        var backupIsSafeToDiscard: Bool {
            switch self {
            case .refusedBeforeMove, .rolledBack: return true
            case .notRolledBack: return false
            }
        }
    }

    /// Everything preflight proved, handed to the commit phase.
    private struct Prepared {
        let plan: ArchiveIndexRename.Plan
        let digest: String
        let sourceIdentity: ArchivePromoteEngine.FileIdentity
        let promotedAt: Date?
    }

    /// Run one refile. Synchronous and DISK-BOUND (two whole-file hashes) —
    /// call it off the main actor. `audit` gets every step line.
    static func execute(_ req: Request,
                        authorization: ArchiveRefileAuthorization,
                        seams: Seams = .live,
                        now: Date = Date(),
                        audit: (String) -> Void) -> Outcome {
        let subject = "Refile: \(req.filename) — "
        switch preflight(req, authorization: authorization, seams: seams, audit: { audit(subject + $0) }) {
        case .failure(let refusal):
            audit(subject + "refused: \(refusal.why). Nothing was changed.")
            return .refused(refusal.why)
        case .success(let prepared):
            seams.afterPreflight()
            return commit(req, prepared, seams: seams, now: now, subject: subject, audit: audit)
        }
    }

    private struct Refusal: Error { let why: String }

    /// (a) Every refusal, before ANY mutation; builds the index plan in memory.
    private static func preflight(_ req: Request, authorization: ArchiveRefileAuthorization,
                                  seams: Seams, audit: (String) -> Void) -> Result<Prepared, Refusal> {
        let root = req.rootPath, from = req.fromRelPath, to = req.toRelPath
        func no(_ why: String) -> Result<Prepared, Refusal> { .failure(Refusal(why: why)) }
        guard authorization.covers(rootPath: root, fromRelPath: from, toRelPath: to) else {
            return no("the archive write exception does not cover this move (\(from) → \(to))")
        }
        audit("checking the archive before moving \(from) → \(to)…")
        do {
            Darwin.close(try ArchivePromoteEngine.openDirectory(root))
        } catch {
            return no("the Master Archive at \(root) is not reachable (\(ArchiveAttestationJournal.describe(error)))")
        }
        if seams.isVolumeReadOnly(root) { return no("the archive volume is mounted read-only") }
        guard ArchivePromoteEngine.isContainedRelPath(from, root: root),
              ArchivePromoteEngine.isContainedRelPath(to, root: root) else {
            return no("\(from) → \(to) is not a place inside the archive")
        }
        // from == to: only the date's known/estimated changed — the index
        // row is updated, the file is not moved (no target to check).
        let moves = from != to
        // The manifest: read once through the validated descriptor; its
        // bytes are the ones the rewrite is built from.
        let manifestData: Data
        let manifestIdentity: ArchivePromoteEngine.FileIdentity
        do {
            (manifestData, manifestIdentity) = try ArchiveIndexRename.readIndexFile(
                root: root, name: MasterArchiveLayout.manifestFilename,
                expectedHeaders: MasterArchiveLayout.acceptedManifestHeaders)
        } catch {
            return no((error as? ArchiveIndexRename.Failure)?.errorDescription ?? "the archive manifest could not be read")
        }
        let rows = ArchiveRefile.parseRows(String(decoding: manifestData, as: UTF8.self))
        let mine = rows.filter { $0.relPath == from }
        guard let digest = mine.last?.sha256, !digest.isEmpty else {
            return no("the archive manifest has no row for \(from) — only files the index knows can be refiled")
        }
        guard Set(mine.map(\.sha256)).count == 1 else {
            return no("the archive manifest lists \(from) with \(Set(mine.map(\.sha256)).count) different fingerprints — check it by hand")
        }
        if let seen = req.expectedRecordDate, let seenConf = req.expectedDateConfidence,
           let row = mine.last, row.recordDate != seen || row.dateConfidence != seenConf {
            return no("This file changed since the sheet opened (the archive now says \(row.recordDate.isEmpty ? "no date" : row.recordDate), \(row.dateConfidence.isEmpty ? "no confidence" : row.dateConfidence)) — reopen Update…")
        }
        if moves, rows.contains(where: { $0.relPath == to }) { return no("the archive manifest already lists a file at \(to)") }
        if moves, let why = targetRefusal(root: root, to: to) { return no(why) }
        let sourceIdentity: ArchivePromoteEngine.FileIdentity
        switch sourceCheck(root: root, from: from, digest: digest, seams: seams, audit: audit) {
        case .failure(let r): return .failure(r)
        case .success(let id): sourceIdentity = id
        }
        switch indexPlan(req, manifestData: manifestData, manifestIdentity: manifestIdentity, expectedRows: mine.count) {
        case .failure(let r): return .failure(r)
        case .success(let plan):
            return .success(Prepared(plan: plan, digest: digest, sourceIdentity: sourceIdentity,
                                     promotedAt: mine.last?.promotedAt))
        }
    }

    /// Nothing at the target on disk (nor an in-flight Promote partial).
    private static func targetRefusal(root: String, to: String) -> String? {
        do {
            for probe in [to, to + ".partial"] {
                if let fd = try ArchivePromoteEngine.openContainedFile(root: root, relativePath: probe) {
                    Darwin.close(fd)
                    return "a file already exists at \(probe)"
                }
            }
        } catch {
            return "the target \(to) cannot be checked safely (\(ArchiveAttestationJournal.describe(error)))"
        }
        return nil
    }

    /// Source: present, a regular file, and its bytes ARE the manifest's
    /// (fixity first — never move a file we cannot vouch for).
    private static func sourceCheck(root: String, from: String, digest: String, seams: Seams,
                                    audit: (String) -> Void) -> Result<ArchivePromoteEngine.FileIdentity, Refusal> {
        func no(_ why: String) -> Result<ArchivePromoteEngine.FileIdentity, Refusal> { .failure(Refusal(why: why)) }
        let identity: ArchivePromoteEngine.FileIdentity
        do {
            guard let fd = try ArchivePromoteEngine.openContainedFile(root: root, relativePath: from) else {
                return no("the file is not at \(from)")
            }
            defer { Darwin.close(fd) }
            guard let (id, _) = ArchivePromoteEngine.FileIdentity.of(fd: fd) else { return no("could not stat \(from)") }
            identity = id
        } catch {
            return no("the source \(from) cannot be opened safely (\(ArchiveAttestationJournal.describe(error)))")
        }
        audit("verifying its fingerprint (SHA-256) at \(from) before the move — this reads the whole file…")
        do {
            guard let actual = try seams.hashFile(root, from) else { return no("the file is not at \(from)") }
            guard actual == digest else {
                return no("the file at \(from) does not match its manifest fingerprint (\(actual.prefix(12))… ≠ \(digest.prefix(12))…) — run Verify Copies before refiling")
            }
        } catch {
            return no("the file at \(from) could not be read (\(ArchiveAttestationJournal.describe(error)))")
        }
        audit("fixity verified at \(from) (sha256 \(digest.prefix(12))…)")
        return .success(identity)
    }

    /// The index plan, built in memory: the manifest row (targeted) plus the
    /// journals' exact old-path values. Nothing written.
    private static func indexPlan(_ req: Request, manifestData: Data,
                                  manifestIdentity: ArchivePromoteEngine.FileIdentity,
                                  expectedRows: Int) -> Result<ArchiveIndexRename.Plan, Refusal> {
        let root = req.rootPath, from = req.fromRelPath, to = req.toRelPath
        do {
            let rewrite = try ArchiveRefile.rewriteManifestRows([UInt8](manifestData), from: from, to: to,
                                                                 recordDate: req.recordDate,
                                                                 dateConfidence: req.dateConfidence)
            guard rewrite.changedLines == expectedRows else {
                return .failure(Refusal(why: "the manifest row for \(from) could not be located for rewriting (\(rewrite.changedLines) of \(expectedRows))"))
            }
            let manifestRewrite = ArchiveIndexRename.FileRewrite(
                name: MasterArchiveLayout.manifestFilename,
                url: MasterArchiveLayout.manifestURL(rootPath: root),
                original: manifestData, updated: Data(rewrite.bytes),
                changedLines: rewrite.changedLines, identity: manifestIdentity)
            let replacements = ArchiveIndexRename.Replacements(
                values: [from: to,
                         (root as NSString).appendingPathComponent(from): (root as NSString).appendingPathComponent(to)],
                oldFilename: (from as NSString).lastPathComponent,
                newFilename: (to as NSString).lastPathComponent)
            let prepared = try ArchiveIndexRename.prepare(root: root, replacements: replacements)
            let journals = prepared.files.filter { $0.name != MasterArchiveLayout.manifestFilename }
            return .success(ArchiveIndexRename.Plan(root: root, files: [manifestRewrite] + journals,
                                                    unchanged: prepared.unchanged.filter { $0.key != MasterArchiveLayout.manifestFilename }))
        } catch let f as ArchiveIndexRename.Failure {
            return .failure(Refusal(why: f.errorDescription ?? "the archive index could not be prepared"))
        } catch {
            return .failure(Refusal(why: "the archive index could not be prepared (\(ArchiveAttestationJournal.describe(error)))"))
        }
    }

    /// (b)–(d) under the #204 backup: backup → recheck → move + verify →
    /// publish; any failure after the move rolls back.
    private static func commit(_ req: Request, _ prep: Prepared, seams: Seams, now: Date,
                               subject: String, audit: (String) -> Void) -> Outcome {
        let root = req.rootPath, from = req.fromRelPath, to = req.toRelPath
        var moved = false
        var unlocked = false
        var recoveryNotDurable: String?
        let backupDir: URL?
        do {
            backupDir = try ArchiveIndexRename.apply(
                prep.plan, now: now, holder: "Archive update \(req.filename)",
                publisher: seams.indexPublisher,
                backupWriter: seams.backupWriter,
                announce: { dir in
                    audit(subject + "index backup written to \(dir.path); moving \(from) → \(to) (one rename on the same volume, never a copy)…")
                },
                moveMedia: {
                    guard from != to else { return }       // index-only update
                    // The FIRST mutation of the file: clear its lock. Locked
                    // and cannot be unlocked → refused, nothing changed.
                    switch ArchiveFileLock.set(.unlock, root: root, relPath: from, reason: .updateUnlock,
                                               seams: seams.fileLock, audit: { audit(subject + $0) }) {
                    case .changed: unlocked = true
                    case .alreadySo: break
                    case .absent: throw StepError.refusedBeforeMove("the file is not at \(from)")
                    case .failed(let why):
                        throw StepError.refusedBeforeMove("the file is locked and could not be unlocked (\(why))")
                    }
                    try moveAndVerify(root: root, from: from, to: to,
                                      srcName: (from as NSString).lastPathComponent,
                                      dstName: (to as NSString).lastPathComponent,
                                      sourceIdentity: prep.sourceIdentity, digest: prep.digest, seams: seams,
                                      moved: &moved, audit: { audit(subject + $0) })
                },
                undoMoveMedia: {
                    guard from != to else { return }
                    audit(subject + "putting the file back: \(to) → \(from)…")
                    do {
                        try moveBack(root: root, from: from, to: to, seams: seams, identity: prep.sourceIdentity)
                    } catch let e as RecoveryNotDurable {
                        recoveryNotDurable = e.description
                        throw e
                    }
                    audit(subject + "the file is back at \(from)")
                })
        } catch {
            let outcome = failureOutcome(error, req, prep, moved: moved, recoveryNotDurable: recoveryNotDurable,
                                         subject: subject, audit: audit)
            return unlocked ? relockAfterFailure(outcome, req, prep, seams: seams, subject: subject, audit: audit) : outcome
        }
        let lines = prep.plan.changedLines, files = prep.plan.files.count
        audit(subject + "index updated — \(lines) line\(lines == 1 ? "" : "s") in \(files) index file\(files == 1 ? "" : "s")\(backupDir.map { "; backup \($0.path)" } ?? "")")
        // Re-lock at the new place — ALWAYS (an index-only update locks a
        // file that somehow was not). A failure is a warning, never a rollback.
        var lockProblem: String?
        let relock = ArchiveFileLock.set(.lock, root: root, relPath: to, reason: .updateRelock,
                                         seams: seams.fileLock, audit: { audit(subject + $0) })
        if !relock.isOK {
            let why: String
            if case .failed(let w) = relock { why = w } else { why = "the file was not found at \(to) to lock" }
            lockProblem = "the file is NOT locked at \(to) (\(why)) — check the drive; Verify Copies lists every unlocked archive file"
            audit(subject + "WARNING: updated, but \(lockProblem ?? "")")
            refileLog.fault("refile relock failed: \(to, privacy: .public) — \(why, privacy: .public)")
        }
        return .refiled(Done(fromRelPath: from, toRelPath: to, sha256: prep.digest, backupDir: backupDir?.path,
                             indexFilesChanged: files, linesChanged: lines, promotedAt: prep.promotedAt,
                             lockProblem: lockProblem))
    }

    /// The file was unlocked and the change did not complete: lock the
    /// ORIGINAL again wherever it is (found by identity). A failure to do so
    /// is added to the outcome's text — never hidden.
    private static func relockAfterFailure(_ outcome: Outcome, _ req: Request, _ prep: Prepared, seams: Seams,
                                           subject: String, audit: (String) -> Void) -> Outcome {
        let root = req.rootPath
        let at: String?
        switch outcome {
        case .mixedState(_, let original): at = original
        default: at = locateOriginal(root: root, candidates: [req.fromRelPath, req.toRelPath], identity: prep.sourceIdentity)
        }
        let result = at.map {
            ArchiveFileLock.set(.lock, root: root, relPath: $0, reason: .updateRollbackRelock,
                                seams: seams.fileLock, audit: { audit(subject + $0) })
        } ?? .absent
        guard !result.isOK else { return outcome }
        let note = " — AND the file could not be locked again\(at.map { " at \($0)" } ?? " (not found by identity)"): the file is not locked (Verify Copies lists every unlocked archive file)"
        audit(subject + "WARNING\(note)")
        refileLog.fault("refile rollback relock failed at \(at ?? "?", privacy: .public)")
        switch outcome {
        case .refused(let w): return .refused(w + note)
        case .rolledBack(let w): return .rolledBack(w + note)
        case .incompleteRecovery(let w): return .incompleteRecovery(w + note)
        case .mixedState(let w, let o): return .mixedState(w + note, originalRelPath: o)
        case .refiled: return outcome
        }
    }

    /// Map a failure of the commit phase to an outcome, proving what it
    /// can from disk (bytes of the index files, identity of the file).
    private static func failureOutcome(_ error: Error, _ req: Request, _ prep: Prepared,
                                       moved: Bool, recoveryNotDurable: String?,
                                       subject: String, audit: (String) -> Void) -> Outcome {
        let root = req.rootPath, from = req.fromRelPath, to = req.toRelPath
        func mixed(_ why: String) -> Outcome {
            // Where is the ARCHIVED ORIGINAL now? By identity (device +
            // inode + size), never by "a file exists at that path" — a
            // foreign file at the old name must not be mistaken for it.
            let at = locateOriginal(root: root, candidates: [to, from], identity: prep.sourceIdentity)
            let place = at.map { "The archived original is at \($0)." }
                ?? "The archived original could not be found by identity at \(from) or \(to)."
            let text = "\(why) Paths: \(from) (old) and \(to) (new). \(place) Nothing was deleted."
            audit(subject + "FAILED and the ROLLBACK FAILED: \(text)")
            refileLog.fault("refile mixed state: \(text, privacy: .public)")
            return .mixedState(text, originalRelPath: at)
        }
        func incomplete(_ why: String) -> Outcome {
            audit(subject + "FAILED, put back, but recovery NOT CONFIRMED DURABLE: \(why). The index backup is KEPT in 00_Index/\(ArchiveIndexRename.backupFolder).")
            refileLog.fault("refile incomplete recovery: \(why, privacy: .public)")
            return .incompleteRecovery(why)
        }
        switch error {
        case StepError.refusedBeforeMove(let why):
            audit(subject + "refused: \(why). Nothing was changed.")
            return .refused(why)
        case StepError.rolledBack(let why):
            audit(subject + "FAILED and ROLLED BACK: \(why). The file is back at \(from); the index was not changed.")
            return .rolledBack(why)
        case let e as IncompleteRecovery:
            return incomplete(e.why)
        case StepError.notRolledBack(let why):
            return mixed(why)
        case let f as ArchiveIndexRename.Failure:
            let text = f.errorDescription ?? "the archive index could not be updated"
            if case .publishFailedNotRolledBack = f {
                // Only the move back's flush failed? Prove the rest by bytes
                // and identity: every index file holds its original bytes and
                // the original is back at `from`.
                // Everything is back in place by bytes and identity, and only
                // DURABILITY is unconfirmed (the media's move back, or an
                // index restore that threw) → incompleteRecovery, not mixed.
                if prep.plan.files.allSatisfy({ (try? Data(contentsOf: $0.url)) == $0.original }),
                   locateOriginal(root: root, candidates: [from], identity: prep.sourceIdentity) == from {
                    let nd = recoveryNotDurable ?? "an index restore was not confirmed durable"
                    return incomplete("\(text) — the file is at \(from) and the index holds its old bytes, but \(nd)")
                }
                return mixed(text)
            }
            if moved {
                audit(subject + "FAILED and ROLLED BACK: \(text) The file is back at \(from); every index file holds its old bytes.")
                return .rolledBack(text)
            }
            audit(subject + "refused: \(text). Nothing was changed.")
            return .refused(text)
        default:
            let text = ArchiveAttestationJournal.describe(error)
            if moved { return .rolledBack(text) }
            audit(subject + "refused: \(text). Nothing was changed.")
            return .refused(text)
        }
    }

    /// The first candidate relpath holding the file with this identity
    /// (device + inode + size, through the O_NOFOLLOW dirfd chain), or nil.
    static func locateOriginal(root: String, candidates: [String],
                               identity: ArchivePromoteEngine.FileIdentity) -> String? {
        for rel in candidates {
            guard let fd = try? ArchivePromoteEngine.openContainedFile(root: root, relativePath: rel) else { continue }
            defer { Darwin.close(fd) }
            if let (id, _) = ArchivePromoteEngine.FileIdentity.of(fd: fd),
               id.device == identity.device, id.inode == identity.inode, id.size == identity.size {
                return rel
            }
        }
        return nil
    }

    /// (b) + (c): the rename and the proof. On a verify failure the file is
    /// renamed back HERE (apply publishes nothing when this throws).
    private static func moveAndVerify(root: String, from: String, to: String,
                                      srcName: String, dstName: String,
                                      sourceIdentity: ArchivePromoteEngine.FileIdentity,
                                      digest: String, seams: Seams, moved: inout Bool,
                                      audit: (String) -> Void) throws {
        let srcDir: Int32, dstDir: Int32
        do {
            srcDir = try ArchivePromoteEngine.openDestinationDirectory(root: root, relativePath: from, create: false)
        } catch {
            throw StepError.refusedBeforeMove("the source folder of \(from) could not be opened (\(ArchiveAttestationJournal.describe(error)))")
        }
        defer { Darwin.close(srcDir) }
        // The file about to move must STILL be the one whose fingerprint was
        // checked (device + inode + size + mtime), read through the same
        // folder descriptor the rename uses — a swapped source is refused
        // before anything moves (Archive Update review r2 #2).
        guard let (now, mode) = ArchivePromoteEngine.FileIdentity.at(dirfd: srcDir, name: srcName), mode == S_IFREG,
              now == sourceIdentity else {
            throw StepError.refusedBeforeMove("the file at \(from) changed after its fingerprint was checked — nothing was moved")
        }
        do {
            dstDir = try ArchivePromoteEngine.openDestinationDirectory(root: root, relativePath: to, create: true)
        } catch {
            throw StepError.refusedBeforeMove("the target folder for \(to) could not be made (\(ArchiveAttestationJournal.describe(error)))")
        }
        defer { Darwin.close(dstDir) }

        // ONE rename: same volume (EXDEV refuses — never a copy + delete),
        // no-clobber (EEXIST refuses), descriptor-relative (no symlink walk).
        guard renameatx_np(srcDir, srcName, dstDir, dstName, UInt32(RENAME_EXCL)) == 0 else {
            let e = errno
            let why: String
            switch e {
            case EEXIST: why = "a file appeared at \(to) just now"
            case EXDEV:  why = "the target folder is on a different volume — refile only renames, it never copies"
            case EROFS:  why = "the archive volume is read-only"
            default:     why = "rename failed (\(String(cString: strerror(e))), errno \(e))"
            }
            throw StepError.refusedBeforeMove(why)
        }
        moved = true
        audit("moved \(from) → \(to)")

        func putBack(_ why: String) -> any Error {
            do {
                try moveBack(root: root, from: from, to: to, seams: seams, identity: sourceIdentity)
                audit("the file is back at \(from)")
                return StepError.rolledBack(why)
            } catch let e as RecoveryNotDurable {
                audit("the file is back at \(from), but \(e) — recovery NOT confirmed durable")
                return IncompleteRecovery(why: "\(why); the file was moved back to \(from) but \(e)")
            } catch let e as NotTheOriginal {
                audit("NOT moving it back: \(e)")
                return StepError.notRolledBack("\(why) — AND \(e)")
            } catch {
                return StepError.notRolledBack("\(why) — AND the file could not be moved back: it is at \(to), the index still says \(from). \(ArchiveAttestationJournal.describe(error))")
            }
        }

        // The names are durable before anything else is claimed.
        guard seams.directoryFsync(dstDir, .afterMove) == 0, seams.directoryFsync(srcDir, .afterMove) == 0 else {
            throw putBack("the folders could not be flushed to disk after the move")
        }
        // (c) The file at the new name IS the file we verified…
        guard let (after, mode) = ArchivePromoteEngine.FileIdentity.at(dirfd: dstDir, name: dstName), mode == S_IFREG,
              after.device == sourceIdentity.device, after.inode == sourceIdentity.inode,
              after.size == sourceIdentity.size else {
            throw putBack("the file at \(to) is not the file that was moved")
        }
        // …and its bytes still match the manifest.
        audit("verifying its fingerprint at \(to) after the move…")
        let actual: String?
        do {
            actual = try seams.hashFile(root, to)
        } catch {
            throw putBack("the file at \(to) could not be read back (\(ArchiveAttestationJournal.describe(error)))")
        }
        guard actual == digest else {
            throw putBack("the file at \(to) does not match its manifest fingerprint after the move (\((actual ?? "missing").prefix(12))… ≠ \(digest.prefix(12))…)")
        }
        audit("fixity verified at \(to)")
    }

    /// Rename `to` back to `from` (no-clobber) and flush both folders.
    /// The file at the place a move back would take it from (or has put it)
    /// is NOT the archived original: nothing is renamed onto the old path
    /// (r4 #2), or — if a swap raced the rename — it is reported.
    struct NotTheOriginal: Error, CustomStringConvertible {
        let description: String
    }

    private static func moveBack(root: String, from: String, to: String, seams: Seams,
                                 identity: ArchivePromoteEngine.FileIdentity) throws {
        let srcDir = try ArchivePromoteEngine.openDestinationDirectory(root: root, relativePath: from, create: false)
        defer { Darwin.close(srcDir) }
        let dstDir = try ArchivePromoteEngine.openDestinationDirectory(root: root, relativePath: to, create: false)
        defer { Darwin.close(dstDir) }
        let toName = (to as NSString).lastPathComponent, fromName = (from as NSString).lastPathComponent
        func isOriginal(_ dirfd: Int32, _ name: String) -> Bool {
            guard let (id, mode) = ArchivePromoteEngine.FileIdentity.at(dirfd: dirfd, name: name), mode == S_IFREG else { return false }
            return id.device == identity.device && id.inode == identity.inode && id.size == identity.size
        }
        // Put back ONLY the archived original (device + inode + size). A
        // stranger at `to` is left exactly where it is.
        guard isOriginal(dstDir, toName) else {
            throw NotTheOriginal(description: "the file now at \(to) is NOT the archived original (another writer replaced it) — it was left in place and nothing was moved back to \(from)")
        }
        guard renameatx_np(dstDir, toName, srcDir, fromName, UInt32(RENAME_EXCL)) == 0 else {
            let e = errno
            throw ArchivePromoteEngine.Failure.renameFailed(to + " → " + from, errno: e)
        }
        guard isOriginal(srcDir, fromName) else {
            throw NotTheOriginal(description: "the file moved back to \(from) is NOT the archived original (a swap raced the move back) — both paths need checking by hand")
        }
        // Checked (codex review #4): a move back whose folders cannot be
        // flushed is not a confirmed recovery.
        let a = seams.directoryFsync(srcDir, .afterMoveBack)
        let b = seams.directoryFsync(dstDir, .afterMoveBack)
        guard a == 0, b == 0 else {
            throw RecoveryNotDurable(description: "the folder flush after moving it back failed (fsync \(a == 0 ? "ok" : "FAILED") on the original folder, \(b == 0 ? "ok" : "FAILED") on the target folder)")
        }
    }
}
