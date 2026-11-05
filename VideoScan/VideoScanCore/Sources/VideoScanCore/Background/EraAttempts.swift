// EraAttempts.swift — VideoScanCore/Background
//
// How many times the era job has tried a file and come away with no verdict
// (Rick 2026-11-04: 402 Avid MXF essences, reference movies and .m4p files
// never ripped a frame; "retry next run" had no limit, so the helper re-ran
// them forever at full speed and said nothing about why).
//
// The rule (the same shape as sound prints' give-up, #416 / v15, without a
// schema change): a unit that ends with no verdict — frames that would not
// rip, windows the model never answered, a clip past its cap, a worker death
// — is ONE try for (signer, digest). On the `maxTries`-th try the job writes
// one `era.none` line that says "gave up after N tries: <why>", which caches
// the file for that signer like any other verdict; its entry here is then
// cleared. A verdict before the limit clears the entry too. Not a try: a file
// that is not there (unreadable before or during the unit), a model that
// will not load, a missing or BROKEN tool (EraJob's ffmpeg canary refuses at
// START and before every "no frame would decode" try), a worker exception
// (it can be systemic; the supervisor's fail-fast holds the kind instead).
//
// Storage: `<state root>/attempts/era.jsonl`, append-only (Fable review
// 11/04: rewriting the whole map per try was 60 ms a unit at 20k entries).
// One line per change — {"k": "<signer> <digest>", "t": tries, "r": reason,
// "a": at} or {"k": …, "clear": true} — fsynced; the last line per key wins.
// A torn LAST line (no newline: a crash mid-append) is ignored — one try is
// lost, so the give-up comes one run later, bounded. Any other unreadable
// line → the job is REFUSED in words naming the file (fail closed: a guess
// either way is a silent give-up or a silent loop). Compacted (atomic
// rewrite of the live entries) at load when dead lines outnumber live ones.
// A crash between a try's line and the unit's checkpoint re-runs the unit
// and can count that try twice: the give-up comes one run early, never late.
//
// Memory: one entry (≈ 200 B) per file currently without a verdict.
//
// C++ reading: a write-ahead log replayed into a std::map at open, behind a mutex.

import Foundation

public struct EraAttempt: Codable, Equatable, Sendable {
    public var tries: Int
    public var lastReason: String
    public var lastAt: Int64
}

public final class EraAttemptStore: @unchecked Sendable {
    /// Tries per (signer, file) before the job gives the file up.
    public static let maxTries = 3

    public let url: URL
    private let lock = NSLock()
    private var entries: [String: EraAttempt] = [:]
    private var handle: FileHandle?

    public static func url(stateRoot: URL) -> URL {
        stateRoot.appendingPathComponent("attempts/era.jsonl")
    }

    private struct Line: Codable {
        var k: String
        var t: Int?
        var r: String?
        var a: Int64?
        var clear: Bool?
    }

    /// Replays the log (absent = no tries). Throws a Refusal naming the file when a line other than a torn tail is unreadable.
    public init(stateRoot: URL) throws {
        url = Self.url(stateRoot: stateRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw refusal("cannot be read (\(error))") }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let tornTail = data.last != 0x0A
        if lines.last?.isEmpty == true { lines.removeLast() }
        var count = 0
        for (i, bytes) in lines.enumerated() where !bytes.isEmpty {
            guard let line = try? JSONDecoder().decode(Line.self, from: Data(bytes)) else {
                if tornTail, i == lines.count - 1 { continue }          // a crash mid-append: one try lost
                throw refusal("line \(i + 1) is not a try record")
            }
            count += 1
            if line.clear == true {
                entries.removeValue(forKey: line.k)
            } else if let t = line.t {
                entries[line.k] = EraAttempt(tries: t, lastReason: line.r ?? "", lastAt: line.a ?? 0)
            }
        }
        if tornTail || count > 2 * entries.count + 64 { try compact() }
    }

    private func refusal(_ why: String) -> Refusal {
        Refusal("era: the try counts at \(url.path) are unreadable (\(why)) — the job is refused rather than "
                + "give files up or retry them blind; move the file aside to start the counts again")
    }

    deinit { try? handle?.close() }

    static func key(_ digest: String, _ signer: String) -> String { "\(signer) \(digest)" }

    public func tries(digest: String, signer: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return entries[Self.key(digest, signer)]?.tries ?? 0
    }

    /// One more try; returns the count after it. Durable (fsynced) before it returns. O(1).
    @discardableResult
    public func record(digest: String, signer: String, reason: String, at: Int64) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(digest, signer)
        let tries = (entries[key]?.tries ?? 0) + 1
        let attempt = EraAttempt(tries: tries, lastReason: String(reason.prefix(500)), lastAt: at)
        try append(Line(k: key, t: tries, r: attempt.lastReason, a: at))
        entries[key] = attempt
        return tries
    }

    public func clear(digest: String, signer: String) throws {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(digest, signer)
        guard entries[key] != nil else { return }
        try append(Line(k: key, clear: true))
        entries.removeValue(forKey: key)
    }

    private func append(_ line: Line) throws {
        if handle == nil {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            handle = try FileHandle(forWritingTo: url)
        }
        guard let handle else { return }
        try handle.seekToEnd()
        try handle.write(contentsOf: try JSONEncoder().encode(line) + Data([0x0A]))
        try handle.synchronize()
    }

    /// The live entries, rewritten atomically (called from init only, before any append).
    private func compact() throws {
        let encoder = JSONEncoder()
        var out = Data()
        for (k, e) in entries.sorted(by: { $0.key < $1.key }) {
            out += try encoder.encode(Line(k: k, t: e.tries, r: e.lastReason, a: e.lastAt)) + Data([0x0A])
        }
        try AtomicFilePublish.write(out, to: url)
    }
}
