// ArchiveRefile.swift
// Refile — move an ALREADY-ARCHIVED file to the folder its CURRENT date
// says, inside the Master Archive (Rick's approved workflow, 2026-09-27).
// The case that started it: a Thanksgiving tape dated 1884 by a typo was
// promoted into 30_Video/1880-1889/1884/; the date was later corrected to
// 1984, and the file stayed filed under 1884.
//
// This file is the PURE layer and the FILESYSTEM engine; the model glue
// (catalog record, ledger, audit sink, Misfiled refresh) is
// VideoScanModel+ArchiveRefile.swift and the sheet is ArchiveRefileSheet.swift.
//
//   ArchiveRefile          — placement (the SAME function Promote uses:
//                            ArchivePathResolver.baseRelativePath), the
//                            "Misfiled" rule, the Why line, the row-targeted
//                            manifest rewrite. No I/O except the manifest
//                            relpath read.
//   ArchiveRefileEngine    — the move, in Rick's order:
//     (a) refuse BEFORE any mutation: grant does not cover the move, archive
//         offline / read-only, source or target path not plain, target (or
//         its .partial) exists on disk or in the manifest, source missing,
//         source digest ≠ manifest digest (fixity first), index unreadable;
//     (b) ONE same-volume rename — renameatx_np(RENAME_EXCL), descriptor-
//         relative, never copy + delete (EXDEV refuses instead of copying);
//     (c) the file at the new path must be the same inode AND hash to the
//         manifest digest — otherwise it is renamed back;
//     (d) the 00_Index manifest row (relpath + record_date + date_confidence)
//         and the journals' exact old path values are rewritten under a
//         backup claimed with the #204 marker machinery
//         (ArchiveIndexRename.apply — backup → recheck → move → publish →
//         rollback);
//     (f) any failure after the move → the file is renamed back, every
//         published index file restored from its in-memory original, and
//         the outcome says so.
//   Step (e) — the ledger event and the catalog record — is the model's.
//
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

    /// Where Promote would put this file with THIS date and THIS name —
    /// `ArchivePathResolver.baseRelativePath`, the function Promote's
    /// destination chooser starts from. No `_NN` suffix: a Refile whose
    /// target is taken is REFUSED (Rick's rule), never silently renamed.
    static func targetRelPath(streamType: StreamType, filename: String, ext: String,
                              hint: ArchiveDateHint, name: String) -> String {
        let facts = ArchivePathResolver.RecordFacts(streamType: streamType, filename: filename, ext: ext,
                                                    dateHint: hint, dateIsLowConfidence: false)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? currentName(ofFilename: filename) : trimmed
        return ArchivePathResolver.baseRelativePath(facts: facts, title: title)
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

    // MARK: Folders

    /// "30_Video/1880-1889/1884/1884-xx-xx_Dad.mov" → bucket "30_Video",
    /// tail "1880-1889/1884". nil when the path is not <media bucket>/…/<file>
    /// (00_Index, 40_Family_Tree, a file dropped at the root).
    static func filedTail(relPath: String) -> (bucket: String, tail: String)? {
        let comps = relPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard comps.count >= 3, MasterArchiveLayout.buckets.contains(comps[0]) else { return nil }
        return (comps[0], comps[1..<(comps.count - 1)].joined(separator: "/"))
    }

    /// The folder tail Promote's rule gives this date ("1980-1989/1984").
    static func expectedTail(streamType: StreamType, filename: String, ext: String,
                             hint: ArchiveDateHint) -> String {
        let facts = facts(streamType: streamType, filename: filename, ext: ext, hint: hint)
        let folder = ArchivePathResolver.folder(for: facts.streamType, hint: hint, medium: facts.medium)
        return folder.split(separator: "/").dropFirst().joined(separator: "/")
    }

    /// "1884" (a year folder), "the 1880s" (a decade folder), "Undated".
    static func folderLabel(tail: String) -> String {
        let last = tail.split(separator: "/").last.map(String.init) ?? tail
        if last == MasterArchiveLayout.undatedFolder { return "Undated" }
        if last.count == 4, Int(last) != nil { return last }
        if last.count == 9, let start = Int(last.prefix(4)) { return "the \(start)s" }
        return last
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

    // MARK: Where the current date came from

    enum Provenance: Sendable, Equatable {
        /// Rick's hand-entered date. `onCopy`: typed on the archive copy's
        /// own record rather than on the original he sees in the lists.
        case userDate(onCopy: Bool, known: Bool, canonical: String)
        /// A machine date at or above the filing floor.
        case machine(source: RecordDateResolution.Source, confidence: Float)
        /// Typed on the Refile sheet itself.
        case typedOnRefileSheet

        /// The manifest's `date_confidence` cell for a file filed on this
        /// date — the same vocabulary Promote writes.
        var manifestConfidence: String {
            switch self {
            case .userDate(_, let known, _): return known ? "user-known" : "user-estimated"
            case .machine(let source, let c):
                return String(format: "%@ %.2f", source == .inferred ? "inferred" : source.rawValue, c)
            case .typedOnRefileSheet: return "user-estimated"
            }
        }

        /// One token for the ledger's `provenance` detail.
        var ledgerToken: String {
            switch self {
            case .userDate(let onCopy, let known, let canonical):
                return "user date \(canonical) (\(known ? "known" : "estimated"))\(onCopy ? " on the archive copy" : "")"
            case .machine(let source, let c):
                return "machine date from \(Self.sourcePhrase(source)) (\(Int((c * 100).rounded()))% sure)"
            case .typedOnRefileSheet:
                return "typed on the Refile sheet"
            }
        }

        static func sourcePhrase(_ s: RecordDateResolution.Source) -> String {
            switch s {
            case .embedded: return "the date written inside the file"
            case .inferred: return "what the video shows (on-screen dates / speech)"
            case .filename: return "its filename"
            case .userDate: return "your date"
            case .none: return "nothing"
            }
        }
    }

    // MARK: Misfiled — the rule

    /// Everything the rule reads about ONE archive copy, captured on the main
    /// actor (a Sendable value, so the evaluation runs off-main).
    struct Candidate: Sendable, Equatable {
        /// The row the Archive window shows: the original (promotion source)
        /// when it is still in the catalog, else the copy itself.
        let rowID: UUID
        let copyID: UUID
        let copyRelPath: String
        let streamTypeRaw: String
        let copyFilename: String
        let ext: String
        /// The ORIGINAL's filename (what Promote resolved the date from).
        /// NOT the archive name: "1884-xx-xx_Dad.mov" would feed the typo'd
        /// year straight back into the filename-date rule.
        let originalFilename: String
        let originalUserDate: String?
        let originalUserDateConfidence: String?
        let copyUserDate: String?
        let copyUserDateConfidence: String?
        let embeddedCreationDate: Date?
        let originMake: String?
        let originModel: String?
        let originEncoder: String?
        let inferredRecordDate: Date?
        let inferredDateConfidence: Float?
        let inferredDateRange: InferredDateRange?

        var streamType: StreamType { StreamType(rawValue: streamTypeRaw) ?? .ffprobeFailed }
    }

    /// One misfiled archive file.
    struct Finding: Sendable, Equatable {
        let rowID: UUID
        let copyID: UUID
        let filedRelPath: String
        let filedTail: String
        let dated: ArchiveDateHint
        let expectedTail: String
        let provenance: Provenance

        var filedLabel: String { ArchiveRefile.folderLabel(tail: filedTail) }
        var datedLabel: String { ArchiveRefile.datedLabel(dated) }
        /// The Catalog badge: "filed under 1884 · dated 1984".
        var badgeText: String { "filed under \(filedLabel) · dated \(datedLabel)" }
    }

    private static func resolve(_ c: Candidate, userDate: String?, confidence: String?) -> RecordDateResolution {
        RecordDateResolver.resolve(userDate: userDate, userDateConfidence: confidence,
                                   embeddedCreationDate: c.embeddedCreationDate,
                                   originMake: c.originMake, originModel: c.originModel,
                                   originEncoder: c.originEncoder,
                                   inferredRecordDate: c.inferredRecordDate,
                                   inferredDateConfidence: c.inferredDateConfidence,
                                   inferredDateRange: c.inferredDateRange,
                                   filename: c.originalFilename.isEmpty ? nil : c.originalFilename)
    }

    /// The file's CURRENT resolved date, by Rick's rule: a hand-entered date
    /// first — the original's, then the copy's, and of two that disagree the
    /// one that no longer matches the folder (at Promote and at Refile both
    /// are made equal to the folder, so the one that differs is the one that
    /// was changed since) — then a machine date at or above the resolver's
    /// filing floor (`ArchivePathResolver.isLowConfidence` is false). nil =
    /// nothing trustworthy is known.
    static func currentDate(of c: Candidate) -> (hint: ArchiveDateHint, provenance: Provenance)? {
        let filed = filedTail(relPath: c.copyRelPath)?.tail
        var firstAgreeing: (ArchiveDateHint, Provenance)?
        for (onCopy, ud, conf) in [(false, c.originalUserDate, c.originalUserDateConfidence),
                                   (true, c.copyUserDate, c.copyUserDateConfidence)] {
            guard let ud, !ud.isEmpty else { continue }
            let r = resolve(c, userDate: ud, confidence: conf)
            let hint = ArchivePathResolver.hint(from: r)
            guard hint != .unknown else { continue }
            let prov = Provenance.userDate(onCopy: onCopy, known: conf == UserDateConfidence.known.rawValue,
                                           canonical: ud)
            if let filed, expectedTail(streamType: c.streamType, filename: c.copyFilename, ext: c.ext, hint: hint) != filed {
                return (hint, prov)
            }
            if firstAgreeing == nil { firstAgreeing = (hint, prov) }
        }
        if let firstAgreeing { return firstAgreeing }
        let r = resolve(c, userDate: nil, confidence: nil)
        let hint = ArchivePathResolver.hint(from: r)
        guard hint != .unknown, !ArchivePathResolver.isLowConfidence(r) else { return nil }
        return (hint, .machine(source: r.source, confidence: r.confidence))
    }

    /// Misfiled = the folder Promote's rule gives the current date differs
    /// from the folder the file is in. Pure; O(1).
    static func evaluate(_ c: Candidate) -> Finding? {
        guard let filed = filedTail(relPath: c.copyRelPath),
              let (hint, provenance) = currentDate(of: c) else { return nil }
        let expected = expectedTail(streamType: c.streamType, filename: c.copyFilename, ext: c.ext, hint: hint)
        guard expected != filed.tail else { return nil }
        return Finding(rowID: c.rowID, copyID: c.copyID, filedRelPath: c.copyRelPath, filedTail: filed.tail,
                       dated: hint, expectedTail: expected, provenance: provenance)
    }

    /// Every candidate the manifest lists (a file the index does not know is
    /// not "archived" for this purpose), evaluated. O(candidates).
    static func findings(candidates: [Candidate], manifestRelPaths: Set<String>) -> [Finding] {
        var out: [Finding] = []
        for c in candidates where manifestRelPaths.contains(c.copyRelPath) {
            if let f = evaluate(c) { out.append(f) }
        }
        return out
    }

    // MARK: Manifest reads (descriptor-relative, validated)

    /// Every `archive_relpath` in the manifest, or why it could not be read.
    /// Read THROUGH the validated index descriptor (O_NOFOLLOW, header
    /// checked) — a missing, symlinked or header-less manifest is a failure,
    /// never an empty success. Memory: the file's bytes once (~200 B/row).
    static func manifestRelPaths(rootPath: String) -> Result<Set<String>, ManifestReadFailure> {
        switch manifestRows(rootPath: rootPath) {
        case .success(let rows): return .success(Set(rows.map(\.relPath)))
        case .failure(let f): return .failure(f)
        }
    }

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
        for line in text.split(separator: "\n").dropFirst() {
            let f = ArchiveManifestCSV.fields(ofLine: String(line))
            guard f.count >= ArchiveManifestCSV.columnCountLegacy, !f[1].isEmpty else { continue }
            rows.append(ManifestRow(promotedAt: iso.date(from: f[0]), relPath: f[1], sha256: f[2], recordDate: f[8]))
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

    // MARK: The Why line

    /// "You dated this 1984 (known) on 25 Sep 2026; it was filed on 1 Sep
    /// as 1884." — from the date's provenance and the manifest's filed
    /// date. `datedOn` = when the date was set (the ledger's dateSet line),
    /// nil when unknown. Pure (clock and zone injected).
    static func whyLine(provenance: Provenance, dated: ArchiveDateHint, datedOn: Date?,
                        filedTail: String, promotedAt: Date?, isMisfiled: Bool,
                        now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let dateText = datedLabel(dated)
        var s: String
        switch provenance {
        case .userDate(let onCopy, let known, _):
            s = "You dated \(onCopy ? "the archive copy" : "this") \(dateText) (\(known ? "known" : "estimated"))"
            if let datedOn { s += " on \(dayText(datedOn, withYear: true, timeZone: timeZone))" }
        case .machine(let source, _):
            s = "Its date now reads \(dateText), from \(Provenance.sourcePhrase(source))"
        case .typedOnRefileSheet:
            s = "You typed \(dateText) on this sheet"
        }
        let filed = folderLabel(tail: filedTail)
        if isMisfiled {
            if let promotedAt {
                let sameYear = year(promotedAt, timeZone) == year(now, timeZone)
                s += "; it was filed on \(dayText(promotedAt, withYear: !sameYear, timeZone: timeZone)) as \(filed)."
            } else {
                s += "; it is filed as \(filed)."
            }
        } else {
            s += "; it is filed as \(filed), which already matches. Change the date or the name below to refile it anyway."
        }
        return s
    }

    private static func year(_ d: Date, _ tz: TimeZone) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.component(.year, from: d)
    }

    /// "25 Sep 2026" / "1 Sep" — fixed locale, like the ledger narrator.
    static func dayText(_ d: Date, withYear: Bool, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = withYear ? "d MMM yyyy" : "d MMM"
        return f.string(from: d)
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
        /// The moved file's identity (device + inode + size) — what a later
        /// replay must find at `toRelPath` before trusting it (r3 #2).
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let backupDir: String?
        let indexFilesChanged: Int
        let linesChanged: Int
        let promotedAt: Date?
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
              ArchivePromoteEngine.isContainedRelPath(to, root: root), from != to else {
            return no("\(from) → \(to) is not a move inside the archive")
        }
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
        if rows.contains(where: { $0.relPath == to }) { return no("the archive manifest already lists a file at \(to)") }
        if let why = targetRefusal(root: root, to: to) { return no(why) }
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
            let journals = try ArchiveIndexRename.prepare(root: root, replacements: replacements)
                .files.filter { $0.name != MasterArchiveLayout.manifestFilename }
            return .success(ArchiveIndexRename.Plan(root: root, files: [manifestRewrite] + journals))
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
        var recoveryNotDurable: String?
        let backupDir: URL?
        do {
            backupDir = try ArchiveIndexRename.apply(
                prep.plan, now: now, holder: "Refile \(req.filename)",
                publisher: seams.indexPublisher,
                backupWriter: seams.backupWriter,
                announce: { dir in
                    audit(subject + "index backup written to \(dir.path); moving \(from) → \(to) (one rename on the same volume, never a copy)…")
                },
                moveMedia: {
                    try moveAndVerify(root: root, from: from, to: to,
                                      srcName: (from as NSString).lastPathComponent,
                                      dstName: (to as NSString).lastPathComponent,
                                      sourceIdentity: prep.sourceIdentity, digest: prep.digest, seams: seams,
                                      moved: &moved, audit: { audit(subject + $0) })
                },
                undoMoveMedia: {
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
            return failureOutcome(error, req, prep, moved: moved, recoveryNotDurable: recoveryNotDurable,
                                  subject: subject, audit: audit)
        }
        let lines = prep.plan.changedLines, files = prep.plan.files.count
        audit(subject + "index updated — \(lines) line\(lines == 1 ? "" : "s") in \(files) index file\(files == 1 ? "" : "s")\(backupDir.map { "; backup \($0.path)" } ?? "")")
        return .refiled(Done(fromRelPath: from, toRelPath: to, sha256: prep.digest,
                             device: prep.sourceIdentity.device, inode: prep.sourceIdentity.inode,
                             size: prep.sourceIdentity.size, backupDir: backupDir?.path,
                             indexFilesChanged: files, linesChanged: lines, promotedAt: prep.promotedAt))
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
                if let nd = recoveryNotDurable,
                   prep.plan.files.allSatisfy({ (try? Data(contentsOf: $0.url)) == $0.original }),
                   locateOriginal(root: root, candidates: [from], identity: prep.sourceIdentity) == from {
                    return incomplete("\(text) — the file was moved back to \(from) and the index restored, but \(nd)")
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
