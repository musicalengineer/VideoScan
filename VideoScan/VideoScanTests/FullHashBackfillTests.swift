// FullHashBackfillTests.swift
// "Fill In Full Hashes…" (Rick 2026-10-11) — the five dimensions:
//   LOGIC     — only records without a valid full hash are read; a second
//               run skips everything the first stored (restart = resume);
//               archived / removed / superseded rows are never written; the
//               save cadence (every N files, every T seconds, at the end);
//               a failed save stops the job and leaves the resume offer.
//   SCALE     — planning over 100k records on 10 drives inside a budget.
//   MEDIA     — mp4/h264, mov/prores, mkv/ffv1+pcm, mxf, avi/dv test_*
//               fixtures: every digest equals an independent SHA-256.
//   ISOLATION — a drive that is not connected is skipped and counted and
//               never stalls the run; a drive that leaves mid-run stops only
//               its lane; a poisoned resume marker is ignored; the marker
//               lives in the test catalog's folder, never App Support.
//   SENSOR    — the job's sources hold no trash / remove / move / write-to-
//               media call; every file's bytes, inode and mtime are unchanged
//               after a run.

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private func sha256(_ path: String) -> String {
    SHA256.hash(data: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data())
        .map { String(format: "%02x", $0) }.joined()
}

@MainActor
private func runBackfill(_ model: VideoScanModel,
                         marker: FullHashBackfillResumeMarker? = nil,
                         online: @escaping @Sendable (String) -> Bool = { _ in true },
                         configure: (FullHashBackfillJob) -> Void = { _ in }) async -> FullHashBackfillJob {
    let job = FullHashBackfillJob(model: model, marker: marker)
    job.volumeOnline = online
    job.tickMilliseconds = 20
    configure(job)
    job.start()
    await job.task?.value
    return job
}

/// Thread-safe call counter for `volumeOnline` seams (≈ C++ std::atomic<int>).
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

// MARK: - Logic

@Suite("Fill in full hashes — logic", .serialized)
@MainActor
struct FullHashBackfillLogicTests {

    @Test("only records without a valid full hash are read; a second run reads nothing (restart = resume)")
    func onlyMissingHashesAreRead() async throws {
        let sb = try ShowAgainSandbox.make("fhb_logic"); defer { sb.cleanup() }
        let a = try sb.record("a.mov", bytes: 4_000, stage: .none)
        let b = try sb.record("b.mov", bytes: 5_000, stage: .none)
        let first = await runBackfill(sb.model)
        #expect(first.state == .finished(summary: first.totals.line), "\(first.subtitle)")
        #expect(first.totals[.hashed] == 2 && first.storedCount == 2)
        #expect(a.contentFixity?.digest == sha256(a.fullPath) && b.contentFixity?.digest == sha256(b.fullPath))
        let aFixity = try #require(a.contentFixity)

        // A new file arrives; one existing hash is lost (as if a crash hit
        // before its save) — only those two are read again.
        let c = try sb.record("c.mov", bytes: 3_000, stage: .none)
        b.contentFixity = nil
        let second = await runBackfill(sb.model)
        #expect(second.totals.planned == 2, Comment(rawValue: second.totals.line))
        #expect(second.totals.alreadyHashed == 1)
        #expect(a.contentFixity == aFixity, "a stored hash is never re-read or rewritten")
        #expect(c.contentFixity?.digest == sha256(c.fullPath))

        let third = await runBackfill(sb.model)
        #expect(third.totals.planned == 0 && third.totals.alreadyHashed == 3, Comment(rawValue: third.totals.line))
    }

    @Test("archived rows, removed rows and superseded rows are never read or written")
    func leavesArchivedRemovedAndSupersededAlone() async throws {
        let sb = try ShowAgainSandbox.make("fhb_skip"); defer { sb.cleanup() }
        let archived = try sb.record("arch.mov", bytes: 1_000, stage: .none)
        archived.archiveFixity = ArchiveFixity(digest: "ab", verifiedAt: Date(), sizeBytes: 1_000)
        let removed = try sb.record("gone.mov", bytes: 1_000, stage: .none)
        removed.purgedAt = Date()
        let superseded = try sb.record("old.mov", bytes: 1_000, stage: .none)
        superseded.supersededByID = UUID()
        let plain = try sb.record("plain.mov", bytes: 1_000, stage: .none)
        let job = await runBackfill(sb.model)
        #expect(job.totals.planned == 1 && job.totals.archivedLeftAlone == 1, Comment(rawValue: job.totals.line))
        #expect(plain.contentFixity != nil)
        #expect(archived.contentFixity == nil && removed.contentFixity == nil && superseded.contentFixity == nil)
    }

    @Test("RED 2026-10-17: an Archived-stage row with no fixity of its own is hashed (the archive rule forbids name/date changes, not added metadata); one that an archiveFixity already identifies is left alone")
    func archivedRowsWithoutFixityAreHashed() async throws {
        let sb = try ShowAgainSandbox.make("fhb_archived"); defer { sb.cleanup() }
        let archivedNoFixity = try sb.record("arch_nofix.mov", bytes: 1_000, stage: .none)
        archivedNoFixity.lifecycleStage = .archived
        let archivedProven = try sb.record("arch_proven.mov", bytes: 1_000, stage: .none)
        archivedProven.lifecycleStage = .archived
        archivedProven.archiveFixity = ArchiveFixity(digest: "ab", verifiedAt: Date(), sizeBytes: 1_000)
        #expect(sb.model.isDateReadOnly(archivedNoFixity), "fixture sanity: the stage rule calls this row read-only")
        let job = await runBackfill(sb.model)
        #expect(job.totals.planned == 1, Comment(rawValue: job.totals.line))
        #expect(job.totals[.hashed] == 1, Comment(rawValue: job.totals.line))
        #expect(job.totals.archivedLeftAlone == 1, Comment(rawValue: job.totals.line))
        #expect(archivedNoFixity.contentFixity?.digest == sha256(archivedNoFixity.fullPath), "the full hash is stored on the archived row")
        #expect(archivedProven.contentFixity == nil, "an archive copy with its own digest is never written")
        // The plan counts it the same way the job did (a second run reads nothing).
        let again = FullHashBackfillPlanner.plan(records: sb.model.records)
        #expect(again.fileCount == 0, "the archived row now carries its hash")
        #expect(again.archivedLeftAlone == 1)
    }

    @Test("an acknowledged save every N stored hashes and at the end")
    func savesEveryNFiles() async throws {
        let sb = try ShowAgainSandbox.make("fhb_saveN"); defer { sb.cleanup() }
        for i in 0..<5 { try sb.record("f\(i).mov", bytes: 2_000, stage: .none) }
        let job = await runBackfill(sb.model, configure: { j in
            j.checkpointFiles = 2
            j.checkpointSeconds = 3_600
            j.saveCatalogForTesting = { true }
        })
        #expect(job.storedCount == 5)
        #expect(job.saveCount == 3, "after 2, after 4, and the final one for the 5th (got \(job.saveCount))")
    }

    @Test("the clock alone triggers a save (a long file never leaves earlier hashes unsaved)")
    func savesOnTheClock() async throws {
        let sb = try ShowAgainSandbox.make("fhb_saveT"); defer { sb.cleanup() }
        for i in 0..<3 { try sb.record("t\(i).mov", bytes: 2_000, stage: .none) }
        let job = await runBackfill(sb.model, configure: { j in
            j.checkpointFiles = 10_000
            j.checkpointSeconds = 0
            j.saveCatalogForTesting = { true }
        })
        #expect(job.storedCount == 3)
        #expect(job.saveCount >= 2, "time-based checkpoints fired (got \(job.saveCount))")
    }

    @Test("the real save reaches catalog.json: a reloaded catalog carries the hashes")
    func hashesSurviveAReload() async throws {
        let sb = try ShowAgainSandbox.make("fhb_durable"); defer { sb.cleanup() }
        let a = try sb.record("d.mov", bytes: 3_000, stage: .none)
        let job = await runBackfill(sb.model)
        #expect(job.saveCount >= 1 && !job.saveFailed)
        let reloaded = CatalogStore(directory: sb.catalogDir).load()
        #expect(reloaded.first { $0.id == a.id }?.contentFixity?.digest == sha256(a.fullPath))
    }

    @Test("a failed save stops the job, says so, and leaves 'Resume…' on the menu")
    func failedSaveStopsAndOffersResume() async throws {
        let sb = try ShowAgainSandbox.make("fhb_savefail"); defer { sb.cleanup() }
        for i in 0..<4 { try sb.record("s\(i).mov", bytes: 2_000, stage: .none) }
        let marker = FullHashBackfillResumeMarker()
        let job = await runBackfill(sb.model, marker: marker, configure: { j in
            j.checkpointFiles = 1
            j.saveCatalogForTesting = { false }
        })
        #expect(job.saveFailed)
        if case .failed = job.state {} else { Issue.record("expected failed, got \(job.state)") }
        #expect(job.totals.done < 4, "it stopped reading after the failed save")
        #expect(marker.unfinished != nil && marker.menuTitle == "Resume Filling In Full Hashes…")
        let relaunch = FullHashBackfillResumeMarker()
        #expect(relaunch.attach(catalogFile: sb.model.catalogStore.fileLocation) != nil, "a relaunch sees it unfinished")
    }

    @Test("a finished run clears the offer; a relaunch sees nothing to resume")
    func finishedRunClearsTheOffer() async throws {
        let sb = try ShowAgainSandbox.make("fhb_marker"); defer { sb.cleanup() }
        try sb.record("m.mov", bytes: 1_000, stage: .none)
        let marker = FullHashBackfillResumeMarker()
        _ = await runBackfill(sb.model, marker: marker)
        #expect(marker.unfinished == nil && marker.menuTitle == "Fill In Full Hashes…")
        let relaunch = FullHashBackfillResumeMarker()
        #expect(relaunch.attach(catalogFile: sb.model.catalogStore.fileLocation) == nil)
    }
}

// MARK: - Scale

@Suite("Fill in full hashes — scale (100k records)", .serialized)
@MainActor
struct FullHashBackfillScaleTests {

    /// 100k records on 10 drives, every 4th already hashed.
    /// Budget (Debug, M4 Max, headroom ×3+): planning < 1.5 s.
    @Test func planningAt100k() {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        let usable = ContentFixity.captured(path: "/", digest: String(repeating: "a", count: 64), byteCount: 1)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.fullPath = "/Volumes/Drive\(i % 10)/\(i / 1000)/clip_\(i).mov"
            r.filename = "clip_\(i).mov"
            r.sizeBytes = Int64(10_000 + i)
            if i % 4 == 0 { r.contentFixity = usable }
            records.append(r)
        }
        let hashedCount = usable?.isUsableForVerification == true ? 25_000 : 0
        let t0 = Date()
        let plan = FullHashBackfillPlanner.plan(records: records)
        let elapsed = -t0.timeIntervalSinceNow
        #expect(plan.lanes.count == 10)
        #expect(plan.alreadyHashed == hashedCount)
        #expect(plan.fileCount == 100_000 - hashedCount)
        #expect(plan.lanes.allSatisfy { lane in zip(lane.items, lane.items.dropFirst()).allSatisfy { $0.path < $1.path } },
                "each lane reads in path order")
        #expect(elapsed < 1.5, "planning took \(elapsed) s")
    }
}

// MARK: - Isolation

@Suite("Fill in full hashes — isolation: drives away, poisoned marker", .serialized)
@MainActor
struct FullHashBackfillIsolationTests {

    @Test("a drive that is not connected is skipped and counted; the run finishes", .timeLimit(.minutes(1)))
    func offlineDriveSkippedNeverStalls() async throws {
        let sb = try ShowAgainSandbox.make("fhb_off"); defer { sb.cleanup() }
        let offlineRoot = "/Volumes/FHBOffline_\(UUID().uuidString.prefix(8))"
        let local = try sb.record("here.mov", bytes: 3_000, stage: .none)
        let away = VideoRecord()
        away.fullPath = offlineRoot + "/away.mov"; away.filename = "away.mov"; away.sizeBytes = 3_000
        away.directory = offlineRoot
        sb.model.records.append(away)
        let job = await runBackfill(sb.model, online: { !$0.hasPrefix(offlineRoot) })
        #expect(job.totals[.driveNotConnected] == 1, Comment(rawValue: job.totals.line))
        #expect(job.totals[.hashed] == 1)
        #expect(local.contentFixity != nil && away.contentFixity == nil)
        #expect(job.lanes.first { $0.root == offlineRoot }?.phase == .disconnected)
        if case .finished = job.state {} else { Issue.record("expected finished, got \(job.state)") }
    }

    @Test("a drive that leaves mid-run stops its lane; the rest are counted, not read", .timeLimit(.minutes(1)))
    func driveLeavingMidRunStopsItsLane() async throws {
        let sb = try ShowAgainSandbox.make("fhb_leave"); defer { sb.cleanup() }
        let a = try sb.record("a.mov", bytes: 2_000, stage: .none)
        try sb.record("b.mov", bytes: 2_000, onDisk: false, stage: .none)   // the read that fails
        let c = try sb.record("c.mov", bytes: 2_000, stage: .none)
        let calls = CallCounter()
        // First probe (the plan's "is it here?") says yes; after that the
        // drive is gone.
        let job = await runBackfill(sb.model, online: { _ in calls.next() == 1 })
        #expect(a.contentFixity != nil)
        #expect(c.contentFixity == nil, "nothing after the disconnect is read")
        #expect(job.totals[.driveNotConnected] == 2, Comment(rawValue: job.totals.line))
        #expect(job.lanes.first?.phase == .disconnected)
    }

    @Test("an unreadable or missing file is named, counted and skipped; the lane goes on")
    func missingFileNamedAndSkipped() async throws {
        let sb = try ShowAgainSandbox.make("fhb_missing"); defer { sb.cleanup() }
        let gone = try sb.record("a_gone.mov", bytes: 2_000, onDisk: false, stage: .none)
        let next = try sb.record("b_next.mov", bytes: 2_000, stage: .none)
        let job = await runBackfill(sb.model)
        #expect(job.totals[.missing] == 1 && job.totals[.hashed] == 1, Comment(rawValue: job.totals.line))
        #expect(job.problems.contains { $0.path == gone.fullPath && $0.result == .missing })
        #expect(next.contentFixity != nil)
    }

    @Test("a poisoned marker is ignored; the marker lives in the test catalog's folder")
    func poisonedMarkerIgnored() throws {
        let sb = try ShowAgainSandbox.make("fhb_poison"); defer { sb.cleanup() }
        try FileManager.default.createDirectory(at: sb.catalogDir, withIntermediateDirectories: true)
        let file = sb.catalogDir.appendingPathComponent(FullHashBackfillResumeMarker.fileName)
        try Data("{ not json".utf8).write(to: file)
        let marker = FullHashBackfillResumeMarker()
        #expect(marker.attach(catalogFile: sb.model.catalogStore.fileLocation) == nil)
        #expect(marker.menuTitle == "Fill In Full Hashes…")
        #expect(marker.fileURL?.path.hasPrefix(sb.root.path) == true, "never the real Application Support marker")
    }
}

// MARK: - Sensor

@Suite("Fill in full hashes — sensor: read only on media", .serialized)
@MainActor
struct FullHashBackfillSensorTests {

    static let sources = [
        "FullHashBackfill.swift", "FullHashBackfillJob.swift", "FullHashBackfillResume.swift",
        "FullHashBackfillDetailView.swift", "FullHashBackfillMenuItem.swift",
    ]

    @Test("no file-moving, -removing or -writing-to-media call in the backfill's sources")
    func sourceIsReadOnly() throws {
        for name in Self.sources {
            let code = try SourceTree.appSource(named: name).split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for call in CheckCopiesSensorTests.forbidden + ["analyzeDuplicates", "purge", "setAside("] {
                #expect(!code.contains(call), "\(name) calls \(call)")
            }
        }
    }

    @Test("every file is still at its path with the same bytes, inode and mtime after a run")
    func filesUntouched() async throws {
        let sb = try ShowAgainSandbox.make("fhb_ro"); defer { sb.cleanup() }
        let recs = try (0..<4).map { try sb.record("ro\($0).mov", bytes: 3_000 + $0, stage: .none) }
        let before = try recs.map { try MediaFingerprint.of($0.fullPath) }
        let job = await runBackfill(sb.model)
        #expect(job.totals[.hashed] == 4)
        #expect(try recs.map { try MediaFingerprint.of($0.fullPath) } == before)
        let names = try FileManager.default.contentsOfDirectory(atPath: sb.files.path).sorted()
        #expect(names == recs.map(\.filename).sorted(), "nothing appeared beside the media")
    }
}

// MARK: - Media matrix

@Suite("Fill in full hashes — media matrix", .serialized)
@MainActor
struct FullHashBackfillMediaMatrixTests {

    private static let fixtures: [(name: String, args: [String])] = {
        let v = ["-f", "lavfi", "-i", "testsrc=duration=2:size=160x120:rate=25"]
        let a = ["-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000"]
        return [
            ("test_fhb_h264.mp4", v + a + ["-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac"]),
            ("test_fhb_prores.mov", v + a + ["-c:v", "prores_ks", "-c:a", "pcm_s16le"]),
            ("test_fhb_ffv1.mkv", v + a + ["-c:v", "ffv1", "-c:a", "pcm_s16le"]),
            ("test_fhb_mpeg2.mxf", ["-f", "lavfi", "-i", "testsrc=duration=2:size=720x576:rate=25"] + a
                + ["-c:v", "mpeg2video", "-c:a", "pcm_s16le", "-ar", "48000"]),
            ("test_fhb_dv.avi", ["-f", "lavfi", "-i", "testsrc=duration=2:size=720x480:rate=30000/1001"] + a
                + ["-c:v", "dvvideo", "-pix_fmt", "yuv411p", "-c:a", "pcm_s16le"]),
        ]
    }()

    @Test("every container is hashed in full; digests match an independent SHA-256; files unchanged",
          .timeLimit(.minutes(3)))
    func hashesEveryContainer() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("fullhash_mm")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = VideoScanModel(logDirectory: dir.appendingPathComponent("logs", isDirectory: true))
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        for f in Self.fixtures {
            let path = dir.appendingPathComponent(f.name).path
            try CleanupTestMedia.runFFmpeg(f.args, output: path)
            let r = VideoRecord()
            r.fullPath = path; r.filename = f.name; r.directory = dir.path
            r.sizeBytes = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            model.records.append(r)
        }
        let before = try model.records.map { try MediaFingerprint.of($0.fullPath) }
        let job = await runBackfill(model)
        #expect(job.totals.planned == 5 && job.totals[.hashed] == 5, Comment(rawValue: job.totals.line))
        for r in model.records {
            #expect(r.contentFixity?.digest == sha256(r.fullPath), "\(r.filename)")
        }
        #expect(try model.records.map { try MediaFingerprint.of($0.fullPath) } == before, "no file changed")
    }
}
