// ObservationJournal.swift — VideoScanCore/Background
//
// The helper's ONLY output toward the catalog (design §3.4): one JSON line
// per observation in ~/Library/Application Support/VideoScan/background/
// journal/<yyyy-mm-dd>.jsonl (UTC day), append-only. The app's
// JournalApplier reads the lines it has not applied yet and commits them
// through the one commit door; the helper never learns whether a line was
// applied (it does not need to).
//
// Line shape (version 1; keys sorted, no whitespace — the CANONICAL form):
//   {"at":<unix s>,"by":"machine:…@r3","confidence":0.6,"evidence":{…},
//    "field":"era.yearRange","id":"<sha256>","job":"<job id>",
//    "state":"inferred","subject_id":"<64 hex>","subject_kind":"content",
//    "table":"provenance_assertions","unit":<n>,"v":1,"value":"1991-1995"}
// `id` = SHA-256 of the canonical line WITHOUT `id` — the idempotence key:
// the same observation written twice has the same id, and a reader that
// recomputes it detects a line that was cut or edited.
//
// Durability (not write-then-rename: a journal APPENDS):
//   * `append` writes ONE unit's lines as ONE buffer with one write(2) on an
//     O_APPEND descriptor (a regular-file write is not split by a signal; a
//     power cut or a full disk can still leave a torn tail), then
//     F_FULLFSYNC (fsync when the volume refuses it) — once per unit;
//   * a torn last line (no trailing newline) is IGNORED by the reader and
//     reported (`torn`), and the next `append` first seals it with "\n" so
//     it becomes one invalid line the applier refuses ("invalid") instead of
//     a prefix glued onto the next good line; the unit it belonged to is not
//     checkpointed, so the job re-runs it and its lines are appended whole.
//
// Sidecars: `<file>.applied` holds the byte offset up to which the APP has
// applied that file (written atomically by the app); `refused.jsonl` holds
// the lines the catalog refused, with the rule that refused them.
//
// Memory: `read(file:from:maxLines:)` holds at most `maxLines` decoded lines
// (≤ ~4 KB each, so 256 lines ≈ 1 MB) plus one 1 MB read buffer;
// `subjects(by:)` streams every file once and keeps one 64-char digest per
// observed content (100k contents ≈ 10 MB).
//
// C++ reading: an append-only log file with a per-record content hash, and
// a cursor (`.applied`) the consumer persists — a write-ahead log the app
// replays into its database.

import CryptoKit
import Darwin
import Foundation

// MARK: - One line

public struct ObservationLine: Sendable, Equatable {
    public static let version = 1
    public static let assertionsTable = "provenance_assertions"

    public let id: String
    public let table: String
    public let subjectKind: String
    public let subjectID: String
    public let field: String
    public let value: String
    public let state: String
    public let by: String
    public let at: Int64
    public let confidence: Double
    /// The evidence object, canonical JSON text (sorted keys).
    public let evidenceJSON: String
    public let job: String
    public let unit: Int

    /// A machine observation for `provenance_assertions`. `evidence` must be
    /// a JSON object of finite values; `confidence` is clamped to [0,1] (it
    /// is the model's self-assessment and is never shown).
    public init(subjectID: String, field: String, value: String, by: String, at: Int64, confidence: Double,
                evidence: [String: Any], job: String, unit: Int, subjectKind: String = ProvenanceAssertionSubject.content) throws {
        guard JSONSerialization.isValidJSONObject(evidence) else { throw JournalLineProblem("evidence is not a JSON object of finite values") }
        let data = try CanonicalJSON.data(evidence)
        try self.init(table: Self.assertionsTable, subjectKind: subjectKind, subjectID: subjectID, field: field, value: value,
                      state: "inferred", by: by, at: at, confidence: confidence.isFinite ? min(1, max(0, confidence)) : 0,
                      evidenceJSON: String(decoding: data, as: UTF8.self), job: job, unit: unit, id: nil)
    }

    private init(table: String, subjectKind: String, subjectID: String, field: String, value: String, state: String, by: String,
                 at: Int64, confidence: Double, evidenceJSON: String, job: String, unit: Int, id: String?) throws {
        self.table = table
        self.subjectKind = subjectKind
        self.subjectID = subjectID
        self.field = field
        self.value = value
        self.state = state
        self.by = by
        self.at = at
        self.confidence = confidence
        self.evidenceJSON = evidenceJSON
        self.job = job
        self.unit = unit
        let computed = Self.sha256(try Self.canonical(Self.object(table: table, subjectKind: subjectKind, subjectID: subjectID,
                                                                  field: field, value: value, state: state, by: by, at: at,
                                                                  confidence: confidence, evidenceJSON: evidenceJSON,
                                                                  job: job, unit: unit)))
        if let id, id != computed { throw JournalLineProblem("id does not match the line (written \(id.prefix(12))…, computed \(computed.prefix(12))…)") }
        self.id = computed
    }

    /// The whole line, canonical, with its trailing newline.
    public var encoded: Data {
        var object = Self.object(table: table, subjectKind: subjectKind, subjectID: subjectID, field: field, value: value,
                                 state: state, by: by, at: at, confidence: confidence, evidenceJSON: evidenceJSON, job: job, unit: unit)
        object["id"] = id
        // Every value was valid when the line was made; a failure here is a programming error.
        var data = (try? Self.canonical(object)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// One line's bytes (without the newline) → the line, or the reason it is not one.
    public static func decode(_ bytes: Data) -> Result<ObservationLine, JournalLineProblem> {
        guard let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
            return .failure(JournalLineProblem("not a JSON object"))
        }
        guard let v = object["v"] as? Int, v == version else {
            return .failure(JournalLineProblem("version \(String(describing: object["v"] ?? "none")) is not \(version)"))
        }
        func text(_ key: String) -> String? { object[key] as? String }
        guard let id = text("id"), let table = text("table"), let kind = text("subject_kind"), let subject = text("subject_id"),
              let field = text("field"), let value = text("value"), let state = text("state"), let by = text("by"),
              let job = text("job"), let at = (object["at"] as? NSNumber)?.int64Value, let unit = object["unit"] as? Int,
              let confidence = (object["confidence"] as? NSNumber)?.doubleValue,
              let evidence = object["evidence"] as? [String: Any],
              let evidenceData = try? CanonicalJSON.data(evidence) else {
            return .failure(JournalLineProblem("a key is missing or has the wrong type"))
        }
        do {
            return .success(try ObservationLine(table: table, subjectKind: kind, subjectID: subject, field: field, value: value,
                                                state: state, by: by, at: at, confidence: confidence,
                                                evidenceJSON: String(decoding: evidenceData, as: UTF8.self), job: job, unit: unit, id: id))
        } catch let problem as JournalLineProblem {
            return .failure(problem)
        } catch {
            return .failure(JournalLineProblem("\(error)"))
        }
    }

    private static func object(table: String, subjectKind: String, subjectID: String, field: String, value: String, state: String,
                               by: String, at: Int64, confidence: Double, evidenceJSON: String, job: String, unit: Int) -> [String: Any] {
        let evidence = (try? JSONSerialization.jsonObject(with: Data(evidenceJSON.utf8))) ?? [String: Any]()
        return ["v": version, "table": table, "subject_kind": subjectKind, "subject_id": subjectID, "field": field, "value": value,
                "state": state, "by": by, "at": at, "confidence": confidence, "evidence": evidence, "job": job, "unit": unit]
    }

    private static func canonical(_ object: [String: Any]) throws -> Data {
        try CanonicalJSON.data(object)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func == (a: ObservationLine, b: ObservationLine) -> Bool { a.id == b.id }
}

/// Sorted keys, no whitespace, shortest round-trip numbers (JSONEncoder
/// writes 0.6 as "0.6"; JSONSerialization writes "0.59999999999999998").
/// Parsing a canonical text and writing it again gives the same bytes, so
/// the id a reader recomputes is the id the writer wrote.
/// (C++: a tagged-union value type with a deterministic printer.)
enum CanonicalJSON {
    indirect enum Value: Encodable {
        case null, bool(Bool), int(Int64), double(Double), string(String), array([Value]), object([String: Value])

        init(_ any: Any) throws {
            switch any {
            case is NSNull: self = .null
            case let s as String: self = .string(s)
            case let n as NSNumber:
                if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue); return }
                let d = n.doubleValue
                guard d.isFinite else { throw JournalLineProblem("a number is not finite") }
                if CFNumberIsFloatType(n) {
                    self = d == d.rounded() && abs(d) < 9e15 ? .int(Int64(d)) : .double(d)
                } else {
                    // Codex #187 F5: an integer outside Int64 (UInt64.max reads back as -1) is refused, never aliased.
                    guard String(n.int64Value) == n.stringValue else { throw JournalLineProblem("the integer \(n.stringValue) is outside Int64") }
                    self = .int(n.int64Value)
                }
            case let a as [Any]: self = .array(try a.map(Value.init))
            case let o as [String: Any]: self = .object(try o.mapValues(Value.init))
            default: throw JournalLineProblem("\(type(of: any)) is not a JSON value")
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let b): try c.encode(b)
            case .int(let i): try c.encode(i)
            case .double(let d): try c.encode(d)
            case .string(let s): try c.encode(s)
            case .array(let a): try c.encode(a)
            case .object(let o): try c.encode(o)
            }
        }
    }

    static func data(_ any: Any) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(try Value(any))
    }
}

public struct JournalLineProblem: Error, Equatable, Sendable, CustomStringConvertible {
    public let words: String
    public init(_ words: String) { self.words = words }
    public var description: String { words }
}

// MARK: - The files

public final class ObservationJournal: @unchecked Sendable {

    public static let refusedFileName = "refused.jsonl"
    public static let appliedSuffix = ".applied"
    /// Read buffer per `read` call.
    static let readChunkBytes = 1 << 20
    /// A line longer than this is a runaway, not an observation: refused as invalid.
    public static let maxLineBytes = 256 * 1024

    public let directory: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// Codex #187 F9: earlier days' torn tails are sealed once per process,
    /// at its first append (only today's file is ever appended to, so an
    /// earlier day's tail with no newline is a crash's, never a write in flight).
    private var earlierDaysSealed = false

    /// ~/Library/Application Support/VideoScan/background/journal
    public static var productionDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VideoScan/background/journal", isDirectory: true)
    }

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// `<yyyy-mm-dd>.jsonl` for the UTC day of `date`.
    public static func fileName(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.jsonl", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Writer (the helper)

    public struct AppendReport: Equatable, Sendable {
        public var file: String
        public var lines: Int
        public var bytes: Int
        /// A torn tail from an earlier crash was sealed with "\n" first.
        public var sealedTornTail: Bool
    }

    /// Append one unit's lines: one write(2) of the whole buffer, then one
    /// full fsync. Empty `lines` writes nothing.
    @discardableResult
    public func append(_ lines: [ObservationLine]) throws -> AppendReport {
        lock.lock(); defer { lock.unlock() }
        let name = Self.fileName(for: now())
        guard !lines.isEmpty else { return AppendReport(file: name, lines: 0, bytes: 0, sealedTornTail: false) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !earlierDaysSealed {
            for earlier in dayFiles() where earlier < name { try Self.sealTornTail(directory.appendingPathComponent(earlier)) }
            earlierDaysSealed = true
        }
        let url = directory.appendingPathComponent(name)
        // Read-write (O_APPEND still sends every write to the end): the torn-tail check preads the last byte.
        let fd = Darwin.open(url.path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw JournalIOError("open \(url.path)", errno) }
        defer { Darwin.close(fd) }
        var buffer = Data()
        let sealed = try Self.endsTorn(fd: fd)
        if sealed { buffer.append(0x0A) }
        for line in lines { buffer.append(line.encoded) }
        try Self.writeAll(fd: fd, buffer, path: url.path)
        try Self.fullSync(fd, path: url.path)
        return AppendReport(file: name, lines: lines.count, bytes: buffer.count, sealedTornTail: sealed)
    }

    /// Append "\n" to a file whose last byte is not one (a crash's torn tail).
    private static func sealTornTail(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDWR | O_APPEND | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        guard try endsTorn(fd: fd) else { return }
        try writeAll(fd: fd, Data([0x0A]), path: url.path)
        try fullSync(fd, path: url.path)
    }

    /// F_FULLFSYNC, or fsync when the volume refuses it; a failure throws.
    static func fullSync(_ fd: Int32, path: String) throws {
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { throw JournalIOError("fsync \(path)", errno) }
    }

    /// True when the file is non-empty and its last byte is not "\n".
    private static func endsTorn(fd: Int32) throws -> Bool {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw JournalIOError("fstat", errno) }
        guard st.st_size > 0 else { return false }
        var last: UInt8 = 0
        guard pread(fd, &last, 1, st.st_size - 1) == 1 else { throw JournalIOError("pread", errno) }
        return last != 0x0A
    }

    private static func writeAll(fd: Int32, _ data: Data, path: String) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw JournalIOError("write \(path)", errno)
                }
                offset += n
            }
        }
    }

    // MARK: Reader (the app, and the helper's cache check)

    public struct ReadLine: Sendable {
        /// Byte offset of the line's first byte, and one past its newline.
        public let offset: Int
        public let end: Int
        public let raw: Data
        public let result: Result<ObservationLine, JournalLineProblem>
    }

    public struct ReadResult: Sendable {
        public var file: String
        public var lines: [ReadLine] = []
        /// One past the last complete line read — where the next read starts.
        public var nextOffset: Int
        /// The file ends in a line with no newline (a write torn by a crash):
        /// ignored, reported; its offset.
        public var tornAt: Int?
        /// No more complete lines after `nextOffset` (now).
        public var atEnd: Bool
    }

    /// Up to `maxLines` complete lines of `file` from byte `offset`. A line
    /// over `maxLineBytes` is streamed past (never held) and returned as ONE
    /// invalid line carrying a bounded prefix (Codex #187 F8).
    public func read(file: String, from offset: Int, maxLines: Int = 256) throws -> ReadResult {
        let url = directory.appendingPathComponent(file)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, offset)))
        var result = ReadResult(file: file, nextOffset: offset, tornAt: nil, atEnd: false)
        var pending = Data()
        var cursor = 0                      // first unread byte of `pending`
        var pendingStart = offset           // file offset of pending[cursor]
        var oversized: (start: Int, prefix: Data, length: Int)?   // skipping a runaway line
        while result.lines.count < maxLines {
            if cursor > 0 { pending.removeSubrange(0..<cursor); cursor = 0 }   // once per chunk, not per line
            let chunk = try handle.read(upToCount: Self.readChunkBytes) ?? Data()
            if chunk.isEmpty {
                if let o = oversized { result.tornAt = o.start } else if !pending.isEmpty { result.tornAt = pendingStart }
                result.atEnd = true
                return result
            }
            pending.append(chunk)
            while result.lines.count < maxLines {
                if var o = oversized {
                    guard let nl = pending[(pending.startIndex + cursor)...].firstIndex(of: 0x0A) else {
                        o.length += pending.count - cursor
                        cursor = pending.count
                        oversized = o
                        break
                    }
                    let consumed = nl - (pending.startIndex + cursor) + 1
                    o.length += consumed
                    cursor += consumed
                    let end = o.start + o.length
                    result.lines.append(ReadLine(offset: o.start, end: end, raw: o.prefix,
                                                 result: .failure(JournalLineProblem("line of \(o.length - 1) bytes is over the \(Self.maxLineBytes)-byte cap"))))
                    pendingStart = end
                    result.nextOffset = end
                    oversized = nil
                    continue
                }
                guard let nl = pending[(pending.startIndex + cursor)...].firstIndex(of: 0x0A) else {
                    if pending.count - cursor > Self.maxLineBytes {
                        let from = pending.startIndex + cursor
                        oversized = (start: pendingStart, prefix: Data(pending[from..<(from + 1024)]), length: pending.count - cursor)
                        cursor = pending.count
                    }
                    break
                }
                let raw = Data(pending[(pending.startIndex + cursor)..<nl])
                let lineLength = raw.count + 1
                let line = ReadLine(offset: pendingStart, end: pendingStart + lineLength,
                                    raw: raw.count > Self.maxLineBytes ? Data(raw.prefix(1024)) : raw,
                                    result: raw.count > Self.maxLineBytes ? .failure(JournalLineProblem("line of \(raw.count) bytes is over the \(Self.maxLineBytes)-byte cap"))
                                        : ObservationLine.decode(raw))
                result.lines.append(line)
                pendingStart += lineLength
                result.nextOffset = pendingStart
                cursor += lineLength
            }
        }
        // Stopped on the line budget: the caller reads again from `nextOffset`.
        return result
    }

    /// Codex #187 F9: an EARLIER day's file (never appended to again — the
    /// helper appends only to today's) whose torn tail is older than
    /// `quietSeconds` is a crash's leftover: seal it with "\n" and return the
    /// fragment's first bytes (≤ 1 KB) so the caller can refuse it as "torn".
    /// nil = not abandoned (today's file, recently written, or not torn).
    public func sealAbandonedTail(_ file: String, tornAt: Int, quietSeconds: TimeInterval = 600) throws -> Data? {
        guard file < Self.fileName(for: now()) else { return nil }
        let url = directory.appendingPathComponent(file)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let modified = attributes[.modificationDate] as? Date, now().timeIntervalSince(modified) >= quietSeconds else { return nil }
        lock.lock(); defer { lock.unlock() }
        let fd = Darwin.open(url.path, O_RDWR | O_APPEND | O_CLOEXEC)
        guard fd >= 0 else { throw JournalIOError("open \(url.path)", errno) }
        defer { Darwin.close(fd) }
        guard try Self.endsTorn(fd: fd) else { return nil }
        var prefix = [UInt8](repeating: 0, count: 1024)
        let n = pread(fd, &prefix, prefix.count, off_t(tornAt))
        try Self.writeAll(fd: fd, Data([0x0A]), path: url.path)
        try Self.fullSync(fd, path: url.path)
        return Data(prefix.prefix(max(0, n)))
    }

    /// The journal's day files, oldest first (never refused.jsonl or a sidecar).
    public func dayFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") && $0 != Self.refusedFileName && !AtomicFilePublish.isTemporaryPublishArtifact($0) }.sorted()
    }

    public func size(of file: String) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file).path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    // MARK: The applied cursor (written by the app)

    /// The offset `.applied` holds for `file` — or 0 (replay from the start;
    /// re-applying is a no-op) when it is absent, unreadable, or no longer
    /// describes this file (Codex #187 F3): another inode, a file shorter
    /// than the cursor, a byte before the cursor that is not a newline, or
    /// a hash of the 4 KB before the cursor that differs. (No stored st_dev:
    /// a device number is not stable across a remount or a reboot —
    /// FixityStampVolumeIdentityTests; the inode and the bytes suffice.)
    public func appliedOffset(_ file: String) -> Int {
        let sidecar = directory.appendingPathComponent(file + Self.appliedSuffix)
        guard let data = try? Data(contentsOf: sidecar),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let offset = o["offset"] as? Int, offset > 0,
              let identity = Self.identity(directory.appendingPathComponent(file)),
              o["inode"] as? Int == identity.inode,
              identity.size >= offset,
              let tail = Self.tailHash(directory.appendingPathComponent(file), before: offset),
              o["tail_sha256"] as? String == tail else { return 0 }
        return offset
    }

    /// The app's cursor for `file`: the offset, bound to the file's identity
    /// and the hash of the bytes just before it. Atomic (write-then-rename).
    public func markApplied(_ file: String, offset: Int) throws {
        let url = directory.appendingPathComponent(file)
        guard let identity = Self.identity(url), let tail = Self.tailHash(url, before: offset) else {
            throw JournalIOError("stat \(url.path)", errno)
        }
        let record: [String: Any] = ["offset": offset, "inode": identity.inode, "tail_sha256": tail]
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(0x0A)
        try AtomicFilePublish.write(data, to: directory.appendingPathComponent(file + Self.appliedSuffix))
    }

    private static func identity(_ url: URL) -> (inode: Int, size: Int)? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return (Int(st.st_ino), Int(st.st_size))
    }

    /// SHA-256 of the (≤ 4 KB) bytes ending at `offset`; nil when they cannot
    /// be read or the byte before `offset` is not a newline.
    private static func tailHash(_ url: URL, before offset: Int) -> String? {
        guard offset > 0, let handle = try? FileHandle(forReadingFrom: url) else { return offset == 0 ? "" : nil }
        defer { try? handle.close() }
        let start = max(0, offset - 4096)
        guard (try? handle.seek(toOffset: UInt64(start))) != nil,
              let bytes = try? handle.read(upToCount: offset - start), bytes.count == offset - start,
              bytes.last == 0x0A else { return nil }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Bytes not applied yet, over every day file (the Catalog Status line
    /// counts lines; this is the cheap "is there anything?" check).
    public func unappliedBytes() -> Int {
        dayFiles().reduce(0) { $0 + max(0, size(of: $1) - appliedOffset($1)) }
    }

    // MARK: Refused lines (written by the app)

    public struct RefusedRecord: Sendable {
        public var raw: Data
        public var file: String
        public var offset: Int
        public var reason: String
        public var detail: String
        public init(raw: Data, file: String, offset: Int, reason: String, detail: String) {
            self.raw = raw; self.file = file; self.offset = offset; self.reason = reason; self.detail = detail
        }
    }

    /// A batch of refused lines: ONE write(2) and ONE full fsync (Codex #187
    /// F10), after sealing a torn tail an earlier crash left (F2). Throws when
    /// any of it cannot be made durable (F1) — the caller must then not move
    /// its cursor, so nothing is lost.
    public func appendRefused(_ records: [RefusedRecord]) throws {
        guard !records.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let at = Int64(now().timeIntervalSince1970)
        var buffer = Data()
        for r in records {
            let record: [String: Any] = ["reason": r.reason, "detail": r.detail, "file": r.file, "offset": r.offset,
                                         "line": String(decoding: r.raw, as: UTF8.self), "refused_at": at]
            buffer.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]))
            buffer.append(0x0A)
        }
        let url = directory.appendingPathComponent(Self.refusedFileName)
        let fd = Darwin.open(url.path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw JournalIOError("open \(url.path)", errno) }
        defer { Darwin.close(fd) }
        if try Self.endsTorn(fd: fd) { buffer.insert(0x0A, at: 0) }
        try Self.writeAll(fd: fd, buffer, path: url.path)
        try Self.fullSync(fd, path: url.path)
        refusedWrites += 1
    }

    /// How many refused batches this instance wrote (the one-write-per-batch sensor).
    public private(set) var refusedWrites = 0


    /// One refused line with the rule that refused it.
    public func appendRefused(raw: Data, file: String, offset: Int, reason: String, detail: String) throws {
        try appendRefused([RefusedRecord(raw: raw, file: file, offset: offset, reason: reason, detail: detail)])
    }

    /// The refused records, as written (each a JSON object).
    public func refusedRecords() -> [[String: Any]] {
        let url = directory.appendingPathComponent(Self.refusedFileName)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
    }

    /// How many refusals refused.jsonl holds (readable records; a sealed
    /// fragment of a crashed write is not one).
    public func refusedCount() -> Int { refusedRecords().count }

    // MARK: The helper's cache check (§0.7)

    /// Every content digest with at least one valid line signed `by`, over
    /// every day file (applied or not). Streams; see the memory note.
    public func subjects(by signer: String) -> Set<String> {
        var out = Set<String>()
        let needle = Data("\"by\":\"\(signer)\"".utf8)
        for file in dayFiles() {
            var offset = 0
            while true {
                guard let chunk = try? read(file: file, from: offset, maxLines: 4096) else { break }
                for line in chunk.lines where line.raw.range(of: needle) != nil {
                    if case .success(let l) = line.result, l.by == signer { out.insert(l.subjectID) }
                }
                if chunk.atEnd || chunk.nextOffset == offset { break }
                offset = chunk.nextOffset
            }
        }
        return out
    }
}

public struct JournalIOError: Error, CustomStringConvertible, Sendable {
    public let words: String
    init(_ what: String, _ code: Int32) { words = "\(what): \(String(cString: strerror(code))) (errno \(code))" }
    public var description: String { words }
}
