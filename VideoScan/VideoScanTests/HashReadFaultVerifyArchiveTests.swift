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
// GH #504 D1 (FIXED 2026-11-21, seen RED first): a read that ends before the
// file's size is a read failure in the one reader, so Verify reports a
// FAILED row "could not be read in full (N of M bytes)", clears nothing and
// writes nothing — also for `aShortReadOfALongerArchiveFileVerifies` (was P1,
// Codex r1 #1: an archive file that is the manifest's bytes PLUS A TAIL,
// read only as far as the manifest's length, was reported verified /
// restored and had archiveFixity written). The failed row names its file
// and reason in the console and the app log (was P3: os_log only).
//
// Outcomes:
//   fault            file == manifest bytes            file == manifest bytes + tail
//   EIO              failed, fixity kept               failed
//   bit flip         MISMATCH, fixity cleared          MISMATCH
//   read ends early  failed, fixity kept               failed, nothing written
//
// What happens to a fixity the record ALREADY carried is pinned per fault
// (a read that failed keeps it — "the check errored"; a digest that
// disagrees clears it — codex #975 — but only when a SECOND read produced
// the same digest).
//
// Codex r1 on this branch (FIXED 2026-11-21, each seen RED first):
//   * D3b at Verify — a read that disagrees with the record's STORED
//     fingerprint is made a second time, whether it matches the manifest (a
//     replacement) or nothing (a clear). Two reads agree → replaced and SAID
//     old → new / flagged MISMATCH as before. They disagree → a failed row
//     "read twice, disagreed (stored fingerprint kept)".
//   * D1 strict — a file whose size moves under the read ("changed while it
//     was read (N bytes before, M after)") never yields a digest.
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
        // The fault is on EVERY read of the file (onPass 0). A flipped digest that
        // disagrees with the record's stored fingerprint earns a second read
        // (GH #504 D3b), which flips the same way — the two reads agree, so the
        // mismatch below stands as a mismatch.
        let expectedFires = c.kind == .bitFlip && c.recordHasFixity ? 2 : 1
        #expect(fault.firedCount == expectedFires, "\(c): the fault never reached the archive file's read (fired \(fault.firedCount))")

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
            #expect(!row.detail.lowercased().contains("write failed"), "\(row.detail)")
            #expect(row.detail == "could not be read in full (read errno \(EIO))", "\(row.detail)")
        case .bitFlip:
            #expect(row.kind == .mismatch && job.tally.mismatch == 1 && summary.contains("1 MISMATCH"), "\(c): \(row) / \(summary)")
            #expect(row.expectedDigest == trueDigest && row.actualDigest != trueDigest)
            // codex #975: a digest that disagrees clears what the record claimed.
            #expect(victim.archiveFixity == nil)
        case .shortRead:
            // GH #504 D1 (was P2): a read that ends early is a FAILED row,
            // never "POSSIBLE CORRUPTION", and it clears nothing.
            #expect(row.kind == .failed && job.tally.failed == 1 && job.tally.mismatch == 0 && summary.contains("1 failed"),
                    "\(c): \(row) / \(summary)")
            #expect(row.detail == "could not be read in full (17000 of \(bytesBefore.count) bytes)", "\(row.detail)")
            #expect(!row.detail.contains("bytes on disk hash to"), "\(row.detail)")
            if c.recordHasFixity { #expect(victim.archiveFixity == fixityBefore, "a read that ended early clears nothing") }
        }

        // --- The log says which file and why (not only a count).
        let console = await hashFaultConsole(model, containing: "Verify Archive: \(summary).")
        #expect(console.contains("Verify Archive: \(summary)."), "\(c): console:\n\(console)")
        let verifyLines = console.split(separator: "\n").filter { $0.hasPrefix("Verify Archive") }
        let namesTheFile = verifyLines.contains { $0.contains(victimName) }
        if c.kind == .bitFlip {
            #expect(verifyLines.contains { $0.contains("MISMATCH") && $0.contains(victimName) }, "\(c): \(verifyLines)")
        } else {
            // A failed read names its file and its reason in the console
            // (was P3: os_log only).
            #expect(namesTheFile, "\(c): \(verifyLines)")
            #expect(verifyLines.contains { $0.contains("FAILED") && $0.contains(victimName) && $0.contains("could not be read in full") },
                    "\(c): \(verifyLines)")
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

    /// Codex r1 #1 (was P1; FIXED by GH #504 D1, seen RED 2026-11-21). The
    /// archive file was changed after Promote: it is the manifest's bytes
    /// followed by more. A full read flags it (the control). A read that
    /// ends at the manifest's length used to hash to the manifest's digest —
    /// Verify called the file verified and restored a stripped fixity. Now
    /// the read fails by name and nothing is written.
    @Test("a read that ENDS EARLY on an archive file holding the manifest's bytes PLUS A TAIL is never verified/restored and writes no archiveFixity: a FAILED row, the run ends red",
          .timeLimit(.minutes(2)), arguments: [true, false])
    func aShortReadOfALongerArchiveFileVerifies(recordHasFixity: Bool) async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("hrf_verify_tail"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let url = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_hrf_verify_tail.mov"),
                                                         bytes: 50_000, seed: 91)
        let source = MasterArchiveTestSupport.makeRecord(path: url.path, userDate: "1993-04-05")
        model.records = [source]
        _ = try #require(await MasterArchiveTestSupport.promote(model, ids: [source.id]))
        let copy = try #require(model.masterArchiveCopy(of: source))
        let manifestDigest = try #require(copy.archiveFixity?.digest)
        MasterArchiveTestSupport.unlockTree(sb.root)
        let archiveURL = URL(fileURLWithPath: copy.fullPath)
        let original = try Data(contentsOf: archiveURL)
        let tail = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 5 &+ 1) })
        try (original + tail).write(to: archiveURL)
        let diskDigest = try #require(MasterArchiveTestSupport.sha256(ofFile: copy.fullPath))
        try #require(diskDigest != manifestDigest, "fixture: the file on disk is not the manifest's bytes")
        let name = archiveURL.lastPathComponent

        // Control: read in full, Verify flags it.
        let control = await run(model)
        #expect(control.outcomes.first { $0.name.hasSuffix(name) }?.kind == .mismatch, "\(control.outcomes)")
        #expect(copy.archiveFixity == nil, "the control cleared the stale fixity")
        if recordHasFixity {
            copy.archiveFixity = ArchiveFixity(digest: manifestDigest, verifiedAt: Date(timeIntervalSince1970: 1), sizeBytes: 50_000)
        }
        let before = copy.archiveFixity

        let fault = HashReadFault(.shortRead, pathSuffix: name, atByte: Int64(original.count), onPass: 0)
        let job = await fault.run { await run(model) }
        #expect(fault.firedCount == 1)
        let row = try #require(job.outcomes.first { $0.name.hasSuffix(name) })
        print("[hash-matrix] verify-archive | shortRead at the manifest's length, file = manifest bytes + tail, record \(recordHasFixity ? "has" : "lost its") fixity | \(row.kind) | \(job.state)")
        #expect(row.kind == .failed, "\(row.kind): \(row.detail)")
        #expect(row.detail == "could not be read in full (\(original.count) of \(original.count + tail.count) bytes)", "\(row.detail)")
        #expect(copy.archiveFixity == before, "archiveFixity was written from a short read: \(String(describing: copy.archiveFixity))")
        if case .finished = job.state { Issue.record("the run ended green: \(job.state)") }
        // The file on disk is untouched.
        #expect(MasterArchiveTestSupport.sha256(ofFile: copy.fullPath) == diskDigest)
    }

    // MARK: Codex r1 P1 (GH #504, D3b at Verify) — a stored fingerprint is replaced only on two agreeing reads

    /// One promoted file; the archive file is then rewritten to `disk`, and the
    /// record's archiveFixity set to the digest of `stored`.
    private func conflict(_ label: String, disk: (Data) -> Data, stored: (Data) -> Data) async throws
        -> (sb: MasterArchiveTestSupport.Sandbox, model: VideoScanModel, copy: VideoRecord, name: String, manifest: String, storedDigest: String) {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let url = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_\(label).mov"), bytes: 50_000, seed: 93)
        let source = MasterArchiveTestSupport.makeRecord(path: url.path, userDate: "1993-04-05")
        model.records = [source]
        _ = try #require(await MasterArchiveTestSupport.promote(model, ids: [source.id]))
        let copy = try #require(model.masterArchiveCopy(of: source))
        let manifest = try #require(copy.archiveFixity?.digest)
        MasterArchiveTestSupport.unlockTree(sb.root)
        let archiveURL = URL(fileURLWithPath: copy.fullPath)
        let a = try Data(contentsOf: archiveURL)
        try disk(a).write(to: archiveURL)
        let storedDigest = hashSeamReference(stored(a))
        copy.archiveFixity = ArchiveFixity(digest: storedDigest, verifiedAt: Date(timeIntervalSince1970: 1), sizeBytes: 50_000)
        copy.contentFixity = nil
        return (sb, model, copy, archiveURL.lastPathComponent, manifest, storedDigest)
    }

    @Test("CONFLICT (Codex r1 P1): the archive holds B and correctly stores SHA(B); the manifest names A, one bit apart; ONE read flips B→A → the stored fingerprint is NOT replaced: 'read twice, disagreed (stored fingerprint kept)', a failed row, the run ends red",
          .timeLimit(.minutes(2)))
    func oneReadThatMatchesTheManifestDoesNotReplaceAStoredFingerprint() async throws {
        let flip: (Data) -> Data = { var d = $0; d[17_000] ^= 0x01; return d }
        let c = try await conflict("hrf_verify_conflict", disk: flip, stored: flip); defer { c.sb.cleanup() }
        let before = c.copy.archiveFixity
        let fault = HashReadFault(.bitFlip, pathSuffix: c.name, atByte: 17_000, onPass: 1)
        let job = await fault.run { await run(c.model) }
        #expect(fault.firedCount == 1)
        let row = try #require(job.outcomes.first { $0.name.hasSuffix(c.name) })
        print("[hash-matrix] verify-archive | stored SHA(B), manifest SHA(A), one B→A flip | \(row.kind) | \(row.detail) | reads \(fault.passCount)")
        #expect(c.copy.archiveFixity == before, "the stored fingerprint was replaced on one read: \(c.copy.archiveFixity?.digest.prefix(12) ?? "nil")…")
        #expect(c.copy.contentFixity == nil, "a general fixity was written from the flipped read")
        #expect(row.kind == .failed, "\(row.kind): \(row.detail)")
        #expect(row.detail.contains("read twice, disagreed (stored fingerprint kept)"), "\(row.detail)")
        #expect(fault.passCount == 2, "\(fault.passCount)")
        if case .finished = job.state { Issue.record("the run ended green: \(job.state)") }
        let console = await hashFaultConsole(c.model, containing: "read twice, disagreed")
        #expect(console.contains("Verify Archive: FAILED") && console.contains(c.name) && console.contains("read twice, disagreed (stored fingerprint kept)"),
                "\(console)")
    }

    @Test("CONFLICT, the other half: the record's fingerprint is stale and TWO reads agree with the manifest → the fingerprint is replaced and the row and the console SAY so, old → new",
          .timeLimit(.minutes(2)))
    func twoReadsThatAgreeWithTheManifestReplaceAStaleFingerprintAndSayIt() async throws {
        let c = try await conflict("hrf_verify_replace", disk: { $0 }, stored: { var d = $0; d[17_000] ^= 0x01; return d })
        defer { c.sb.cleanup() }
        let reads = HashReadFault(.eio, pathSuffix: c.name, atByte: 1 << 40, onPass: 0)   // counts, never fires
        let job = await reads.run { await run(c.model) }
        let row = try #require(job.outcomes.first { $0.name.hasSuffix(c.name) })
        print("[hash-matrix] verify-archive | stale stored fingerprint, two clean reads agree with the manifest | \(row.kind) | \(row.detail)")
        #expect(reads.passCount == 2, "a replaced fingerprint costs a second read — \(reads.passCount)")
        #expect(c.copy.archiveFixity?.digest == c.manifest)
        #expect(row.kind == .restored && row.detail.contains("REPLACED")
                && row.detail.contains("sha256 \(c.storedDigest.prefix(12))… → \(c.manifest.prefix(12))…"), "\(row.kind): \(row.detail)")
        let console = await hashFaultConsole(c.model, containing: "REPLACED the fingerprint")
        #expect(console.contains("Verify Archive: REPLACED the fingerprint on") && console.contains(c.name), "\(console)")
        guard case .finished = job.state else { Issue.record("\(job.state)"); return }
    }

    @Test("CONFLICT × the SECOND read: EIO or a read that ends early in the confirming read → a failed row naming it, the stored fingerprint kept",
          .timeLimit(.minutes(2)), arguments: [HashReadFault.Kind.eio, .shortRead])
    func aFailedSecondReadKeepsTheStoredFingerprint(_ kind: HashReadFault.Kind) async throws {
        let c = try await conflict("hrf_verify_second_\(kind)", disk: { $0 }, stored: { var d = $0; d[17_000] ^= 0x01; return d })
        defer { c.sb.cleanup() }
        let before = c.copy.archiveFixity
        let fault = HashReadFault(kind, pathSuffix: c.name, atByte: 9_000, onPass: 2)
        let job = await fault.run { await run(c.model) }
        #expect(fault.firedCount == 1)
        let row = try #require(job.outcomes.first { $0.name.hasSuffix(c.name) })
        #expect(row.kind == .failed && row.detail.contains("could not be read in full") && row.detail.contains("on the second read (stored fingerprint kept)"),
                "\(kind): \(row.kind): \(row.detail)")
        #expect(c.copy.archiveFixity == before && c.copy.contentFixity == nil)
    }

    /// A single flipped read of a file whose record AGREES with the manifest
    /// used to clear the true fingerprint and cry POSSIBLE CORRUPTION; the
    /// matrix above flips EVERY read (that is, to any reader, the content).
    @Test("ONE flipped read of an intact, verified file: the second read disagrees with the first → failed 'read twice, disagreed (stored fingerprint kept)', the true fingerprint is NOT cleared, no POSSIBLE CORRUPTION",
          .timeLimit(.minutes(2)))
    func oneFlippedReadDoesNotClearATrueFingerprint() async throws {
        let c = try await conflict("hrf_verify_oneflip", disk: { $0 }, stored: { $0 }); defer { c.sb.cleanup() }
        let before = c.copy.archiveFixity
        try #require(before?.digest == c.manifest)
        let fault = HashReadFault(.bitFlip, pathSuffix: c.name, atByte: 17_000, onPass: 1)
        let job = await fault.run { await run(c.model) }
        #expect(fault.firedCount == 1 && fault.passCount == 2)
        let row = try #require(job.outcomes.first { $0.name.hasSuffix(c.name) })
        #expect(row.kind == .failed && row.detail.contains("read twice, disagreed (stored fingerprint kept)"), "\(row.kind): \(row.detail)")
        #expect(!row.detail.contains("POSSIBLE CORRUPTION") && job.tally.mismatch == 0)
        #expect(c.copy.archiveFixity == before, "the true fingerprint was cleared on one flipped read")
        let clean = await run(c.model)
        guard case .finished = clean.state else { Issue.record("clean re-run: \(clean.state)"); return }
    }

    // MARK: Codex r1 P1 (GH #504, D1 stricter) — a file that changes size under the read yields no digest

    @Test("SHRINK (Codex r1 P1): the archive file is truncated to half AFTER its whole content was buffered by the first read → never restored/verified from the former digest: a failed row 'changed while it was read (50000 bytes before, 25000 after)', no fixity written",
          .timeLimit(.minutes(2)))
    func aFileThatShrinksUnderTheReadIsNeverRestored() async throws {
        let c = try await conflict("hrf_verify_shrink", disk: { $0 }, stored: { $0 }); defer { c.sb.cleanup() }
        c.copy.archiveFixity = nil
        let path = c.copy.fullPath
        let name = c.name
        final class Once: @unchecked Sendable { let lock = NSLock(); var done = false }
        let once = Once()
        let hook: ArchivePromoteEngine.ReadHook = { fd, offset, _ in
            guard offset == 0, HashReadFault.path(of: fd)?.hasSuffix(name) == true else { return nil }
            once.lock.withLock {
                guard !once.done else { return }
                once.done = true
                truncate(path, 25_000)
            }
            return nil
        }
        let job = await ArchivePromoteEngine.$readHook.withValue(hook) { await run(c.model) }
        #expect(once.done, "the hook never saw the archive file's read")
        let row = try #require(job.outcomes.first { $0.name.hasSuffix(name) })
        print("[hash-matrix] verify-archive | truncated to half after the first pread buffered it all | \(row.kind) | \(row.detail)")
        #expect(row.kind == .failed, "\(row.kind): \(row.detail)")
        #expect(row.detail == "changed while it was read (50000 bytes before, 25000 after)", "\(row.detail)")
        #expect(!row.detail.contains("POSSIBLE CORRUPTION"))
        #expect(c.copy.archiveFixity == nil && c.copy.contentFixity == nil, "a fixity was written from a file that changed under the read")
    }
}
