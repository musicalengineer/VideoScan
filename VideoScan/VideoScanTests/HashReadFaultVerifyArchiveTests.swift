// HashReadFaultVerifyArchiveTests.swift
// NEGATIVE MATRIX — Verify Archive Copies under a faulted read of an archive
// file (hash read seam, 2026-11-20). Two promoted files; the fault is aimed
// at the first one's archive copy, the second is the control. Each of
// {EIO mid-file, a read that ends early, one flipped bit} × {the record
// carries a fixity, the record's fixity was stripped}:
//
//   * the faulted file is never reported verified or restored;
//   * no fixity is WRITTEN from the faulted read (rule 1) — a stripped record
//     stays without one;
//   * the row for that file names what happened, the run ends red, the
//     summary counts it;
//   * the archive file, the manifest and the control file's verdict are
//     untouched; a clean second run verifies / restores the file.
//
// What happens to a fixity the record ALREADY carried is pinned per fault
// (EIO keeps it — "the check errored"; a digest that disagrees clears it —
// codex #975). Misnamed outcomes are PARKED, not fixed (rule 10).
//
// Parallel-safe: sandbox per test, task-local hook, no global log swap.

import Foundation
import Testing
@testable import VideoScan

struct VerifyFaultCase: Sendable, CustomStringConvertible {
    let kind: HashReadFault.Kind
    /// false = the record's archiveFixity was stripped first (the GH #167
    /// recovery shape: Verify would RESTORE it from the manifest).
    let recordHasFixity: Bool
    var description: String { "\(kind), record \(recordHasFixity ? "has" : "lost its") fixity" }
    static let all: [VerifyFaultCase] = HashReadFault.Kind.allCases.flatMap {
        [VerifyFaultCase(kind: $0, recordHasFixity: true), VerifyFaultCase(kind: $0, recordHasFixity: false)]
    }
}

@Suite("Hash read fault × Verify Archive Copies — a faulted read never verifies and never writes a fixity")
@MainActor
struct HashReadFaultVerifyArchiveTests {

    private func run(_ model: VideoScanModel) async -> VerifyArchiveCopiesJob {
        let job = VerifyArchiveCopiesJob(model: model)
        job.start()
        await job.task?.value
        return job
    }

    @Test("MATRIX: each fault in the archive file's read → never verified, no fixity written from it, the row and the red summary name it, the control file is unaffected",
          .timeLimit(.minutes(2)), arguments: VerifyFaultCase.all)
    func aFaultedReadNeverVerifies(_ c: VerifyFaultCase) async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("hrf_verify"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        var sources: [VideoRecord] = []
        for i in 0..<2 {
            let url = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_hrf_verify_\(i).mov"),
                                                             bytes: 50_000 + i, seed: UInt64(60 + i))
            sources.append(MasterArchiveTestSupport.makeRecord(path: url.path, userDate: "199\(i)-03-0\(i + 1)"))
        }
        model.records = sources
        _ = try #require(await MasterArchiveTestSupport.promote(model, ids: sources.map(\.id)))
        let victim = try #require(model.masterArchiveCopy(of: sources[0]))
        let control = try #require(model.masterArchiveCopy(of: sources[1]))
        let trueDigest = try #require(victim.archiveFixity?.digest)
        let (fixityBefore, generalBefore) = (victim.archiveFixity, victim.contentFixity)
        if !c.recordHasFixity { victim.archiveFixity = nil; victim.contentFixity = nil }
        let bytesBefore = try Data(contentsOf: URL(fileURLWithPath: victim.fullPath))
        let manifestBefore = try Data(contentsOf: sb.manifestURL)
        let victimName = (victim.fullPath as NSString).lastPathComponent

        let fault = HashReadFault(c.kind, pathSuffix: victimName, atByte: 17_000, onPass: 0)
        let job = await fault.run { await run(model) }
        #expect(fault.firedCount == 1, "\(c): the fault never reached the archive file's read")

        // --- Never verified; nothing written from the faulted read.
        let row = try #require(job.outcomes.first { $0.name.hasSuffix(victimName) }, "\(c): no row for the file")
        print("[hash-matrix] verify-archive | \(c) | \(row.kind) | \(row.detail)")
        #expect(row.kind != .verified && row.kind != .restored && row.kind != .unmanifested, "\(c): \(row)")
        #expect(job.tally.verified + job.tally.restored == 1, "\(c): only the control verifies — \(job.tally)")
        if let now = victim.archiveFixity {
            #expect(now == fixityBefore, "\(c): the fixity was rewritten by a faulted read")
            #expect(now.digest == trueDigest)
        }
        if let general = victim.contentFixity {
            #expect(general == generalBefore, "\(c): a general fixity was written from a faulted read")
        }
        if !c.recordHasFixity {
            #expect(victim.archiveFixity == nil && victim.contentFixity == nil, "\(c): a stripped record gained a fixity")
        }

        // --- Red, counted, named.
        guard case .failed(let summary) = job.state else {
            Issue.record("\(c): the run did not end red — \(job.state)"); return
        }
        switch c.kind {
        case .eio:
            #expect(row.kind == .failed && job.tally.failed == 1 && summary.contains("1 failed"), "\(c): \(row) / \(summary)")
            if c.recordHasFixity {
                #expect(victim.archiveFixity == fixityBefore, "an errored check clears nothing")
            }
            withKnownIssue("PARKED 2026-11-20 (P3, wording): Verify reports a READ error as \"write failed: read errno 5\" (Failure.writeFailed from sha256(fd:)). Proposed: Failure.readFailed — \"could not be read in full (errno N)\".") {
                #expect(!row.detail.lowercased().contains("write failed"), "\(row.detail)")
            }
            #expect(row.detail.contains("read errno \(EIO)"))
        case .bitFlip:
            #expect(row.kind == .mismatch && job.tally.mismatch == 1 && summary.contains("1 MISMATCH"), "\(c): \(row) / \(summary)")
            #expect(row.expectedDigest == trueDigest && row.actualDigest != trueDigest)
            // codex #975: a digest that disagrees clears what the record claimed.
            #expect(victim.archiveFixity == nil)
        case .shortRead:
            #expect(row.kind == .mismatch && job.tally.mismatch == 1, "\(c): \(row) / \(summary)")
            #expect(victim.archiveFixity == nil)
            withKnownIssue("PARKED 2026-11-20 (P2, truth): a read that ENDS EARLY (bytes consumed < file size) is reported as \"POSSIBLE CORRUPTION — bytes on disk hash to …\" and clears the record's fixity; the digest is of a prefix, not of the bytes on disk. Proposed: compare bytes consumed with the size (as FixityRebind does) → a `.failed` row \"could not be read in full (read N of M bytes)\", fixity left alone.") {
                #expect(row.kind == .failed, "\(c): \(row.kind)")
                #expect(!row.detail.contains("bytes on disk hash to"), "\(row.detail)")
                if c.recordHasFixity { #expect(victim.archiveFixity == fixityBefore) }
            }
        }

        // --- The log says which file and why (not only a count).
        let console = await hashFaultConsole(model, containing: "Verify Archive: \(summary).")
        #expect(console.contains("Verify Archive: \(summary)."), "\(c): console:\n\(console)")
        let verifyLines = console.split(separator: "\n").filter { $0.hasPrefix("Verify Archive") }
        let namesTheFile = verifyLines.contains { $0.contains(victimName) }
        if c.kind == .eio {
            withKnownIssue("PARKED 2026-11-20 (P3, logging): a FAILED read in Verify is counted in the summary (\"1 failed\") but the file and the reason reach only os_log — not the console, catalog.log or videoscan.log (mismatch and missing do log their file). Proposed: model.log + appLog.write for the failed row, like flagMismatch.") {
                #expect(namesTheFile, "\(c): \(verifyLines)")
            }
        } else {
            #expect(verifyLines.contains { $0.contains("MISMATCH") && $0.contains(victimName) }, "\(c): \(verifyLines)")
        }

        // --- Media and index untouched; the control verified.
        #expect(try Data(contentsOf: URL(fileURLWithPath: victim.fullPath)) == bytesBefore)
        #expect(try Data(contentsOf: sb.manifestURL) == manifestBefore)
        #expect(control.archiveFixity != nil)
        #expect(job.outcomes.contains { $0.name.hasSuffix((control.fullPath as NSString).lastPathComponent) && $0.kind == .verified })

        // --- A clean run settles it from the manifest.
        let again = await run(model)
        guard case .finished = again.state else { Issue.record("\(c): clean re-run: \(again.state)"); return }
        #expect(victim.archiveFixity?.digest == trueDigest)
    }
}
