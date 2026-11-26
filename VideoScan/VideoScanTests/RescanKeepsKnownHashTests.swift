// RescanKeepsKnownHashTests.swift
// REGRESSION GH #434: a rescan purges every re-seen row and writes a fresh
// record with no whole-file hash; the commit HOLDS it in pending_rows and
// Fill In Full Hashes re-reads the file in full. On 2026-11-05 every one of
// 5,395 held rows already had a row at the same path with a content digest,
// the same size and the same mtime — terabytes re-read per rescan.
//
// Fix: the probe engine stamps the file it probed (FileIdentityStamp:
// volume UUID + inode + size + mtime + ctime, one opened descriptor) and the
// merge's last-moment live pass carries the live row's ContentFixity onto
// the fresh record ONLY when `ContentFixity.describesFileNow(stamp)` — the
// persistent digest policy (DECISIONS 2026-10-26, git's racily-clean rule)
// — and the stamp's size is the probe's size. Anything else re-hashes.
// Identity stays the whole-file SHA-256 (rule 6).
//
// Red/green (before the fix → after):
//   unchangedFileKeepsItsHash ........................................ RED → green
//   anEditInsideTheDebounceWindowAndTheHashBothLand .................. RED → green
//   duringAWriteHoldNothingIsLostAndTheHashLandsAfter ................ RED → green
//   acrossAViewerFlipTheHashLandsWhenMasterAgain ..................... RED → green
//   aFileRewrittenInPlaceIsHashedAgain (truth) ....................... green → green
//   aFileReplacedAtThePathIsHashedAgain (truth) ...................... green → green
//   aStampWithNoVolumeIsNeverTrusted (truth) ......................... green → green
//   aRacilyCleanStampIsNeverTrusted (truth) .......................... green → green
//   theCarryRuleAt100kRowsFitsTheBudget (scale) ...................... green → green
//
// Dimensions: LOGIC + TRUTH (above); CATALOG WRITER — an edit inside the
// debounce window, during a write hold, across a role flip, then relaunch
// (each test ends with a relaunch read of catalog.sqlite); SCALE (100k);
// ISOLATION (sandbox catalog folder, sealed temp files); MEDIA MATRIX: N/A —
// the carry reads no media bytes and no container (a stat of the file);
// SENSOR: the production-shape run on a .backup copy is
// ProductionShapeRescanSensorTests' harness (see the commit).

import CryptoKit
import Darwin
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
@Suite("Rescan keeps a known whole-file hash only for an unchanged file (GH #434)", .serialized, .scratchCleanup)
struct RescanKeepsKnownHashTests {

    // MARK: Fixture: one real file, catalogued with its full hash

    struct Catalogued {
        let url: URL
        let record: VideoRecord
        let digest: String
        var root: String { url.deletingLastPathComponent().path }
    }

    /// A real file whose mtime is an hour old (outside the probe's
    /// write-in-progress window), hashed in full AFTER its last change (so
    /// the stamp is not racily clean), committed as a catalog row.
    static func catalogue(in scene: CutoverScene, bytes: Int = 128 * 1024) throws -> Catalogued {
        let dir = try TestScratch.unique("vs_rescan434_")
        let url = dir.appendingPathComponent("Hudson_Christmas_1994.mov")
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: url)
        try age(url)
        usleep(20_000)
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let fixity = try #require(ContentFixity.captured(path: url.path, digest: digest, byteCount: Int64(data.count)))
        try #require(fixity.isUsableForVerification && !fixity.isRacilyAmbiguous, "the fixture's stamp is trusted")
        let rec = VideoRecord()
        rec.fullPath = url.path
        rec.filename = url.lastPathComponent
        rec.ext = "MOV"
        rec.directory = dir.path
        rec.sizeBytes = Int64(data.count)
        rec.streamTypeRaw = StreamType.videoAndAudio.rawValue
        rec.scanContext.volumeUUID = VolumeIdentity.uuid(forPath: url.path) ?? ""
        rec.contentFixity = fixity
        scene.model.records.append(rec)
        try #require(scene.model.saveCatalogNow(), "the catalogued row is stored")
        return Catalogued(url: url, record: rec, digest: digest)
    }

    /// mtime an hour ago (sets ctime to now — the kernel's own clock).
    static func age(_ url: URL, mtime: Date = Date().addingTimeInterval(-3600)) throws {
        var times = [timespec(tv_sec: Int(mtime.timeIntervalSince1970), tv_nsec: 0),
                     timespec(tv_sec: Int(mtime.timeIntervalSince1970), tv_nsec: 0)]
        guard utimensat(AT_FDCWD, url.path, &times, 0) == 0 else { throw CutoverFailure(words: "utimensat \(errno)") }
    }

    /// The scan's own path for one file: the probe engine → a fresh record.
    static func probe(_ model: VideoScanModel, _ url: URL) async -> VideoRecord {
        let outcome = await model.probeFileOutcome(url: url, skipHashing: true, scanRootPath: url.deletingLastPathComponent().path)
        let fresh = VideoRecord()
        fresh.apply(outcome)
        return fresh
    }

    /// A complete rescan of the file's folder through the real merge.
    static func rescan(_ scene: CutoverScene, _ c: Catalogued) async -> VideoRecord {
        let target = CatalogScanTarget(searchPath: c.root)
        scene.model.snapshotPreservedFieldsForRescan(of: target)
        let fresh = await probe(scene.model, c.url)
        scene.model.applyPreservedFieldsAfterRescan(of: target, onto: [fresh])
        await scene.model.commitScanResults(root: c.root, volName: "Fixture", targetRecords: [fresh], scanWasComplete: true)
        return fresh
    }

    static func relaunch(_ scene: CutoverScene, from model: VideoScanModel) async throws -> VideoScanModel {
        if let committer = model.catalogCutover.committer { await committer.repository.close() }
        let sandbox = scene.sandbox
        let fresh = VideoScanModel(logDirectory: sandbox.logs)
        fresh.catalogStore = CatalogStore(directory: sandbox.catalogDir)
        fresh.mediaLedger = MediaLedger(directory: sandbox.root.appendingPathComponent("ledger", isDirectory: true))
        fresh.records = fresh.loadCatalogAtLaunch()
        try #require(fresh.catalogCutover.isSQLiteAuthority, "the relaunch opened catalog.sqlite")
        return fresh
    }

    static func live(_ model: VideoScanModel, at path: String) -> [VideoRecord] {
        model.records.filter { $0.fullPath == path && $0.removal == nil }
    }

    // MARK: Logic — the incident

    @Test("an unchanged file's rescan keeps its whole-file hash: nothing held, nothing queued for Fill In Full Hashes, the relaunch has it")
    func unchangedFileKeepsItsHash() async throws {
        let scene = try CutoverScene.make("r434_unchanged"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let c = try Self.catalogue(in: scene)

        let fresh = await Self.rescan(scene, c)
        #expect(scene.model.saveCatalogNow())

        #expect(fresh.id != c.record.id, "the rescan made a fresh record (the shape the incident had)")
        #expect(VideoScanModel.storedFullDigest(fresh) == c.digest, "the fresh record lost the known hash — Fill In Full Hashes would re-read it")
        let committer = try #require(scene.model.catalogCutover.committer)
        #expect(!committer.heldIDs.contains(fresh.id), "the fresh row was held in pending_rows")
        let reopened = try await Self.relaunch(scene, from: scene.model)
        let rows = Self.live(reopened, at: c.url.path)
        #expect(rows.count == 1)
        #expect(rows.first.flatMap(VideoScanModel.storedFullDigest) == c.digest, "the relaunch lost the hash")
        if let k = reopened.catalogCutover.committer { await k.repository.close() }
    }

    // MARK: Catalog writer — debounce window, write hold, role flip, relaunch

    @Test("WRITER: a star edited inside the debounce window of the rescan's save — both the star and the kept hash survive the relaunch")
    func anEditInsideTheDebounceWindowAndTheHashBothLand() async throws {
        let scene = try CutoverScene.make("r434_debounce"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let c = try Self.catalogue(in: scene)
        let fresh = await Self.rescan(scene, c)
        scene.model.saveCatalogDebounced()                       // the scan's own save
        let committer = try #require(scene.model.catalogCutover.committer)
        #expect(committer.isBusy, "the rescan's save waits on the debounce timer")
        fresh.starRating = 3                                     // Rick, inside the window (stars are 1–3)
        scene.model.saveCatalogDebounced()
        #expect(scene.model.saveCatalogNow())
        let reopened = try await Self.relaunch(scene, from: scene.model)
        let row = try #require(Self.live(reopened, at: c.url.path).first)
        #expect(row.starRating == 3)
        #expect(VideoScanModel.storedFullDigest(row) == c.digest)
        if let k = reopened.catalogCutover.committer { await k.repository.close() }
    }

    @Test("WRITER: a rescan during a job's write hold loses nothing; after release the row lands with its hash and survives the relaunch")
    func duringAWriteHoldNothingIsLostAndTheHashLandsAfter() async throws {
        let scene = try CutoverScene.make("r434_hold"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let c = try Self.catalogue(in: scene)
        await scene.hold()
        let fresh = await Self.rescan(scene, c)
        _ = scene.model.saveCatalogNow()                          // refused or deferred while held
        scene.release()
        #expect(scene.model.saveCatalogNow(), "after release the merge commits")
        #expect(VideoScanModel.storedFullDigest(fresh) == c.digest)
        let reopened = try await Self.relaunch(scene, from: scene.model)
        let rows = Self.live(reopened, at: c.url.path)
        #expect(rows.count == 1, "one live row for the file — nothing lost, nothing doubled")
        #expect(rows.first.flatMap(VideoScanModel.storedFullDigest) == c.digest)
        if let k = reopened.catalogCutover.committer { await k.repository.close() }
    }

    @Test("WRITER: across a viewer ↔ master flip — the viewer writes nothing; master again, the row lands with its hash and survives the relaunch")
    func acrossAViewerFlipTheHashLandsWhenMasterAgain() async throws {
        let scene = try CutoverScene.make("r434_flip"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let c = try Self.catalogue(in: scene)
        scene.model.updateReadOnlyFacts { $0.viewerRole = true }
        let fresh = await Self.rescan(scene, c)
        _ = scene.model.saveCatalogNow()                          // a viewer writes nothing
        scene.model.updateReadOnlyFacts { $0.viewerRole = false }
        #expect(scene.model.saveCatalogNow(), "master again: the merge commits")
        #expect(VideoScanModel.storedFullDigest(fresh) == c.digest)
        let reopened = try await Self.relaunch(scene, from: scene.model)
        let rows = Self.live(reopened, at: c.url.path)
        #expect(rows.count == 1)
        #expect(rows.first.flatMap(VideoScanModel.storedFullDigest) == c.digest)
        if let k = reopened.catalogCutover.committer { await k.repository.close() }
    }

    // MARK: Truth — anything that may have changed the bytes is hashed again

    @Test("TRUTH: a file rewritten in place (same size, mtime put back) is hashed again — ctime moved")
    func aFileRewrittenInPlaceIsHashedAgain() async throws {
        let scene = try CutoverScene.make("r434_rewrite"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let c = try Self.catalogue(in: scene)
        let mtime = try #require(c.record.contentFixity?.stamp.mtimeNs)
        let handle = try FileHandle(forWritingTo: c.url)
        try handle.seek(toOffset: 1000); try handle.write(contentsOf: Data([0xFF, 0xFE])); try handle.close()
        try Self.age(c.url, mtime: Date(timeIntervalSince1970: Double(mtime) / 1e9))

        let fresh = await Self.rescan(scene, c)
        #expect(fresh.contentFixity == nil, "a rewritten file kept the old digest — a lie about its bytes")
    }

    @Test("TRUTH: another file put at the path (new inode, same size and mtime) is hashed again")
    func aFileReplacedAtThePathIsHashedAgain() async throws {
        let scene = try CutoverScene.make("r434_replace"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let c = try Self.catalogue(in: scene)
        let mtime = try #require(c.record.contentFixity?.stamp.mtimeNs)
        let other = c.url.deletingLastPathComponent().appendingPathComponent("other.tmp")
        try Data(repeating: 0x11, count: Int(c.record.sizeBytes)).write(to: other)
        _ = try FileManager.default.replaceItemAt(c.url, withItemAt: other)
        try Self.age(c.url, mtime: Date(timeIntervalSince1970: Double(mtime) / 1e9))

        let fresh = await Self.rescan(scene, c)
        #expect(fresh.contentFixity == nil, "another file at the path inherited the old file's digest")
    }

    @Test("TRUTH: a stored stamp with no volume UUID never stands in for a read")
    func aStampWithNoVolumeIsNeverTrusted() async throws {
        let scene = try CutoverScene.make("r434_novolume"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let c = try Self.catalogue(in: scene)
        let f = try #require(c.record.contentFixity)
        c.record.contentFixity = ContentFixity(digest: f.digest, byteCount: f.byteCount,
                                               stamp: FileIdentityStamp(device: f.stamp.device, inode: f.stamp.inode, size: f.stamp.size,
                                                                        mtimeNs: f.stamp.mtimeNs, ctimeNs: f.stamp.ctimeNs, volumeUUID: nil),
                                               computedAt: f.computedAt)
        let fresh = await Self.rescan(scene, c)
        #expect(fresh.contentFixity == nil)
    }

    @Test("TRUTH: a hash taken in the instant the file last changed (racily clean) never stands in for a read")
    func aRacilyCleanStampIsNeverTrusted() async throws {
        let scene = try CutoverScene.make("r434_racy"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let c = try Self.catalogue(in: scene)
        let f = try #require(c.record.contentFixity)
        let changedNs = max(f.stamp.mtimeNs, f.stamp.ctimeNs)
        c.record.contentFixity = ContentFixity(digest: f.digest, byteCount: f.byteCount, stamp: f.stamp,
                                               computedAt: Date(timeIntervalSince1970: Double(changedNs) / 1e9 - 0.000_01))
        try #require(c.record.contentFixity?.isRacilyAmbiguous == true)
        let fresh = await Self.rescan(scene, c)
        #expect(fresh.contentFixity == nil)
    }

    // MARK: Scale

    @Test("SCALE: the carry rule over 100,000 re-seen rows fits 3 s")
    func theCarryRuleAt100kRowsFitsTheBudget() {
        let uuid = "11111111-2222-3333-4444-555555555555"
        var pairs: [(ContentFixity, VideoRecord)] = []
        pairs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let stamp = FileIdentityStamp(device: 7, inode: UInt64(i + 1), size: 1_000, mtimeNs: 1_000_000_000,
                                          ctimeNs: 1_000_000_000, volumeUUID: uuid)
            let fixity = ContentFixity(digest: String(repeating: "a", count: 64), byteCount: 1_000, stamp: stamp,
                                       computedAt: Date(timeIntervalSince1970: 2))
            let fresh = VideoRecord()
            fresh.sizeBytes = 1_000
            fresh.scanIdentityStamp = i % 10 == 0
                ? FileIdentityStamp(device: 7, inode: UInt64(i + 1), size: 1_000, mtimeNs: 1_000_000_000, ctimeNs: 9, volumeUUID: uuid)
                : stamp
            pairs.append((fixity, fresh))
        }
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        var kept = 0
        let elapsed = clock.measure {
            for (live, fresh) in pairs where RescanPreservedFields.carriedContentFixity(live: live, onto: fresh) != nil { kept += 1 }
        }
        print("[scale] carry rule over 100,000 rows: \(elapsed), kept \(kept)")
        #expect(kept == 90_000, "every unchanged stamp kept, every changed one dropped")
        expectWithinTimingBudget("rescan hash-carry rule over 100,000 rows", measured: elapsed,
                                 budget: PerformanceLane.debugCeiling(.seconds(3)), loadBefore: load)
    }
}
