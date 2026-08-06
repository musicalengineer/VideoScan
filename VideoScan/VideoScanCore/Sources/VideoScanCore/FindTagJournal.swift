// FindTagJournal.swift (VideoScanCore)
// The write-back contract for the DETACHED find-and-tag daemon
// (2026-08-06, modeled on the preview-sweep helper's Stage 2).
//
// THE data-flow difference from the preview helper: previews write cache
// FILES the app merely reads, but Find & Tag's product is catalog TAG
// mutations — and the catalog is single-writer, owned by the app. So the
// daemon NEVER touches catalog.json. It appends one JSONL line per
// verdict to a per-run journal file; the app ingests the journal and
// applies tags through the exact same applyRecipeVerdict path the
// in-app job uses. One mechanism buys four things:
//   1. app-quit survival (the daemon keeps scanning, journal accretes)
//   2. crash durability (each verdict is fsync'd — the 2026-08-06
//      cascade lost nothing journaled)
//   3. resume (a new run reuses prior verdicts by content fingerprint,
//      so a killed 11-hour scan continues instead of restarting)
//   4. single-writer safety (append-only file, one writer per run,
//      distinct file per run)
//
// Tier policy: the journal records the raw SCORE, not the tier. The app
// re-derives detected/suspected at APPLY time from the recipeID's
// current thresholds (applyRecipeVerdict) — so a threshold retune
// between scan and ingest is honored without rescanning.
//
// Wire format (append-only JSONL, sorted keys, ISO-8601 dates; one
// entry per line, discriminated by "kind"):
//
//   {"kind":"runStart","v":1,"runId":"…","at":"…","person":"Donna",
//    "recipeID":"recipe-v1-native","engine":"arcface",
//    "catalogPath":"…","planned":2979}
//   {"kind":"verdict","seq":1,"at":"…","recordID":"<catalog UUID>",
//    "path":"…","fingerprint":"size|dur|md5","score":0.71,"error":null,
//    "frames":220,"gatedFaces":31,"transport":"avfoundation",
//    "seconds":41.2,"reusedFrom":null}
//   {"kind":"heartbeat","at":"…","index":57,"planned":2979,
//    "currentPath":"…"}
//   {"kind":"runEnd","at":"…","status":"completed","scored":2900,
//    "errors":63,"reused":145,"skippedHuman":12}
//
// Schema evolution rule (codex contract): ADD optional keys freely;
// never rename or repurpose existing keys; bump "v" in runStart only
// for breaking changes, and the reader must skip files whose v it
// doesn't know. A malformed/partial line (crash mid-write) is skipped,
// never fatal — everything before it stands.

import Foundation

// MARK: - Entry payloads

/// First line of every journal file: identifies the run and the
/// scan configuration the verdicts were produced under.
public struct FindTagRunStart: Codable, Equatable, Sendable {
    /// Schema version. Readers must skip whole files with an unknown v.
    public var v: Int
    public var runId: String
    public var at: Date
    public var person: String
    /// Threshold-map key (e.g. "recipe-v1-native") — the app maps
    /// score → tier under THIS id at apply time.
    public var recipeID: String
    /// Embedding backend ("arcface", "adaface") — provenance only.
    public var engine: String
    public var catalogPath: String
    /// Files planned after filtering (video-bearing, not human-settled).
    public var planned: Int
    /// CONTENT digest of the reference gallery the run scored against
    /// (per-file byte hashes, combined). Cross-run verdict REUSE
    /// requires an exact match — a retouched Donna gallery must
    /// invalidate old scores, or stale reuse persists forever (codex
    /// QA #275). nil (pre-digest journals) never qualifies for reuse.
    public var galleryDigest: String?
    /// Digest of the scorer configuration (engine + every
    /// RecipeParameters field). Same exact-match reuse rule: scores
    /// produced under different gates/thresholds/backends are not
    /// comparable (codex QA #277).
    public var paramsDigest: String?

    public init(v: Int = FindTagJournalSchema.version,
                runId: String, at: Date, person: String, recipeID: String,
                engine: String, catalogPath: String, planned: Int,
                galleryDigest: String? = nil,
                paramsDigest: String? = nil) {
        self.v = v
        self.runId = runId
        self.at = at
        self.person = person
        self.recipeID = recipeID
        self.engine = engine
        self.catalogPath = catalogPath
        self.planned = planned
        self.galleryDigest = galleryDigest
        self.paramsDigest = paramsDigest
    }
}

/// One scanned (or reused, or errored) file. `score` and `error` are
/// mutually exclusive-ish: a nil score with nil error never happens for
/// a written verdict; an error verdict carries score nil.
public struct FindTagVerdict: Codable, Equatable, Sendable {
    /// 1-based position in this run's plan (monotonic within a file).
    public var seq: Int
    public var at: Date
    /// The catalog record's stable UUID string — the ingest key. The
    /// app falls back to `fingerprint` matching if the id is gone
    /// (record purged + re-cataloged between scan and ingest).
    public var recordID: String
    public var path: String
    /// Content identity "sizeBytes|durationSeconds|partialMD5" — never
    /// filename (same-name ≠ same-bytes). nil when the record has no
    /// hash (dedup and resume then can't apply to it).
    public var fingerprint: String?
    public var score: Double?
    public var error: String?
    public var frames: Int
    public var gatedFaces: Int
    /// Decode route ("avfoundation", "avfoundation-seek", "ffmpeg") —
    /// provenance; route is part of the measurement (scores differ up
    /// to ~.16 across routes on the same bytes).
    public var transport: String?
    /// Wall-clock seconds this file took (0 for reused verdicts).
    public var seconds: Double
    /// When the verdict was copied from a fingerprint-equivalent file
    /// instead of decoded: the witness file's name. nil = fresh decode.
    public var reusedFrom: String?

    public init(seq: Int, at: Date, recordID: String, path: String,
                fingerprint: String?, score: Double?, error: String?,
                frames: Int, gatedFaces: Int, transport: String?,
                seconds: Double, reusedFrom: String? = nil) {
        self.seq = seq
        self.at = at
        self.recordID = recordID
        self.path = path
        self.fingerprint = fingerprint
        self.score = score
        self.error = error
        self.frames = frames
        self.gatedFaces = gatedFaces
        self.transport = transport
        self.seconds = seconds
        self.reusedFrom = reusedFrom
    }
}

/// Liveness + position for the app's progress row (tail the file, show
/// the last heartbeat). Not fsync'd — losing one is harmless.
public struct FindTagHeartbeat: Codable, Equatable, Sendable {
    public var at: Date
    /// 1-based index of the file currently being scanned.
    public var index: Int
    public var planned: Int
    public var currentPath: String

    public init(at: Date, index: Int, planned: Int, currentPath: String) {
        self.at = at
        self.index = index
        self.planned = planned
        self.currentPath = currentPath
    }
}

/// Terminal line. A journal file WITHOUT one means the run died hard
/// (SIGKILL/crash/power) — every verdict above it still counts.
public struct FindTagRunEnd: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case completed      // scanned the whole plan
        case terminated     // clean SIGTERM/SIGINT stop
        case failed         // setup or unrecoverable error
    }
    public var at: Date
    public var status: Status
    public var scored: Int
    public var errors: Int
    public var reused: Int
    /// Records skipped because a human already settled them (person in
    /// confirmedByUser or rejected) — never machine-tagged over.
    public var skippedHuman: Int

    public init(at: Date, status: Status, scored: Int, errors: Int,
                reused: Int, skippedHuman: Int) {
        self.at = at
        self.status = status
        self.scored = scored
        self.errors = errors
        self.reused = reused
        self.skippedHuman = skippedHuman
    }
}

// MARK: - Entry (kind-discriminated)

public enum FindTagJournalEntry: Equatable, Sendable {
    case runStart(FindTagRunStart)
    case verdict(FindTagVerdict)
    case heartbeat(FindTagHeartbeat)
    case runEnd(FindTagRunEnd)
}

extension FindTagJournalEntry: Codable {
    private enum CodingKeys: String, CodingKey { case kind }
    private enum Kind: String, Codable {
        case runStart, verdict, heartbeat, runEnd
    }

    public init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: CodingKeys.self)
            .decode(Kind.self, forKey: .kind)
        switch kind {
        case .runStart:  self = .runStart(try FindTagRunStart(from: decoder))
        case .verdict:   self = .verdict(try FindTagVerdict(from: decoder))
        case .heartbeat: self = .heartbeat(try FindTagHeartbeat(from: decoder))
        case .runEnd:    self = .runEnd(try FindTagRunEnd(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .runStart(let p):
            try c.encode(Kind.runStart, forKey: .kind)
            try p.encode(to: encoder)
        case .verdict(let p):
            try c.encode(Kind.verdict, forKey: .kind)
            try p.encode(to: encoder)
        case .heartbeat(let p):
            try c.encode(Kind.heartbeat, forKey: .kind)
            try p.encode(to: encoder)
        case .runEnd(let p):
            try c.encode(Kind.runEnd, forKey: .kind)
            try p.encode(to: encoder)
        }
    }
}

public enum FindTagJournalSchema {
    public static let version = 1
}

// MARK: - Writer (append-only, fsync per durable line)

/// One writer per run, one file per run. Verdicts / runStart / runEnd
/// are fsync'd (a SIGKILL loses at most the in-flight clip); heartbeats
/// are not (losing one is harmless, and they're the only high-frequency
/// line). Lock-guarded (`@unchecked Sendable`, tiny-box convention):
/// the daemon's scan loop and its periodic heartbeat task both append,
/// and interleaved partial lines would tear the JSONL framing.
public final class FindTagJournalWriter: @unchecked Sendable {

    private let lock = NSLock()
    private let handle: FileHandle
    private let encoder: JSONEncoder
    public let fileURL: URL

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        self.handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]   // stable diffs, codex-pinnable
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }

    /// Append one entry as a single JSONL line. `sync` forces the line
    /// to disk before returning (default for everything but heartbeats).
    public func append(_ entry: FindTagJournalEntry, sync: Bool = true) throws {
        lock.lock()
        defer { lock.unlock() }
        // Encode UNDER the lock: JSONEncoder is not documented
        // thread-safe, and the scan loop + heartbeat task both append
        // (codex QA #275).
        let data = try encoder.encode(entry)
        try handle.write(contentsOf: data + Data([0x0A]))
        if sync { try handle.synchronize() }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle.synchronize()
        try? handle.close()
    }
}

// MARK: - Reader (tolerant, resume support)

public enum FindTagJournalReader {

    /// Decode every parseable line. A malformed line (typically the
    /// crash-truncated tail) is SKIPPED, never fatal — everything
    /// decoded before it stands. A file whose runStart declares an
    /// unknown schema version yields [] (skip what we can't interpret).
    public static func entries(in data: Data) -> [FindTagJournalEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [FindTagJournalEntry] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let entry = try? decoder.decode(FindTagJournalEntry.self,
                                                  from: Data(line)) else { continue }
            // STRICT version match: a v this reader doesn't know —
            // higher, zero, negative — skips the whole file (codex QA
            // #274: the earlier `>` check accepted v=0/negative, which
            // no writer ever issued).
            if case .runStart(let start) = entry,
               start.v != FindTagJournalSchema.version {
                return []
            }
            out.append(entry)
        }
        return out
    }

    public static func entries(at url: URL) -> [FindTagJournalEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return entries(in: data)
    }

    /// Resume/dedup index across PRIOR runs: fingerprint → verdict, for
    /// journals whose runStart matches this person + recipeID + gallery.
    ///
    /// Policy (deliberate, mirrors + extends the in-run dedup):
    ///   - success verdicts are reusable (skip the decode entirely)
    ///   - ERROR verdicts are NOT — a past failure may have been
    ///     transient (unreachable volume, wedge) and deserves a retry
    ///   - reused verdicts chain fine (their score is the witness's)
    ///   - later entries win on fingerprint collision (newest scan of
    ///     the content is the best-informed one)
    ///   - the run's galleryDigest AND paramsDigest must EXACTLY match
    ///     the caller's current ones — scores are only comparable
    ///     against the same reference gallery and scorer configuration;
    ///     nil on either side disqualifies (codex QA #275/#277:
    ///     stale-reuse-forever after a gallery or params change)
    public static func reusableVerdicts(
        fromJournalFiles files: [URL],
        person: String,
        recipeID: String,
        galleryDigest: String?,
        paramsDigest: String?
    ) -> [String: FindTagVerdict] {
        guard let galleryDigest, let paramsDigest else { return [:] }
        var index: [String: FindTagVerdict] = [:]
        // Filename sort ≈ chronological (files are timestamp-named);
        // later files overwrite earlier entries.
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let all = entries(at: url)
            guard case .runStart(let start)? = all.first,
                  start.person.compare(person, options: .caseInsensitive) == .orderedSame,
                  start.recipeID == recipeID,
                  start.galleryDigest == galleryDigest,
                  start.paramsDigest == paramsDigest else { continue }
            for case .verdict(let v) in all {
                guard let fp = v.fingerprint, v.error == nil, v.score != nil else { continue }
                index[fp] = v
            }
        }
        return index
    }
}

// MARK: - Ingest state (app-side consumption cursor)

/// Tracks how far the APP has applied each journal file, so ingest is
/// idempotent across launches and polls: per filename, the highest
/// verdict `seq` already applied. Verdicts are strictly seq-ordered
/// within a file, so "apply everything with seq > cursor" never
/// double-applies and never skips. Persisted as a sidecar JSON in the
/// journal directory (it is app state ABOUT the journals, not part of
/// any journal — a daemon crash can't tear it, and deleting it merely
/// re-applies verdicts, which applyRecipeVerdict makes idempotent).
public struct FindTagIngestState: Codable, Equatable, Sendable {

    /// journal filename → highest verdict seq already applied.
    public var appliedSeq: [String: Int]

    public init(appliedSeq: [String: Int] = [:]) {
        self.appliedSeq = appliedSeq
    }

    public static let filename = ".ingest-state.json"

    public static func url(inJournalDirectory dir: URL) -> URL {
        dir.appendingPathComponent(filename)
    }

    public static func restored(from url: URL) -> FindTagIngestState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(FindTagIngestState.self, from: data) else {
            return FindTagIngestState()
        }
        return state
    }

    /// - Returns: whether the sidecar durably reached disk. Callers
    ///   advancing in-memory parse offsets must check (codex QA #281:
    ///   a silently-lost sidecar with advanced offsets suppresses
    ///   retry until relaunch).
    @discardableResult
    public func save(to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The verdicts in `entries` not yet applied for `filename`,
    /// in seq order. Pure — the app maps these through its record
    /// lookup + applyRecipeVerdict.
    public func pendingVerdicts(in entries: [FindTagJournalEntry],
                                filename: String) -> [FindTagVerdict] {
        let cursor = appliedSeq[filename] ?? 0
        var out: [FindTagVerdict] = []
        for case .verdict(let v) in entries where v.seq > cursor {
            out.append(v)
        }
        return out.sorted { $0.seq < $1.seq }
    }

    /// Advance the cursor after applying through `seq`.
    public mutating func markApplied(filename: String, through seq: Int) {
        appliedSeq[filename] = max(appliedSeq[filename] ?? 0, seq)
    }
}

// MARK: - Standard paths

/// Canonical on-disk locations for the find-tag daemon. Journals are
/// DATA (Application Support), the daemon's stdout log is a LOG
/// (~/Library/Logs/VideoScan) — same split as the preview helper.
public enum FindTagPaths {

    /// ~/Library/Application Support/VideoScan/findtag-journal/
    public static func journalDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("findtag-journal", isDirectory: true)
    }

    /// ~/Library/Application Support/VideoScan/.findtagd.lock —
    /// same flock + identity-record protocol as the preview helper's
    /// pidfile (SingleInstanceLock writes it; the app's running-probe
    /// reads it), distinct path so the two daemons never collide.
    public static func pidfileURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent(".findtagd.lock")
    }

    /// ~/Library/Logs/VideoScan/findtagd.log — the daemon's stdout/err.
    public static func logURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("findtagd.log")
    }

    /// Journal filename for a new run: sortable timestamp + short run id.
    public static func journalFilename(runId: String, at date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        let shortId = String(runId.prefix(8))
        return "findtag-\(fmt.string(from: date))-\(shortId).jsonl"
    }
}
