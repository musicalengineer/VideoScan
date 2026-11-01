// JournalApplicationTests.swift — the body the app's JournalApplier runs
// inside its one transaction (JournalApplication.swift), on a real
// catalog.sqlite (GRDB, schema 14).
//   LOGIC      — every line lands in exactly one bucket: applied, duplicate,
//                or refused with its rule (invalid, unknownTable,
//                notAnObservation, notADigest, unknownDigest,
//                archivedNameOrDate, vetoed); "sha256:"-prefixed digests are
//                normalised; applying the same file twice = once.
//   SCALE      — 100k journal lines over 10k contents applied in 256-line
//                batches; every batch's blocking commit ≤ 0.1 s (the design's
//                main-actor budget, §6 scale), and the table holds 100k rows.
// Synthetic digests only.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("JournalApplication")
struct JournalApplicationTests {

    static let by = ObservationJournalTests.by
    static func hex(_ n: Int) -> String { String(format: "%064x", n) }

    static func scene(contents: Int) async throws -> (StoreFixture, GRDBCatalogRepository) {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        try EraFixture.seedContents(fixture, count: contents)
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        return (fixture, repository)
    }

    static func readLine(_ line: ObservationLine, offset: Int = 0) -> ObservationJournal.ReadLine {
        let raw = line.encoded.dropLast()
        return ObservationJournal.ReadLine(offset: offset, end: offset + raw.count + 1, raw: Data(raw), result: .success(line))
    }

    static func raw(_ text: String, offset: Int = 0) -> ObservationJournal.ReadLine {
        let data = Data(text.utf8)
        return ObservationJournal.ReadLine(offset: offset, end: offset + data.count + 1, raw: data, result: ObservationLine.decode(data))
    }

    static func apply(_ repository: GRDBCatalogRepository, _ lines: [ObservationJournal.ReadLine]) throws -> JournalBatchOutcome {
        let box = OutcomeBox()
        let written = repository.writeBlocking(as: .ui) { tx in box.value = try JournalApplication.apply(lines, in: tx) }
        guard case .committed = written else { throw Refusal("write: \(written)") }
        return box.value
    }

    @Test func everyLineLandsInExactlyOneBucketWithItsRule() async throws {
        let (fixture, repository) = try await Self.scene(contents: 3)
        defer { fixture.remove() }
        // Rick rejected 1980-1985 on content 3.
        try #require(Self.apply(repository, []).applied == 0)
        _ = repository.writeBlocking(as: .ui) { tx in
            _ = try tx.appendProvenanceAssertion(CatalogRow.ProvenanceAssertionDraft(subjectKind: "content", subjectID: Self.hex(3), field: "era.fused",
                                                                                   value: "1980-1985", state: "rejected", by: "rick", at: 1,
                                                                                   confidence: nil, evidenceJSON: "{}"))
        }
        let good = try ObservationJournalTests.line(1)
        let prefixed = try ObservationLine(subjectID: "sha256:" + Self.hex(2).uppercased(), field: "era.yearRange", value: "1991-1995",
                                           by: Self.by, at: 5, confidence: 0.5, evidence: [:], job: "J", unit: 1)
        let unknown = try ObservationJournalTests.line(99)
        let vetoed = try ObservationJournalTests.line(3, field: "era.fused", value: "1980-1985")
        let notDigest = try ObservationLine(subjectID: "v1:abc", field: "era.yearRange", value: "1991-1995", by: Self.by, at: 5,
                                            confidence: 0.5, evidence: [:], job: "J", unit: 1)
        let notMachine = try ObservationLine(subjectID: Self.hex(1), field: "era.yearRange", value: "1991-1995", by: "rick", at: 5,
                                             confidence: 0.5, evidence: [:], job: "J", unit: 1)
        let lines = [Self.readLine(good, offset: 0), Self.readLine(good, offset: 1), Self.readLine(prefixed, offset: 2),
                     Self.readLine(unknown, offset: 3), Self.readLine(vetoed, offset: 4), Self.readLine(notDigest, offset: 5),
                     Self.readLine(notMachine, offset: 6), Self.raw("{garbage", offset: 7)]
        let outcome = try Self.apply(repository, lines)
        #expect(outcome.applied == 2, "good + the prefixed digest, normalised")
        #expect(outcome.duplicates == 1, "the same line twice in one batch")
        let reasons = Dictionary(grouping: outcome.refused, by: \.reason).mapValues(\.count)
        #expect(reasons == [.unknownDigest: 1, .vetoed: 1, .notADigest: 1, .notAnObservation: 1, .invalid: 1], "\(reasons)")
        #expect(outcome.applied + outcome.duplicates + outcome.refused.count == lines.count, "one bucket per line")
        let stored = try await repository.read { try $0.provenanceAssertions(subjectKind: "content", subjectID: Self.hex(2)) }
        #expect(stored.map(\.subjectID) == [Self.hex(2)], "stored in content.digest's spelling")
        // Apply the same lines again: nothing new.
        let again = try Self.apply(repository, lines)
        #expect(again.applied == 0)
        #expect(again.duplicates == 3)
        #expect(try await repository.read { try $0.provenanceAssertionCount() } == 3, "2 observations + Rick's rejection")
        await repository.close()
    }

    @Test func anUnknownTableIsRefused() throws {
        let line = try ObservationJournalTests.line(1)
        let text = String(decoding: line.encoded.dropLast(), as: UTF8.self)
        // Build a line for another table with a valid id: decode accepts it, admission refuses it.
        let other = text.replacingOccurrences(of: "\"table\":\"provenance_assertions\"", with: "\"table\":\"captions\"")
        if case .failure(let refusal) = JournalApplication.admit(Self.raw(other)) {
            #expect(refusal.reason == .invalid, "an edited table breaks the id: \(refusal.detail)")
        } else {
            Issue.record("an edited line was admitted")
        }
    }

    @Test("F7: an unsupported subject kind is refused at admission; its neighbours land")
    func codex187F7UnsupportedSubjectIsRefused() async throws {
        let (fixture, repository) = try await Self.scene(contents: 1)
        defer { fixture.remove() }
        let odd = try ObservationLine(subjectID: Self.hex(1), field: "era.yearRange", value: "1991-1995", by: Self.by, at: 5,
                                      confidence: 0.5, evidence: [:], job: "J", unit: 1, subjectKind: "file")
        let outcome = try Self.apply(repository, [Self.readLine(odd), Self.readLine(try ObservationJournalTests.line(1), offset: 1)])
        #expect(outcome.applied == 1)
        #expect(outcome.refused.map(\.reason) == [.unsupportedSubject])
        await repository.close()
    }

    @Test(.timeLimit(.minutes(5)))
    func oneHundredThousandLinesInBatchesOf256WithinTheMainActorBudget() async throws {
        let (fixture, repository) = try await Self.scene(contents: 10_000)
        defer { fixture.remove() }
        var lines: [ObservationJournal.ReadLine] = []
        lines.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let line = try ObservationLine(subjectID: Self.hex(i % 10_000 + 1), field: "era.yearRange", value: "19\(50 + i % 50)-1999",
                                           by: Self.by, at: Int64(1_762_000_000 + i), confidence: 0.5,
                                           evidence: ["window": [Double(i % 7), Double(i % 7 + 60)]], job: "J", unit: i / 10)
            lines.append(Self.readLine(line, offset: i))
        }
        let clock = ContinuousClock()
        let loadBefore = TimingBudget.sampleLoad()
        var worst = Duration.zero
        var total = Duration.zero
        var applied = 0
        var start = 0
        while start < lines.count {
            let batch = Array(lines[start..<min(start + 256, lines.count)])
            var outcome = JournalBatchOutcome()
            let took = try clock.measure { outcome = try Self.apply(repository, batch) }
            worst = max(worst, took)
            total += took
            applied += outcome.applied
            start += 256
        }
        #expect(applied == 100_000)
        #expect(try await repository.read { try $0.provenanceAssertionCount() } == 100_000)
        print("JournalApplication scale: 100k lines, \(lines.count / 256 + 1) batches, total \(total), worst batch \(worst)")
        // Design §6: the main-actor commit ≤ 0.1 s per 256-line batch (load-aware; strict where the lane pins it).
        expectWithinTimingBudget("worst 256-line journal batch", measured: worst, budget: .milliseconds(100), loadBefore: loadBefore)
        await repository.close()
    }
}

private final class OutcomeBox: @unchecked Sendable {
    var value = JournalBatchOutcome()
}
