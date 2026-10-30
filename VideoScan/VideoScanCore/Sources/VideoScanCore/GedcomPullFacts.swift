// GedcomPullFacts.swift
// "When was each GEDCOM pull the tree uses exported?" (Rick, 2026-10-30).
//
// Three pieces, all pure or file-read-only:
//   1. GedcomHeaderFacts — reads ONLY the head of one .ged: the export date
//      (`1 DATE` + `2 TIME` directly under `0 HEAD`), the exporting program
//      (`1 SOUR` under HEAD) and the surname of the first INDI's first NAME
//      (getmyancestors writes the start person first; that surname is the
//      pull's label). Unknown → nil, never a guess, never "today".
//   2. GedcomPullDescriber — for the sources a loaded tree was built from,
//      finds each file by name under the GEDCOM directory (recursively, so
//      pulls/ is included) and CONFIRMS it by full-file SHA-256 (identity is
//      the hash, CLAUDE.md rule 6). Not found / wrong bytes → "not on disk",
//      no pane line.
//   3. GedcomPullLine — one line per label, the newest export date in that
//      group: "Breen GEDCOM 26 Aug 2026".
//
// Memory, worst case: the header read holds one 64 KiB chunk plus one
// partial line (capped at 64 KiB) and stops at `byteCap` (8 MiB) even if no
// INDI appeared; it never loads a whole pull (Rick's are 70–130 MB). The
// hash streams in 4 MiB chunks (GedcomCompiledTree.fullSHA256). The hash
// cache holds at most `GedcomPullHashCache.capacity` short keys.

import Foundation
import os

// MARK: - 1. Header facts

public struct GedcomHeaderFacts: Sendable, Equatable {
    /// HEAD `1 DATE` (+ its `2 TIME` when present and well formed), read as
    /// UTC so the day shown is exactly the day written in the file. Nil when
    /// the DATE is missing or not a GEDCOM date_exact ("D MON YYYY").
    public var exportDate: Date?
    /// True when a well-formed `2 TIME` refined `exportDate`.
    public var exportDateHasTime = false
    /// HEAD `1 SOUR` value ("getmyancestors", "Ancestry.com Family Trees",
    /// "VideoScan").
    public var sourceProgram: String?
    /// Surname (between the slashes) of the first INDI record's first NAME.
    /// Nil when there is no INDI within the read, no NAME, or no slashes.
    public var firstPersonSurname: String?

    public init(exportDate: Date? = nil, exportDateHasTime: Bool = false,
                sourceProgram: String? = nil, firstPersonSurname: String? = nil) {
        self.exportDate = exportDate
        self.exportDateHasTime = exportDateHasTime
        self.sourceProgram = sourceProgram
        self.firstPersonSurname = firstPersonSurname
    }

    /// Stop reading after this many bytes even without a first INDI.
    public static let defaultByteCap = 8 << 20

    /// Reads the head of `url` (see the file comment for the bound). Nil only
    /// when the file cannot be opened; an unreadable header is facts of nils.
    public static func read(from url: URL, byteCap: Int = defaultByteCap) -> GedcomHeaderFacts? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var scanner = Scanner()
        var reader = LineSplitter()
        var consumed = 0
        while !scanner.isDone, consumed < byteCap,
              let chunk = try? handle.read(upToCount: min(64 << 10, byteCap - consumed)), !chunk.isEmpty {
            consumed += chunk.count
            reader.feed(chunk) { line in
                guard !scanner.isDone else { return }
                scanner.feed(line)
            }
        }
        if !scanner.isDone, let last = reader.finish() { scanner.feed(last) }
        return scanner.facts
    }

    /// The same parse over lines already in memory (tests, small inputs).
    public static func parse<S: Sequence>(lines: S) -> GedcomHeaderFacts where S.Element: StringProtocol {
        var scanner = Scanner()
        for line in lines {
            scanner.feed(String(line))
            if scanner.isDone { break }
        }
        return scanner.facts
    }

    /// GEDCOM 5.5.1 date_exact "D MON YYYY" (month case-insensitive) plus an
    /// optional "hh:mm[:ss[.fff]]". A malformed TIME is ignored (the day is
    /// still the file's own); a malformed DATE is nil.
    public static func exportDate(date: String, time: String?) -> (date: Date, hasTime: Bool)? {
        let parts = date.split(whereSeparator: \.isWhitespace)
        guard parts.count == 3,
              (1...2).contains(parts[0].count), let day = Int(parts[0]),
              let month = monthNumber[parts[1].uppercased()],
              parts[2].count == 4, let year = Int(parts[2]), parts[2].allSatisfy(\.isNumber)
        else { return nil }
        var components = DateComponents(year: year, month: month, day: day)
        var hasTime = false
        if let time, let (h, m, s) = clock(time) {
            components.hour = h; components.minute = m; components.second = s
            hasTime = true
        }
        guard components.isValidDate(in: utcCalendar), let value = utcCalendar.date(from: components) else { return nil }
        return (value, hasTime)
    }

    /// "26 Aug 2026" — the GEDCOM spelling, in UTC (the zone the date was read in).
    public static func dayText(_ date: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.day ?? 0) \(monthNames[(c.month ?? 1) - 1]) \(c.year ?? 0)"
    }

    /// "26 Aug 2026 05:07:30" when the header had a TIME, else the day.
    public var exportText: String? {
        guard let exportDate else { return nil }
        guard exportDateHasTime else { return Self.dayText(exportDate) }
        let c = Self.utcCalendar.dateComponents([.hour, .minute, .second], from: exportDate)
        return Self.dayText(exportDate) + String(format: " %02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let monthNumber: [String: Int] = Dictionary(
        uniqueKeysWithValues: monthNames.enumerated().map { ($1.uppercased(), $0 + 1) })
    static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static func clock(_ text: String) -> (Int, Int, Int)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts[0].count <= 2, let h = Int(parts[0]), (0...23).contains(h),
              parts[1].count == 2, let m = Int(parts[1]), (0...59).contains(m)
        else { return nil }
        var s = 0
        if parts.count == 3 {
            let whole = parts[2].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            guard whole[0].count == 2, let v = Int(whole[0]), (0...59).contains(v) else { return nil }
            s = v
        }
        return (h, m, s)
    }

    /// "Richard Harding /Testsurname/ Jr" → "Testsurname". No slashes or an
    /// empty surname → nil.
    static func surname(fromName value: String) -> String? {
        guard let open = value.firstIndex(of: "/") else { return nil }
        let rest = value[value.index(after: open)...]
        guard let close = rest.firstIndex(of: "/") else { return nil }
        let name = rest[..<close].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// The line-at-a-time state machine. A value type: `feed` ≈ a member
    /// function on a C++ struct passed by reference (`mutating`).
    struct Scanner {
        enum Section { case preamble, head, firstIndi, other }
        private(set) var isDone = false
        private var section = Section.preamble
        private var headSeen = false
        private var indiSeen = false
        private var headLevel1Tag: String?
        private var dateText: String?
        private var timeText: String?
        private var sourceProgram: String?
        private var surname: String?

        var facts: GedcomHeaderFacts {
            let date = dateText.flatMap { GedcomHeaderFacts.exportDate(date: $0, time: timeText) }
            return GedcomHeaderFacts(exportDate: date?.date, exportDateHasTime: date?.hasTime ?? false,
                                     sourceProgram: sourceProgram, firstPersonSurname: surname)
        }

        mutating func feed(_ raw: String) {
            var line = Substring(raw)
            if line.first == "\u{FEFF}" { line = line.dropFirst() }
            line = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let (level, tag, value) = Self.split(line) else { return }
            if level == 0 {
                enterRecord(tag)
                return
            }
            switch section {
            case .head:
                headLine(level: level, tag: tag, value: value)
            case .firstIndi:
                if level == 1, tag == "NAME" {
                    surname = GedcomHeaderFacts.surname(fromName: value)
                    isDone = true
                }
            case .preamble, .other:
                break
            }
        }

        /// A level-0 line starts a record: the first HEAD, the first INDI,
        /// or anything else. Leaving the first INDI without a NAME ends the
        /// read (its label is unknown; a later person's would be a guess).
        private mutating func enterRecord(_ tag: String) {
            if section == .firstIndi { isDone = true; return }
            if tag == "HEAD", !headSeen {
                section = .head; headSeen = true
            } else if tag == "INDI", !indiSeen {
                section = .firstIndi; indiSeen = true
            } else {
                section = .other
            }
        }

        /// Inside HEAD: `1 DATE` (+ its `2 TIME`) and `1 SOUR`; only the first of each.
        private mutating func headLine(level: Int, tag: String, value: String) {
            if level == 1 {
                headLevel1Tag = tag
                if tag == "DATE", dateText == nil { dateText = value }
                if tag == "SOUR", sourceProgram == nil, !value.isEmpty { sourceProgram = value }
            } else if level == 2, tag == "TIME", headLevel1Tag == "DATE", timeText == nil {
                timeText = value
            }
        }

        /// "LEVEL [@XREF@] TAG [VALUE]" → (level, TAG, value). Nil when the
        /// line is not a GEDCOM line.
        static func split(_ line: Substring) -> (Int, String, String)? {
            var fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count >= 1, let level = Int(fields[0]), level >= 0 else { return nil }
            guard fields.count == 2 else { return nil }
            var rest = fields[1]
            if rest.first == "@" {
                fields = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard fields.count == 2 else { return nil }
                rest = fields[1]
            }
            let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let tag = String(parts[0]).uppercased()
            let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            return (level, tag, value)
        }
    }

    /// Splits a byte stream on CR, LF or CRLF. Lines longer than
    /// `maxLine` are truncated (header lines are short; this bounds memory).
    struct LineSplitter {
        static let maxLine = 64 << 10
        private var pending: [UInt8] = []
        mutating func feed(_ chunk: Data, _ emit: (String) -> Void) {
            for byte in chunk {
                if byte == 0x0A || byte == 0x0D {
                    if !pending.isEmpty { emit(String(decoding: pending, as: UTF8.self)) }
                    pending.removeAll(keepingCapacity: true)
                } else if pending.count < Self.maxLine {
                    pending.append(byte)
                }
            }
        }
        mutating func finish() -> String? {
            defer { pending.removeAll() }
            return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
        }
    }
}

// MARK: - 2. Which files, found and confirmed by hash

/// A source the loaded tree names: file name + the SHA-256 it was built from.
public struct GedcomPullSource: Sendable, Equatable {
    public let fileName: String
    public let sha256: String
    public init(fileName: String, sha256: String) {
        self.fileName = fileName; self.sha256 = sha256.lowercased()
    }
    public var shortSHA: String { String(sha256.prefix(8)) }

    /// The pulls behind `graph`: its logical sources that carry a hash; when
    /// it lists none (a single-file ingest), its physical source(s).
    public static func describing(_ graph: GedcomFamilyGraph) -> [GedcomPullSource] {
        describing(logical: graph.effectiveProvenance, physical: graph.physicalSources)
    }

    public static func describing(logical: [GedcomFamilyGraph.SourceProvenance],
                                  physical: [GedcomFamilyGraph.SourceProvenance]) -> [GedcomPullSource] {
        let hashed = logical.compactMap { p in p.sha256.map { GedcomPullSource(fileName: p.name, sha256: $0) } }
        if !hashed.isEmpty { return hashed }
        return physical.compactMap { p in p.sha256.map { GedcomPullSource(fileName: p.name, sha256: $0) } }
    }
}

public struct GedcomPullFact: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// A file with this name hashed to the recorded SHA-256.
        case verified
        /// No file with this name under the search roots.
        case notOnDisk
        /// Files with this name exist but none has the recorded bytes.
        case hashMismatch(candidates: Int)
    }
    public let source: GedcomPullSource
    public let status: Status
    public var url: URL?
    public var size: Int?
    public var modifiedAt: Date?
    public var header: GedcomHeaderFacts?

    public init(source: GedcomPullSource, status: Status, url: URL? = nil, size: Int? = nil,
                modifiedAt: Date? = nil, header: GedcomHeaderFacts? = nil) {
        self.source = source; self.status = status; self.url = url
        self.size = size; self.modifiedAt = modifiedAt; self.header = header
    }

    /// The pane label: the first person's surname, only for a verified file.
    public var label: String? { status == .verified ? header?.firstPersonSurname : nil }

    /// One `[family-tree]` log line. `ingest` / `generation` are the
    /// compiled generation's createdAt and id (nil = not known).
    public func logLine(ingest: Date?, generation: String?) -> String {
        let iso = ISO8601DateFormatter()
        let tail = "sha=\(source.shortSHA) ingest=\(ingest.map { iso.string(from: $0) } ?? "unknown") "
            + "generation=\(generation ?? "unknown")"
        switch status {
        case .verified:
            return "[family-tree] gedcom pull label=\(label ?? "unknown") "
                + "header=\(header?.exportText ?? "none") file=\(source.fileName) "
                + "size=\(size.map(String.init) ?? "?") mtime=\(modifiedAt.map { iso.string(from: $0) } ?? "?") "
                + "program=\(header?.sourceProgram ?? "unknown") " + tail
        case .notOnDisk:
            return "[family-tree] gedcom pull NOT ON DISK file=\(source.fileName) " + tail
        case .hashMismatch(let n):
            return "[family-tree] gedcom pull NOT ON DISK file=\(source.fileName) "
                + "(\(n) file\(n == 1 ? "" : "s") with that name, none with the recorded bytes) " + tail
        }
    }
}

/// (path, size, mtime) → SHA-256, so re-opening the tab does not rehash
/// 200 MB. A same-size, mtime-preserving rewrite inside one app session is
/// the miss this accepts (the compiled store itself never trusts stat; this
/// cache only decides which pane line to draw). At most `capacity` entries;
/// full → cleared (a GEDCOM folder holds a handful of files).
public final class GedcomPullHashCache: Sendable {
    public static let capacity = 64
    struct Key: Hashable { let path: String; let size: Int; let mtime: TimeInterval }
    // ≈ std::mutex guarding a std::unordered_map.
    private let entries = OSAllocatedUnfairLock(initialState: [Key: String]())
    public init() {}

    func sha(path: String, size: Int, mtime: TimeInterval, compute: () throws -> String) rethrows -> String {
        let key = Key(path: path, size: size, mtime: mtime)
        if let hit = entries.withLock({ $0[key] }) { return hit }
        let value = try compute()
        entries.withLock { map in
            if map.count >= Self.capacity { map.removeAll() }
            map[key] = value
        }
        return value
    }
    public var count: Int { entries.withLock { $0.count } }
}

public struct GedcomPullDescriber: Sendable {
    /// Folders searched recursively (hidden entries skipped).
    public var searchRoots: [URL]
    public var cache: GedcomPullHashCache
    /// Full-file SHA-256; injectable so a test can count hashes.
    public var hasher: @Sendable (URL) throws -> String = { try GedcomCompiledTree.fullSHA256(of: $0) }
    /// Bound on the directory walk (a GEDCOM folder holds a handful of files).
    public var maxEntriesVisited = 20_000

    public init(searchRoots: [URL], cache: GedcomPullHashCache = GedcomPullHashCache()) {
        self.searchRoots = searchRoots; self.cache = cache
    }

    public func describe(_ sources: [GedcomPullSource]) -> [GedcomPullFact] {
        let index = filesByName()
        return sources.map { source in
            let candidates = index[source.fileName] ?? []
            guard !candidates.isEmpty else { return GedcomPullFact(source: source, status: .notOnDisk) }
            for url in candidates {
                guard let stat = try? GedcomCompiledTree.sourceStat(url),
                      let sha = try? cache.sha(path: url.path, size: stat.size, mtime: stat.mtime,
                                               compute: { try hasher(url) }),
                      sha.lowercased() == source.sha256
                else { continue }
                return GedcomPullFact(source: source, status: .verified, url: url, size: stat.size,
                                      modifiedAt: Date(timeIntervalSince1970: stat.mtime),
                                      header: GedcomHeaderFacts.read(from: url))
            }
            return GedcomPullFact(source: source, status: .hashMismatch(candidates: candidates.count))
        }
    }

    /// name → regular .ged files with that name, in a stable (path) order.
    func filesByName() -> [String: [URL]] {
        var out: [String: [URL]] = [:]
        var seen = Set<String>()
        var visited = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        for root in searchRoots {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in walker {
                visited += 1
                if visited > maxEntriesVisited { break }
                guard url.pathExtension.lowercased() == "ged",
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true, values.isSymbolicLink != true
                else { continue }
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                out[url.lastPathComponent, default: []].append(url.standardizedFileURL)
            }
        }
        for key in out.keys { out[key]?.sort { $0.path < $1.path } }
        return out
    }
}

// MARK: - 3. Pane lines

public struct GedcomPullLine: Sendable, Equatable, Identifiable {
    public let label: String
    /// Newest export date among this label's verified pulls; nil = none had one.
    public let newestExportDate: Date?
    public let facts: [GedcomPullFact]
    public var id: String { label }

    /// "Testsurname GEDCOM 26 Aug 2026" (or "… GEDCOM, no date in file").
    public var text: String {
        newestExportDate.map { "\(label) GEDCOM \(GedcomHeaderFacts.dayText($0))" }
            ?? "\(label) GEDCOM, no date in file"
    }

    /// Tooltip: the ingest date and the file names behind this line.
    public func helpText(ingest: Date?) -> String {
        var lines = ["Ingested into this tree " + (ingest.map { GedcomHeaderFacts.dayText($0) } ?? "(date unknown)")]
        for fact in facts {
            lines.append("\(fact.source.fileName) — exported \(fact.header?.exportText ?? "(no date in file)")"
                         + " · \(fact.source.shortSHA)")
        }
        return lines.joined(separator: "\n")
    }

    /// One line per label (first-appearance order); unlabeled facts draw nothing.
    public static func lines(from facts: [GedcomPullFact]) -> [GedcomPullLine] {
        var order: [String] = []
        var groups: [String: [GedcomPullFact]] = [:]
        for fact in facts {
            guard let label = fact.label else { continue }
            if groups[label] == nil { order.append(label) }
            groups[label, default: []].append(fact)
        }
        return order.map { label in
            let group = groups[label] ?? []
            return GedcomPullLine(label: label,
                                  newestExportDate: group.compactMap { $0.header?.exportDate }.max(),
                                  facts: group)
        }
    }
}

// MARK: - The generation behind a loaded graph

extension FamilyGraphCompiledStore {
    /// The manifest (current, else previous) whose physical and logical
    /// sources are exactly `graph`'s — so the ingest date and generation id
    /// logged belong to the tree on screen. Nil when none matches.
    public func manifest(describing graph: GedcomFamilyGraph) -> Manifest? {
        guard let pointer = readPointer() else { return nil }
        let logical = graph.sourceProvenance.map { "\($0.name)\u{0}\($0.sha256 ?? "")" }
        let physical = graph.physicalSources.map { "\($0.name)\u{0}\($0.sha256 ?? "")" }
        for name in [pointer.current, pointer.previous].compactMap({ $0 }) {
            guard let manifest = readManifest(name) else { continue }
            let mLogical = manifest.logicalSources.map { "\($0.fileName)\u{0}\($0.sha256 ?? "")" }
            let mPhysical = manifest.sources.map { "\($0.fileName)\u{0}\($0.sha256)" }
            if mPhysical == physical, mLogical == logical || mLogical.isEmpty { return manifest }
        }
        return nil
    }
}
