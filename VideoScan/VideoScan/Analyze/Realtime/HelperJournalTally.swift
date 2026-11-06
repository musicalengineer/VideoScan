// HelperJournalTally.swift — what VideoScan Background wrote today, counted
// from its own journal (Realtime Content Analysis, 2026-11-05).
//
// READ ONLY. The helper's journal (`background/journal/<day>.jsonl`) is the
// typed record of every observation it made; this reads the NEWEST day file
// through `ObservationJournal.read` — the same reader the app's applier uses
// — and never writes, seals, compacts or marks anything. The cursor keeps a
// byte offset, so each refresh reads only what was appended since.
//
// Classification (one rule, pinned by HelperJournalTallyTests):
//   era found       field `era.fused`, state `inferred`, a value that parses
//                   as a year range (MachineEraResolver.range) — the line the
//                   inspector would show as the era;
//   gave up         field `era.none` with evidence.gaveUp == true (the
//                   give-up line EraRecordMapper writes after 3 tries);
//   no usable era   any other `era.none` line (DECISIONS 2026-11-01: never an era);
//   other           every other valid line (era.yearRange windows, ocr.date…);
//   unreadable      a line the reader refused (not JSON, wrong version, an
//                   id that does not match) — counted, never guessed at.
//
// Memory: counts, the newest `latestCap` observations (≈ 200 B each), and one
// read buffer inside `ObservationJournal.read` (≤ 1 MB + maxLines decoded
// lines ≈ 4 KB each). A 6 MB day file is streamed, never held.
//
// (For Rick: a fold over an append-only log with a persisted cursor; the
// actor is the one place the cursor mutates.)

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

    /// The day file the counts are from; nil = no journal file yet.
    var file: String?
    var eraFound = 0
    var eraNone = 0
    var gaveUp = 0
    var other = 0
    var unreadable = 0
    /// Valid + unreadable lines counted so far.
    var lines: Int { eraFound + eraNone + gaveUp + other + unreadable }
    /// The file ends in a torn line (a write in flight or a crash); it is not counted.
    var torn = false
    /// Newest first, at most `latestCap`.
    var latest: [Observation] = []
    /// Bytes of the file folded in so far (the cursor; tests pin incremental reads).
    var bytesRead = 0
    /// The directory or file could not be read (the words say why).
    var readProblem: String?

    // MARK: The rule

    static func classify(_ line: ObservationLine) -> Kind {
        if line.field == EraRecordMapper.noneField {
            return gaveUp(line) ? .gaveUp : .eraNone
        }
        if line.field == MachineEraResolver.fusedField, line.state == "inferred", MachineEraResolver.range(line.value) != nil {
            return .eraFound
        }
        return .other
    }

    /// evidence.gaveUp == true (EraRecordMapper's give-up line).
    static func gaveUp(_ line: ObservationLine) -> Bool {
        guard let evidence = (try? JSONSerialization.jsonObject(with: Data(line.evidenceJSON.utf8))) as? [String: Any] else { return false }
        return (evidence["gaveUp"] as? Bool) == true
    }

    /// The give-up reason, verbatim, when the evidence carries one.
    static func reason(_ line: ObservationLine) -> String? {
        guard let evidence = (try? JSONSerialization.jsonObject(with: Data(line.evidenceJSON.utf8))) as? [String: Any] else { return nil }
        return evidence["reason"] as? String
    }

    static func words(_ line: ObservationLine, kind: Kind) -> String {
        switch kind {
        case .eraFound: return "era found — " + AnalysisResultsReport.eraWords(line.value)
        case .eraNone: return "no usable era"
        case .gaveUp: return "gave up — " + (reason(line) ?? "no reason recorded")
        case .other: return "\(line.field) = \(line.value)"
        case .unreadable: return "unreadable line"
        }
    }

    mutating func add(_ read: ObservationJournal.ReadLine) {
        switch read.result {
        case .failure:
            unreadable += 1
        case .success(let line):
            let kind = Self.classify(line)
            switch kind {
            case .eraFound: eraFound += 1
            case .eraNone: eraNone += 1
            case .gaveUp: gaveUp += 1
            case .other: other += 1
            case .unreadable: unreadable += 1
            }
            guard kind != .other else { return }
            latest.insert(Observation(id: line.id, at: line.at, kind: kind, words: Self.words(line, kind: kind)), at: 0)
            if latest.count > Self.latestCap { latest.removeLast(latest.count - Self.latestCap) }
        }
    }
}

/// Reads the newest day file incrementally; the one place the cursor moves.
actor HelperJournalCursor {
    private let journal: ObservationJournal
    private var tally = HelperJournalTally()
    /// Lines per `ObservationJournal.read` call (its own cap is the memory bound).
    static let chunkLines = 4096

    init(directory: URL) {
        journal = ObservationJournal(directory: directory)
    }

    /// Fold in everything appended since the last call, up to `maxLines`
    /// (a refresh never reads forever; the next one continues). A newer day
    /// file replaces the tally — the counts are for one day file.
    func refresh(maxLines: Int = 200_000) -> HelperJournalTally {
        guard let newest = journal.dayFiles().last else {
            tally = HelperJournalTally()
            tally.readProblem = "no journal file yet in \(journal.directory.path)"
            return tally
        }
        if tally.file != newest {
            tally = HelperJournalTally()
            tally.file = newest
        }
        tally.readProblem = nil
        var budget = maxLines
        while budget > 0 {
            let chunk: ObservationJournal.ReadResult
            do {
                chunk = try journal.read(file: newest, from: tally.bytesRead, maxLines: min(Self.chunkLines, budget))
            } catch {
                tally.readProblem = "\(newest) could not be read: \(error)"
                return tally
            }
            for line in chunk.lines { tally.add(line) }
            budget -= chunk.lines.count
            tally.bytesRead = chunk.nextOffset
            tally.torn = chunk.tornAt != nil
            if chunk.atEnd || chunk.lines.isEmpty { break }
        }
        return tally
    }
}
