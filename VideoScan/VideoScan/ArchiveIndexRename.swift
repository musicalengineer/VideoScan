// ArchiveIndexRename.swift
// Carries a Catalog rename through to the Master Archive's index files
// (Rick 2026-09-25: "renaming a file in the Catalog is THE way to fix a
// typo in a name, including for files in the master archive"). KISS: a
// typo is not history, so the old strings are fixed IN PLACE — no new
// record kinds, no rename events.
//
// What is rewritten, under `<root>/00_Index/`:
//   - Archive_Inventory_Manifest.csv   (any cell EQUAL to an old value)
//   - .promote_journal.jsonl           (any JSON string value EQUAL to an old value)
//   - .attestation_journal.jsonl
//   - media-ledger.jsonl               (the archive's mirror of the ledger)
//   - .promote_decisions.jsonl
// Exact values only — never substrings: `…_misc.mkv` never touches
// `…_misc.mkv.bak` or a longer folder name. One extra, equally exact rule:
// a JSON object's `filename` member that equals the old filename is
// updated ONLY when a path member of that same object matched (the
// attestation/ledger lines carry both; a lone filename match elsewhere
// could be a different file with the same name and is left alone).
//
// Byte stability: files are processed as raw bytes, line by line. A line
// with no match is copied through untouched; in a changed line only the
// matched token's bytes are replaced (JSON keys keep their order, the
// original writer's `\/` escaping style is kept, CSV cells stay quoted
// the way ArchiveManifestCSV.escape quotes them). Untouched lines are
// byte-identical by construction.
//
// Order and safety (see VideoScanModel+Rename.swift for the caller):
//   1. prepare  — read + parse + rewrite every index file IN MEMORY. Any
//                 unreadable / unparseable file refuses; nothing changed.
//   2. backup   — each affected file's original bytes are written to
//                 00_Index/.rename_backups/<timestamp>/.
//   3. recheck  — each affected file must still be the file we read
//                 (inode + size + mtime); a concurrent append refuses.
//   4. move     — the media file is renamed. Failure ⇒ nothing published.
//   5. publish  — each index file atomically (AtomicFilePublish, full
//                 fsync). A failure ROLLS BACK: files already published
//                 are restored from the in-memory originals and the media
//                 file is moved back, so the archive is left exactly as it
//                 was. Only if the rollback itself fails is the state
//                 mixed — then every path is logged loudly.
//
// Memory: one index file's bytes are held at a time during parse, plus
// the rewritten copy of each AFFECTED file until publish (worst case ≈ 2×
// the sum of the index files; a 100k-promotion archive is ~20 MB manifest
// + ~30 MB ledger ⇒ ~100 MB peak). Each read is capped at `readLimit`
// (256 MB) — a larger file refuses rather than being silently truncated.
//
// (For Rick: an `enum` with no cases is Swift's namespace — ≈ a C++
// `namespace` of free functions. `ArraySlice<UInt8>` ≈ a `std::span` over
// the file's bytes — no copy.)

import Foundation
import os
import VideoScanCore

private let renameIndexLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "renameIndex")

enum ArchiveIndexRename {

    /// Index files considered, in publish order (manifest first: it is
    /// the file Verify reads, so it is the one a rollback most wants).
    static var indexFilenames: [String] {
        [MasterArchiveLayout.manifestFilename,
         ArchivePromoteJournal.filename,
         ArchiveAttestationJournal.filename,
         MediaLedger.mirrorFilename,
         ArchivePromoteDecisions.filename]
    }

    /// `00_Index/<backupFolder>/<timestamp>/<file>`.
    static let backupFolder = ".rename_backups"

    /// A read stops here; a file this large refuses instead of being
    /// rewritten from a truncated copy.
    static let readLimit = 256 << 20

    // MARK: Types

    /// Exact old value → new value. `values` holds the paths (absolute and
    /// archive-relative); the filename pair is applied only beside a
    /// matched path inside the same JSON object (see file header).
    struct Replacements: Sendable, Equatable {
        var values: [String: String]
        var oldFilename: String
        var newFilename: String

        var isEmpty: Bool { values.isEmpty }
    }

    /// One index file's prepared rewrite.
    struct FileRewrite: Sendable {
        let name: String
        let url: URL
        let original: Data
        let updated: Data
        let changedLines: Int
        let identity: ArchivePromoteEngine.FileIdentity
    }

    /// Every affected file. Files with zero matches are not in it.
    struct Plan: Sendable {
        let root: String
        let files: [FileRewrite]
        var isEmpty: Bool { files.isEmpty }
        var changedLines: Int { files.reduce(0) { $0 + $1.changedLines } }
        var indexURL: URL {
            URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(MasterArchiveLayout.indexFolder, isDirectory: true)
        }
    }

    /// The publish seam: production is an atomic full-fsync publish; a
    /// test injects a failure on the Nth file to exercise the rollback.
    typealias Publisher = (Data, URL) throws -> Void
    static func livePublish(_ data: Data, to url: URL) throws {
        try AtomicFilePublish.write(data, to: url, durability: .fullFsync, createIntermediates: false)
    }

    enum Failure: LocalizedError, Equatable {
        case unreadable(file: String, reason: String)
        case unparseable(file: String, line: Int, reason: String)
        case changedDuringRename(file: String)
        case backupFailed(path: String, reason: String)
        /// Publish failed; every published file was restored and the
        /// media file moved back. Nothing changed.
        case publishFailedRolledBack(file: String, reason: String)
        /// Publish failed AND the rollback failed — mixed state, details
        /// (exact paths) in `detail` and in catalog.log.
        case publishFailedNotRolledBack(file: String, reason: String, detail: String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let f, let r):
                return "The archive's index file “\(f)” couldn't be read (\(r)). Nothing was renamed."
            case .unparseable(let f, let line, let r):
                return "The archive's index file “\(f)” has a damaged line (line \(line): \(r)). Nothing was renamed."
            case .changedDuringRename(let f):
                return "The archive's index file “\(f)” changed while the rename was being prepared — something else is writing to the archive. Nothing was renamed; try again in a moment."
            case .backupFailed(let p, let r):
                return "Couldn't save a backup of the archive's index before renaming:\n\(p)\n(\(r)). Nothing was renamed."
            case .publishFailedRolledBack(let f, let r):
                return "Couldn't update the archive's index file “\(f)” (\(r)). The rename was undone; nothing changed."
            case .publishFailedNotRolledBack(let f, let r, let detail):
                return "Couldn't update the archive's index file “\(f)” (\(r)), and undoing the rename also failed.\n\n\(detail)"
            }
        }
    }

    // MARK: Prepare (read + parse + rewrite in memory; touches nothing)

    /// Build the plan. A missing `00_Index/` or a missing index file is
    /// simply "nothing to do"; an index file that exists but cannot be
    /// read or parsed throws — the caller refuses the rename.
    static func prepare(root: String, replacements: Replacements) throws -> Plan {
        guard !replacements.isEmpty else { return Plan(root: root, files: []) }
        let indexDir = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(MasterArchiveLayout.indexFolder, isDirectory: true)
        var sb = stat()
        guard lstat(indexDir.path, &sb) == 0 else {
            if errno == ENOENT { return Plan(root: root, files: []) }
            throw Failure.unreadable(file: MasterArchiveLayout.indexFolder,
                                     reason: String(cString: strerror(errno)))
        }
        var files: [FileRewrite] = []
        for name in indexFilenames {
            let url = indexDir.appendingPathComponent(name)
            guard lstat(url.path, &sb) == 0 else {
                if errno == ENOENT { continue }
                throw Failure.unreadable(file: name, reason: String(cString: strerror(errno)))
            }
            let isManifest = name == MasterArchiveLayout.manifestFilename
            let (data, identity) = try readIndexFile(root: root, name: name,
                                                     expectedHeaders: isManifest ? MasterArchiveLayout.acceptedManifestHeaders : nil)
            let bytes = [UInt8](data)
            let result = isManifest
                ? try rewriteCSV(bytes, replacements: replacements, file: name)
                : try rewriteJSONL(bytes, replacements: replacements, file: name, lenient: false)
            guard result.changedLines > 0 else { continue }
            files.append(FileRewrite(name: name, url: url, original: data,
                                     updated: Data(result.bytes), changedLines: result.changedLines,
                                     identity: identity))
        }
        return Plan(root: root, files: files)
    }

    /// Read one index file through the validated descriptor (O_NOFOLLOW,
    /// regular file, header checked for the manifest).
    static func readIndexFile(root: String, name: String,
                              expectedHeaders: [String]?) throws -> (Data, ArchivePromoteEngine.FileIdentity) {
        let fd: Int32
        do {
            fd = try ArchivePromoteEngine.openIndexFile(root: root, name: name, mustExist: true,
                                                        expectedHeaders: expectedHeaders)
        } catch {
            throw Failure.unreadable(file: name, reason: ArchiveAttestationJournal.describe(error))
        }
        defer { close(fd) }
        guard let (identity, _) = ArchivePromoteEngine.FileIdentity.of(fd: fd) else {
            throw Failure.unreadable(file: name, reason: "could not stat")
        }
        let data: Data
        do {
            data = try ArchivePromoteEngine.readAll(fd: fd, limit: readLimit + 1)
        } catch {
            throw Failure.unreadable(file: name, reason: ArchiveAttestationJournal.describe(error))
        }
        guard data.count <= readLimit else {
            throw Failure.unreadable(file: name, reason: "larger than \(readLimit >> 20) MB")
        }
        return (data, identity)
    }

    /// The identity of the file at `name` right now (for the recheck).
    static func currentIdentity(root: String, name: String) -> ArchivePromoteEngine.FileIdentity? {
        guard let fd = try? ArchivePromoteEngine.openIndexFile(root: root, name: name, mustExist: true) else {
            return nil
        }
        defer { close(fd) }
        return ArchivePromoteEngine.FileIdentity.of(fd: fd)?.0
    }

    // MARK: Apply (backup → recheck → move → publish, rollback on failure)

    /// Run the plan around the media move. `moveMedia` performs the rename
    /// and throws its own error (propagated unchanged — nothing is
    /// published). `undoMoveMedia` moves it back during a rollback.
    /// Returns the backup folder (nil when the plan was empty).
    @discardableResult
    static func apply(_ plan: Plan,
                      now: Date = Date(),
                      publisher: Publisher = livePublish(_:to:),
                      moveMedia: () throws -> Void,
                      undoMoveMedia: () throws -> Void) throws -> URL? {
        guard !plan.isEmpty else {
            try moveMedia()
            return nil
        }

        // 2. Backups — the exact bytes the plan was built from.
        let backupDir = try writeBackups(plan, now: now)

        // 3. Recheck: still the file we read? (A promote appending between
        //    prepare and here would otherwise be lost by the replace.)
        for f in plan.files where currentIdentity(root: plan.root, name: f.name) != f.identity {
            throw Failure.changedDuringRename(file: f.name)
        }

        // 4. Move the media file. Its failure propagates; nothing published.
        try moveMedia()

        // 5. Publish, rolling back on the first failure.
        var published: [FileRewrite] = []
        for f in plan.files {
            do {
                try publisher(f.updated, f.url)
                published.append(f)
            } catch {
                let reason = ArchiveAttestationJournal.describe(error)
                throw rollback(published: published, failed: f, reason: reason,
                               backupDir: backupDir, publisher: publisher, undoMoveMedia: undoMoveMedia)
            }
        }
        return backupDir
    }

    /// Undo a half-published plan: restore every published file from its
    /// in-memory original, then move the media back. Returns the error to
    /// throw — rolled back, or (if any undo step failed) the loud one.
    private static func rollback(published: [FileRewrite], failed: FileRewrite, reason: String,
                                 backupDir: URL, publisher: Publisher,
                                 undoMoveMedia: () throws -> Void) -> Failure {
        var problems: [String] = []
        for f in published.reversed() {
            do {
                try publisher(f.original, f.url)
            } catch {
                problems.append("\(f.url.path) still holds the NEW names — restore it from \(backupDir.appendingPathComponent(f.name).path) (\(ArchiveAttestationJournal.describe(error)))")
            }
        }
        do {
            try undoMoveMedia()
        } catch {
            problems.append("the media file keeps its NEW name — could not move it back (\(error.localizedDescription))")
        }
        if problems.isEmpty {
            appLog.write("Catalog: rename refused — archive index \(failed.name) not updated (\(reason)); \(published.count) index file(s) restored, media file moved back. Backups: \(backupDir.path)")
            renameIndexLog.error("rename rolled back: \(failed.name, privacy: .public) — \(reason, privacy: .public)")
            return .publishFailedRolledBack(file: failed.name, reason: reason)
        }
        let unpublished = [failed.url.path]
        let detail = (["ARCHIVE INDEX RENAME LEFT MIXED STATE — backups at \(backupDir.path)",
                       "not updated (old names): \(unpublished.joined(separator: ", "))"] + problems)
            .joined(separator: "\n")
        appLog.write("Catalog: RENAME ROLLBACK FAILED — \(detail.replacingOccurrences(of: "\n", with: " | "))")
        renameIndexLog.fault("rename rollback failed: \(detail, privacy: .public)")
        return .publishFailedNotRolledBack(file: failed.name, reason: reason, detail: detail)
    }

    static func backupStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HHmmss.SSS"
        return f.string(from: date)
    }

    /// Write every affected file's original bytes under a fresh
    /// `.rename_backups/<timestamp>/` (suffix -2, -3… if taken).
    private static func writeBackups(_ plan: Plan, now: Date) throws -> URL {
        let parent = plan.indexURL.appendingPathComponent(backupFolder, isDirectory: true)
        let stamp = backupStamp(now)
        var dir = parent.appendingPathComponent(stamp, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: dir.path) {
            dir = parent.appendingPathComponent("\(stamp)-\(n)", isDirectory: true)
            n += 1
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in plan.files {
                try AtomicFilePublish.write(f.original, to: dir.appendingPathComponent(f.name),
                                            durability: .fullFsync, createIntermediates: false)
            }
        } catch {
            throw Failure.backupFailed(path: dir.path, reason: ArchiveAttestationJournal.describe(error))
        }
        return dir
    }

    // MARK: Line plumbing (bytes, so untouched lines stay byte-identical)

    struct Rewrite {
        let bytes: [UInt8]
        let changedLines: Int
    }

    private static let newline: UInt8 = 0x0A
    private static let cr: UInt8 = 0x0D
    private static let quote: UInt8 = 0x22
    private static let comma: UInt8 = 0x2C
    private static let backslash: UInt8 = 0x5C

    /// Split on LF only (a CR stays inside its line), call `transform` per
    /// line; nil = unchanged. Rejoining the pieces with LF reproduces the
    /// input exactly when nothing changed.
    private static func mapLines(_ bytes: [UInt8],
                                 _ transform: (_ line: ArraySlice<UInt8>, _ lineNumber: Int) throws -> [UInt8]?) rethrows -> Rewrite {
        var out: [UInt8] = []
        var changed = 0
        var start = 0
        var lineNumber = 1
        var touched = false
        while start <= bytes.count {
            let end = byteIndex(of: newline, in: bytes[start...]) ?? bytes.count
            let line = bytes[start..<end]
            if let replaced = try transform(line, lineNumber) {
                if !touched {
                    // First change: copy everything before this line.
                    out.reserveCapacity(bytes.count + 256)
                    out.append(contentsOf: bytes[0..<start])
                    touched = true
                }
                out.append(contentsOf: replaced)
                changed += 1
            } else if touched {
                out.append(contentsOf: line)
            }
            if end == bytes.count { break }
            if touched { out.append(newline) }
            start = end + 1
            lineNumber += 1
        }
        return Rewrite(bytes: touched ? out : bytes, changedLines: changed)
    }

    /// Cheap pre-filter: a line can only hold a matching JSON string / CSV
    /// cell if it contains an old value literally or has an escape in it.
    private static func mightMatch(_ line: ArraySlice<UInt8>, needles: [[UInt8]]) -> Bool {
        if byteIndex(of: backslash, in: line) != nil { return true }
        for n in needles where containsBytes(n, in: line) { return true }
        return false
    }

    // memchr / memmem: the scans run over every byte of every index file,
    // and the generic Collection versions are ~50× slower in a Debug
    // build (unspecialized). Same answers, C speed in both configurations.
    // (`withUnsafeBufferPointer` ≈ taking `&v[0]` + size in C++ — valid
    // only inside the closure.)

    /// Absolute index of the first `byte` in `slice`, or nil.
    static func byteIndex(of byte: UInt8, in slice: ArraySlice<UInt8>) -> Int? {
        slice.withUnsafeBufferPointer { buf -> Int? in
            guard let base = buf.baseAddress, buf.count > 0,
                  let hit = memchr(base, Int32(byte), buf.count) else { return nil }
            return slice.startIndex + (UnsafeRawPointer(hit) - UnsafeRawPointer(base))
        }
    }

    /// True when `needle` occurs in `slice` as a contiguous byte run.
    static func containsBytes(_ needle: [UInt8], in slice: ArraySlice<UInt8>) -> Bool {
        guard !needle.isEmpty else { return true }
        return slice.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { n in
                guard let h = hay.baseAddress, let nb = n.baseAddress, hay.count >= n.count else { return false }
                return memmem(h, hay.count, nb, n.count) != nil
            }
        }
    }

    // MARK: CSV (the manifest)

    /// Rewrite every cell (any column, header excluded) whose decoded value
    /// equals an old value. A row with broken quoting refuses.
    static func rewriteCSV(_ bytes: [UInt8], replacements: Replacements, file: String) throws -> Rewrite {
        let needles = replacements.values.keys.map { Array($0.utf8) }
        return try mapLines(bytes) { line, number in
            guard number > 1, !line.isEmpty, mightMatch(line, needles: needles) else { return nil }
            var body = line
            var suffix: ArraySlice<UInt8> = []
            if body.last == cr {
                suffix = body[(body.endIndex - 1)...]
                body = body[..<(body.endIndex - 1)]
            }
            let cells = try csvCells(body, file: file, line: number)
            var edits: [(Range<Int>, [UInt8])] = []
            for cell in cells {
                let value = csvDecode(body[cell])
                if let new = replacements.values[value] {
                    edits.append((cell, Array(ArchiveManifestCSV.escape(new).utf8)))
                }
            }
            guard !edits.isEmpty else { return nil }
            return splice(Array(body), base: body.startIndex, edits: edits) + Array(suffix)
        }
    }

    /// Cell byte ranges (raw, including their quotes) of one CSV row.
    private static func csvCells(_ b: ArraySlice<UInt8>, file: String, line: Int) throws -> [Range<Int>] {
        var cells: [Range<Int>] = []
        var i = b.startIndex
        while true {
            let cellStart = i
            if i < b.endIndex, b[i] == quote {
                i += 1
                var closed = false
                while i < b.endIndex {
                    if b[i] == quote {
                        if i + 1 < b.endIndex, b[i + 1] == quote { i += 2; continue }
                        i += 1
                        closed = true
                        break
                    }
                    i += 1
                }
                guard closed else {
                    throw Failure.unparseable(file: file, line: line, reason: "a quoted cell never ends")
                }
                guard i == b.endIndex || b[i] == comma else {
                    throw Failure.unparseable(file: file, line: line, reason: "text after a closing quote")
                }
            } else {
                while i < b.endIndex, b[i] != comma { i += 1 }
            }
            cells.append(cellStart..<i)
            if i == b.endIndex { break }
            i += 1                                   // the comma
            if i == b.endIndex { cells.append(i..<i); break }
        }
        return cells
    }

    /// A raw cell's value: outer quotes removed, doubled quotes collapsed.
    private static func csvDecode(_ raw: ArraySlice<UInt8>) -> String {
        guard raw.count >= 2, raw.first == quote, raw.last == quote else {
            return String(decoding: raw, as: UTF8.self)
        }
        let inner = raw[(raw.startIndex + 1)..<(raw.endIndex - 1)]
        return String(decoding: inner, as: UTF8.self).replacingOccurrences(of: "\"\"", with: "\"")
    }

    // MARK: JSONL (journals, ledger mirror)

    /// Rewrite every JSON string VALUE (keys never) equal to an old value,
    /// at any depth, plus the same-object `filename` rule. `lenient` leaves
    /// an unparseable line untouched instead of refusing (used for the App
    /// Support ledger, which is rewritten after the rename already landed).
    static func rewriteJSONL(_ bytes: [UInt8], replacements: Replacements, file: String,
                             lenient: Bool) throws -> Rewrite {
        let needles = replacements.values.keys.map { Array($0.utf8) }
        // Strict mode must prove EVERY line parses. One parse of the whole
        // file as a JSON array is ~5× cheaper than 50k single-line parses;
        // only when it fails (or the element count disagrees) do we fall
        // back to per-line parsing, which names the damaged line.
        let wholeFileParses = !lenient && allLinesParse(bytes)
        return try mapLines(bytes) { line, number in
            // Blank lines are skipped by every reader; leave them be.
            guard line.contains(where: { !isBlank($0) }) else { return nil }
            // A damaged index refuses the rename (strict) — or, lenient,
            // the damaged line is simply left alone.
            if !lenient, !wholeFileParses, !parses(line) {
                throw Failure.unparseable(file: file, line: number, reason: "not valid JSON")
            }
            guard mightMatch(line, needles: needles) else { return nil }
            if lenient, !parses(line) { return nil }
            let tokens = jsonStringValues(line)
            var edits: [(Range<Int>, [UInt8])] = []
            var matchedContainers = Set<Int>()
            for t in tokens {
                if let new = replacements.values[t.value] {
                    edits.append((t.range, jsonEncode(new, escapeSlashes: t.escapedSlash)))
                    matchedContainers.insert(t.container)
                }
            }
            guard !edits.isEmpty else { return nil }
            if !replacements.oldFilename.isEmpty, replacements.oldFilename != replacements.newFilename {
                for t in tokens where t.key == "filename" && t.value == replacements.oldFilename
                    && matchedContainers.contains(t.container) {
                    edits.append((t.range, jsonEncode(replacements.newFilename, escapeSlashes: t.escapedSlash)))
                }
            }
            let rewritten = splice(Array(line), base: line.startIndex, edits: edits)
            // Belt and braces: the edited line must still be JSON.
            guard (try? JSONSerialization.jsonObject(with: Data(rewritten), options: [.fragmentsAllowed])) != nil else {
                throw Failure.unparseable(file: file, line: number, reason: "rewrite produced invalid JSON")
            }
            return rewritten
        }
    }

    private static func isBlank(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == cr }

    private static func parses(_ line: ArraySlice<UInt8>) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(line), options: [.fragmentsAllowed])) != nil
    }

    /// True when every non-blank line is ONE JSON value: the lines joined
    /// as `[l1,l2,…]` parse, and the array has exactly one element per
    /// line (so `1,2` on one line, or a value split across two lines, is
    /// caught by the count and sent to the per-line check).
    /// Memory: one extra copy of the file's bytes, for the call only.
    static func allLinesParse(_ bytes: [UInt8]) -> Bool {
        var joined: [UInt8] = [0x5B]
        joined.reserveCapacity(bytes.count + 2)
        var count = 0
        var start = 0
        while start <= bytes.count {
            let end = byteIndex(of: newline, in: bytes[start...]) ?? bytes.count
            let line = bytes[start..<end]
            if line.contains(where: { !isBlank($0) }) {
                if count > 0 { joined.append(comma) }
                joined.append(contentsOf: line)
                count += 1
            }
            if end == bytes.count { break }
            start = end + 1
        }
        joined.append(0x5D)
        guard let array = (try? JSONSerialization.jsonObject(with: Data(joined))) as? [Any] else { return false }
        return array.count == count
    }

    /// A JSON string value in a line: its raw byte range (quotes included),
    /// decoded value, the id of the object/array holding it, and its key
    /// when that container is an object.
    struct StringToken {
        let range: Range<Int>
        let value: String
        let container: Int
        let key: String?
        let escapedSlash: Bool
    }

    /// Minimal scanner over an already-validated JSON line.
    static func jsonStringValues(_ b: ArraySlice<UInt8>) -> [StringToken] {
        struct Frame { let id: Int; let isObject: Bool; var expectingKey: Bool; var lastKey: String? }
        var stack: [Frame] = []
        var nextID = 0
        var tokens: [StringToken] = []
        var i = b.startIndex
        while i < b.endIndex {
            switch b[i] {
            case 0x7B:                                           // {
                stack.append(Frame(id: nextID, isObject: true, expectingKey: true, lastKey: nil))
                nextID += 1; i += 1
            case 0x5B:                                           // [
                stack.append(Frame(id: nextID, isObject: false, expectingKey: false, lastKey: nil))
                nextID += 1; i += 1
            case 0x7D, 0x5D:                                     // } ]
                if !stack.isEmpty { stack.removeLast() }
                i += 1
            case comma:
                if let top = stack.last, top.isObject { stack[stack.count - 1].expectingKey = true }
                i += 1
            case 0x3A:                                           // :
                if !stack.isEmpty { stack[stack.count - 1].expectingKey = false }
                i += 1
            case quote:
                let start = i
                var hasEscape = false
                var escapedSlash = false
                i += 1
                while i < b.endIndex {
                    if b[i] == backslash {
                        hasEscape = true
                        if i + 1 < b.endIndex, b[i + 1] == 0x2F { escapedSlash = true }
                        i += 2
                        continue
                    }
                    if b[i] == quote { break }
                    i += 1
                }
                let end = min(i + 1, b.endIndex)
                i = end
                let raw = b[start..<end]
                let value: String
                if hasEscape {
                    value = (try? JSONSerialization.jsonObject(with: Data(raw), options: [.fragmentsAllowed])) as? String ?? ""
                } else {
                    value = String(decoding: raw.dropFirst().dropLast(), as: UTF8.self)
                }
                if let top = stack.last, top.isObject, top.expectingKey {
                    stack[stack.count - 1].lastKey = value
                } else {
                    let top = stack.last
                    tokens.append(StringToken(range: start..<end, value: value,
                                              container: top?.id ?? -1,
                                              key: top?.isObject == true ? top?.lastKey : nil,
                                              escapedSlash: escapedSlash))
                }
            default:
                i += 1
            }
        }
        return tokens
    }

    /// JSON string literal for `s`, matching JSONEncoder's escapes; `/` is
    /// escaped only when the token being replaced used `\/` (the promote
    /// journal's default encoder does, the sorted-key journals do not).
    static func jsonEncode(_ s: String, escapeSlashes: Bool) -> [UInt8] {
        var out: [UInt8] = [quote]
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += [backslash, quote]
            case "\\": out += [backslash, backslash]
            case "/" where escapeSlashes: out += [backslash, 0x2F]
            case "\n": out += Array("\\n".utf8)
            case "\r": out += Array("\\r".utf8)
            case "\t": out += Array("\\t".utf8)
            case "\u{08}": out += Array("\\b".utf8)
            case "\u{0C}": out += Array("\\f".utf8)
            default:
                if u.value < 0x20 {
                    out += Array(String(format: "\\u%04x", u.value).utf8)
                } else {
                    out += Array(String(u).utf8)
                }
            }
        }
        out.append(quote)
        return out
    }

    /// Replace byte ranges (absolute indices into the original buffer that
    /// started at `base`) — applied back to front so earlier ranges hold.
    private static func splice(_ bytes: [UInt8], base: Int, edits: [(Range<Int>, [UInt8])]) -> [UInt8] {
        var out = bytes
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            out.replaceSubrange((range.lowerBound - base)..<(range.upperBound - base), with: replacement)
        }
        return out
    }

    // MARK: The App Support ledger (the mirror's source)

    /// Rewrite the App Support ledger with the same exact-value rules, so
    /// the next Promote mirror does not copy the old names back into the
    /// archive. Lenient (a damaged line is left alone — the rename has
    /// already happened), backed up beside the ledger, published
    /// atomically. Returns the number of changed lines.
    static func rewriteLedgerFile(at url: URL, replacements: Replacements, now: Date = Date()) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let data = try Data(contentsOf: url)
        guard data.count <= readLimit else {
            throw Failure.unreadable(file: url.lastPathComponent, reason: "larger than \(readLimit >> 20) MB")
        }
        let result = try rewriteJSONL([UInt8](data), replacements: replacements,
                                      file: url.lastPathComponent, lenient: true)
        guard result.changedLines > 0 else { return 0 }
        let backupDir = url.deletingLastPathComponent()
            .appendingPathComponent(backupFolder, isDirectory: true)
            .appendingPathComponent(backupStamp(now), isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        try AtomicFilePublish.write(data, to: backupDir.appendingPathComponent(url.lastPathComponent),
                                    durability: .fullFsync, createIntermediates: false)
        try AtomicFilePublish.write(Data(result.bytes), to: url, durability: .fullFsync, createIntermediates: false)
        return result.changedLines
    }
}
