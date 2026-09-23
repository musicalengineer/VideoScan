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
//   • the old-stamp upgrade pass upgrades ONLY what it can prove, is
//     compare-and-set, respects read-only, and is idempotent;
//   • scale: 100k records / 100k captures under budget;
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

@Suite("Fixity stamp volume identity — consumers and upgrade pass", .serialized)
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
        #expect(fresh == [remount], "remount fresh; other disk stale; legacy stays stale until upgraded")
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

    // MARK: The upgrade pass

    @Test func upgradePassBindsOnlyProvenLegacyStampsAndIsIdempotent() async throws {
        let r = try rig("pass"); defer { r.sb.cleanup() }
        let realUUID = try #require(VolumeIdentity.uuid(forPath: r.sb.sources.path))
        func legacyRecord(_ name: String, seed: UInt64, scanUUID: String,
                          mutate: (FileIdentityStamp) -> FileIdentityStamp) throws -> VideoRecord {
            let (url, fx) = try r.file(name, seed: seed)
            let rec = MasterArchiveTestSupport.makeRecord(path: url.path)
            rec.sizeBytes = 4_096
            rec.scanContext.volumeUUID = scanUUID
            rec.scanContext.volumeName = "Scratch"
            rec.contentFixity = withStamp(fx, mutate(remounted(fx.stamp, keepUUID: false)))
            return rec
        }
        let proven = try legacyRecord("proven.mov", seed: 1, scanUUID: realUUID.lowercased()) { $0 }
        let otherScan = try legacyRecord("otherscan.mov", seed: 2, scanUUID: otherDiskUUID) { $0 }
        let noScan = try legacyRecord("noscan.mov", seed: 3, scanUUID: "") { $0 }
        let changed = try legacyRecord("changed.mov", seed: 4, scanUUID: realUUID) {
            FileIdentityStamp(device: $0.device, inode: $0.inode, size: $0.size, mtimeNs: $0.mtimeNs, ctimeNs: $0.ctimeNs &- 1)
        }
        let offline = MasterArchiveTestSupport.makeRecord(path: r.sb.sources.appendingPathComponent("gone.mov").path)
        offline.scanContext.volumeUUID = realUUID
        offline.contentFixity = withStamp(proven.contentFixity!, proven.contentFixity!.stamp)
        let (bURL, bound) = try r.file("bound.mov", seed: 5)
        let alreadyBound = MasterArchiveTestSupport.makeRecord(path: bURL.path)
        alreadyBound.contentFixity = bound
        r.model.records = [proven, otherScan, noScan, changed, offline, alreadyBound]
        let before = r.model.records.map(\.contentFixity)
        #expect(proven.contentFixity?.describesFileNow(FileIdentityStamp.capture(path: proven.fullPath)) == false,
                "precondition: today's bug — the remounted legacy stamp is stale")

        let report = await r.model.upgradeLegacyFixityStampsNow(trigger: "test")
        #expect(report.candidates == 5)
        #expect(report.written == 1)
        #expect(report.upgradedByVolume == ["Scratch": 1])
        #expect(report.notUpgradedByVolume["Scratch"] == [.volumeNotProven: 2, .fileChanged: 1])
        let offlineLabel = VideoScanModel.fixityVolumeLabel(forPath: offline.fullPath)
        #expect(report.notUpgradedByVolume[offlineLabel] == [.offline: 1])
        let up = try #require(proven.contentFixity)
        #expect(up.stamp.volumeUUID == realUUID && up.digest == before[0]?.digest && up.computedAt == before[0]?.computedAt)
        #expect(up.describesFileNow(FileIdentityStamp.capture(path: proven.fullPath)))
        for (i, rec) in r.model.records.enumerated() where rec !== proven {
            #expect(rec.contentFixity == before[i], "\(rec.filename) must be left exactly as it was")
        }
        // Idempotent: the upgraded record is no longer a candidate; the rest
        // are re-examined and still refused.
        let again = await r.model.upgradeLegacyFixityStampsNow(trigger: "test")
        #expect(again.candidates == 4 && again.written == 0)
        // And the consumer sees it: Archive Angel lends from it now.
        let probes = ArchiveAngelFixityCheck.probes(for: [proven])
        #expect(await ArchiveAngelFixityCheck.fresh(probes) == [proven.id])
    }

    @Test func upgradePassWritesNothingOnAReadOnlyCatalog() async throws {
        let r = try rig("readonly"); defer { r.sb.cleanup() }
        let (url, fx) = try r.file("a.mov")
        let rec = MasterArchiveTestSupport.makeRecord(path: url.path)
        rec.scanContext.volumeUUID = fx.stamp.volumeUUID ?? ""
        let legacy = withStamp(fx, remounted(fx.stamp, keepUUID: false))
        rec.contentFixity = legacy
        r.model.records = [rec]
        r.model.isReadOnly = true
        let report = await r.model.upgradeLegacyFixityStampsNow(trigger: "test")
        #expect(report.written == 0 && rec.contentFixity == legacy)
    }

    @Test func writeBackIsCompareAndSet() throws {
        let r = try rig("cas"); defer { r.sb.cleanup() }
        let (url, fx) = try r.file("a.mov")
        let rec = MasterArchiveTestSupport.makeRecord(path: url.path)
        let legacy = withStamp(fx, remounted(fx.stamp, keepUUID: false))
        rec.contentFixity = legacy
        r.model.records = [rec]
        let item = FixityStampUpgradeItem(id: rec.id, path: rec.fullPath, fixity: legacy,
                                          recordVolumeUUID: fx.stamp.volumeUUID ?? "", volumeLabel: "Scratch")
        let outcome = legacy.upgradedToVolumeIdentity(current: fx.stamp, recordVolumeUUID: item.recordVolumeUUID)
        guard case .upgraded = outcome else { Issue.record("precondition: provable"); return }
        // A job re-read the file meanwhile and stored a newer fixity.
        rec.contentFixity = fx
        var report = FixityStampUpgradeReport()
        r.model.applyFixityStampUpgrades([(item, outcome)], into: &report)
        #expect(report.written == 0 && report.skippedAtWrite == 1)
        #expect(rec.contentFixity == fx, "the newer fixity is never overwritten")
    }

    // MARK: Scale

    /// 100k records (a few real files, many rows): the main-actor
    /// snapshot and the off-main stat pass both under budget.
    @Test func upgradePassScalesToAHundredThousandRecords() async throws {
        let r = try rig("scale"); defer { r.sb.cleanup() }
        var files: [(URL, ContentFixity)] = []
        for i in 0..<8 { files.append(try r.file("f\(i).mov", seed: UInt64(i + 1))) }
        let uuid = files[0].1.stamp.volumeUUID ?? ""
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let (url, fx) = files[i % files.count]
            let rec = MasterArchiveTestSupport.makeRecord(path: url.path)
            rec.scanContext.volumeUUID = uuid
            rec.contentFixity = withStamp(fx, remounted(fx.stamp, keepUUID: false))
            recs.append(rec)
        }
        r.model.records = recs
        let clock = ContinuousClock()
        var items: [FixityStampUpgradeItem] = []
        let snap = clock.measure { items = r.model.legacyFixityStampItems() }
        #expect(items.count == 100_000)
        #expect(snap < .seconds(1), "main-actor snapshot \(snap)")
        let start = clock.now
        let results = await VideoScanModel.computeFixityStampUpgrades(items)
        let pass = clock.now - start
        #expect(results.allSatisfy { if case .upgraded = $0.outcome { return true } else { return false } })
        #expect(pass < .seconds(10), "off-main stat pass \(pass)")
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
        #expect(job.contains("recorded.describesSameFile(now: current, changeTime: .mustMatch, legacyVolume: .notCompared)"))
        let check = try String(contentsOf: Self.projectDir.appendingPathComponent(
            "VideoScan/ArchiveAngel/Promote/ArchiveAngelFixityCheck.swift"), encoding: .utf8)
        #expect(check.contains("p.fixity.describesFileNow(FileIdentityStamp.capture(path: p.path))"))
    }
}
