import Testing
import Foundation
import VideoScanCore
@testable import VideoScan

// MARK: - PerceptualFingerprintStoreTests (GH #293 item 1, 2026-10-07)
//
// The bug: PerceptualFingerprinter's 32-frame pHash died with the compare
// that made it — 0% of the real catalog carried one, so Find Similar,
// delete-excess Tier 2 and the archive Year check could never reuse it.
// Fix: an ADDITIVE optional record field (`perceptualFingerprint`), read
// before any recompute, and an MFO backfill job (archived first).
//
// Five dimensions:
//   logic      encoding round trip (incl. values above 2^53), damaged / stale
//              values read as absent, additive Codable (absent key → nil, no
//              key written when nil), clone, plan order (archive first),
//              compare-and-set writes, the compare tier's write-back
//   scale      100k records: plan + 100k stored-fingerprint lookups in
//              budget (the planner and the compare read this per record)
//   media      mp4/h264, mov/prores, mkv/ffv1+pcm, mxf/mpeg2, avi/dv —
//              synthetic `test_*` ffmpeg fixtures through the REAL job
//   isolation  poisoned stored values (damaged text, old recipe, wrong size)
//              are never trusted; models use a temp catalog directory
//   sensor     a stored current fingerprint is never recomputed; the job is
//              read-only on media (bytes + mtime unchanged)

private func videoRecord(_ path: String, size: Int64 = 10_000_000, duration: Double = 120) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.directory = (path as NSString).deletingLastPathComponent
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    r.sizeBytes = size
    r.durationSeconds = duration
    return r
}

private func hashes(_ seed: UInt64, count: Int = 32) -> [UInt64] {
    (0..<UInt64(count)).map { ($0 &+ seed) &* 0x9E37_79B9_7F4A_7C15 }
}

@MainActor
private func isolatedModel(_ label: String) -> VideoScanModel {
    let m = VideoScanModel()
    m.catalogStore = CatalogStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("FingerprintStore-\(label)-\(UUID().uuidString)", isDirectory: true))
    return m
}

@Suite("GH #293 — stored perceptual fingerprint (logic)")
struct StoredPerceptualFingerprintLogicTests {

    @Test("round trip keeps every bit (incl. values above 2^53) in PerceptualHash's designed persisted form")
    func roundTripInDesignedForm() {
        let values: [UInt64] = [0, 1, UInt64.max, 1 << 63, (1 << 53) + 1, 0x0123_4567_89AB_CDEF] + hashes(7, count: 26)
        let fp = StoredPerceptualFingerprint(hashes: values, sizeBytes: 5, durationSeconds: 1)
        #expect(fp.hashes == values)
        #expect(fp.hashesBase64.count == 344, "32 hashes → 256 bytes → 344 base64 chars")
        // The SAME string the app's encoder (PerceptualHash.swift) designed for persistence.
        #expect(fp.hashesBase64 == PerceptualHash.base64(from: values))
        #expect(PerceptualHash.fingerprint(fromBase64: fp.hashesBase64) == values)
    }

    @Test("damaged text reads as absent and is never current")
    func damagedTextIsAbsent() {
        var fp = StoredPerceptualFingerprint(hashes: hashes(1), sizeBytes: 100, durationSeconds: 10)
        fp.hashesBase64 = String(fp.hashesBase64.dropLast(4))
        #expect(fp.hashes == nil)
        #expect(!fp.isCurrent(forSizeBytes: 100, minimumFrames: 10))
        var bad = StoredPerceptualFingerprint(hashes: hashes(1), sizeBytes: 100, durationSeconds: 10)
        bad.hashesBase64 = "not base64 at all!"
        #expect(bad.hashes == nil)
        #expect(!bad.isCurrent(forSizeBytes: 100, minimumFrames: 10))
        var empty = StoredPerceptualFingerprint(hashes: [], sizeBytes: 100, durationSeconds: 10)
        empty.hashesBase64 = ""
        #expect(empty.hashes == nil)
    }

    @Test("current only for the same recipe, the same size, and enough frames")
    func currentness() {
        let fp = StoredPerceptualFingerprint(hashes: hashes(2), sizeBytes: 100, durationSeconds: 10)
        #expect(fp.isCurrent(forSizeBytes: 100, minimumFrames: 10))
        #expect(!fp.isCurrent(forSizeBytes: 101, minimumFrames: 10), "different bytes")
        let old = StoredPerceptualFingerprint(hashes: hashes(2), sizeBytes: 100, durationSeconds: 10, algorithmVersion: 0)
        #expect(!old.isCurrent(forSizeBytes: 100, minimumFrames: 10), "older recipe")
        let thin = StoredPerceptualFingerprint(hashes: hashes(2, count: 9), sizeBytes: 100, durationSeconds: 10)
        #expect(!thin.isCurrent(forSizeBytes: 100, minimumFrames: 10))
    }

    @Test("additive: a record without one writes no key; with one it round-trips through the catalog DTO")
    @MainActor
    func additiveCodable() throws {
        let plain = videoRecord("/Volumes/V/a.mov")
        let plainJSON = String(decoding: try JSONEncoder().encode(VideoRecordDTO(plain)), as: UTF8.self)
        #expect(!plainJSON.contains("perceptualFingerprint"))
        let back = try JSONDecoder().decode(VideoRecord.self, from: Data(plainJSON.utf8))
        #expect(back.perceptualFingerprint == nil)

        let r = videoRecord("/Volumes/V/b.mov")
        r.perceptualFingerprint = StoredPerceptualFingerprint(hashes: hashes(3), sizeBytes: r.sizeBytes,
                                                             durationSeconds: 120, computedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(VideoRecordDTO(r))
        let round = try decoder.decode(VideoRecord.self, from: data)
        #expect(round.perceptualFingerprint == r.perceptualFingerprint)
        #expect(round.perceptualFingerprint?.hashes == hashes(3))
    }

    @Test("a damaged stored value never stops the record from decoding")
    @MainActor
    func damagedValueStillDecodes() throws {
        let r = videoRecord("/Volumes/V/c.mov")
        var fp = StoredPerceptualFingerprint(hashes: hashes(4), sizeBytes: r.sizeBytes, durationSeconds: 120)
        fp.hashesBase64 = "not base64 at all!"
        r.perceptualFingerprint = fp
        let data = try JSONEncoder().encode(VideoRecordDTO(r))
        let round = try JSONDecoder().decode(VideoRecord.self, from: data)
        #expect(round.perceptualFingerprint?.hashes == nil)
        #expect(VideoScanModel.storedPerceptualFingerprint(of: round) == nil)
    }

    @Test("clone carries the fingerprint")
    @MainActor
    func cloneCarriesIt() {
        let r = videoRecord("/Volumes/V/d.mov")
        r.perceptualFingerprint = StoredPerceptualFingerprint(hashes: hashes(5), sizeBytes: r.sizeBytes, durationSeconds: 120)
        #expect(r.snapshotClone().perceptualFingerprint == r.perceptualFingerprint)
    }
}

@MainActor
@Suite("GH #293 — fingerprint plan, writes and the compare write-back")
struct PerceptualFingerprintPlanTests {

    @Test("archived files first, then the rest, each in path order; only videos that need one")
    func planOrderAndFilter() {
        let archivedB = videoRecord("/Volumes/FamilyArchive/30_Video/1992/b.mkv")
        let archivedA = videoRecord("/Volumes/FamilyArchive/30_Video/1984/a.mkv")
        archivedA.derivationKind = ArchivePromotion.derivationKind
        archivedB.derivationKind = ArchivePromotion.derivationKind
        let other = videoRecord("/Volumes/LaCie/c.mov")
        let done = videoRecord("/Volumes/LaCie/done.mov")
        done.perceptualFingerprint = StoredPerceptualFingerprint(hashes: hashes(6), sizeBytes: done.sizeBytes, durationSeconds: 120)
        let stale = videoRecord("/Volumes/LaCie/stale.mov", size: 999)
        stale.perceptualFingerprint = StoredPerceptualFingerprint(hashes: hashes(6), sizeBytes: 111, durationSeconds: 120)
        let audio = videoRecord("/Volumes/LaCie/audio.wav"); audio.streamTypeRaw = StreamType.audioOnly.rawValue
        let noDuration = videoRecord("/Volumes/LaCie/nodur.mov", duration: 0)
        let purged = videoRecord("/Volumes/LaCie/purged.mov"); purged.purgedAt = Date()

        let plan = VideoScanModel.perceptualFingerprintBackfillPlan(
            records: [other, archivedB, done, stale, audio, archivedA, noDuration, purged],
            isArchived: { $0.derivationKind == ArchivePromotion.derivationKind })
        #expect(plan.map(\.filename) == ["a.mkv", "b.mkv", "c.mov", "stale.mov"])
        #expect(plan.map(\.isArchived) == [true, true, false, false])
    }

    @Test("compare-and-set: written for the planned record; refused when it moved, changed size or the catalog is read-only")
    func compareAndSet() {
        let m = isolatedModel("cas")
        let r = videoRecord("/Volumes/V/e.mov")
        m.records = [r]
        let item = VideoScanModel.perceptualFingerprintBackfillPlan(records: [r], isArchived: { _ in false })[0]
        let fp = StoredPerceptualFingerprint(hashes: hashes(7), sizeBytes: r.sizeBytes, durationSeconds: 120)
        #expect(m.applyPerceptualFingerprint(fp, to: item) == .written)
        #expect(r.perceptualFingerprint == fp)
        #expect(m.revertPerceptualFingerprint(item, written: fp))
        #expect(r.perceptualFingerprint == nil)

        r.fullPath = "/Volumes/V/moved.mov"
        #expect(m.applyPerceptualFingerprint(fp, to: item) == .recordChanged)
        r.fullPath = item.path; r.sizeBytes = 1
        #expect(m.applyPerceptualFingerprint(fp, to: item) == .recordChanged)
        r.sizeBytes = item.sizeBytes
        m.applyReadOnlyMode(true)
        #expect(m.applyPerceptualFingerprint(fp, to: item) == .recordChanged)
        #expect(r.perceptualFingerprint == nil)
    }

    @Test("the compare tier keeps what it computed once, and never over a current value or a changed file")
    func compareWriteBack() {
        let r = videoRecord("/Volumes/V/f.mov")
        #expect(keepPerceptualFingerprint(hashes(8), on: r, sizeBytes: r.sizeBytes, durationSeconds: 120))
        #expect(VideoScanModel.storedPerceptualFingerprint(of: r) == hashes(8))
        #expect(!keepPerceptualFingerprint(hashes(9), on: r, sizeBytes: r.sizeBytes, durationSeconds: 120),
                "a current value is reused, not replaced")
        let moved = videoRecord("/Volumes/V/g.mov")
        #expect(!keepPerceptualFingerprint(hashes(8), on: moved, sizeBytes: moved.sizeBytes + 1, durationSeconds: 120))
        #expect(!keepPerceptualFingerprint(hashes(8, count: 5), on: moved, sizeBytes: moved.sizeBytes, durationSeconds: 120))
        #expect(moved.perceptualFingerprint == nil)
    }

    @Test("rescan: a kept fingerprint alone is snapshotted; it follows the same-size file and is dropped for a changed one")
    func rescanCarriesOnlyForTheSameBytes() {
        let r = videoRecord("/Volumes/V/h.mov")
        r.perceptualFingerprint = StoredPerceptualFingerprint(hashes: hashes(10), sizeBytes: r.sizeBytes, durationSeconds: 120)
        let snap = RescanPreservedFields(from: r)
        #expect(!snap.isWorthRestoring && snap.carriesKeptFingerprint, "the fingerprint alone puts it in the snapshot map")
        let same = videoRecord("/Volumes/V/h.mov", size: r.sizeBytes)
        _ = snap.apply(to: same)
        #expect(same.perceptualFingerprint == r.perceptualFingerprint)
        let changed = videoRecord("/Volumes/V/h.mov", size: r.sizeBytes + 4096)
        _ = snap.apply(to: changed)
        #expect(changed.perceptualFingerprint == nil, "different bytes — recomputed by the next backfill")
    }

    @Test("progress line: N of M, the file, time left")
    func progressLine() {
        #expect(PerceptualFingerprintBackfillJob.progressLine(done: 0, total: 164, current: "a.mkv", elapsed: 0) == "0 of 164 · a.mkv")
        #expect(PerceptualFingerprintBackfillJob.progressLine(done: 82, total: 164, current: "a.mkv", elapsed: 600)
                == "82 of 164 · a.mkv · ~10 min left")
        #expect(PerceptualFingerprintBackfillJob.progressLine(done: 10, total: 164, current: "a.mkv", elapsed: 600)
                .hasSuffix("· ~2 h 34 min left"))
    }
}

@MainActor
@Suite("GH #293 — fingerprint backfill job (stubbed pass)")
struct PerceptualFingerprintBackfillJobTests {

    private func job(_ m: VideoScanModel, pass: @escaping PerceptualFingerprintBackfillJob.Fingerprinter,
                     save: Bool = true) -> PerceptualFingerprintBackfillJob {
        let j = PerceptualFingerprintBackfillJob(model: m)
        j.fingerprinterForTesting = pass
        j.fileExists = { !$0.contains("offline") }
        j.saveCatalogForTesting = { save }
        return j
    }

    @Test("archived first; every fingerprint stored; offline and failed files listed with a reason; resumable")
    func runsArchiveFirstAndReports() async {
        let m = isolatedModel("job")
        let arch = videoRecord("/Volumes/FamilyArchive/30_Video/1992/cape.mkv")
        arch.derivationKind = ArchivePromotion.derivationKind
        let ok = videoRecord("/Volumes/LaCie/ok.mov")
        let offline = videoRecord("/Volumes/offline/gone.mov")
        let broken = videoRecord("/Volumes/LaCie/broken.mxf")
        m.records = [ok, offline, broken, arch]
        let order = OrderBox()
        let j = job(m, pass: { path, _, _ in
            await order.append(path)
            if path.hasSuffix("broken.mxf") { throw PerceptualFingerprintError.tooFewFrames(file: path, got: 3) }
            return hashes(UInt64(path.count))
        })
        j.start()
        await j.task?.value
        #expect(await order.paths.first == arch.fullPath, "archived files first")
        #expect(j.totals.stored == 2 && j.totals.failed == 1 && j.totals.offline == 1)
        #expect(j.storedCount == 2)
        #expect(VideoScanModel.storedPerceptualFingerprint(of: arch) != nil)
        #expect(VideoScanModel.storedPerceptualFingerprint(of: ok) != nil)
        #expect(broken.perceptualFingerprint == nil && offline.perceptualFingerprint == nil)
        #expect(j.problems.map(\.kind).sorted { "\($0)" < "\($1)" } == [.failed, .offline])
        if case .finished(let summary) = j.state {
            #expect(summary == "Stored 2 · failed 1 · not connected 1")
        } else {
            Issue.record("expected finished, got \(j.state)")
        }
        // Resumable: only the two undone files are candidates again.
        #expect(m.perceptualFingerprintBackfillPlan().map(\.filename).sorted() == ["broken.mxf", "gone.mov"])
    }

    @Test("a failed catalog save stops the job and UNDOES the unsaved fingerprints")
    func failedSaveUndoes() async {
        let m = isolatedModel("savefail")
        let a = videoRecord("/Volumes/LaCie/a.mov"), b = videoRecord("/Volumes/LaCie/b.mov")
        m.records = [a, b]
        let j = job(m, pass: { _, _, _ in hashes(1) }, save: false)
        j.start()
        await j.task?.value
        #expect(a.perceptualFingerprint == nil && b.perceptualFingerprint == nil)
        #expect(j.storedCount == 0)
        if case .failed(let msg) = j.state { #expect(msg.contains("could not be saved")) } else {
            Issue.record("expected failed, got \(j.state)")
        }
    }

    @Test("refused on a read-only catalog — nothing read")
    func refusedReadOnly() async {
        let m = isolatedModel("ro")
        m.records = [videoRecord("/Volumes/LaCie/a.mov")]
        m.applyReadOnlyMode(true)
        let called = OrderBox()
        let j = job(m, pass: { p, _, _ in await called.append(p); return hashes(1) })
        j.start()
        await j.task?.value
        #expect(j.wasRefused)
        #expect(await called.paths.isEmpty)
    }

    @Test("a pass that stops making progress (a sleeping drive) fails that file with a reason; the run moves on")
    func stalledPassFailsCleanly() async {
        let m = isolatedModel("stall")
        let wedged = videoRecord("/Volumes/LaCie/a-wedged.mov"), next = videoRecord("/Volumes/LaCie/b-next.mov")
        m.records = [wedged, next]
        let j = job(m, pass: { path, _, _ in
            if path.contains("wedged") { try await Task.sleep(nanoseconds: 30_000_000_000) }   // silent, never ticks
            return hashes(3)
        })
        j.stallThresholdSeconds = 1
        j.stallPollSeconds = 0.05
        let started = Date()
        j.start()
        await j.task?.value
        #expect(Date().timeIntervalSince(started) < 10, "the wedged pass was cut off, not waited out")
        #expect(j.totals.failed == 1 && j.totals.stored == 1)
        #expect(j.problems.first?.detail.hasPrefix("stalled — no progress") == true, "\(j.problems.first?.detail ?? "nil")")
        #expect(wedged.perceptualFingerprint == nil)
        #expect(VideoScanModel.storedPerceptualFingerprint(of: next) == hashes(3))
    }

    @Test("Pause says so at once and takes effect between files")
    func pauseFeedback() async {
        let m = isolatedModel("pause")
        m.records = [videoRecord("/Volumes/LaCie/a.mov"), videoRecord("/Volumes/LaCie/b.mov")]
        let j = job(m, pass: { _, _, _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            return hashes(4)
        })
        j.start()
        try? await Task.sleep(nanoseconds: 30_000_000)
        j.pause()
        #expect(j.subtitle.hasPrefix("Pausing after the current file"), "\(j.subtitle)")
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(j.totals.done == 1, "the first file finished; the second waits")
        #expect(j.state == .running)
        j.resume()
        await j.task?.value
        #expect(j.totals.stored == 2)
    }

    @Test("Stop keeps what was saved and ends Cancelled, not Failed")
    func stopEndsCancelled() async {
        let m = isolatedModel("stop")
        m.records = (0..<5).map { videoRecord("/Volumes/LaCie/\($0).mov") }
        let j = job(m, pass: { _, _, _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            return hashes(2)
        })
        j.start()
        try? await Task.sleep(nanoseconds: 80_000_000)
        j.cancel()
        await j.task?.value
        #expect(j.state == .cancelled, "\(j.state)")
        #expect(j.totals.stored < 5)
    }
}

/// Order recorder for the stubbed pass (an actor ≈ a mutex-guarded vector).
private actor OrderBox {
    private(set) var paths: [String] = []
    func append(_ p: String) { paths.append(p) }
}

@MainActor
@Suite("GH #293 — fingerprint lookup at scale")
struct PerceptualFingerprintScaleTests {

    @Test("100k records: the plan and 100k stored-fingerprint lookups stay in budget")
    func hundredThousand() {
        let records: [VideoRecord] = (0..<100_000).map { i in
            let r = videoRecord("/Volumes/V\(i % 7)/clip\(i).mov", size: Int64(1_000 + i))
            if i % 2 == 0 {
                r.perceptualFingerprint = StoredPerceptualFingerprint(hashes: hashes(UInt64(i)), sizeBytes: r.sizeBytes,
                                                                     durationSeconds: 120)
            }
            // Archived rows are odd-numbered, so none is fingerprinted yet.
            if i % 10 == 1 { r.derivationKind = ArchivePromotion.derivationKind }
            return r
        }
        let start = Date()
        let plan = VideoScanModel.perceptualFingerprintBackfillPlan(
            records: records, isArchived: { $0.derivationKind == ArchivePromotion.derivationKind })
        var found = 0
        for r in records where VideoScanModel.storedPerceptualFingerprint(of: r) != nil { found += 1 }
        let elapsed = Date().timeIntervalSince(start)
        #expect(plan.count == 50_000)
        #expect(found == 50_000)
        let archivedFirst = plan.prefix(10_000).allSatisfy { $0.isArchived }
        #expect(archivedFirst, "the 10k archived rows come first")
        #expect(plan[10_000].isArchived == false)
        #expect(elapsed < 3.0, "plan + 100k lookups took \(elapsed) s")
    }
}

@MainActor
@Suite("GH #293 — media matrix through the real backfill job", .serialized)
struct PerceptualFingerprintMediaMatrixTests {

    private static let fixtures: [(name: String, args: [String])] = [
        ("test_h264.mp4", ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30:duration=4",
                           "-c:v", "libx264", "-pix_fmt", "yuv420p"]),
        ("test_prores.mov", ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30:duration=4",
                             "-c:v", "prores_ks", "-profile:v", "0"]),
        ("test_ffv1_pcm.mkv", ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30:duration=4",
                               "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
                               "-c:v", "ffv1", "-c:a", "pcm_s16le"]),
        ("test_mpeg2.mxf", ["-f", "lavfi", "-i", "testsrc2=size=720x576:rate=25:duration=4",
                            "-c:v", "mpeg2video", "-pix_fmt", "yuv422p", "-b:v", "8M", "-f", "mxf"]),
        ("test_dv.avi", ["-f", "lavfi", "-i", "testsrc2=size=720x480:rate=30000/1001:duration=4",
                         "-c:v", "dvvideo", "-pix_fmt", "yuv411p"]),
    ]

    @Test("five containers / codecs fingerprinted and kept; media bytes and mtimes untouched; a rerun recomputes nothing")
    func mediaMatrix() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vs-fp293-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var records: [VideoRecord] = []
        var before: [String: (Data, Date)] = [:]
        for f in Self.fixtures {
            let url = dir.appendingPathComponent(f.name)
            let r = await ProcessRunner.runProcess(executable: ToolLocator.ffmpegPath,
                                                   arguments: ["-nostdin", "-v", "error"] + f.args + ["-y", url.path])
            try #require(r.exitCode == 0, "fixture \(f.name) failed: \(r.stderr)")
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let rec = videoRecord(url.path, size: (attrs[.size] as? NSNumber)?.int64Value ?? 0, duration: 4)
            records.append(rec)
            before[url.path] = (try Data(contentsOf: url), attrs[.modificationDate] as? Date ?? .distantPast)
        }
        let m = isolatedModel("matrix")
        m.records = records
        let j = PerceptualFingerprintBackfillJob(model: m)
        j.saveCatalogForTesting = { true }
        j.start()
        await j.task?.value
        #expect(j.totals.stored == 5, "\(j.problems.map { "\($0.filename): \($0.detail)" })")
        for rec in records {
            let kept = VideoScanModel.storedPerceptualFingerprint(of: rec)
            #expect((kept?.count ?? 0) >= PerceptualFingerprinter.minimumFrames, "\(rec.filename)")
            let (bytes, mtime) = try #require(before[rec.fullPath])
            #expect(try Data(contentsOf: URL(fileURLWithPath: rec.fullPath)) == bytes, "\(rec.filename) bytes changed")
            let now = try FileManager.default.attributesOfItem(atPath: rec.fullPath)[.modificationDate] as? Date
            #expect(now == mtime, "\(rec.filename) mtime changed")
        }
        // Sensor: a second run finds nothing to do (stored values are read, not recomputed).
        #expect(m.perceptualFingerprintBackfillPlan().isEmpty)
        // The kept value equals a fresh pass (deterministic recipe).
        let first = try #require(records.first)
        let fresh = try await PerceptualFingerprinter.fingerprint(ffmpegPath: ToolLocator.ffmpegPath, path: first.fullPath,
                                                                  durationSeconds: 4, onFraction: { _ in })
        #expect(VideoScanModel.storedPerceptualFingerprint(of: first) == fresh)
    }
}

@MainActor
@Suite("GH #293 — isolation: poisoned stored fingerprints are never trusted")
struct PerceptualFingerprintIsolationTests {

    @Test("damaged text, an old recipe, or another file's size → recomputed and replaced")
    func poisonedValuesAreRecomputed() async {
        let m = isolatedModel("poison")
        let damaged = videoRecord("/Volumes/LaCie/damaged.mov")
        var d = StoredPerceptualFingerprint(hashes: hashes(1), sizeBytes: damaged.sizeBytes, durationSeconds: 120)
        d.hashesBase64 = "%%" + String(d.hashesBase64.dropFirst(2))
        damaged.perceptualFingerprint = d
        let old = videoRecord("/Volumes/LaCie/old.mov")
        old.perceptualFingerprint = StoredPerceptualFingerprint(hashes: hashes(1), sizeBytes: old.sizeBytes,
                                                               durationSeconds: 120, algorithmVersion: 99)
        let other = videoRecord("/Volumes/LaCie/other.mov")
        other.perceptualFingerprint = StoredPerceptualFingerprint(hashes: hashes(1), sizeBytes: 42, durationSeconds: 120)
        m.records = [damaged, old, other]
        #expect(m.perceptualFingerprintBackfillPlan().count == 3)
        let j = PerceptualFingerprintBackfillJob(model: m)
        j.fingerprinterForTesting = { _, _, _ in hashes(77) }
        j.fileExists = { _ in true }
        j.saveCatalogForTesting = { true }
        j.start()
        await j.task?.value
        for r in [damaged, old, other] {
            #expect(VideoScanModel.storedPerceptualFingerprint(of: r) == hashes(77), "\(r.filename)")
        }
    }
}
