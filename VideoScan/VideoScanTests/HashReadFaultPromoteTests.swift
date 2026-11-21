// HashReadFaultPromoteTests.swift
// NEGATIVE MATRIX — Promote to Archive under a faulted full-file read
// (hash read seam, 2026-11-20). Promote reads the source twice (the proving
// read, then the copy pass) and the copy once (the read-back). Each of
// {EIO mid-file, a read that ends early, one flipped bit} is injected into
// each of those three reads; for every cell:
//
//   * nothing is promoted: no file under the archive root, no `.partial`,
//     no manifest row, no archive-copy record, the source record untouched;
//   * the outcome is a FAILED row for that file and the job does not finish
//     as a success;
//   * no digest is recorded from the faulted read (no fixity on the source,
//     no journal entry that reached `done`);
//   * the source file's bytes are what they were;
//   * the console line names the file's failure.
//
// A retry with no fault promotes the same file — the refusal leaves nothing
// behind that blocks it.
//
// Wording that names the failure wrongly is PARKED (withKnownIssue), not
// fixed here: Promote is a data-risk path (rule 10).
//
// Parallel-safe: one sandbox, model, ledger and task-local hook per test.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// Which of Promote's three full reads carries the fault.
enum PromoteRead: String, Sendable, CaseIterable, CustomStringConvertible {
    /// The source, read in full before anything is written (duplicate check + proof).
    case sourceProof
    /// The source again, as the copy pass streams it into the `.partial`.
    case sourceCopy
    /// The `.partial`, read back to verify the copy.
    case copyReadBack
    var description: String { rawValue }
}

struct PromoteFaultCase: Sendable, CustomStringConvertible {
    let read: PromoteRead
    let kind: HashReadFault.Kind
    var description: String { "\(kind) in \(read)" }
    static let all: [PromoteFaultCase] = PromoteRead.allCases.flatMap { read in
        HashReadFault.Kind.allCases.map { PromoteFaultCase(read: read, kind: $0) }
    }
}

@Suite("Hash read fault × Promote — nothing is promoted on an unproven read")
@MainActor
struct HashReadFaultPromoteTests {

    static let fileName = "test_hrf_promote.mov"
    static let bytes = 60_000
    static let faultAt: Int64 = 20_000

    private func fault(_ c: PromoteFaultCase) -> HashReadFault {
        switch c.read {
        case .sourceProof:
            return HashReadFault(c.kind, pathSuffix: "Sources/" + Self.fileName, atByte: Self.faultAt, onPass: 1)
        case .sourceCopy:
            return HashReadFault(c.kind, pathSuffix: "Sources/" + Self.fileName, atByte: Self.faultAt, onPass: 2)
        case .copyReadBack:
            return HashReadFault(c.kind, where: { $0.hasSuffix(".partial") }, atByte: Self.faultAt, onPass: 1)
        }
    }

    @Test("FIXTURE: a clean promote reads the source in full exactly twice and the copy once — the three reads the matrix aims at")
    func theThreeReads() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("hrf_reads"); defer { sb.cleanup() }
        let src = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent(Self.fileName),
                                                         bytes: Self.bytes, seed: 21)
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path, userDate: "1994-05-01")
        model.records = [rec]
        // Never fires (byte beyond the file): it only counts the reads.
        let source = HashReadFault(.eio, pathSuffix: "Sources/" + Self.fileName, atByte: 1 << 40, onPass: 0)
        let partial = HashReadFault(.eio, where: { $0.hasSuffix(".partial") }, atByte: 1 << 40, onPass: 0)
        let hook: ArchivePromoteEngine.ReadHook = { fd, off, n in source.hook(fd, off, n) ?? partial.hook(fd, off, n) }
        let job = try #require(await ArchivePromoteEngine.$readHook.withValue(hook) {
            await MasterArchiveTestSupport.promote(model, ids: [rec.id])
        })
        guard case .finished = job.state else { Issue.record("\(job.state)"); return }
        #expect(source.passCount == 2 && partial.passCount == 1, "source \(source.passCount), partial \(partial.passCount)")
        #expect(source.firedCount == 0 && partial.firedCount == 0)
    }

    @Test("MATRIX: each fault in each of Promote's reads → the file is refused, nothing lands, nothing is recorded, a clean retry promotes it",
          .timeLimit(.minutes(2)), arguments: PromoteFaultCase.all)
    func nothingIsPromoted(_ c: PromoteFaultCase) async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("hrf_promote"); defer { sb.cleanup() }
        let src = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent(Self.fileName),
                                                         bytes: Self.bytes, seed: 21)
        let before = try Data(contentsOf: src)
        let trueDigest = try #require(MasterArchiveTestSupport.sha256(ofFile: src.path))
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path, userDate: "1994-05-01")
        model.records = [rec]

        let fault = fault(c)
        let job = try #require(await fault.run { await MasterArchiveTestSupport.promote(model, ids: [rec.id]) })
        await job.completionTask?.value
        #expect(fault.firedCount == 1, "\(c): the fault never reached its read (passes \(fault.passCount))")

        // --- Nothing landed.
        #expect(MasterArchiveTestSupport.archivedFiles(sb).isEmpty, "\(c): \(MasterArchiveTestSupport.archivedFiles(sb))")
        #expect(MasterArchiveTestSupport.manifestRows(sb).isEmpty, "\(c): a manifest row was written")
        #expect(model.records.count == 1 && model.masterArchiveCopy(of: rec) == nil, "\(c): an archive record exists")
        #expect(rec.archiveStage != .masterAssigned && rec.lifecycleStage != .archived)
        #expect(!rec.notes.contains("promoted to Master Archive"))

        // --- Named, and never a success.
        #expect(job.outcomes.count == 1, "\(c): \(job.outcomes)")
        let row = try #require(job.outcomes.first)
        #expect(row.kind == .failed && row.recordID == rec.id, "\(c): \(row)")
        guard case .failed(let summary) = job.state else {
            Issue.record("\(c): the job did not end failed — \(job.state)"); return
        }
        #expect(summary.contains("Promoted 0") && summary.contains("failed 1"), "\(c): \(summary)")
        print("[hash-matrix] promote | \(c) | \(row.kind) | \(row.detail)")

        // --- No digest recorded from the faulted read.
        #expect(rec.contentFixity == nil, "\(c): a fixity was stored on the source from this run")
        let journal = (try? String(contentsOf: sb.journalURL, encoding: .utf8)) ?? ""
        for state in ["renamed", "published", "done"] {
            #expect(!journal.contains("\"\(state)\""), "\(c): a journal entry reached \(state):\n\(journal)")
        }
        await model.mediaLedger.waitForPendingWrites()
        let landed = model.mediaLedger.allEvents().filter { $0.event == .archived }
        #expect(landed.isEmpty, "\(c): the ledger says promoted")

        // --- The source is untouched; the console names the failure.
        #expect(try Data(contentsOf: src) == before)
        let console = await hashFaultConsole(model, containing: "failed 1")
        #expect(console.contains("Promote: Promoted 0 · skipped 0 · failed 1."), "\(c): console:\n\(console)")
        // The per-file line: a refusal carries the op id and the facts (names
        // stay out of the persistent lines); a thrown failure names the file.
        #expect(console.split(separator: "\n").contains { $0.hasPrefix("Promote:") && ($0.contains("FAILED") || $0.contains("refused")) },
                "\(c): no per-file failure line:\n\(console)")

        // --- Truthful words (parked where they are not).
        expectTruthfulWords(c, row.detail)

        // --- A clean retry promotes it: the refusal blocked nothing.
        let retry = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .finished = retry.state else {
            Issue.record("\(c): the clean retry did not promote — \(retry.state) \(retry.outcomes)"); return
        }
        let files = MasterArchiveTestSupport.archivedFiles(sb)
        #expect(files.count == 1)
        if let rel = files.first {
            #expect(MasterArchiveTestSupport.sha256(ofFile: sb.archiveRoot.appendingPathComponent(rel).path) == trueDigest)
        }
        #expect(model.masterArchiveCopy(of: rec)?.archiveFixity?.digest == trueDigest)
    }

    /// EIO must be named as a READ failure. A flip or an early end shows up
    /// as two reads that disagree; "changed"/"verification failed" is the
    /// most the app can know, and is accepted.
    private func expectTruthfulWords(_ c: PromoteFaultCase, _ detail: String) {
        let d = detail.lowercased()
        switch (c.kind, c.read) {
        case (.eio, .sourceProof), (.eio, .copyReadBack):
            withKnownIssue("PARKED 2026-11-20 (P3, wording): a READ error during a hash is reported as \"write failed: read errno 5\" (ArchivePromoteEngine.sha256(fd:) maps it to Failure.writeFailed). Proposed: a Failure.readFailed case — \"could not be read in full (errno N)\".") {
                #expect(!d.contains("write failed"), "\(c): \(detail)")
            }
            #expect(d.contains("read errno \(EIO)"), "\(c): the errno is in the words: \(detail)")
        case (.eio, .sourceCopy):
            withKnownIssue("PARKED 2026-11-20 (P3, wording): a READ error in the copy pass is reported as \"could not open source …\" (Failure.sourceUnreadable); the file opened, a read failed. Proposed: the same Failure.readFailed case.") {
                #expect(!d.contains("could not open"), "\(c): \(detail)")
            }
        case (_, .sourceProof), (_, .sourceCopy):
            #expect(d.contains("changed") || d.contains("does not match"), "\(c): \(detail)")
        case (_, .copyReadBack):
            #expect(d.contains("verification failed"), "\(c): \(detail)")
        }
    }
}
