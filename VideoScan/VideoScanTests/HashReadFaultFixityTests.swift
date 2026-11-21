// HashReadFaultFixityTests.swift
// NEGATIVE MATRIX — the verbs that STORE a whole-file digest from one read
// (hash read seam, 2026-11-20): "Fill In Full Hashes…" (FullHashBackfillJob)
// and "Bind Fixity to Volume" (BindFixityToVolumeJob). Both hash through
// `FixityRebind.rehash` → `ArchivePromoteEngine.sha256(fd:)`.
//
//   EIO mid-file        → `unreadable`: nothing stored, the row and the
//                         summary say so, the old fixity (if any) is kept;
//   a read ending early → refused ("read N bytes, the file has M"): nothing
//                         stored;
//   one flipped bit     → NOT DETECTABLE by a single read with no reference.
//                         Pinned as it is: the backfill stores the digest of
//                         the flipped bytes; Bind stores it too and reports
//                         "held different bytes than before". See LIMIT below.
//
// In every cell the file's bytes are untouched, and a clean run afterwards
// stores the true digest (EIO / short read) — the refusal blocks nothing.
//
// Parallel-safe: sandbox per test, task-local hook, no global log swap.

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private func trueDigest(_ path: String) -> String {
    SHA256.hash(data: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data())
        .map { String(format: "%02x", $0) }.joined()
}

@Suite("Hash read fault × Fill In Full Hashes / Bind Fixity — no digest is stored from a read that failed")
@MainActor
struct HashReadFaultFixityTests {

    // MARK: Fill In Full Hashes

    private func runBackfill(_ model: VideoScanModel) async -> FullHashBackfillJob {
        let job = FullHashBackfillJob(model: model, marker: nil)
        job.volumeOnline = { _ in true }
        job.tickMilliseconds = 20
        job.start()
        await job.task?.value
        return job
    }

    @Test("BACKFILL × {EIO, short read}: nothing is stored for the faulted file, it is counted and named, the control file is hashed; a clean run then stores the true digest",
          .timeLimit(.minutes(2)), arguments: [HashReadFault.Kind.eio, .shortRead])
    func backfillStoresNothingFromAFailedRead(_ kind: HashReadFault.Kind) async throws {
        let sb = try ShowAgainSandbox.make("hrf_fhb_\(kind)"); defer { sb.cleanup() }
        let victim = try sb.record("test_hrf_victim.mov", bytes: 30_000, stage: .none)
        let control = try sb.record("test_hrf_control.mov", bytes: 31_000, stage: .none)
        let bytesBefore = try Data(contentsOf: URL(fileURLWithPath: victim.fullPath))

        let fault = HashReadFault(kind, pathSuffix: "test_hrf_victim.mov", atByte: 12_000, onPass: 0)
        let job = await fault.run { await runBackfill(sb.model) }
        #expect(fault.firedCount == 1, "\(kind): the fault never reached the read")
        print("[hash-matrix] full-hash-backfill | \(kind) | \(job.state) | \(job.totals.line)")

        #expect(victim.contentFixity == nil, "\(kind): a digest was stored from a failed read")
        #expect(control.contentFixity?.digest == trueDigest(control.fullPath))
        #expect(job.totals[.hashed] == 1 && job.storedCount == 1, "\(job.totals.line)")
        switch kind {
        case .eio:
            #expect(job.totals[.unreadable] == 1 && job.totals.line.contains("1 unreadable"), "\(job.totals.line)")
        case .shortRead:
            #expect(job.totals[.changedDuringRead] == 1, "\(job.totals.line)")
            withKnownIssue("PARKED 2026-11-20 (P3, truth): a read that ENDED EARLY is counted as \"changed while it was read\" (FixityRebind.changedDuringRead); the detail \"read N bytes, the file has M\" is accurate, the bucket is not — the file did not change. Proposed: a `.unreadable(\"read N of M bytes\")` outcome for seen ≠ size when the before/after stamps agree.") {
                #expect(job.totals[.unreadable] == 1, "\(job.totals.line)")
            }
        case .bitFlip: break
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: victim.fullPath)) == bytesBefore)
        // The run is not reported as a clean success for that file.
        #expect(job.totals.line.contains("1 of 2 hashed in full"), "\(job.totals.line)")

        let clean = await runBackfill(sb.model)
        #expect(clean.totals[.hashed] == 1 && victim.contentFixity?.digest == trueDigest(victim.fullPath), "\(clean.totals.line)")
    }

    /// LIMIT, pinned — not parked as a defect because no single-read design
    /// can do otherwise: with no reference digest, a bit flipped on the read
    /// path is the file's content as far as the reader can know. What it
    /// costs: the stored digest names bytes that do not exist. It cannot
    /// cause a delete (no other file hashes to it, and every delete path
    /// re-reads both files), and the next full read of the file exposes it.
    /// Reported for Rick + Codex: is a second read wanted before a digest is
    /// first stored?
    @Test("LIMIT — BACKFILL × bit flip: a single read with no reference stores the digest of the flipped bytes as the file's fixity")
    func backfillCannotSeeAFlip() async throws {
        let sb = try ShowAgainSandbox.make("hrf_fhb_flip"); defer { sb.cleanup() }
        let victim = try sb.record("test_hrf_victim.mov", bytes: 30_000, stage: .none)
        let fault = HashReadFault(.bitFlip, pathSuffix: "test_hrf_victim.mov", atByte: 12_000, onPass: 0)
        let job = await fault.run { await runBackfill(sb.model) }
        #expect(fault.firedCount == 1)
        print("[hash-matrix] full-hash-backfill | bitFlip | \(job.state) | \(job.totals.line)")
        let stored = try #require(victim.contentFixity)
        var flipped = try Data(contentsOf: URL(fileURLWithPath: victim.fullPath))
        flipped[12_000] ^= 0x01
        #expect(stored.digest == SHA256.hash(data: flipped).map { String(format: "%02x", $0) }.joined())
        #expect(stored.digest != trueDigest(victim.fullPath), "the stored fixity does not describe the file")
        #expect(job.totals[.hashed] == 1, "and the run calls it hashed in full: \(job.totals.line)")
        // The stamp still describes the file, so every stamp-trusting reader believes the digest.
        #expect(stored.describesFileNow(FileIdentityStamp.capture(path: victim.fullPath)))
    }

    // MARK: Bind Fixity to Volume

    private struct BindRig {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
        let record: VideoRecord
        let legacy: ContentFixity
        let digest: String
    }

    /// One record whose stored fixity is true but pre-UUID (no volume
    /// identity) — exactly what Bind Fixity re-reads.
    private func bindRig(_ label: String) throws -> BindRig {
        let sb = try MasterArchiveTestSupport.makeSandbox("hrf_bind_\(label)")
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.scanTargets = []
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        let url = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_hrf_bind.mov"),
                                                         bytes: 30_000, seed: 77)
        let digest = trueDigest(url.path)
        let fx = try #require(ContentFixity.captured(path: url.path, digest: digest, byteCount: 30_000))
        let s = fx.stamp
        let legacy = ContentFixity(algorithm: fx.algorithm, digest: fx.digest, byteCount: fx.byteCount,
                                   stamp: FileIdentityStamp(device: s.device &+ 7, inode: s.inode, size: s.size,
                                                            mtimeNs: s.mtimeNs, ctimeNs: s.ctimeNs, volumeUUID: nil),
                                   computedAt: fx.computedAt)
        let rec = MasterArchiveTestSupport.makeRecord(path: url.path)
        rec.contentFixity = legacy
        model.records = [rec]
        return BindRig(sb: sb, model: model, record: rec, legacy: legacy, digest: digest)
    }

    private func runBind(_ r: BindRig) async -> BindFixityToVolumeJob {
        let job = BindFixityToVolumeJob(scopePath: r.sb.sources.path, scopeLabel: "Scratch", model: r.model)
        job.start()
        await job.task?.value
        return job
    }

    @Test("BIND × {EIO, short read}: nothing is bound, the old fixity stays exactly as it was (still untrusted), the tally and summary say why; a clean run then binds the true digest",
          .timeLimit(.minutes(2)), arguments: [HashReadFault.Kind.eio, .shortRead])
    func bindStoresNothingFromAFailedRead(_ kind: HashReadFault.Kind) async throws {
        let r = try bindRig("\(kind)"); defer { r.sb.cleanup() }
        let fault = HashReadFault(kind, pathSuffix: "test_hrf_bind.mov", atByte: 12_000, onPass: 0)
        let job = await fault.run { await runBind(r) }
        #expect(fault.firedCount == 1, "\(kind): the fault never reached the read")
        print("[hash-matrix] bind-fixity | \(kind) | \(job.state) | \(job.summaryLine)")

        #expect(r.record.contentFixity == r.legacy, "\(kind): the fixity was rewritten from a failed read")
        #expect(job.tally.bound == 0 && job.storedCount == 0 && job.tally.digestChanged == 0, "\(job.tally)")
        switch kind {
        case .eio: #expect(job.tally.unreadable == 1 && job.summaryLine.contains("1 unreadable"), "\(job.summaryLine)")
        case .shortRead: #expect(job.tally.changedDuringRead == 1 && job.summaryLine.contains("1 changed during the read"), "\(job.summaryLine)")
        case .bitFlip: break
        }
        #expect(trueDigest(r.record.fullPath) == r.digest)
        #expect(r.model.fixityRebindCandidates(prefix: r.sb.sources.path).map(\.id) == [r.record.id], "still waiting to be bound")

        let clean = await runBind(r)
        #expect(clean.tally.bound == 1 && clean.tally.digestChanged == 0, "\(clean.summaryLine)")
        #expect(r.record.contentFixity?.digest == r.digest && r.record.contentFixity?.stamp.volumeUUID != nil)
    }

    /// Bind HAS a reference (the digest it is re-binding), and a flipped read
    /// disagrees with it — yet the job stores the new digest over the old,
    /// true one and counts the file as bound. It says so ("held different
    /// bytes than before"), but the catalog now carries a digest of bytes
    /// that are not on disk, under a fresh volume-bound stamp that every
    /// stamp-trusting reader accepts unread.
    @Test("BIND × bit flip: the read disagrees with the stored digest — the true digest must not be replaced on the strength of ONE disagreeing read")
    func bindOverwritesATrueDigestOnOneDisagreeingRead() async throws {
        let r = try bindRig("flip"); defer { r.sb.cleanup() }
        let fault = HashReadFault(.bitFlip, pathSuffix: "test_hrf_bind.mov", atByte: 12_000, onPass: 0)
        let job = await fault.run { await runBind(r) }
        #expect(fault.firedCount == 1)
        print("[hash-matrix] bind-fixity | bitFlip | \(job.state) | \(job.summaryLine)")
        // It is at least SAID: the disagreement is counted and in the summary.
        #expect(job.tally.digestChanged == 1 && job.summaryLine.contains("1 held different bytes than before"), "\(job.summaryLine)")
        #expect(trueDigest(r.record.fullPath) == r.digest, "the file itself never changed")
        withKnownIssue("PARKED 2026-11-20 (P2, integrity): Bind Fixity replaces a stored digest with the digest of ONE read that disagrees with it (applyFixityRebind → .digestChanged, still written and counted as bound). A flip on the read path therefore overwrites a TRUE digest with a false one under a volume-bound stamp. No media moves. Proposed: on disagreement read the file a second time; store only if the two fresh reads agree, else leave the old fixity and report \"read twice, the reads disagree\".") {
            #expect(r.record.contentFixity?.digest == r.digest, "the true digest was replaced by \(r.record.contentFixity?.digest.prefix(12) ?? "nil")…")
        }
    }
}
