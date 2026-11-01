// ObservationJournalTests.swift — the helper's one road toward the catalog
// (ObservationJournal.swift; design §3.4).
//   LOGIC      — the line is canonical (sorted keys) and round-trips; the id
//                is the SHA-256 of the line without it: the same observation
//                → the same id, a different `at` / value → another id;
//                confidence is clamped; a non-finite evidence is refused.
//   ISOLATION  — an edited line (value changed, id kept) is caught by its id;
//                a torn last line (no newline) is ignored and reported, and
//                the next append seals it so it reads as ONE invalid line,
//                never glued to the next good one; a garbage line and a line
//                over the cap are invalid, the reader moves past them; an
//                unreadable `.applied` reads as 0 (re-reading is safe).
//   LOGIC      — paging by maxLines resumes exactly at nextOffset; dayFiles
//                skips refused.jsonl and sidecars; subjects(by:) finds the
//                digests one signer observed; refused lines land with reason.
//   SCALE      — 100k lines written in 1,000-line units and read back in
//                256-line pages inside a budget.
// Synthetic digests only.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("ObservationJournal")
struct ObservationJournalTests {

    static let by = "machine:qwen3-vl-8b-4bit/era-v1/window-60s@r3"
    static func hex(_ n: Int) -> String { String(format: "%064x", n) }

    static func line(_ n: Int, field: String = "era.yearRange", value: String = "1991-1995", at: Int64 = 1_762_000_000,
                     by: String = by, unit: Int = 0, confidence: Double = 0.6) throws -> ObservationLine {
        try ObservationLine(subjectID: hex(n), field: field, value: value, by: by, at: at, confidence: confidence,
                            evidence: ["window": [120.0, 180.0], "rationale": "4:3, OSD", "selfConfidence": confidence],
                            job: "JOB-1", unit: unit)
    }

    static func journal() throws -> (ObservationJournal, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
        let fixed = Date(timeIntervalSince1970: 1_762_000_000)   // 2025-11-01 UTC
        return (ObservationJournal(directory: dir, now: { fixed }), dir)
    }

    static func readAll(_ journal: ObservationJournal, _ file: String) throws -> [ObservationJournal.ReadLine] {
        var out: [ObservationJournal.ReadLine] = []
        var offset = 0
        while true {
            let r = try journal.read(file: file, from: offset, maxLines: 256)
            out += r.lines
            if r.lines.isEmpty { break }
            offset = r.nextOffset
        }
        return out
    }

    // MARK: - The line

    @Test func theLineIsCanonicalAndRoundTrips() throws {
        let line = try Self.line(1)
        let text = String(decoding: line.encoded, as: UTF8.self)
        #expect(text.hasSuffix("}\n"))
        #expect(text.hasPrefix(#"{"at":1762000000,"by":"machine:qwen3-vl-8b-4bit/era-v1/window-60s@r3","confidence":0.6,"evidence":{"#))
        #expect(text.contains(#""subject_id":"\#(Self.hex(1))","subject_kind":"content","table":"provenance_assertions","unit":0,"v":1,"value":"1991-1995"}"#))
        let decoded = try ObservationLine.decode(line.encoded.dropLast()).get()
        #expect(decoded.id == line.id)
        #expect(decoded.evidenceJSON == line.evidenceJSON)
        #expect(decoded.encoded == line.encoded, "decode → encode is byte-identical")
    }

    @Test func theIdIsTheIdempotenceKey() throws {
        #expect(try Self.line(1).id == Self.line(1).id)
        #expect(try Self.line(1).id != Self.line(1, at: 1_762_000_001).id)
        #expect(try Self.line(1).id != Self.line(1, value: "1990-1995").id)
        #expect(try Self.line(1).id != Self.line(2).id)
        #expect(try Self.line(1).id.count == 64)
    }

    @Test func confidenceIsClampedAndBadEvidenceIsRefused() throws {
        #expect(try Self.line(1, confidence: 1.7).confidence == 1)
        #expect(try Self.line(1, confidence: -0.2).confidence == 0)
        #expect(throws: JournalLineProblem.self) {
            _ = try ObservationLine(subjectID: Self.hex(1), field: "era.yearRange", value: "x", by: Self.by, at: 1, confidence: 0.5,
                                    evidence: ["bad": Double.nan], job: "J", unit: 0)
        }
    }

    @Test func anEditedLineIsCaughtByItsId() throws {
        let text = String(decoding: try Self.line(1).encoded.dropLast(), as: UTF8.self).replacingOccurrences(of: "1991-1995", with: "1971-1975")
        guard case .failure(let problem) = ObservationLine.decode(Data(text.utf8)) else {
            Issue.record("an edited line decoded")
            return
        }
        #expect(problem.words.contains("id does not match"))
    }

    // MARK: - Torn tails

    @Test func aTornLastLineIsIgnoredReportedAndSealedByTheNextAppend() throws {
        let (journal, dir) = try Self.journal()
        defer { try? FileManager.default.removeItem(at: dir) }
        try journal.append([Self.line(1), Self.line(2)])
        let file = ObservationJournal.fileName(for: Date(timeIntervalSince1970: 1_762_000_000))
        // The crash: half of a third line, no newline.
        let url = dir.appendingPathComponent(file)
        let half = try Self.line(3).encoded.prefix(40)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: half)
        try handle.close()

        let torn = try journal.read(file: file, from: 0)
        #expect(torn.lines.count == 2)
        #expect(torn.tornAt == torn.nextOffset, "the torn line starts where the good ones end")
        #expect(torn.atEnd)

        let report = try journal.append([Self.line(3)])
        #expect(report.sealedTornTail)
        let all = try Self.readAll(journal, file)
        #expect(all.count == 4)
        let valid = all.compactMap { try? $0.result.get() }
        #expect(valid.map(\.subjectID) == [Self.hex(1), Self.hex(2), Self.hex(3)], "the re-appended line is whole")
        guard case .failure = all[2].result else {
            Issue.record("the sealed torn tail must read as invalid")
            return
        }
        #expect(try journal.read(file: file, from: all[3].end).tornAt == nil)
    }

    @Test func garbageAndOversizedLinesAreInvalidAndTheReaderMovesPast() throws {
        let (journal, dir) = try Self.journal()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var data = Data("not json\n".utf8)
        data.append(Data(repeating: 0x41, count: ObservationJournal.maxLineBytes + 1)); data.append(0x0A)
        data.append(try Self.line(1).encoded)
        try data.write(to: dir.appendingPathComponent("2025-11-01.jsonl"))
        let all = try Self.readAll(journal, "2025-11-01.jsonl")
        #expect(all.count == 3)
        #expect(all.prefix(2).allSatisfy { if case .failure = $0.result { return true } else { return false } })
        #expect((try? all[2].result.get())?.subjectID == Self.hex(1))
    }

    // MARK: - Paging, cursor, files

    @Test func pagingResumesExactlyAtNextOffset() throws {
        let (journal, dir) = try Self.journal()
        defer { try? FileManager.default.removeItem(at: dir) }
        try journal.append((1...10).map { try Self.line($0) })
        let file = journal.dayFiles()[0]
        let first = try journal.read(file: file, from: 0, maxLines: 4)
        #expect(first.lines.count == 4)
        let rest = try journal.read(file: file, from: first.nextOffset, maxLines: 100)
        #expect(rest.lines.count == 6)
        #expect(rest.atEnd)
        #expect(rest.nextOffset == journal.size(of: file))
        let ids = (first.lines + rest.lines).compactMap { try? $0.result.get().subjectID }
        #expect(ids == (1...10).map(Self.hex))
    }

    @Test func theAppliedCursorRoundTripsAndAnUnreadableOneIsZero() throws {
        let (journal, dir) = try Self.journal()
        defer { try? FileManager.default.removeItem(at: dir) }
        try journal.append([Self.line(1)])
        let file = journal.dayFiles()[0]
        #expect(journal.appliedOffset(file) == 0)
        #expect(journal.unappliedBytes() == journal.size(of: file))
        try journal.markApplied(file, offset: journal.size(of: file))
        #expect(journal.appliedOffset(file) == journal.size(of: file))
        #expect(journal.unappliedBytes() == 0)
        try Data("garbage".utf8).write(to: dir.appendingPathComponent(file + ObservationJournal.appliedSuffix))
        #expect(journal.appliedOffset(file) == 0)
        #expect(journal.dayFiles() == [file], "sidecars are not day files")
    }

    @Test func refusedLinesLandWithTheirReasonAndAreNotADayFile() throws {
        let (journal, dir) = try Self.journal()
        defer { try? FileManager.default.removeItem(at: dir) }
        try journal.appendRefused(raw: Data("x".utf8), file: "2025-11-01.jsonl", offset: 7, reason: "vetoed", detail: "Rick rejected 1991-1995")
        #expect(journal.refusedCount() == 1)
        #expect(journal.refusedRecords().first?["reason"] as? String == "vetoed")
        #expect(journal.refusedRecords().first?["offset"] as? Int == 7)
        #expect(journal.dayFiles().isEmpty)
    }

    @Test func subjectsByOneSignerAreFoundAndOthersAreNot() throws {
        let (journal, dir) = try Self.journal()
        defer { try? FileManager.default.removeItem(at: dir) }
        try journal.append([Self.line(1), Self.line(2), Self.line(3, by: "machine:other/era-v1/window-60s@r1")])
        #expect(journal.subjects(by: Self.by) == [Self.hex(1), Self.hex(2)])
        #expect(journal.subjects(by: "machine:none@r1").isEmpty)
    }

    // MARK: - Codex #187 (red first)

    @Test("F2: a refusal torn by a crash is sealed before the next refusal is appended — both readable")
    func codex187F2TornRefusalTailIsSealed() throws {
        let (journal, dir) = try Self.journal()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"reason":"vetoed","li"#.utf8).write(to: dir.appendingPathComponent(ObservationJournal.refusedFileName))
        try journal.appendRefused([ObservationJournal.RefusedRecord(raw: Data("x".utf8), file: "f", offset: 0, reason: "unknownDigest", detail: "d")])
        #expect(journal.refusedRecords().map { $0["reason"] as? String } == ["unknownDigest"])
        #expect(journal.refusedCount() == 1, "the sealed fragment is not a refusal")
    }

    @Test("F1: a refusal that cannot be written throws (the caller must not move its cursor)")
    func codex187F1UnwritableRefusalThrows() throws {
        let (journal, dir) = try Self.journal()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent(ObservationJournal.refusedFileName).path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let refused = dir.appendingPathComponent(ObservationJournal.refusedFileName)
        try Data().write(to: refused)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: refused.path)
        #expect(throws: JournalIOError.self) {
            try journal.appendRefused([ObservationJournal.RefusedRecord(raw: Data("x".utf8), file: "f", offset: 0, reason: "vetoed", detail: "d")])
        }
    }

    @Test("F3: a cursor is bound to its file — a replaced, truncated or same-size-replaced file restarts at 0")
    func codex187F3CursorBoundToTheFile() throws {
        let (journal, dir) = try Self.journal()
        defer { try? FileManager.default.removeItem(at: dir) }
        try journal.append([Self.line(1), Self.line(2), Self.line(3)])
        let file = journal.dayFiles()[0]
        let url = dir.appendingPathComponent(file)
        try journal.markApplied(file, offset: journal.size(of: file))
        #expect(journal.appliedOffset(file) == journal.size(of: file))
        // Same size, different bytes, new file (inode): replaced.
        let original = try Data(contentsOf: url)
        var other = original
        other.replaceSubrange(0..<1, with: Data(" ".utf8))
        try FileManager.default.removeItem(at: url)
        try other.write(to: url)
        #expect(journal.appliedOffset(file) == 0, "a replaced file restarts at 0")
        // Truncated in place.
        try FileManager.default.removeItem(at: url)
        try original.write(to: url)
        try journal.markApplied(file, offset: original.count)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 10)
        try handle.close()
        #expect(journal.appliedOffset(file) == 0, "a shrunk file restarts at 0")
    }

    @Test("F5: a number outside Int64 / Double exactness is refused, never aliased")
    func codex187F5UnsignedMaxIsRefused() {
        #expect(throws: JournalLineProblem.self) {
            _ = try ObservationLine(subjectID: Self.hex(1), field: "era.yearRange", value: "x", by: Self.by, at: 1, confidence: 0.5,
                                    evidence: ["n": NSNumber(value: UInt64.max)], job: "J", unit: 0)
        }
    }

    @Test("F8: a line far over the cap is streamed past as ONE invalid line; the next line is read")
    func codex187F8HugeLineIsPassed() throws {
        let (journal, dir) = try Self.journal()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var data = Data(repeating: 0x41, count: 2 * 1024 * 1024 + 1); data.append(0x0A)
        data.append(try Self.line(1).encoded)
        try data.write(to: dir.appendingPathComponent("2025-11-01.jsonl"))
        let all = try Self.readAll(journal, "2025-11-01.jsonl")
        #expect(all.count == 2)
        if all.count == 2 {
            #expect(all[0].end == 2 * 1024 * 1024 + 2)
            #expect(all[0].raw.count <= 1024, "a bounded prefix is kept, not the line")
            #expect((try? all[1].result.get())?.subjectID == Self.hex(1))
        }
    }

    @Test("F9: an earlier day's torn tail (a crash before UTC midnight) is sealed by the next process's first append")
    func codex187F9EarlierDayTornTailIsSealed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let day1 = ObservationJournal(directory: dir, now: { Date(timeIntervalSince1970: 1_762_000_000) })
        try day1.append([Self.line(1)])
        let file1 = day1.dayFiles()[0]
        let handle = try FileHandle(forWritingTo: dir.appendingPathComponent(file1))
        try handle.seekToEnd(); try handle.write(contentsOf: try Self.line(2).encoded.prefix(30)); try handle.close()
        let day2 = ObservationJournal(directory: dir, now: { Date(timeIntervalSince1970: 1_762_000_000 + 86_400) })
        try day2.append([Self.line(3)])
        #expect(try day2.read(file: file1, from: 0).tornAt == nil, "yesterday's torn tail is sealed")
        #expect(try Self.readAll(day2, file1).count == 2)
    }

    // MARK: - Scale

    @Test(.timeLimit(.minutes(3)))
    func oneHundredThousandLinesWriteAndPageInsideABudget() throws {
        let (journal, dir) = try Self.journal()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ContinuousClock()
        let write = try clock.measure {
            for u in 0..<100 { try journal.append((0..<1000).map { try Self.line(u * 1000 + $0 + 1, unit: u) }) }
        }
        let file = journal.dayFiles()[0]
        var count = 0
        let read = try clock.measure { count = try Self.readAll(journal, file).count }
        #expect(count == 100_000)
        // Budgets (Debug, load-aware): write 30 s, read 30 s. Measured on the Ultra: see the commit.
        #expect(write < .seconds(30), "write \(write)")
        #expect(read < .seconds(30), "read \(read)")
        print("ObservationJournal scale: write \(write), read \(read)")
    }
}
