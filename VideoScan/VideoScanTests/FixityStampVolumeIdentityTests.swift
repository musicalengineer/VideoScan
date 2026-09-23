// FixityStampVolumeIdentityTests.swift
// App-level tests for the 2026-09-23 fixity-stamp volume identity fix
// (rule + rationale: VideoScanCore/ContentFixity.swift header; the pass:
// VideoScanModel+FixityStampUpgrade.swift).
//
// Found while calibrating Find Similar Footage: 1,429 of 1,493 stamps on
// Rick's catalog failed `describesFileNow` ONLY on st_dev (a remount).
// Here, for every consumer that decides with a stored stamp:
//   • the remount is simulated exactly as it happens — same file, same
//     volume UUID, a different st_dev — and must now count as fresh;
//   • a different disk (another UUID) must stay stale;
//   • a legacy stamp (no UUID) is untrusted everywhere until ONE full
//     re-read binds it (codex #1707) — the rehash engine refuses a remount,
//     a missing UUID or a retarget mid-read; the Bind Fixity to Volume job
//     binds, pauses (gives the disk back), is compare-and-set, respects
//     read-only, and is resumable by construction;
//   • scale: 100k records under budget;
//   • sensor: no app code compares a stored stamp's device number for
//     freshness outside the one comparison.
//
// Real temp files, real SHA-256, real stat stamps; the "other disk" is a
// stamp carrying another UUID or the task-local resolver seam.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let otherDiskUUID = "0978904A-3D3C-4546-BC51-5A53F32BCB23"

/// The same file after a remount: every field equal, st_dev different.
private func remounted(_ s: FileIdentityStamp, keepUUID: Bool = true) -> FileIdentityStamp {
    FileIdentityStamp(device: s.device &+ 7, inode: s.inode, size: s.size, mtimeNs: s.mtimeNs,
                      ctimeNs: s.ctimeNs, volumeUUID: keepUUID ? s.volumeUUID : nil)
}

private func onOtherDisk(_ s: FileIdentityStamp) -> FileIdentityStamp {
    FileIdentityStamp(device: s.device, inode: s.inode, size: s.size, mtimeNs: s.mtimeNs,
                      ctimeNs: s.ctimeNs, volumeUUID: otherDiskUUID)
}

private func withStamp(_ f: ContentFixity, _ s: FileIdentityStamp) -> ContentFixity {
    ContentFixity(algorithm: f.algorithm, digest: f.digest, byteCount: f.byteCount, stamp: s, computedAt: f.computedAt)
}

@Suite("Fixity stamp volume identity — consumers, rehash, Bind Fixity to Volume", .serialized)
@MainActor
struct FixityStampVolumeIdentityTests {

    private struct Rig {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
        func file(_ name: String, seed: UInt64 = 1) throws -> (URL, ContentFixity) {
            let url = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent(name), bytes: 4_096, seed: seed)
            let digest = try #require(MasterArchiveTestSupport.sha256(ofFile: url.path))
            let fx = try #require(ContentFixity.captured(path: url.path, digest: digest, byteCount: 4_096))
            return (url, fx)
        }
    }

    private func rig(_ label: String) throws -> Rig {
        let sb = try MasterArchiveTestSupport.makeSandbox("fixvol_\(label)")
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.scanTargets = []
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        return Rig(sb: sb, model: model)
    }

    // MARK: Consumers

    @Test func archiveAngelAndFootageTreatARemountAsFreshAndAnotherDiskAsStale() async throws {
        let r = try rig("angel"); defer { r.sb.cleanup() }
        let (a, fx) = try r.file("a.bin")
        #expect(fx.stamp.volumeUUID != nil, "new stamps carry the volume UUID")
        let remount = UUID(), other = UUID(), legacy = UUID()
        let fresh = await ArchiveAngelFixityCheck.fresh([
            .init(id: remount, path: a.path, fixity: withStamp(fx, remounted(fx.stamp))),
            .init(id: other, path: a.path, fixity: withStamp(fx, onOtherDisk(remounted(fx.stamp)))),
            .init(id: legacy, path: a.path, fixity: withStamp(fx, remounted(fx.stamp, keepUUID: false))),
        ])
        #expect(fresh == [remount], "remount fresh; other disk stale; legacy untrusted until re-read")
        // Find Similar Footage goes through the same probe + check.
        let rec = MasterArchiveTestSupport.makeRecord(path: a.path)
        rec.contentFixity = withStamp(fx, remounted(fx.stamp))
        let probe = try #require(VideoScanModel.footageFixityProbe(rec))
        #expect(await VideoScanModel.footageCurrentDigests([probe]) == [rec.id])
    }

    @Test func deleteDuplicatesCountsARemountedSiblingButNotAnotherDisk() throws {
        let r = try rig("gather"); defer { r.sb.cleanup() }
        let (_, keeper) = try r.file("k.mov")
        let (sib, fx) = try r.file("sib.mov")
        var c = DeletionTierCandidates()
        c.keeperLabel = "keeper"; c.keeperPath = r.sb.sources.appendingPathComponent("k.mov").path
        _ = keeper
        c.otherCopies = [.init(path: sib.path, fixity: withStamp(fx, remounted(fx.stamp)), label: "sibling sib.mov")]
        let counted = DeletionTierFacts.gather(c, digest: fx.digest)
        #expect(counted.remainingVerifiedCopies == 2, "\(counted.summary)")
        c.otherCopies = [.init(path: sib.path, fixity: withStamp(fx, onOtherDisk(fx.stamp)), label: "sibling sib.mov")]
        let refused = DeletionTierFacts.gather(c, digest: fx.digest)
        #expect(refused.remainingVerifiedCopies == 1)
        #expect(refused.notCounted == ["sibling sib.mov changed since it was verified"])
        // The resolver seam: the SAME stored stamp, but the disk at that
        // path now answers another UUID — a swapped drive.
        c.otherCopies = [.init(path: sib.path, fixity: fx, label: "sibling sib.mov")]
        let swapped = VolumeIdentity.$resolverOverride.withValue({ _ in otherDiskUUID }) {
            DeletionTierFacts.gather(c, digest: fx.digest)
        }
        #expect(swapped.remainingVerifiedCopies == 1)
    }

    @Test func storedKeeperFixityStandsInForTheReadAcrossARemount() throws {
        let r = try rig("keeper"); defer { r.sb.cleanup() }
        let (k, fx) = try r.file("k.mov", seed: 7)
        let d = r.sb.sources.appendingPathComponent("d.mov")
        try FileManager.default.copyItem(at: k, to: d)
        final class Reads: @unchecked Sendable { var keeper = 0 }
        let reads = Reads()
        var hooks = SignatureVerification.Hooks.live
        hooks.didReadBlock = { if $0 == "keeper" { reads.keeper += 1 } }
        let proof = try SignatureVerification.verifyAgainstStoredKeeper(
            keeperPath: k.path, keeperFixity: withStamp(fx, remounted(fx.stamp)), duplicatePath: d.path, hooks: hooks).get()
        #expect(proof.keeperReadInFull == false && reads.keeper == 0, "the remount no longer forces a keeper re-read")
        reads.keeper = 0
        let reread = try SignatureVerification.verifyAgainstStoredKeeper(
            keeperPath: k.path, keeperFixity: withStamp(fx, onOtherDisk(fx.stamp)), duplicatePath: d.path, hooks: hooks).get()
        #expect(reread.keeperReadInFull == true && reads.keeper > 0, "another disk's stamp is never trusted")
    }

    @Test func resumeAndQuarantineIdentityHonourTheVolumeUUID() throws {
        let r = try rig("resume"); defer { r.sb.cleanup() }
        let (_, fx) = try r.file("q.mov")
        let now = fx.stamp
        #expect(DeleteDuplicatesJob.quarantineIdentityMatches(recorded: remounted(now), current: now))
        #expect(DeleteDuplicatesJob.keeperUnchangedAcrossRemount(planned: remounted(now), current: now))
        #expect(DeleteDuplicatesJob.keeperUnchangedAcrossRemount(planned: remounted(now, keepUUID: false), current: now),
                "a plan written before the fix keeps its device-blind rule")
        #expect(!DeleteDuplicatesJob.quarantineIdentityMatches(recorded: onOtherDisk(now), current: now))
        #expect(!DeleteDuplicatesJob.keeperUnchangedAcrossRemount(planned: onOtherDisk(now), current: now),
                "a different disk at the keeper's path is not the planned keeper")
    }

    // MARK: Legacy stamps are untrusted until re-read (codex #1707)

    @Test func legacyStampIsUntrustedEverywhereUntilRebound() async throws {
        let r = try rig("legacy"); defer { r.sb.cleanup() }
        let (url, fx) = try r.file("a.mov")
        let rec = MasterArchiveTestSupport.makeRecord(path: url.path)
        rec.sizeBytes = 4_096
        // The pre-fix stamp of THIS file on THIS mount — same device even.
        rec.contentFixity = withStamp(fx, FileIdentityStamp(device: fx.stamp.device, inode: fx.stamp.inode,
                                                            size: fx.stamp.size, mtimeNs: fx.stamp.mtimeNs,
                                                            ctimeNs: fx.stamp.ctimeNs))
        r.model.records = [rec]
        #expect(rec.contentFixity?.isUsableForVerification == false)
        #expect(ArchiveAngelFixityCheck.probes(for: [rec]).isEmpty, "Angel: not even a candidate")
        #expect(VideoScanModel.footageFixityProbe(rec) == nil, "Footage: never Identical on it")
        var c = DeletionTierCandidates()
        c.otherCopies = [.init(path: url.path, fixity: rec.contentFixity, label: "sibling a.mov")]
        #expect(DeletionTierFacts.gather(c, digest: fx.digest).remainingVerifiedCopies == 1)
        #expect(DeleteDuplicatesJob.siblingsThatMayNeedReading(c, keeperDigest: nil, goal: 2) == [url.path],
                "Delete Duplicates plans a proving read for it")

        let job = BindFixityToVolumeJob(scopePath: r.sb.sources.path, scopeLabel: "Scratch", model: r.model)
        job.start(); await job.task?.value
        #expect(job.tally.bound == 1, "\(job.summaryLine)")
        let bound = try #require(rec.contentFixity)
        #expect(bound.stamp.volumeUUID != nil && bound.digest == fx.digest)
        #expect(await ArchiveAngelFixityCheck.fresh(ArchiveAngelFixityCheck.probes(for: [rec])) == [rec.id])
    }

    // MARK: The rehash engine

    @Test func rehashBindsWithMatchingDigestAndUUID() throws {
        let r = try rig("rehash"); defer { r.sb.cleanup() }
        let (url, fx) = try r.file("a.mov", seed: 3)
        guard case .bound(let got) = FixityRebind.rehash(path: url.path, control: .init()) else {
            Issue.record("expected a binding"); return
        }
        #expect(got.digest == fx.digest && got.byteCount == 4_096)
        #expect(got.stamp == fx.stamp, "the stamp of the very file, volume UUID included")
        #expect(got.describesFileNow(FileIdentityStamp.capture(path: url.path)))
    }

    /// A remount between the before-capture and the after-capture (the
    /// resolver answers another UUID the second time) — refused.
    @Test func remountDuringTheReadRefuses() throws {
        let r = try rig("remount"); defer { r.sb.cleanup() }
        let (url, _) = try r.file("a.mov")
        let real = try #require(VolumeIdentity.uuid(forPath: url.path))
        final class Calls: @unchecked Sendable { var n = 0; let lock = NSLock() }
        let calls = Calls()
        let flip: @Sendable (String) -> String? = { _ in
            calls.lock.withLock { calls.n += 1; return calls.n == 1 ? real : otherDiskUUID }
        }
        let outcome = VolumeIdentity.$resolverOverride.withValue(flip) {
            FixityRebind.rehash(path: url.path, control: .init())
        }
        #expect(outcome == .changedDuringRead("changed during the read (volume)"), "\(outcome)")
    }

    @Test func rehashRefusesWithoutAVolumeUUIDAndReportsOfflineAndStop() throws {
        let r = try rig("refuse"); defer { r.sb.cleanup() }
        let (url, _) = try r.file("a.mov")
        let none = VolumeIdentity.$resolverOverride.withValue({ _ in nil }) {
            FixityRebind.rehash(path: url.path, control: .init())
        }
        #expect(none == .noVolumeIdentity)
        #expect(FixityRebind.rehash(path: url.path + ".gone", control: .init()) == .offline)
        let stop = FixityRebind.Control(); stop.requestStop()
        #expect(FixityRebind.rehash(path: url.path, control: stop) == .interrupted)
    }

    /// A symlink retargeted after the plan: the rehash binds the NEW target
    /// honestly (a fresh read of what the path names now), and the OLD
    /// stored fixity never describes it.
    @Test func symlinkRetargetNeverLendsTheOldDigest() throws {
        let r = try rig("symlink"); defer { r.sb.cleanup() }
        let (a, fxA) = try r.file("a.mov", seed: 1)
        let (b, _) = try r.file("b.mov", seed: 2)
        let link = r.sb.sources.appendingPathComponent("link.mov")
        #expect(symlink(a.path, link.path) == 0)
        let old = try #require(ContentFixity.captured(path: link.path, digest: fxA.digest, byteCount: 4_096))
        #expect(unlink(link.path) == 0 && symlink(b.path, link.path) == 0)
        #expect(!old.describesFileNow(FileIdentityStamp.capture(path: link.path)))
        guard case .bound(let now) = FixityRebind.rehash(path: link.path, control: .init()) else {
            Issue.record("expected a binding of the new target"); return
        }
        #expect(now.digest != fxA.digest)
    }

    // MARK: The job

    @Test func jobBindsTheVolumeAndIsResumableByConstruction() async throws {
        let r = try rig("job"); defer { r.sb.cleanup() }
        var recs: [VideoRecord] = []
        for i in 0..<3 {
            let (url, fx) = try r.file("f\(i).mov", seed: UInt64(i + 1))
            let rec = MasterArchiveTestSupport.makeRecord(path: url.path)
            rec.contentFixity = withStamp(fx, remounted(fx.stamp, keepUUID: false))
            recs.append(rec)
        }
        // A digest that no longer matches the bytes: stored anew, named.
        let (wURL, wfx) = try r.file("wrong.mov", seed: 9)
        let wrong = MasterArchiveTestSupport.makeRecord(path: wURL.path)
        wrong.contentFixity = ContentFixity(digest: String(repeating: "0", count: 64), byteCount: 4_096,
                                            stamp: remounted(wfx.stamp, keepUUID: false))
        let gone = MasterArchiveTestSupport.makeRecord(path: r.sb.sources.appendingPathComponent("gone.mov").path)
        gone.contentFixity = recs[0].contentFixity
        let (bURL, bfx) = try r.file("bound.mov", seed: 5)
        let already = MasterArchiveTestSupport.makeRecord(path: bURL.path)
        already.contentFixity = bfx
        r.model.records = recs + [wrong, gone, already]
        #expect(r.model.fixityRebindCandidates(prefix: r.sb.sources.path).count == 5)

        let job = BindFixityToVolumeJob(scopePath: r.sb.sources.path, scopeLabel: "Scratch", model: r.model)
        job.start(); await job.task?.value
        #expect(job.state == .finished(summary: job.summaryLine), "\(job.state)")
        #expect(job.tally.bound == 4 && job.tally.digestChanged == 1 && job.tally.offline == 1, "\(job.tally)")
        #expect(job.tally.boundBytes == 4 * 4_096)
        for rec in recs + [wrong] {
            #expect(rec.contentFixity?.describesFileNow(FileIdentityStamp.capture(path: rec.fullPath)) == true)
        }
        #expect(wrong.contentFixity?.digest == wfx.digest)
        #expect(already.contentFixity == bfx, "an already-bound fixity is never touched")
        #expect(gone.contentFixity?.stamp.volumeUUID == nil, "an offline record keeps its (untrusted) fixity")
        // Resumable by construction: only the offline one is left.
        #expect(r.model.fixityRebindCandidates(prefix: r.sb.sources.path).map(\.id) == [gone.id])
    }

    @Test func jobPauseGivesWayAndResumeFinishes() async throws {
        let r = try rig("pause"); defer { r.sb.cleanup() }
        let (url, fx) = try r.file("a.mov")
        let rec = MasterArchiveTestSupport.makeRecord(path: url.path)
        rec.contentFixity = withStamp(fx, remounted(fx.stamp, keepUUID: false))
        r.model.records = [rec]
        let job = BindFixityToVolumeJob(scopePath: r.sb.sources.path, scopeLabel: "Scratch", model: r.model)
        job.pause()
        job.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(job.state == .running && job.isPaused && rec.contentFixity?.stamp.volumeUUID == nil)
        job.resume()
        await job.task?.value
        #expect(job.tally.bound == 1 && rec.contentFixity?.stamp.volumeUUID != nil)
    }

    @Test func jobRefusesOnAReadOnlyCatalogAndAnAbsentVolume() async throws {
        let r = try rig("ro"); defer { r.sb.cleanup() }
        let (url, fx) = try r.file("a.mov")
        let rec = MasterArchiveTestSupport.makeRecord(path: url.path)
        let legacy = withStamp(fx, remounted(fx.stamp, keepUUID: false))
        rec.contentFixity = legacy
        r.model.records = [rec]
        r.model.isReadOnly = true
        let ro = BindFixityToVolumeJob(scopePath: r.sb.sources.path, scopeLabel: "Scratch", model: r.model)
        ro.start(); await ro.task?.value
        #expect(ro.wasRefused && rec.contentFixity == legacy)
        r.model.isReadOnly = false
        let away = BindFixityToVolumeJob(scopePath: "/Volumes/NotHere-\(UUID().uuidString)", scopeLabel: "NotHere", model: r.model)
        away.start(); await away.task?.value
        #expect(away.wasRefused)
    }

    @Test func writeBackIsCompareAndSet() throws {
        let r = try rig("cas"); defer { r.sb.cleanup() }
        let (url, fx) = try r.file("a.mov")
        let rec = MasterArchiveTestSupport.makeRecord(path: url.path)
        let legacy = withStamp(fx, remounted(fx.stamp, keepUUID: false))
        rec.contentFixity = legacy
        r.model.records = [rec]
        let item = try #require(r.model.fixityRebindCandidates(prefix: r.sb.sources.path).first)
        rec.contentFixity = fx          // a job re-read it meanwhile
        #expect(r.model.applyFixityRebind(item, fixity: fx) == .recordChanged)
        #expect(rec.contentFixity == fx)
    }

    // MARK: Scale

    @Test func candidateScanScalesToAHundredThousandRecords() throws {
        let r = try rig("scale"); defer { r.sb.cleanup() }
        let (url, fx) = try r.file("a.mov")
        let legacy = withStamp(fx, remounted(fx.stamp, keepUUID: false))
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let rec = MasterArchiveTestSupport.makeRecord(path: i % 2 == 0 ? url.path : "/Volumes/Other/\(i).mov")
            rec.contentFixity = i % 4 == 0 ? fx : legacy
            recs.append(rec)
        }
        r.model.records = recs
        var items: [FixityRebindItem] = []
        let elapsed = ContinuousClock().measure { items = r.model.fixityRebindCandidates(prefix: r.sb.sources.path) }
        #expect(items.count == 25_000)
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }

    // MARK: Sensor

    private static var projectDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every raw device-number comparison in app + core sources, outside
    /// the one comparison (ContentFixity.swift). Each remaining one is a
    /// SAME-INSTANT identity (two stats of one pass, or an fd vs the stat
    /// just before it) — never "is this stored stamp still true". A new
    /// site fails this until it is routed through
    /// `FileIdentityStamp.describesSameFile` / `describesFileNow` or
    /// reviewed and added here.
    @Test func noStoredStampIsComparedByDeviceNumberOutsideTheOneComparison() throws {
        let reviewed: [String: Int] = [
            // fd opened for hashing vs the stat taken just before (QA round 3).
            "VideoScan/SignatureVerification.swift": 1,
            // fd vs name identity inside one publish step.
            "VideoScan/ArchivePromoteEngine.swift": 1,
            // partial-file registry: lstat now vs the stat of the same op.
            "VideoScan/PartialFileNaming.swift": 1,
            // hard-link de-dup keys from stats of ONE gather pass.
            "VideoScan/DeleteDuplicatesPlan.swift": 1,
            "VideoScan/DeleteDuplicatesSiblingProof.swift": 1,
            // names which identity field moved, for the log line only.
            "VideoScan/FixityRebind.swift": 1,
        ]
        let pattern = try NSRegularExpression(pattern:
            #"(\.device\s*[!=]=)|([!=]=\s*[\w.()]*\.device\b)|(st_dev\)?\s*[!=]=)|([!=]=\s*[\w.()]*st_dev\b)|(\\\(\w+\.device\))"#)
        var found: [String: Int] = [:]
        let fm = FileManager.default
        for sub in ["VideoScan", "VideoScanCore/Sources/VideoScanCore"] {
            let base = Self.projectDir.appendingPathComponent(sub)
            guard let e = fm.enumerator(atPath: base.path) else { continue }
            for case let rel as String in e where rel.hasSuffix(".swift") {
                if rel.hasSuffix("ContentFixity.swift") { continue }       // the one comparison lives here
                let text = try String(contentsOf: base.appendingPathComponent(rel), encoding: .utf8)
                let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
                let n = pattern.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
                if n > 0 { found["\(sub == "VideoScan" ? "VideoScan" : "VideoScanCore")/\(rel)"] = n }
            }
        }
        #expect(found == reviewed, "device-number comparisons changed: \(found.sorted { $0.key < $1.key })")
        // The consumers really use the one comparison.
        let job = try String(contentsOf: Self.projectDir.appendingPathComponent("VideoScan/DeleteDuplicatesJob.swift"), encoding: .utf8)
        #expect(job.contains("recorded.describesSameFile(now: current, changeTime: .mustMatch, volume: .resumeAcrossRemount)"))
        let check = try String(contentsOf: Self.projectDir.appendingPathComponent(
            "VideoScan/ArchiveAngel/Promote/ArchiveAngelFixityCheck.swift"), encoding: .utf8)
        #expect(check.contains("p.fixity.describesFileNow(FileIdentityStamp.capture(path: p.path))"))
        // Terabytes of reads are Rick's decision: nothing starts the job at
        // launch or on mount (codex #1707), and no stat-only upgrade exists.
        for rel in ["VideoScan/VideoScanApp.swift", "VideoScan/VideoScanModel+VolumeLifecycle.swift", "VideoScan/VideoScanModel.swift"] {
            let text = try String(contentsOf: Self.projectDir.appendingPathComponent(rel), encoding: .utf8)
            #expect(!text.contains("startBindFixityToVolume") && !text.contains("FixityStampUpgrade"), "\(rel)")
        }
        let core = try String(contentsOf: Self.projectDir.appendingPathComponent(
            "VideoScanCore/Sources/VideoScanCore/ContentFixity.swift"), encoding: .utf8)
        #expect(!core.contains("upgradedToVolumeIdentity"))
    }
}
