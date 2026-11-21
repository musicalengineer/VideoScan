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
// THAT MATRIX IS THE FRESH-COPY PATH ONLY. `expectedSourceSHA` (the digest
// of the proving read, re-proved against the bytes the copy pass reads) is
// what catches a flipped proving read there. It does not protect:
//
//   GH #504 D3c (FIXED 2026-11-21; was P1, Codex r1 #3) —
//   `aFlippedProvingReadAdoptsAnotherFile`: the ADOPTION branch. When a file
//   already sits at the proposed destination and hashes to the proving
//   read's digest, Promote adopts it — no copy. Before it does, the source
//   is now read a SECOND time and must reproduce the proving digest, so a
//   bit flipped in the one proving read can no longer tie the source to a
//   different file in the manifest, the journal and the catalog.
//
// Outcomes:
//   read faulted            fresh copy                       destination already holds a file
//   proving read, EIO/short failed ("could not be read in    failed
//                           full")
//   proving read, bit flip  failed ("source changed")        failed ("two reads of <file> disagreed")
//   source's 2nd read       (no such read)                   failed (EIO/short); clean → adopted
//   copy pass / read-back   failed                           (no such read on this path)
//
// Wording (GH #504 D1, fixed 2026-11-21): EIO and a read that ends early are
// "could not be read in full (read errno N | N of M bytes)" in all three
// reads — no longer "write failed: read errno 5" / "could not open source".
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
          .timeLimit(.minutes(HashReadFaultLimits.hangGuardMinutes)), arguments: PromoteFaultCase.all)
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

    /// Codex r1 #3 (was P1; GH #504 D3c, fixed). Source A has no stored
    /// fixity. An unindexed file B — same size, one bit different at byte
    /// 20,000 — already sits where A would be filed. The flip lands on that
    /// byte of A's proving read, so the digest Promote holds for A is
    /// SHA-256(B). The source's SECOND read, made before adopting, disagrees.
    @Test("a bit flipped in the proving read makes the source 'identical' to a different file at the destination — NOT adopted: the source's second read disagrees, 'two reads of <file> disagreed — nothing was recorded'",
          .timeLimit(.minutes(HashReadFaultLimits.hangGuardMinutes)))
    func aFlippedProvingReadAdoptsAnotherFile() async throws {
        // Where would this file be filed? Ask a clean promote in a scratch sandbox.
        let probe = try MasterArchiveTestSupport.makeSandbox("hrf_adopt_probe"); defer { probe.cleanup() }
        let probeSrc = try MasterArchiveTestSupport.writeBlob(at: probe.sources.appendingPathComponent(Self.fileName),
                                                              bytes: Self.bytes, seed: 21)
        let probeModel = MasterArchiveTestSupport.makeModel(probe)
        try MasterArchiveTestSupport.initialize(probeModel, in: probe)
        let probeRec = MasterArchiveTestSupport.makeRecord(path: probeSrc.path, userDate: "1994-05-01")
        probeModel.records = [probeRec]
        _ = try #require(await MasterArchiveTestSupport.promote(probeModel, ids: [probeRec.id]))
        let rel = try #require(MasterArchiveTestSupport.archivedFiles(probe).first)

        let sb = try MasterArchiveTestSupport.makeSandbox("hrf_adopt"); defer { sb.cleanup() }
        let src = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent(Self.fileName),
                                                         bytes: Self.bytes, seed: 21)
        let a = try Data(contentsOf: src)
        var b = a
        b[Int(Self.faultAt)] ^= 0x01
        let digestA = try #require(MasterArchiveTestSupport.sha256(ofFile: src.path))
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let squatter = sb.archiveRoot.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: squatter.deletingLastPathComponent(), withIntermediateDirectories: true)
        try b.write(to: squatter)
        let digestB = try #require(MasterArchiveTestSupport.sha256(ofFile: squatter.path))
        try #require(digestA != digestB)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path, userDate: "1994-05-01")
        model.records = [rec]

        let fault = HashReadFault(.bitFlip, pathSuffix: "Sources/" + Self.fileName, atByte: Self.faultAt, onPass: 1)
        let job = try #require(await fault.run { await MasterArchiveTestSupport.promote(model, ids: [rec.id]) })
        await job.completionTask?.value
        #expect(fault.firedCount == 1)
        let row = try #require(job.outcomes.first)
        let rows = MasterArchiveTestSupport.manifestRows(sb)
        let copy = model.masterArchiveCopy(of: rec)
        print("[hash-matrix] promote | bitFlip in sourceProof, a one-bit-different file at the destination | \(row.kind) | \(row.detail) | source reads \(fault.passCount) | manifest sha \(rows.first?[ArchiveManifestCSV.sha256Column].prefix(12) ?? "-")")

        // Seen RED 2026-11-21: outcome `adopted`, the manifest's sha was the
        // OTHER file's, after one source read.
        #expect(fault.passCount == 2, "the source was read a second time before adopting — \(fault.passCount)")
        #expect(row.kind == .failed, "\(row.kind): \(row.detail)")
        #expect(row.detail.contains("two reads of \(Self.fileName) disagreed — nothing was recorded"), "\(row.detail)")
        #expect(rows.isEmpty, "a manifest row was written: \(rows)")
        #expect(copy == nil, "an archive record ties the source to \(copy?.archiveFixity?.digest.prefix(12) ?? "?")…")
        #expect(rec.archiveStage != .masterAssigned && rec.contentFixity == nil, "the source is marked archived / given a fixity")
        let journal = (try? String(contentsOf: sb.journalURL, encoding: .utf8)) ?? ""
        #expect(!journal.contains(rec.id.uuidString), "a journal entry records the adoption:\n\(journal)")
        guard case .failed(let summary) = job.state else { Issue.record("the job did not end failed — \(job.state)"); return }
        #expect(summary.contains("Promoted 0") && summary.contains("failed 1"), "\(summary)")
        // Both files are exactly what they were.
        #expect(try Data(contentsOf: src) == a)
        #expect(try Data(contentsOf: squatter) == b)
        #expect(MasterArchiveTestSupport.sha256(ofFile: squatter.path) == digestB)

        // The refusal was the fault's and blocks nothing: a clean retry sees
        // that the file at the destination is NOT the source's bytes and
        // promotes the source beside it.
        let retry = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .finished = retry.state else { Issue.record("the clean retry: \(retry.state) \(retry.outcomes)"); return }
        #expect(retry.outcomes.first?.kind == .promoted, "\(retry.outcomes)")
        #expect(model.masterArchiveCopy(of: rec)?.archiveFixity?.digest == digestA)
        #expect(try Data(contentsOf: squatter) == b, "the file that was already there is untouched")
    }

    /// Where a clean promote files this suite's source: asked of a scratch
    /// sandbox, so the answer is the engine's own.
    private func whereItWouldBeFiled() async throws -> String {
        let probe = try MasterArchiveTestSupport.makeSandbox("hrf_adopt_probe"); defer { probe.cleanup() }
        let probeSrc = try MasterArchiveTestSupport.writeBlob(at: probe.sources.appendingPathComponent(Self.fileName),
                                                              bytes: Self.bytes, seed: 21)
        let probeModel = MasterArchiveTestSupport.makeModel(probe)
        try MasterArchiveTestSupport.initialize(probeModel, in: probe)
        let probeRec = MasterArchiveTestSupport.makeRecord(path: probeSrc.path, userDate: "1994-05-01")
        probeModel.records = [probeRec]
        _ = try #require(await MasterArchiveTestSupport.promote(probeModel, ids: [probeRec.id]))
        return try #require(MasterArchiveTestSupport.archivedFiles(probe).first)
    }

    /// D3c's other half: a GENUINE adoption (the file at the destination
    /// really holds the source's bytes) still adopts — after the source's
    /// second read agreed — and a fault in that second read refuses by name.
    @Test("ADOPTION, the source's SECOND read: clean → adopted after exactly two source reads, no copy; EIO or a read that ends early → failed 'could not be read in full', nothing recorded",
          .timeLimit(.minutes(HashReadFaultLimits.hangGuardMinutes)), arguments: [HashReadFault.Kind?.none, .eio, .shortRead])
    func theConfirmingReadBeforeAnAdoption(_ kind: HashReadFault.Kind?) async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("hrf_adopt2"); defer { sb.cleanup() }
        let src = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent(Self.fileName),
                                                         bytes: Self.bytes, seed: 21)
        let a = try Data(contentsOf: src)
        let digestA = try #require(MasterArchiveTestSupport.sha256(ofFile: src.path))
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path, userDate: "1994-05-01")
        model.records = [rec]
        let existing = sb.archiveRoot.appendingPathComponent(try await whereItWouldBeFiled())
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try a.write(to: existing)

        // Counts every source read; faults the second one when asked.
        let fault = HashReadFault(kind ?? .eio, pathSuffix: "Sources/" + Self.fileName,
                                  atByte: kind == nil ? 1 << 40 : Self.faultAt, onPass: 2)
        let partials = HashReadFault(.eio, where: { $0.hasSuffix(".partial") }, atByte: 1 << 40, onPass: 0)
        let hook: ArchivePromoteEngine.ReadHook = { fd, off, n in fault.hook(fd, off, n) ?? partials.hook(fd, off, n) }
        let job = try #require(await ArchivePromoteEngine.$readHook.withValue(hook) {
            await MasterArchiveTestSupport.promote(model, ids: [rec.id])
        })
        await job.completionTask?.value
        let row = try #require(job.outcomes.first)
        print("[hash-matrix] promote adoption | \(kind.map { "\($0)" } ?? "clean") in the source's second read | \(row.kind) | \(row.detail) | source reads \(fault.passCount)")
        #expect(fault.passCount == 2 && partials.passCount == 0, "two source reads, no copy: source \(fault.passCount), partial \(partials.passCount)")
        #expect(try Data(contentsOf: existing) == a && Data(contentsOf: src) == a)
        guard let kind else {
            #expect(row.kind == .adopted, "\(row.kind): \(row.detail)")
            #expect(model.masterArchiveCopy(of: rec)?.archiveFixity?.digest == digestA)
            #expect(MasterArchiveTestSupport.manifestRows(sb).count == 1)
            return
        }
        #expect(fault.firedCount == 1)
        #expect(row.kind == .failed && row.detail.contains("could not be read in full"), "\(kind): \(row.kind): \(row.detail)")
        #expect(MasterArchiveTestSupport.manifestRows(sb).isEmpty && model.masterArchiveCopy(of: rec) == nil)
        #expect(rec.archiveStage != .masterAssigned)
    }

    // MARK: Codex r1 P1 (GH #504, D3c) — the adoption DESTINATION is confirmed too

    /// Source A (no stored fixity); the file already at the destination is B,
    /// one bit apart; the destination's FIRST read returns that bit flipped,
    /// so it hashes to SHA-256(A). Two clean source reads cannot see that.
    @Test("ADOPTION, destination (Codex r1 P1): the file already at the destination is ONE BIT apart and its first read flips that bit → NOT adopted: its second read disagrees, 'two reads of <path> disagreed — nothing was recorded'",
          .timeLimit(.minutes(HashReadFaultLimits.hangGuardMinutes)))
    func aFlippedDestinationReadAdoptsNothing() async throws {
        let rel = try await whereItWouldBeFiled()
        let sb = try MasterArchiveTestSupport.makeSandbox("hrf_adopt_dest"); defer { sb.cleanup() }
        let src = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent(Self.fileName),
                                                         bytes: Self.bytes, seed: 21)
        let a = try Data(contentsOf: src)
        var b = a
        b[Int(Self.faultAt)] ^= 0x01
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let existing = sb.archiveRoot.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try b.write(to: existing)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path, userDate: "1994-05-01")
        model.records = [rec]

        let fault = HashReadFault(.bitFlip, where: { $0.hasSuffix(rel) }, atByte: Self.faultAt, onPass: 1)
        let job = try #require(await fault.run { await MasterArchiveTestSupport.promote(model, ids: [rec.id]) })
        await job.completionTask?.value
        #expect(fault.firedCount == 1, "the flip never reached the destination's read")
        let row = try #require(job.outcomes.first)
        print("[hash-matrix] promote adoption | bitFlip in the DESTINATION's first read, destination one bit apart | \(row.kind) | \(row.detail) | destination reads \(fault.passCount)")
        #expect(row.kind == .failed, "\(row.kind): \(row.detail)")
        #expect(row.detail.contains("two reads of") && row.detail.contains("disagreed — nothing was recorded"), "\(row.detail)")
        #expect(fault.passCount == 2, "the destination was read a second time — \(fault.passCount)")
        #expect(MasterArchiveTestSupport.manifestRows(sb).isEmpty && model.masterArchiveCopy(of: rec) == nil)
        #expect(rec.archiveStage != .masterAssigned)
        #expect(try Data(contentsOf: existing) == b && Data(contentsOf: src) == a)
    }

    /// The manifest leg: a manifest row names this source (a crash after the
    /// manifest append), its catalog record is gone. The file the row points
    /// at now holds B, one bit apart from the manifest's bytes; its first
    /// read returns that bit flipped.
    @Test("ADOPTION, manifest leg (Codex r1 P1): the file the manifest row points at is ONE BIT apart and its first read flips that bit → NOT linked: its second read disagrees; a clean run refuses it as a digest mismatch",
          .timeLimit(.minutes(HashReadFaultLimits.hangGuardMinutes)))
    func aFlippedDestinationReadOnTheManifestLegLinksNothing() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("hrf_adopt_manifest"); defer { sb.cleanup() }
        let src = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent(Self.fileName),
                                                         bytes: Self.bytes, seed: 21)
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path, userDate: "1994-05-01")
        model.records = [rec]
        _ = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        let copy = try #require(model.masterArchiveCopy(of: rec))
        let archiveURL = URL(fileURLWithPath: copy.fullPath)
        let a = try Data(contentsOf: archiveURL)
        // The crash shape: the manifest row stays, the catalog record is gone.
        model.records = [rec]
        rec.contentFixity = nil
        try #require(model.masterArchiveCopy(of: rec) == nil, "fixture: the archive record is gone")
        // Control: a clean run adopts from the manifest.
        MasterArchiveTestSupport.unlockTree(sb.root)
        var b = a
        b[Int(Self.faultAt)] ^= 0x01
        try b.write(to: archiveURL)
        let name = archiveURL.lastPathComponent

        let fault = HashReadFault(.bitFlip, where: { $0.contains("/Archive/") && $0.hasSuffix(name) }, atByte: Self.faultAt, onPass: 1)
        let job = try #require(await fault.run { await MasterArchiveTestSupport.promote(model, ids: [rec.id]) })
        await job.completionTask?.value
        try #require(fault.firedCount == 1, "fixture: the manifest leg never read the archive file — \(job.outcomes)")
        let row = try #require(job.outcomes.first)
        print("[hash-matrix] promote adoption, manifest leg | bitFlip in the archive file's first read | \(row.kind) | \(row.detail) | reads \(fault.passCount)")
        #expect(row.kind == .failed, "\(row.kind): \(row.detail)")
        #expect(row.detail.contains("two reads of") && row.detail.contains("disagreed — nothing was recorded"), "\(row.detail)")
        #expect(fault.passCount == 2, "\(fault.passCount)")
        #expect(model.masterArchiveCopy(of: rec) == nil, "the source was linked to a file that does not hold its bytes")
        #expect(try Data(contentsOf: archiveURL) == b)
        // Clean: one read, a plain digest mismatch, still nothing linked.
        let clean = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        await clean.completionTask?.value
        #expect(clean.outcomes.first?.kind == .failed && clean.outcomes.first?.detail.contains("does not match the recorded digest") == true,
                "\(clean.outcomes)")
    }

    /// The reconcile leg (same rule, third place): the journal holds an
    /// `intent` for this source and a file sits at its destination — an
    /// interrupted promotion. That file is B, one bit apart; its first read
    /// returns the bit flipped, so it hashes to the source's digest.
    @Test("ADOPTION, reconcile leg: the file an interrupted promotion left at the destination is ONE BIT apart and its first read flips that bit → NOT indexed (its second read disagrees, said in the console); the source is then promoted beside it",
          .timeLimit(.minutes(HashReadFaultLimits.hangGuardMinutes)))
    func aFlippedDestinationReadOnTheReconcileLegIndexesNothing() async throws {
        let rel = try await whereItWouldBeFiled()
        let sb = try MasterArchiveTestSupport.makeSandbox("hrf_adopt_reconcile"); defer { sb.cleanup() }
        let src = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent(Self.fileName),
                                                         bytes: Self.bytes, seed: 21)
        let a = try Data(contentsOf: src)
        let digestA = try #require(MasterArchiveTestSupport.sha256(ofFile: src.path))
        var b = a
        b[Int(Self.faultAt)] ^= 0x01
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path, userDate: "1994-05-01")
        model.records = [rec]
        let dest = sb.archiveRoot.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try b.write(to: dest)
        try ArchivePromoteJournal.append(.init(sourceRecordID: rec.id, sourcePath: src.path, destRelPath: rel,
                                               state: .intent, sha256: nil, copyRecordID: nil, at: Date()),
                                         rootPath: sb.archiveRoot.path)

        let fault = HashReadFault(.bitFlip, where: { $0.hasSuffix(rel) }, atByte: Self.faultAt, onPass: 1)
        let job = try #require(await fault.run { await MasterArchiveTestSupport.promote(model, ids: [rec.id]) })
        await job.completionTask?.value
        try #require(fault.firedCount == 1, "fixture: the reconcile leg never read the file at the destination")
        let copy = model.masterArchiveCopy(of: rec)
        print("[hash-matrix] promote reconcile leg | bitFlip in the destination's first read | \(job.outcomes.map { "\($0.kind): \($0.detail)" }) | archive copy \(copy?.fullPath ?? "none")")
        #expect(copy?.fullPath != dest.path, "the source was tied to a file that does not hold its bytes")
        #expect(try Data(contentsOf: dest) == b, "the file that was there is untouched")
        let console = await hashFaultConsole(model, containing: "left in place, not indexed")
        #expect(console.contains("two reads of \(rel) disagreed") && console.contains("left in place, not indexed"), "\(console)")
        // The source itself is then promoted like any other — beside the file that was there.
        #expect(copy?.archiveFixity?.digest == digestA, "\(job.outcomes)")
        let rows = MasterArchiveTestSupport.manifestRows(sb)
        #expect(rows.count == 1 && rows.first?[ArchiveManifestCSV.relPathColumn] != rel, "\(rows)")
    }

    /// EIO and a read that ends early are named as READ failures (GH #504
    /// D1; were "write failed: read errno 5" / "could not open source" /
    /// "changed"). A flip shows up as two reads that disagree;
    /// "changed"/"verification failed" is the most the app can know.
    private func expectTruthfulWords(_ c: PromoteFaultCase, _ detail: String) {
        let d = detail.lowercased()
        switch (c.kind, c.read) {
        case (.eio, _):
            #expect(!d.contains("write failed") && !d.contains("could not open"), "\(c): \(detail)")
            #expect(d.contains("could not be read in full (read errno \(EIO))"), "\(c): the errno is in the words: \(detail)")
        case (.shortRead, _):
            #expect(d.contains("could not be read in full (\(Self.faultAt) of \(Self.bytes) bytes)"), "\(c): \(detail)")
        case (_, .sourceProof), (_, .sourceCopy):
            #expect(d.contains("changed") || d.contains("does not match"), "\(c): \(detail)")
        case (_, .copyReadBack):
            #expect(d.contains("verification failed"), "\(c): \(detail)")
        }
    }
}
