// HelperJournalTally.swift — what VideoScan Background wrote today, counted
// from its own journal (Realtime Content Analysis, 2026-11-05).
//
// READ ONLY, and simple on purpose (Codex re-review 2, Rick's KISS): every
// refresh re-folds the NEWEST day file (`background/journal/<day>.jsonl`)
// from byte 0 — no cursor, no offsets, nothing to invalidate when the file is
// truncated, regrown, replaced or rewritten. The helper pane refreshes every
// few seconds, which is far more often than the journal needs.
//
// Bounded: the file is opened with O_NOFOLLOW and must be a regular file
// (fstat), its size must be under `maxBytes`, and the read loop itself stops
// at the cap — a symlink to /dev/zero, a FIFO or a runaway file is refused in
// words, never read. Over the cap → unavailable with the size.
//
// Classification (one rule, pinned by HelperJournalTallyTests):
//   era found       field `era.fused`, state `inferred`, a value that parses
//                   as a year range (MachineEraResolver.range);
//   gave up         field `era.none` with evidence.gaveUp == true;
//   no usable era   any other `era.none` line (DECISIONS 2026-11-01: never an era);
//   other           every other valid line (era.yearRange windows, ocr.date…);
//   unreadable      not a JSON object with the journal's keys, or a line over
//                   ObservationJournal.maxLineBytes — counted, never guessed at.
// Each line is read as JSON (`JSONSerialization`), not through the applier's
// full decode: the applier verifies every line's id before it commits one;
// this counts what the file says. A torn last line (no newline) is reported
// and not counted.
//
// Memory: the file's bytes (≤ maxBytes, 64 MB) for the length of one fold,
// plus the counts and ≤ 8 observations. Time: ~5 µs a line (HelperJournalTally
// scale test: 100k lines measured, budget 10 s).
//
// (For Rick: a pure fold over the file's bytes; the only state is the result.)

import Darwin
import Foundation
import VideoScanCore

struct HelperJournalTally: Equatable, Sendable {

    enum Kind: String, Equatable, Sendable {
        case eraFound, eraNone, gaveUp, other, unreadable
    }

    /// One observation in words (never the model's confidence; never a date).
    struct Observation: Equatable, Sendable, Identifiable {
        var id: String
        var at: Int64
        var kind: Kind
        var words: String
    }

    static let latestCap = 8
    static let notReadYet = "not read yet"

    /// The day file the counts are from; nil = no journal file yet.
    var file: String?
    var eraFound = 0
    var eraNone = 0
    var gaveUp = 0
    var other = 0
    var unreadable = 0
    /// Valid + unreadable lines counted.
    var lines: Int { eraFound + eraNone + gaveUp + other + unreadable }
    /// The file ends in a torn line (a write in flight or a crash); it is not counted.
    var torn = false
    /// Newest first, at most `latestCap`.
    var latest: [Observation] = []
    /// Bytes of the file folded (the whole file).
    var bytes = 0
    /// The counts are unavailable and this is why (not read yet, a failed read, a file over a cap).
    var readProblem: String?

    var available: Bool { readProblem == nil }

    /// The tally with no counts and the reason (never stale or invented numbers).
    static func unavailable(file: String?, _ why: String) -> HelperJournalTally {
        var t = HelperJournalTally()
        t.file = file
        t.readProblem = why
        return t
    }

    // MARK: The rule (on the line's JSON object)

    static func classify(field: String, value: String, state: String, evidence: [String: Any]) -> Kind {
        if field == EraRecordMapper.noneField {
            return (evidence["gaveUp"] as? Bool) == true ? .gaveUp : .eraNone
        }
        if field == MachineEraResolver.fusedField, state == "inferred", MachineEraResolver.range(value) != nil {
            return .eraFound
        }
        return .other
    }

    /// The same rule on a decoded line (tests write lines through ObservationLine).
    static func classify(_ line: ObservationLine) -> Kind {
        let evidence = (try? JSONSerialization.jsonObject(with: Data(line.evidenceJSON.utf8))) as? [String: Any] ?? [:]
        return classify(field: line.field, value: line.value, state: line.state, evidence: evidence)
    }

    static func words(kind: Kind, value: String, field: String, evidence: [String: Any]) -> String {
        switch kind {
        case .eraFound: return "era found — " + AnalysisResultsReport.eraWords(value)
        case .eraNone: return "no usable era"
        case .gaveUp: return "gave up — " + ((evidence["reason"] as? String) ?? "no reason recorded")
        case .other: return "\(field) = \(value)"
        case .unreadable: return "unreadable line"
        }
    }

    /// Fold one line's bytes (without the newline).
    mutating func add(line: Data) {
        guard line.count <= ObservationJournal.maxLineBytes,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              (object["v"] as? Int) == ObservationLine.version,
              let id = object["id"] as? String, let field = object["field"] as? String,
              let value = object["value"] as? String, let state = object["state"] as? String,
              let at = (object["at"] as? NSNumber)?.int64Value else {
            unreadable += 1
            return
        }
        let evidence = object["evidence"] as? [String: Any] ?? [:]
        let kind = Self.classify(field: field, value: value, state: state, evidence: evidence)
        switch kind {
        case .eraFound: eraFound += 1
        case .eraNone: eraNone += 1
        case .gaveUp: gaveUp += 1
        case .other: other += 1
        case .unreadable: unreadable += 1
        }
        guard kind != .other else { return }
        latest.insert(Observation(id: id, at: at, kind: kind, words: Self.words(kind: kind, value: value, field: field, evidence: evidence)), at: 0)
        if latest.count > Self.latestCap { latest.removeLast(latest.count - Self.latestCap) }
    }

    /// Fold a whole file's bytes: lines split on "\n"; a tail with no newline is torn.
    static func fold(_ data: Data, file: String) -> HelperJournalTally {
        var t = HelperJournalTally()
        t.file = file
        t.bytes = data.count
        var start = data.startIndex
        while start < data.endIndex {
            guard let newline = data[start...].firstIndex(of: 0x0A) else {
                t.torn = true
                break
            }
            if newline > start { t.add(line: data[start..<newline]) }
            start = newline + 1
        }
        return t
    }
}

/// Reads the newest day file, bounded, from byte 0.
enum HelperJournalReader {
    /// A day file larger than this is refused (today's biggest real file is 6 MB).
    static let maxBytes = 64 << 20

    /// The newest day file's tally, or why it is unavailable. Runs wherever it
    /// is called (the store calls it in its detached helper refresh).
    static func read(directory: URL) -> HelperJournalTally {
        let journal = ObservationJournal(directory: directory)
        guard let newest = journal.dayFiles().last else {
            return .unavailable(file: nil, "no journal file yet in \(directory.path)")
        }
        switch readBounded(directory.appendingPathComponent(newest)) {
        case .success(let data): return HelperJournalTally.fold(data, file: newest)
        case .failure(let why): return .unavailable(file: newest, "\(newest) \(why.words)")
        }
    }

    /// The file's bytes if it is a regular file under `maxBytes` — opened
    /// without following a symlink, checked with fstat, read at most
    /// `maxBytes + 1` bytes so a file that grows under us is still refused.
    static func readBounded(_ url: URL) -> Result<Data, Refusal> {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            return .failure(Refusal(code == ELOOP ? "is not a regular file (a symbolic link) — not read"
                                    : "could not be opened: \(String(cString: strerror(code))) (errno \(code))"))
        }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .failure(Refusal("could not be stat'ed (errno \(errno))")) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .failure(Refusal("is not a regular file — not read")) }
        guard st.st_size <= off_t(maxBytes) else {
            return .failure(Refusal("is \(Int(st.st_size) >> 20) MB, over the \(maxBytes >> 20) MB cap — not read"))
        }
        var data = Data()
        data.reserveCapacity(Int(st.st_size))
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        while data.count <= maxBytes {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                return .failure(Refusal("could not be read: \(String(cString: strerror(errno))) (errno \(errno))"))
            }
            if n == 0 { return .success(data) }
            data.append(contentsOf: chunk[0..<n])
        }
        return .failure(Refusal("grew past the \(maxBytes >> 20) MB cap while being read — not read"))
    }
}
