// BackupAttestationJournalTests.swift
// The MAIN-ACTOR RULE for `recordAttestation` (codex #1416, 2026-09-12):
//
//   - one journal append (one open, one write, one fsync) per BATCH, and
//     successive batches land in call order;
//   - a journal that cannot be written (00_Index made read-only) still
//     updates and announces every record, and the log names the journal
//     path and the REAL error (errno), never a generic "unreachable";
//   - 5,000 records return within a budget with NO file I/O on the main
//     actor: zero journal calls before return, one after; console lines
//     through ONE `writeBatch`, never one `write` (= one fsync) per record.
//
// Everything runs against a temp sandbox; the journal writer and the log
// sink are injected. Serialized: the tests swap the global `appLog`.

import Foundation
import Testing
@testable import VideoScan

// MARK: - Seams

/// Counts writer calls (and the size of each batch); forwards to the
/// live writer when asked so the file really gets written.
final class CountingAttestationJournalWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [Int] = []
    private let forward: Bool
    init(forward: Bool) { self.forward = forward }

    var batchSizes: [Int] { lock.lock(); defer { lock.unlock() }; return sizes }
    var callCount: Int { batchSizes.count }

    var writer: ArchiveAttestationJournal.Writer {
        { [self] entries, root in
            lock.lock(); sizes.append(entries.count); lock.unlock()
            if forward { try ArchiveAttestationJournal.append(entries, rootPath: root) }
        }
    }
}

/// A log sink that tells `write` from `writeBatch` apart — PersistentLog
/// fsyncs once per call of either, so the per-record beachball is the
/// `write` count.
final class BatchCountingLogSink: LogSink, @unchecked Sendable {
    let name = "batch-counting"
    var fileURL: URL? { nil }
    private let lock = NSLock()
    private var buffer: [String] = []
    private(set) var writeCalls = 0
    private(set) var batchCalls = 0

    var lines: [String] { lock.lock(); defer { lock.unlock() }; return buffer }
    func start(append: Bool) {}
    func flush() {}
    func close() {}
    func write(_ line: String) { lock.lock(); writeCalls += 1; buffer.append(line); lock.unlock() }
    func writeBatch(_ lines: [String]) { lock.lock(); batchCalls += 1; buffer.append(contentsOf: lines); lock.unlock() }
}

final class FsyncCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

// MARK: - Suite

@Suite("Backup attestations — journal batching, failure, main-actor budget", .serialized)
@MainActor
struct BackupAttestationJournalTests {

    private let at = Date(timeIntervalSince1970: 1_757_700_000)

    private func rec(_ name: String) -> VideoRecord {
        let r = VideoRecord(); r.filename = name; r.fullPath = "/Volumes/T/\(name)"; r.directory = "/Volumes/T"
        return r
    }

    private func capturingMutations(_ body: () -> Void) -> [VideoRecord] {
        var seen: [VideoRecord] = []
        let token = NotificationCenter.default.addObserver(forName: .videoScanCatalogMutated, object: nil, queue: nil) { note in
            if let r = note.object as? VideoRecord { seen.append(r) }
        }
        body()
        NotificationCenter.default.removeObserver(token)
        return seen
    }

    @Test("one append and one fsync per batch; batches land in call order; the journal carries millisecond timestamps")
    func journalAppendsOncePerBatch() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("attbatch")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let a = rec("a.mov"), b = rec("b.mov"), c = rec("c.mov")
        model.records = [a, b, c]

        let counter = CountingAttestationJournalWriter(forward: true)
        let fsyncs = FsyncCounter()
        let barriers = ArchivePromoteEngine.Barriers(
            fullFsync: { fd in fsyncs.bump(); return fcntl(fd, F_FULLFSYNC) == 0 ? 0 : Darwin.fsync(fd) },
            fsync: { fd in fsyncs.bump(); return Darwin.fsync(fd) })

        // The task-local barrier seam is inherited by the `Task {}` the
        // model spawns, so the fsync count is THIS batch's.
        let first = await ArchivePromoteEngine.$barriers.withValue(barriers) {
            let w = model.recordAttestation(kind: .cloud, answer: .yes, label: "iCloud",
                                            at: at.addingTimeInterval(0.25), for: [a.id, b.id, c.id],
                                            journalWriter: counter.writer)
            await w.journal?.value
            return w.records.count
        }
        #expect(first == 3)
        #expect(counter.batchSizes == [3], "ONE append for three records")
        #expect(fsyncs.count == 1, "ONE barrier for the batch, not one per line")

        let entries = ArchiveAttestationJournal.entries(rootPath: sb.archiveRoot.path)
        #expect(entries.map(\.filename) == ["a.mov", "b.mov", "c.mov"])
        let raw = try String(contentsOf: ArchiveAttestationJournal.url(rootPath: sb.archiveRoot.path), encoding: .utf8)
        #expect(raw.split(separator: "\n").count == 3, "JSONL: one physical line per entry")
        #expect(raw.contains("\"at\":\"2025-09-12T18:00:00.250Z\""), "the journal carries the fractional representation: \(raw)")
        #expect(entries.first?.at == at.addingTimeInterval(0.25))

        // A second batch is chained after the first — file order = call order.
        let w2 = model.recordAttestation(kind: .offsite, answer: .no, at: at.addingTimeInterval(1), for: [c.id, a.id],
                                         journalWriter: counter.writer)
        let w3 = model.recordAttestation(kind: .drive, answer: .notApplicable, at: at.addingTimeInterval(2), for: [b.id],
                                         journalWriter: counter.writer)
        await w2.journal?.value
        await w3.journal?.value
        #expect(counter.batchSizes == [3, 2, 1])
        #expect(ArchiveAttestationJournal.entries(rootPath: sb.archiveRoot.path).map(\.kind)
                == ["cloud", "cloud", "cloud", "offsite", "offsite", "drive"], "call order preserved across off-main appends")
        // Unknown ids only → nothing to journal, no task.
        let w4 = model.recordAttestation(kind: .cloud, answer: .no, for: [UUID()], journalWriter: counter.writer)
        #expect(w4.records.isEmpty && w4.journal == nil)
        #expect(counter.batchSizes == [3, 2, 1], "an empty batch never touches the writer")
    }

    @Test("a journal that cannot be written: records updated and announced BEFORE the attempt; the log names the path and the real errno")
    func failingJournalStillUpdatesRecordsAndLogsTheRealError() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("attrofail")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let a = rec("a.mov"), b = rec("b.mov")
        model.records = [a, b]

        // 00_Index read-only: openat(O_CREAT) → EACCES (13).
        let indexDir = sb.archiveRoot.appendingPathComponent(MasterArchiveLayout.indexFolder, isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: indexDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: indexDir.path) }

        let sink = InMemoryLogSink()
        let previousLog = appLog
        appLog = sink
        defer { appLog = previousLog }

        var write: BackupAttestationWrite?
        let posted = capturingMutations {
            write = model.recordAttestation(kind: .cloud, answer: .no, at: at, for: [a.id, b.id])
        }
        #expect(posted.map(\.filename) == ["a.mov", "b.mov"], "announced synchronously, before any journal attempt")
        #expect(a.backupAttestations.map(\.token) == ["cloud=no"] && b.backupAttestations.map(\.token) == ["cloud=no"])
        #expect(write?.records.count == 2)
        #expect(write?.journal != nil, "an archive IS designated, so the append was attempted")

        await write?.journal?.value
        #expect(ArchiveAttestationJournal.entries(rootPath: sb.archiveRoot.path).isEmpty, "nothing landed")
        let journalPath = ArchiveAttestationJournal.url(rootPath: sb.archiveRoot.path).path
        let failure = sink.lines.first { $0.contains("journal line(s) not written") }
        #expect(failure != nil, "the failure is logged: \(sink.joined)")
        #expect(failure?.contains("2 journal line(s)") == true)
        #expect(failure?.contains(journalPath) == true, "names the journal path: \(failure ?? "")")
        #expect(failure?.contains("errno 13") == true, "the REAL error (EACCES), not a story: \(failure ?? "")")
        #expect(failure?.contains("archive root unreachable") == false, "the old blanket wording is gone")
        #expect(failure?.contains("catalog records were updated") == true)
        #expect(sink.lines.filter { $0.contains("attestation: a.mov") }.count == 1, "the per-record console line still appears once")
    }

    @Test("SCALE: 5,000 records return within budget with no main-actor file I/O — zero journal calls before return, one after; console lines in ONE writeBatch")
    func fiveThousandRecordsReturnWithinBudgetWithoutPerRecordIO() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("att5k")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        var records: [VideoRecord] = []
        records.reserveCapacity(5_000)
        for i in 0..<5_000 { records.append(rec("clip_\(i).mov")) }
        model.records = records
        let ids = records.map(\.id)

        let counter = CountingAttestationJournalWriter(forward: false)
        let sink = BatchCountingLogSink()
        let previousLog = appLog
        appLog = sink
        defer { appLog = previousLog }

        var write: BackupAttestationWrite?
        var postedCount = 0
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            postedCount = capturingMutations {
                write = model.recordAttestation(kind: .offsite, answer: .yes, label: "Tim's house", at: at, for: ids,
                                                journalWriter: counter.writer)
            }.count
        }
        #expect(write?.records.count == 5_000)
        #expect(postedCount == 5_000, "one record-scoped post per record, all before return")
        #expect(elapsed < .seconds(2), "recordAttestation for 5,000 records took \(elapsed)")
        // Nothing has yielded the main actor yet, so the spawned task cannot
        // have run: the journal writer has NOT been called on this path.
        #expect(counter.callCount == 0, "no journal I/O before return")
        #expect(sink.batchCalls == 1 && sink.writeCalls == 0, "console: ONE writeBatch, zero per-record writes")
        #expect(sink.lines.count == 5_000)
        #expect(records[4_999].backupAttestations.map(\.token) == ["offsite=yes 'Tim's house'"])

        await write?.journal?.value
        #expect(counter.batchSizes == [5_000], "ONE append carrying every line")
    }
}
