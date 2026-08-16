// MasterArchive.swift
// Master Archive + Promote to Archive — the PURE layer (design v2,
// docs/archive_promotion_workflow.md, 2026-08-15).
//
//   - `MasterArchiveDesignation` — the catalog-level "which volume is the
//     master" value, persisted with the catalog snapshot (additive key).
//   - `MasterArchiveLayout`      — folder names, index files, README and
//     manifest header text. One place for every string the on-disk tree
//     depends on.
//   - `ArchiveDateHint`          — what we know about WHEN a record was
//     shot, at the precision we know it (day / month / year / decade /
//     nothing). Built from a record by `ArchivePathResolver.dateHint`.
//   - `ArchivePathResolver`      — (record facts, root) → relative
//     destination path per spec §2. Nonisolated, no I/O except an
//     injectable `fileExists` for the `_NN` collision suffix, so the
//     whole matrix is table-testable.
//   - `ArchiveManifestCSV`       — one CSV row per promoted file, RFC-4180
//     escaping, appended with ONE O_APPEND write (the write-journal
//     lesson: seek+write is two syscalls and interleaves).
//
// Nothing here touches the catalog, the model, or MFO — those live in
// VideoScanModel+MasterArchive.swift and PromoteToArchiveJob.swift.
//
// (For Rick: everything in this file is the C++ "header + free functions
// with no globals" layer — value types and static functions only.)

import Foundation

// MARK: - Designation (persisted)

/// The one Master Archive per catalog. Persisted INSIDE catalog.json
/// (CatalogSnapshot's additive `masterArchive` key) so the designation
/// travels with the catalog and survives a scan-target list rebuild.
///
/// `targetPath` is the CatalogScanTarget's `searchPath` (the volume or
/// folder Rick picked); `rootPath` is `<targetPath>/Breen_Family_Archive`.
/// Scan-target ids are regenerated every launch (`CatalogScanTarget.id`
/// is `let id = UUID()`) and are NOT persisted anywhere, so the durable
/// keys are (codex QA blocker 1): the volume's UUID
/// (`URLResourceKey.volumeUUIDStringKey`, captured at Initialize) FIRST,
/// then the canonical normalized path. Re-resolution on load / mount:
/// if the stored path is not reachable but a mounted volume carries the
/// stored UUID, the designation follows the volume to its new mount
/// point (`VideoScanModel.reresolveMasterArchiveMount`).
struct MasterArchiveDesignation: Codable, Equatable, Sendable {
    /// Canonical (standardized, no trailing slash) path Rick picked.
    let targetPath: String
    /// `<targetPath>/Breen_Family_Archive`, canonical.
    let rootPath: String
    /// The volume's filesystem UUID at designation time; nil when the
    /// filesystem does not report one (some network/FAT volumes).
    let volumeUUID: String?
    let designatedAt: Date

    init(targetPath: String, rootPath: String, volumeUUID: String? = nil, designatedAt: Date = Date()) {
        self.targetPath = PathScope.normalize(URL(fileURLWithPath: targetPath).standardizedFileURL.path)
        self.rootPath = PathScope.normalize(URL(fileURLWithPath: rootPath).standardizedFileURL.path)
        self.volumeUUID = volumeUUID
        self.designatedAt = designatedAt
    }

    /// The path this designation would have if the same volume were
    /// mounted at `newTargetPath` (volume renamed / remounted).
    func rehomed(to newTargetPath: String) -> MasterArchiveDesignation {
        MasterArchiveDesignation(
            targetPath: newTargetPath,
            rootPath: MasterArchiveLayout.rootURL(forTargetPath: newTargetPath).path,
            volumeUUID: volumeUUID,
            designatedAt: designatedAt)
    }

    /// `volumeUUIDString` for the filesystem holding `path`, or nil.
    /// Routed through `volumeUUIDProbe` so tests can present "a different
    /// disk at the same path" (codex R3 blocker 1) without a real mount.
    static func volumeUUID(forPath path: String) -> String? {
        volumeUUIDProbe(path)
    }

    /// Test seam for the volume-UUID probe. Production = the real
    /// resource-value read; tests that swap it run serialized.
    nonisolated(unsafe) static var volumeUUIDProbe: @Sendable (String) -> String? = { path in
        let url = URL(fileURLWithPath: path)
        return (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }
}

// MARK: - Canonical containment

extension ArchivePathResolver {
    /// Component-wise "is `path` at or under `root`" on standardized file
    /// URLs — no prefix-string tricks (codex QA major c): "/Volumes/A"
    /// never contains "/Volumes/AB/x", and "a/../b" forms are collapsed
    /// before comparing. Symlinks are NOT resolved (catalog paths are
    /// already absolute; resolving would touch the disk per call).
    static func isInside(path: String, root: String) -> Bool {
        let rootComps = URL(fileURLWithPath: root).standardizedFileURL.pathComponents
        let pathComps = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        // A root of "/" would contain everything — the catalog-wide
        // footgun PathScope.contains also refuses.
        guard rootComps.count > 1, pathComps.count >= rootComps.count else { return false }
        return Array(pathComps.prefix(rootComps.count)) == rootComps
    }
}

// MARK: - Layout constants

/// Spec §2 — the on-disk shape. Numbered buckets with gaps so
/// `40_Documents` can slot in later without renumbering.
enum MasterArchiveLayout {
    static let rootFolderName = "Breen_Family_Archive"
    static let indexFolder = "00_Index"
    static let photosBucket = "10_Photos"
    static let audioBucket = "20_Audio"
    static let videoBucket = "30_Video"
    static let undatedFolder = "Undated"
    static let manifestFilename = "Archive_Inventory_Manifest.csv"
    static let readmeFilename = "README_Naming_and_Layout.txt"

    /// The three content buckets Initialize creates up front (empty).
    static let buckets: [String] = [photosBucket, audioBucket, videoBucket]

    static func rootURL(forTargetPath targetPath: String) -> URL {
        URL(fileURLWithPath: targetPath, isDirectory: true)
            .appendingPathComponent(rootFolderName, isDirectory: true)
    }

    static func manifestURL(rootPath: String) -> URL {
        URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(indexFolder, isDirectory: true)
            .appendingPathComponent(manifestFilename)
    }

    static func readmeURL(rootPath: String) -> URL {
        URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(indexFolder, isDirectory: true)
            .appendingPathComponent(readmeFilename)
    }

    /// Plain-English rules for the no-app cousin test (spec §2). Written
    /// once by Initialize; never rewritten (a hand-edited README stays).
    static let readmeText: String = """
    Breen Family Archive — Naming and Layout
    =========================================

    This folder is the family's master media archive. It is maintained by
    the VideoScan app, but it is designed to make sense to a person with
    no app at all — just Finder and this note.

    Layout
    ------
      00_Index/   Archive_Inventory_Manifest.csv — one line per file ever
                  promoted here (when, where it came from, its SHA-256
                  fingerprint, who is in it, its rating). Append-only.
                  README_Naming_and_Layout.txt — this file.
      10_Photos/  Loose photo scans (Apple Photos owns the photo library;
                  this bucket exists for stray scans).
      20_Audio/   Audio-only recordings (interviews, tapes, voice memos).
      30_Video/   Video (with or without sound).

    Inside each bucket
    ------------------
      <decade>/            e.g. 1990-1999  (always the full range, sorts cleanly)
      <decade>/<year>/     e.g. 1990-1999/1992  — only when the year is known
      Undated/             nothing reliable is known about the date

      A file whose decade is known but not its year sits directly in the
      decade folder.

    Filenames
    ---------
      YYYY-MM-DD_Slug.ext         full date known
      YYYY-MM-xx_Slug.ext         day unknown
      YYYY-xx-xx_Slug.ext         month and day unknown
      xxxx-xx-xx_Slug.ext         undated (lives in Undated/)
      ..._Slug_02.ext             a numeric suffix appears only when two
                                  files would otherwise share a name

      The slug is the file's title if it was given one, otherwise the
      original filename cleaned up (spaces → dashes, punctuation removed).
      The original extension is always kept: files are copied here
      byte-for-byte, never converted. The manifest records the original
      path of every file.

    Rules of the house
    ------------------
      • Files are COPIED here, never moved. The archive is a second,
        verified home — the source stays where it was until a human
        decides otherwise.
      • Every copy is verified: the SHA-256 in the manifest was computed
        from the file after it landed here. `shasum -a 256 <file>` in
        Terminal should print the same value.
      • Nothing in 00_Index/ is ever rewritten by hand-tools; the manifest
        only grows.
    """

    /// Manifest header — spec §2 column list, in order.
    static let manifestHeader =
        "promoted_at,archive_relpath,sha256,size_bytes,original_path,original_volume,record_id,source_record_id,record_date,date_confidence,people,star_rating"
}

// MARK: - Date hint

/// What we know about when a record was shot, at the precision we know
/// it. Deliberately NOT a Date: "1992" and "1992-06-14" carry different
/// information, and the archive filename must say which.
/// (`enum` with associated values ≈ a C++ tagged union / std::variant.)
enum ArchiveDateHint: Equatable, Sendable {
    case day(year: Int, month: Int, day: Int)
    case month(year: Int, month: Int)
    case year(Int)
    /// Decade known (start year, e.g. 1990), year not. No current record
    /// field yields this on its own — it exists so the resolver's
    /// decade-root rule (spec §2) is real and tested, ready for the
    /// later Refile phase / a future decade signal.
    case decade(startYear: Int)
    case unknown

    var year: Int? {
        switch self {
        case .day(let y, _, _), .month(let y, _), .year(let y): return y
        case .decade, .unknown: return nil
        }
    }

    var decadeStart: Int? {
        switch self {
        case .decade(let s): return s
        default: return year.map { $0 - ($0 % 10) }
        }
    }

    /// The `YYYY-MM-DD` filename prefix with `xx` for unknown parts.
    var filenamePrefix: String {
        switch self {
        case .day(let y, let m, let d): return String(format: "%04d-%02d-%02d", y, m, d)
        case .month(let y, let m):      return String(format: "%04d-%02d-xx", y, m)
        case .year(let y):              return String(format: "%04d-xx-xx", y)
        case .decade, .unknown:         return "xxxx-xx-xx"
        }
    }

    /// The manifest's `record_date` column: same shape as the prefix but
    /// empty when nothing is known (a CSV consumer should not have to
    /// parse `xxxx`).
    var manifestDate: String {
        if case .unknown = self { return "" }
        if case .decade(let s) = self { return "\(s)s" }
        return filenamePrefix
    }
}

// MARK: - Resolver

/// Pure destination-path rules (spec §2). Every method is a static
/// function of its arguments — no clock, no locale, no filesystem beyond
/// the injected `fileExists` closure used for `_NN`.
enum ArchivePathResolver {

    /// The confidence floor for trusting a dossier-inferred date.
    static let inferredConfidenceFloor: Float = 0.6

    /// Facts the resolver needs about one record. Built from a live
    /// VideoRecord on the main actor (`facts(for:)`), then handed to the
    /// pure functions — so the job can resolve paths off-main with a
    /// Sendable value.
    struct RecordFacts: Sendable, Equatable {
        /// Raw stream-type string (StreamType itself is not Sendable).
        let streamTypeRaw: String
        let filename: String
        let ext: String
        let dateHint: ArchiveDateHint
        /// True when the date came from an inferred signal below the
        /// confidence floor (or none at all) — surfaced as a warning.
        let dateIsLowConfidence: Bool

        var streamType: StreamType { StreamType(rawValue: streamTypeRaw) ?? .ffprobeFailed }

        init(streamType: StreamType, filename: String, ext: String,
             dateHint: ArchiveDateHint, dateIsLowConfidence: Bool) {
            self.streamTypeRaw = streamType.rawValue
            self.filename = filename
            self.ext = ext
            self.dateHint = dateHint
            self.dateIsLowConfidence = dateIsLowConfidence
        }
    }

    /// Which numbered bucket a stream shape belongs in.
    static func bucket(for streamType: StreamType) -> String {
        switch streamType {
        case .audioOnly:
            return MasterArchiveLayout.audioBucket
        case .videoAndAudio, .videoOnly, .noStreams, .ffprobeFailed:
            // No-stream / probe-failed records only reach promotion if
            // the user insists; the video bucket is the honest default
            // for anything that is not audio-only. Photos are Apple
            // Photos' job (spec §2) — 10_Photos exists for loose scans
            // handled by a later phase.
            return MasterArchiveLayout.videoBucket
        }
    }

    /// `<bucket>/<decade>[/<year>]` or `<bucket>/Undated`.
    static func folder(for streamType: StreamType, hint: ArchiveDateHint) -> String {
        let bucket = bucket(for: streamType)
        guard let decadeStart = hint.decadeStart else {
            return "\(bucket)/\(MasterArchiveLayout.undatedFolder)"
        }
        let decade = String(format: "%04d-%04d", decadeStart, decadeStart + 9)
        if let year = hint.year {
            return "\(bucket)/\(decade)/\(String(format: "%04d", year))"
        }
        return "\(bucket)/\(decade)"
    }

    /// Filesystem-safe slug: letters, digits, `-` and `_` only; runs of
    /// anything else collapse to a single dash; trimmed; capped so a
    /// pathological 300-char stem cannot overflow a filename. Empty input
    /// (or input that is all punctuation) yields "untitled".
    static func slug(from raw: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in raw.unicodeScalars {
            let ch = Character(scalar)
            if ch.isLetter || ch.isNumber || ch == "_" {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(ch)
            } else {
                pendingDash = true
            }
        }
        if out.isEmpty { return "untitled" }
        if out.count > 80 { out = String(out.prefix(80)) }
        // A cap can leave a trailing dash — tidy it.
        while out.last == "-" { out.removeLast() }
        return out.isEmpty ? "untitled" : out
    }

    /// The slug source: a curated title when the record has one, else the
    /// original filename's stem. VideoRecord has no title field today —
    /// `title` is plumbed so the day it does, this is a one-line change.
    static func slugSource(title: String?, filename: String) -> String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        return (filename as NSString).deletingPathExtension
    }

    /// Relative destination path under the archive root, WITHOUT any
    /// collision suffix: `30_Video/1990-1999/1992/1992-07-15_Slug.mov`.
    static func baseRelativePath(facts: RecordFacts, title: String? = nil) -> String {
        let folder = folder(for: facts.streamType, hint: facts.dateHint)
        let stem = "\(facts.dateHint.filenamePrefix)_\(slug(from: slugSource(title: title, filename: facts.filename)))"
        let ext = normalizedExtension(facts.ext, filename: facts.filename)
        return ext.isEmpty ? "\(folder)/\(stem)" : "\(folder)/\(stem).\(ext)"
    }

    /// Final relative path with `_NN` (02, 03, …) appended on collision.
    /// `fileExists` is asked about ABSOLUTE paths under `rootPath`; a
    /// caller that has already claimed names in this batch should fold
    /// them into the closure (the job does).
    static func resolveRelativePath(facts: RecordFacts,
                                    rootPath: String,
                                    title: String? = nil,
                                    fileExists: (String) -> Bool) -> String {
        let base = baseRelativePath(facts: facts, title: title)
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        if !fileExists(root.appendingPathComponent(base).path) { return base }
        let ext = (base as NSString).pathExtension
        let stemPath = (base as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty
                ? String(format: "%@_%02d", stemPath, n)
                : String(format: "%@_%02d.%@", stemPath, n, ext)
            if !fileExists(root.appendingPathComponent(candidate).path) { return candidate }
            n += 1
            if n > 9_999 { return candidate }   // pathological; give up uniquifying
        }
    }

    /// Records store `ext` sometimes with a leading dot, sometimes not,
    /// and sometimes empty (extensionless media). Prefer the record's
    /// field, fall back to the filename, lower-case for consistency.
    /// STRICT: ASCII letters/digits only, ≤ 16 chars — anything else
    /// (separators, dots, control chars, unicode look-alikes) is dropped
    /// so an extension can never smuggle a path component (codex QA
    /// round 2, blocker 3). Empty ⇒ extensionless archive filename.
    static func normalizedExtension(_ ext: String, filename: String) -> String {
        var e = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        if e.isEmpty { e = (filename as NSString).pathExtension }
        let strict = e.lowercased().unicodeScalars.filter {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x61 && $0.value <= 0x7A)
        }
        return String(String.UnicodeScalarView(strict).prefix(16))
    }

    // MARK: Date hint from record fields

    /// Spec §2 date source, in rank order:
    ///   1. Rick's hand-entered `userDate` (either confidence) — reduced
    ///      precision preserved ("1992" → year-only).
    ///   2. `inferredRecordDate` when `inferredDateConfidence` ≥ 0.6.
    ///   3. Otherwise unknown. File creation dates are NOT used — on old
    ///      tapes they are the transfer date, not the shooting date.
    /// Returns the hint plus a low-confidence flag for the warning list.
    static func dateHint(userDate: String?,
                         inferredRecordDate: Date?,
                         inferredDateConfidence: Float?) -> (hint: ArchiveDateHint, lowConfidence: Bool) {
        if let ud = userDate, let parts = UserDateEntry.components(of: ud) {
            if let m = parts.month, let d = parts.day {
                return (.day(year: parts.year, month: m, day: d), false)
            }
            if let m = parts.month {
                return (.month(year: parts.year, month: m), false)
            }
            return (.year(parts.year), false)
        }
        if let inferred = inferredRecordDate {
            let conf = inferredDateConfidence ?? 0
            if conf >= inferredConfidenceFloor {
                let dc = utcGregorian.dateComponents([.year, .month, .day], from: inferred)
                if let y = dc.year, let m = dc.month, let d = dc.day {
                    return (.day(year: y, month: m, day: d), false)
                }
            }
            // An inferred date we do not trust: undated, flagged.
            return (.unknown, true)
        }
        return (.unknown, false)
    }

    private static let utcGregorian: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()
}

// MARK: - Main-actor bridge (record → facts)

extension ArchivePathResolver {
    /// Snapshot the fields the resolver reads. Main actor because
    /// VideoRecord lives there; the result is a Sendable value.
    @MainActor
    static func facts(for record: VideoRecord) -> RecordFacts {
        let (hint, low) = dateHint(userDate: record.userDate,
                                   inferredRecordDate: record.inferredRecordDate,
                                   inferredDateConfidence: record.inferredDateConfidence)
        return RecordFacts(streamType: record.streamType,
                           filename: record.filename,
                           ext: record.ext,
                           dateHint: hint,
                           dateIsLowConfidence: low)
    }
}

// MARK: - Manifest CSV

/// The append-only inventory. Header written by Initialize; one row per
/// promotion. Rows are RFC-4180: fields containing `,` `"` CR or LF are
/// double-quoted with embedded quotes doubled.
enum ArchiveManifestCSV {

    struct Row: Sendable, Equatable {
        let promotedAt: Date
        let archiveRelPath: String
        let sha256: String
        let sizeBytes: Int64
        let originalPath: String
        let originalVolume: String
        let recordID: UUID
        let sourceRecordID: UUID
        let recordDate: String
        let dateConfidence: String
        let people: [String]
        let starRating: Int
    }

    /// One CSV field — ALWAYS quoted (codex QA round 2, blocker 3: no
    /// field is ever emitted bare, so a comma/quote in a title or path
    /// can never re-shape the row), embedded quotes doubled (RFC 4180),
    /// and control characters (including CR/LF — CSV-injection vectors and
    /// line-splitter breakers) replaced by a space so every row stays one
    /// physical line.
    static func escape(_ field: String) -> String {
        var cleaned = ""
        cleaned.reserveCapacity(field.count)
        for scalar in field.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                cleaned.append(" ")
            } else {
                cleaned.unicodeScalars.append(scalar)
            }
        }
        return "\"" + cleaned.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The row as one line, WITH its trailing newline (so a single write
    /// is a complete record).
    static func line(for row: Row) -> String {
        let fields: [String] = [
            iso8601.string(from: row.promotedAt),
            row.archiveRelPath,
            row.sha256,
            String(row.sizeBytes),
            row.originalPath,
            row.originalVolume,
            row.recordID.uuidString,
            row.sourceRecordID.uuidString,
            row.recordDate,
            row.dateConfidence,
            row.people.joined(separator: "; "),
            String(row.starRating)
        ]
        return fields.map(escape).joined(separator: ",") + "\n"
    }

    /// Append one row with a single O_APPEND write + F_FULLFSYNC (codex R3
    /// blockers 3+4). The manifest is opened DESCRIPTOR-RELATIVE from the
    /// archive root (`00_Index/` via openat, O_NOFOLLOW) with NO O_CREAT: it
    /// must already exist as a regular file that starts with the header —
    /// Initialize owns creation; a missing or replaced manifest is a
    /// refusal, never a create-and-append. A short write or a failed
    /// barrier throws (the row is not durable ⇒ not claimed).
    /// (`nonisolated` ≈ a free function: safe to call from the job's
    /// background work.)
    nonisolated static func append(_ row: Row, rootPath: String) throws {
        let data = Data(line(for: row).utf8)
        let fd = try ArchivePromoteEngine.openIndexFile(
            root: rootPath, name: MasterArchiveLayout.manifestFilename,
            mustExist: true, expectedHeader: MasterArchiveLayout.manifestHeader)
        defer { close(fd) }
        try ArchivePromoteEngine.appendDurable(fd: fd, data: data, full: true, label: "manifest append")
    }

    /// Preflight: the manifest under `rootPath` is reachable descriptor-
    /// relative, is a regular file (not a symlink) and carries the header.
    /// Throws the same refusals `append` would.
    nonisolated static func validate(rootPath: String) throws {
        let fd = try ArchivePromoteEngine.openIndexFile(
            root: rootPath, name: MasterArchiveLayout.manifestFilename,
            mustExist: true, expectedHeader: MasterArchiveLayout.manifestHeader)
        close(fd)
    }

    /// Minimal parser for tests + the "already in manifest" sensor: splits
    /// one line into fields honoring quotes. Not a general CSV library.
    static func fields(ofLine line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        var pending: Character? = iterator.next()
        while let ch = pending {
            let next = iterator.next()
            if inQuotes {
                if ch == "\"" {
                    if next == "\"" {
                        current.append("\"")
                        pending = iterator.next()
                        continue
                    }
                    inQuotes = false
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" {
                inQuotes = true
            } else if ch == "," {
                out.append(current)
                current = ""
            } else if ch == "\n" || ch == "\r" {
                // end of record
            } else {
                current.append(ch)
            }
            pending = next
        }
        out.append(current)
        return out
    }

    /// Column index of `source_record_id` in the header (0-based).
    static let sourceRecordIDColumn = 7
    /// Column index of `archive_relpath`.
    static let relPathColumn = 1
    /// Column index of `sha256`.
    static let sha256Column = 2

    /// The set of source record ids already listed in the manifest — the
    /// second leg of the promote idempotency check (codex QA major a: a
    /// crash between manifest append and catalog record must not yield a
    /// second copy on the next run). Reads the whole file: the manifest
    /// is ~200 bytes/row, so even 100k promotions is ~20 MB, once per
    /// job. Missing/unreadable file ⇒ empty set (the job's preflight
    /// already refused a missing manifest).
    nonisolated static func sourceRecordIDs(in url: URL) -> Set<UUID> {
        Set(rowsBySource(in: url).keys)
    }

    /// What the manifest already says about each source: its archive
    /// relpath and digest, keyed by source record id (latest row wins).
    nonisolated static func rowsBySource(in url: URL) -> [UUID: (relPath: String, sha256: String)] {
        fieldRowsBySource(in: url).mapValues { ($0[relPathColumn], $0[sha256Column]) }
    }

    /// Every field of the latest manifest row per source id (for
    /// self-contained orphan registration — codex R3 major 7).
    nonisolated static func fieldRowsBySource(in url: URL) -> [UUID: [String]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [UUID: [String]] = [:]
        for line in text.split(separator: "\n").dropFirst() {   // header
            let fields = fields(ofLine: String(line))
            guard fields.count >= 12,
                  let id = UUID(uuidString: fields[sourceRecordIDColumn]) else { continue }
            out[id] = fields
        }
        return out
    }

    enum ManifestError: Error, CustomStringConvertible {
        case openFailed(path: String, errno: Int32)
        case shortWrite(path: String, expected: Int, wrote: Int)
        case missingHeader(path: String)

        var description: String {
            switch self {
            case .openFailed(let p, let e):
                return "could not open manifest \(p) (errno \(e))"
            case .shortWrite(let p, let expected, let wrote):
                return "manifest write to \(p) was short (\(wrote) of \(expected) bytes)"
            case .missingHeader(let p):
                return "manifest \(p) is missing — run Initialize Master Archive again"
            }
        }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
