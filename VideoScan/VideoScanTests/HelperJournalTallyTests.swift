// HelperJournalTallyTests.swift — the Realtime Content Analysis window's
// VideoScan Background tally (Analyze/Realtime/HelperJournalTally.swift).
//
// Dimensions (CLAUDE.md rule 8):
//   TRUTH      lines written through the REAL ObservationJournal (the shapes
//              EraRecordMapper writes: era.fused, era.none with gaveUp, era.none
//              without, era.yearRange) → the counts and the words; era.none is
//              never shown as an era (DECISIONS 2026-11-01).
//   ISOLATION  a poisoned day file (not JSON, wrong version, a torn tail, a
//              line past the cap) is counted as unreadable / torn, never guessed
//              at, never a crash; the file's bytes are untouched (read-only).
//   LOGIC      incremental: a refresh reads only what was appended; a newer day
//              file replaces the tally; no journal → words.
//   SCALE      100k lines in one day file folded within a budget, holding ≤ 8
//              observations (memory is counts, not lines).
//   MEDIA N/A. Synthetic digests only; temp folders only.

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private let signer = SeatedApproach.eraA2.signer

private func digest(_ i: Int) -> String {
    SHA256.hash(data: Data("subject \(i)".utf8)).map { String(format: "%02x", $0) }.joined()
}

private func found(_ i: Int, at: Int64 = 1_793_925_000) throws -> ObservationLine {
    try ObservationLine(subjectID: digest(i), field: MachineEraResolver.fusedField, value: "1991-1995", by: signer, at: at,
                        confidence: 0.6, evidence: ["validEraWindows": 1], job: "TEST", unit: i)
}

private func gaveUp(_ i: Int, at: Int64 = 1_793_925_001) throws -> ObservationLine {
    try ObservationLine(subjectID: digest(i), field: EraRecordMapper.noneField, value: EraRecordMapper.noneValue, by: signer, at: at,
                        confidence: 0, evidence: ["gaveUp": true, "tries": 3,
                                                  "reason": "gave up after 3 tries: 6 of 6 frames would not decode (ffmpeg: ffmpeg exited 0 and wrote no frame)"],
                        job: "TEST", unit: i)
}

private func none(_ i: Int, at: Int64 = 1_793_925_002) throws -> ObservationLine {
    try ObservationLine(subjectID: digest(i), field: EraRecordMapper.noneField, value: EraRecordMapper.noneValue, by: signer, at: at,
                        confidence: 0, evidence: ["reason": "no usable era"], job: "TEST", unit: i)
}

private func window(_ i: Int, at: Int64 = 1_793_925_003) throws -> ObservationLine {
    try ObservationLine(subjectID: digest(i), field: MachineEraResolver.windowField, value: "1990-1996", by: signer, at: at,
                        confidence: 0.5, evidence: ["window": [0.0, 60.0]], job: "TEST", unit: i)
}

private func scratchDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("realtime-ca-tally-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Realtime Content Analysis — the helper's journal, counted read-only")
struct HelperJournalTallyTests {

    @Test func theCountsAndTheWordsAreTheJournalsOwn() async throws {
        let dir = try scratchDirectory("truth")
        let journal = ObservationJournal(directory: dir)
        try journal.append([try found(1), try gaveUp(2), try none(3), try window(4)])
        let before = try Data(contentsOf: dir.appendingPathComponent(ObservationJournal.fileName(for: Date())))

        let cursor = HelperJournalCursor(directory: dir)
        let t = await cursor.refresh()
        #expect(t.file == ObservationJournal.fileName(for: Date()))
        #expect(t.eraFound == 1 && t.gaveUp == 1 && t.eraNone == 1 && t.other == 1 && t.unreadable == 0)
        #expect(t.lines == 4 && !t.torn && t.readProblem == nil)
        #expect(t.bytesRead == before.count, "the cursor sits at the end of the file")
        #expect(t.latest.map(\.kind) == [.eraNone, .gaveUp, .eraFound], "newest first; windows are not listed")
        #expect(t.latest[2].words == "era found — early 1990s (1991–1995)")
        #expect(t.latest[1].words.hasPrefix("gave up — gave up after 3 tries: 6 of 6 frames would not decode"))
        #expect(t.latest[0].words == "no usable era", "era.none is never an era")
        #expect(!t.latest[0].words.contains("19"), "no year in the words of an era.none line")
        #expect(t.latest[0].at == 1_793_925_002)

        let after = try Data(contentsOf: dir.appendingPathComponent(ObservationJournal.fileName(for: Date())))
        #expect(after == before, "read-only: the bytes are untouched")
    }

    @Test func theRuleOnEachShape() throws {
        #expect(HelperJournalTally.classify(try found(1)) == .eraFound)
        #expect(HelperJournalTally.classify(try gaveUp(2)) == .gaveUp)
        #expect(HelperJournalTally.classify(try none(3)) == .eraNone)
        #expect(HelperJournalTally.classify(try window(4)) == .other)
        // A fused value that is not a range is not "found" (shown as stored by the Results sheet; here: other).
        let odd = try ObservationLine(subjectID: digest(5), field: MachineEraResolver.fusedField, value: "unknown", by: signer,
                                      at: 1, confidence: 0.1, evidence: [:], job: "TEST", unit: 5)
        #expect(HelperJournalTally.classify(odd) == .other)
    }

    @Test("ISOLATION: a poisoned day file is counted, never guessed at, never written")
    func aPoisonedFileIsCountedNotGuessed() async throws {
        let dir = try scratchDirectory("poison")
        let name = ObservationJournal.fileName(for: Date())
        var bytes = Data()
        bytes.append(try found(1).encoded)
        bytes.append(Data("this is not json\n".utf8))
        bytes.append(Data("{\"v\":99,\"table\":\"provenance_assertions\"}\n".utf8))
        bytes.append(Data(repeating: 0x61, count: ObservationJournal.maxLineBytes + 10) + Data([0x0A]))
        bytes.append(try none(2).encoded)
        bytes.append(Data("{\"torn\":".utf8))                     // a write in flight / a crash: no newline
        try bytes.write(to: dir.appendingPathComponent(name))

        let cursor = HelperJournalCursor(directory: dir)
        let t = await cursor.refresh()
        #expect(t.eraFound == 1 && t.eraNone == 1)
        #expect(t.unreadable == 3, "not JSON, wrong version, over the cap: \(t.unreadable)")
        #expect(t.torn, "the torn tail is reported, not counted")
        #expect(t.latest.count == 2)
        #expect(try Data(contentsOf: dir.appendingPathComponent(name)) == bytes, "never sealed, never rewritten")

        // The helper seals the tail and writes on: the fragment becomes one unreadable line, the new line counts.
        var more = Data([0x0A])
        more.append(try gaveUp(3).encoded)
        let handle = try FileHandle(forWritingTo: dir.appendingPathComponent(name))
        try handle.seekToEnd()
        try handle.write(contentsOf: more)
        try handle.close()
        let t2 = await cursor.refresh()
        #expect(t2.unreadable == 4 && t2.gaveUp == 1 && !t2.torn)
        #expect(t2.eraFound == 1 && t2.eraNone == 1, "earlier counts are kept, not re-read")
        #expect(t2.bytesRead == bytes.count + more.count)
    }

    @Test func aRefreshReadsOnlyWhatWasAppended() async throws {
        let dir = try scratchDirectory("incremental")
        let journal = ObservationJournal(directory: dir)
        try journal.append([try found(1)])
        let cursor = HelperJournalCursor(directory: dir)
        let first = await cursor.refresh()
        let appended = try journal.append([try found(2), try none(3)])
        let second = await cursor.refresh()
        #expect(second.bytesRead == first.bytesRead + appended.bytes)
        #expect(second.eraFound == 2 && second.eraNone == 1 && second.lines == 3)
        let third = await cursor.refresh()
        #expect(third == second, "nothing appended: nothing changes")
    }

    @Test func aNewerDayFileReplacesTheTally() async throws {
        let dir = try scratchDirectory("days")
        let yesterday = ObservationJournal(directory: dir, now: { Date(timeIntervalSince1970: 1_793_838_600) })   // 2026-11-05 UTC
        try yesterday.append([try found(1), try found(2)])
        let cursor = HelperJournalCursor(directory: dir)
        let t1 = await cursor.refresh()
        #expect(t1.file == "2026-11-05.jsonl" && t1.eraFound == 2)
        let today = ObservationJournal(directory: dir, now: { Date(timeIntervalSince1970: 1_793_925_000) })       // 2026-11-06 UTC
        try today.append([try none(3)])
        let t2 = await cursor.refresh()
        #expect(t2.file == "2026-11-06.jsonl" && t2.eraFound == 0 && t2.eraNone == 1, "the counts are one day file's")
    }

    @Test func noJournalSaysSo() async throws {
        let dir = try scratchDirectory("empty")
        let t = await HelperJournalCursor(directory: dir).refresh()
        #expect(t.file == nil && t.lines == 0)
        #expect(t.readProblem?.hasPrefix("no journal file yet") == true)
    }

    @Test("SCALE: 100k journal lines fold within a budget and hold ≤ 8 observations")
    func scaleHundredThousandLines() async throws {
        let dir = try scratchDirectory("scale")
        let journal = ObservationJournal(directory: dir)
        var lines: [ObservationLine] = []
        lines.reserveCapacity(100_000)
        for i in 0..<100_000 {
            switch i % 4 {
            case 0: lines.append(try found(i, at: Int64(i)))
            case 1: lines.append(try none(i, at: Int64(i)))
            case 2: lines.append(try gaveUp(i, at: Int64(i)))
            default: lines.append(try window(i, at: Int64(i)))
            }
        }
        try journal.append(lines)
        let cursor = HelperJournalCursor(directory: dir)
        let clock = ContinuousClock()
        let took = await clock.measure { _ = await cursor.refresh() }
        let t = await cursor.refresh()
        #expect(t.lines == 100_000 && t.eraFound == 25_000 && t.eraNone == 25_000 && t.gaveUp == 25_000 && t.other == 25_000)
        #expect(t.latest.count == HelperJournalTally.latestCap)
        #expect(t.latest.first?.at == 99_998, "the newest verdict line (windows are not listed)")
        #expect(took < .seconds(30), "100k lines took \(took)")
    }
}
