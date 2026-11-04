// AudioFingerprintStampDurabilityTests.swift
// GH #416 (P1, 2026-11-03): "Fingerprint sound" stamped the same 50 archived
// files every run and none reached catalog.sqlite's `sound_prints`.
//
// Root cause: the planner keyed a record's stamp on `contentFixity` only. A
// row whose whole-file digest is its ARCHIVE fixity (`files.digest_source =
// archiveFixity` — every archive copy re-minted by the 10/22 FamilyArchive
// rescan) loads with no `contentFixity`, so the stamp was keyed on the
// sampled "v1:" hash. `sound_prints` binds only a sha256 key, so the commit
// saw no change ("unchanged"), and the stamp lived in memory until quit.
// Worse, when the content's print WAS stored (its original copy), the
// loaded stamp (sha256) no longer "described" the row (preferred digest
// v1), the row was redone, and its v1 stamp's commit DELETED the print.
//
// Every case runs the REAL job (stub decode) through the REAL save
// (`saveCatalogAcknowledged` → the committer → catalog.sqlite), then
// relaunches the store and reads `sound_prints`, the reloaded stamp and the
// next plan. Sandbox only (CutoverScene); no real volume.
//   LOGIC      the planner's preferred digest is the stored whole-file hash,
//              content or archive fixity — the Integrity tier's rule
//              (`VideoScanModel.storedFullDigest`).
//   TRUTH      after relaunch the stamp shown is the sha256 one from the store.
//   ISOLATION  the two-rows-one-digest shapes (archive copy + original, both
//              live; original purged) — the production shape of #416.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// A printable stub print (landmarks > 0), as long as the catalog says.
private let printablePass: AudioFingerprintBackfillJob.Pass = { item in
    let n = 64
    return AudioFingerprint(sampleRate: 8_000, hopSamples: 512, frameSize: 1_024, durationSeconds: item.durationSeconds,
                            complete: true, hashes: (0..<n).map { UInt32($0) &* 2_654_435_761 &+ 7 },
                            times: (0..<n).map { UInt32($0 * 2) })
}

@MainActor
private enum StampScene {

    /// The real job, stub decode, PRODUCTION save (no save seam).
    static func run(_ model: VideoScanModel) async -> AudioFingerprintBackfillJob {
        let job = AudioFingerprintBackfillJob(model: model)
        job.volumeOnline = { _ in true }
        job.tickMilliseconds = 20
        job.passForTesting = printablePass
        job.ffmpegPath = "/bin/ls"   // the stubbed pass never runs ffmpeg; any executable passes the preflight
        job.start()
        await job.task?.value
        return job
    }

    /// Every `sound_prints.digest` in the scene's catalog.sqlite (a second
    /// read handle, opened and closed here).
    static func soundPrintDigests(_ scene: CutoverScene) async throws -> Set<String> {
        let repository = GRDBCatalogRepository(host: "stamp-test")
        _ = await repository.open(at: scene.databaseURL)
        do {
            let digests = try await repository.read { reader -> Set<String> in
                var out: Set<String> = []
                try reader.soundPrintDigests { out.insert($0) }
                return out
            }
            await repository.close()
            return digests
        } catch {
            await repository.close()
            throw error
        }
    }

    /// An original copy (contentFixity) and its archive copy (archiveFixity
    /// only, promoted from it) of the same bytes, both committed.
    static func originalAndArchive(_ scene: CutoverScene, label: String)
        throws -> (original: VideoRecord, archive: VideoRecord, digest: String) {
        let media = scene.folder.appendingPathComponent("media", isDirectory: true)
        let archiveDir = media.appendingPathComponent("Archive", isDirectory: true)
        let copyDir = media.appendingPathComponent("copies", isDirectory: true)
        for dir in [archiveDir, copyDir] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let size = 48 * 1024
        let originalURL = try MasterArchiveTestSupport.writeBlob(at: copyDir.appendingPathComponent("\(label).mov"),
                                                                 bytes: size, seed: 416)
        let archiveURL = archiveDir.appendingPathComponent("\(label)-archive.mov")
        try FileManager.default.copyItem(at: originalURL, to: archiveURL)
        let digest = try scene.sha256(originalURL)

        let original = try scene.freshCopy(of: .healthy, path: originalURL.path)
        let archive = try scene.freshCopy(of: .healthy, path: archiveURL.path)
        for r in [original, archive] {
            r.sizeBytes = Int64(size)
            r.audioFingerprint = nil
            r.audioCodec = "aac"
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.durationSeconds = 60
        }
        original.contentHash = "v1:\(label)-original"
        archive.contentHash = "v1:\(label)-archive"
        original.contentFixity = ContentFixity.captured(path: originalURL.path, digest: digest, byteCount: Int64(size))
        archive.derivationKind = VideoRecord.archivePromotionDerivationKind
        archive.archiveFixity = ArchiveFixity(digest: digest, verifiedAt: Date(), sizeBytes: Int64(size))
        archive.derivedFrom = original.id     // the store requires an archive copy to name a stored source
        scene.model.records.append(original)
        try #require(scene.model.saveCatalogNow(), "fixture: the original is in catalog.sqlite")
        scene.model.records.append(archive)
        try #require(scene.model.saveCatalogNow(), "fixture: the archive copy is in catalog.sqlite")
        return (original, archive, digest)
    }

    static func planned(_ model: VideoScanModel) -> Set<UUID> {
        Set(model.audioFingerprintBackfillPlan().lanes.flatMap(\.items).map(\.id))
    }
}

@Suite("Fingerprint sound — #416: stamps reach catalog.sqlite and survive a relaunch", .serialized)
@MainActor
struct AudioFingerprintStampDurabilityTests {

    @Test("LOGIC: an archive copy's preferred digest is its archive fixity's SHA-256 (the row's stored whole-file hash), then the sampled hash")
    func archiveFixityIsThePreferredDigest() {
        let r = VideoRecord()
        r.fullPath = "/Volumes/FamilyArchive/a.mov"
        r.sizeBytes = 2_000
        r.contentHash = "v1:a"
        r.archiveFixity = ArchiveFixity(digest: String(repeating: "A", count: 64), verifiedAt: Date(), sizeBytes: 2_000)
        #expect(AudioFingerprintBackfillPlanner.digests(of: r) == ["sha256:" + String(repeating: "a", count: 64), "v1:a"])
        // An archive fixity of another size is not this file's hash.
        r.archiveFixity = ArchiveFixity(digest: String(repeating: "a", count: 64), verifiedAt: Date(), sizeBytes: 1_999)
        #expect(AudioFingerprintBackfillPlanner.digests(of: r) == ["v1:a"])
    }

    @Test("RED Codex #216 P1: content and archive fixities that DISAGREE give no full-digest key (either size), as the commit refuses them; the run shares nothing and keeps no sidecar row under either hash")
    func disagreeingFixitiesGiveNoFullKey() async throws {
        let sb = try ShowAgainSandbox.make("afb416_disagree"); defer { sb.cleanup() }
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        let r = try sb.record("disputed.mov", bytes: 2_000, onDisk: true, stage: .none)
        r.contentHash = "v1:x"
        r.durationSeconds = 60
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.audioCodec = "aac"
        r.archiveFixity = ArchiveFixity(digest: a, verifiedAt: Date(), sizeBytes: 2_000)
        for contentBytes in [Int64(1_999), 2_000] {
            r.contentFixity = ContentFixity(digest: b, byteCount: contentBytes,
                                            stamp: FileIdentityStamp(device: 1, inode: 2, size: contentBytes, mtimeNs: 3))
            #expect(AudioFingerprintBackfillPlanner.digests(of: r) == ["v1:x"],
                    "content fixity over \(contentBytes) bytes vs archive fixity: \(AudioFingerprintBackfillPlanner.digests(of: r))")
        }
        // A sidecar row for one of the two hashes must not be shared to it.
        let store = try AudioFingerprintStore(directory: sb.catalogDir)
        let other = try await printablePass(AudioFingerprintBackfillItem(id: UUID(), path: "/x", filename: "x", sizeBytes: 2_000,
                                                                         durationSeconds: 60, isVideoOnly: false, audioCodec: "aac",
                                                                         isArchived: false, digests: ["sha256:" + a]))
        try store.put([AudioFingerprintStore.Entry(key: .init(contentDigest: "sha256:" + a, sizeBytes: 2_000), fingerprint: other,
                                                   sourcePath: "/elsewhere/a.mov", computedAt: Date())])
        let job = await StampScene.run(sb.model)
        #expect(job.totals[.shared] == 0, Comment(rawValue: job.totals.line))
        #expect(r.audioFingerprint?.contentDigest == "v1:x", "stamped under the sampled hash only: \(r.audioFingerprint?.contentDigest ?? "nil")")
        #expect(try !AudioFingerprintStore(directory: sb.catalogDir).has(.init(contentDigest: "sha256:" + b, sizeBytes: 2_000)),
                "no sidecar row under the disputed content hash")
    }

    @Test("RED #416 (production shape): an archive copy whose original was purged — its stamp lands in sound_prints, survives a relaunch, and the next plan has nothing to do")
    func archiveCopyStampSurvivesRelaunch() async throws {
        let scene = try CutoverScene.make("afb416_purged"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let (original, archive, digest) = try StampScene.originalAndArchive(scene, label: "cape1993")
        // The 10/22 rescan shape: the original's row is purged, the archive copy stays.
        scene.model.records.removeAll { $0.id == original.id }
        scene.model.purgeCatalogRows(ids: [original.id], reason: "rescan replaced")
        try #require(scene.model.saveCatalogNow())
        try await scene.relaunch()
        let loaded = try #require(scene.model.records.first { $0.id == archive.id })
        try #require(loaded.contentFixity == nil && loaded.archiveFixity != nil, "fixture: the row's digest is its archive fixity")
        try #require(StampScene.planned(scene.model).contains(archive.id), "fixture: no stamp yet — planned")

        let job = await StampScene.run(scene.model)
        #expect(!job.saveFailed && job.saveCount >= 1, Comment(rawValue: job.totals.line))

        try await scene.relaunch()
        let prints = try await StampScene.soundPrintDigests(scene)
        #expect(prints.contains(digest), "sound_prints holds the archive copy's print after relaunch — \(prints.count) row(s)")
        let reloaded = try #require(scene.model.records.first { $0.id == archive.id })
        #expect(reloaded.audioFingerprint?.contentDigest == "sha256:" + digest,
                "the reloaded stamp: \(reloaded.audioFingerprint?.contentDigest ?? "nil")")
        #expect(!StampScene.planned(scene.model).contains(archive.id), "the next run does not read it again")
    }

    @Test("RED #416 (two rows, one digest): the original's stored print is not deleted by its archive copy, and neither is planned again")
    func archiveCopyDoesNotDeleteTheOriginalsPrint() async throws {
        let scene = try CutoverScene.make("afb416_both"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let (original, archive, digest) = try StampScene.originalAndArchive(scene, label: "kids2004")
        // The original was fingerprinted earlier (its stamp is in sound_prints).
        original.audioFingerprint = AudioFingerprintStamp(contentDigest: "sha256:" + digest, sizeBytes: original.sizeBytes,
                                                          outcome: .fingerprinted, analyzedSeconds: 60, complete: true,
                                                          landmarks: 64, bytes: 512)
        try #require(scene.model.saveCatalogNow())
        try await scene.relaunch()
        try #require(try await StampScene.soundPrintDigests(scene).contains(digest), "fixture: the print is stored")
        let loaded = try #require(scene.model.records.first { $0.id == archive.id })
        #expect(loaded.audioFingerprint?.contentDigest == "sha256:" + digest, "the archive copy loads the content's print")
        let before = StampScene.planned(scene.model)
        #expect(!before.contains(archive.id) && !before.contains(original.id),
                "both copies carry a current stamp — nothing to read (archive planned: \(before.contains(archive.id)))")

        _ = await StampScene.run(scene.model)
        try await scene.relaunch()
        #expect(try await StampScene.soundPrintDigests(scene).contains(digest), "the content's print is still in sound_prints")
        let after = StampScene.planned(scene.model)
        #expect(!after.contains(archive.id) && !after.contains(original.id), "still nothing to read after a run and a relaunch")
    }
}
