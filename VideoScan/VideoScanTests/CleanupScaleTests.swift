// CleanupScaleTests.swift
// SCALE dimension for Clean Up Video (feature-test checklist item 2):
// anything that iterates `records` gets exercised at 100k synthetic
// records with an explicit time budget.
//
// Two production surfaces iterate or could accidentally iterate records:
//   1. CleanupJob.catalogCleanupOutput — firstIndex(where:) over
//      model.records + append/replace. Linear by design; these tests pin
//      that a full job stays inside budget at 100k and that the
//      replace-vs-append branch is correct.
//   2. The "Clean Up Video" submenu gate in CatalogContent+Table — must
//      consult ONLY the recipe registry, the operations center's job
//      list, per-record flags, and the reachability cache. Never
//      model.records. Pinned by evaluating the exact gate expression
//      1,000× against a 100k-record model under a budget no O(records)
//      implementation could meet.
//
// Budgets are generous (Debug build, loaded test hosts) — they are
// sensors for complexity-class regressions (O(n) → O(n²)), not
// micro-benchmarks.

import Testing
import Foundation
@testable import VideoScan

@Suite(.serialized) @MainActor
struct CleanupScaleTests {

    private func syntheticRecords(_ n: Int) -> [VideoRecord] {
        (0..<n).map { i in
            let r = VideoRecord()
            r.filename = "clip\(i).mov"
            r.fullPath = "/Volumes/Scale\(i % 8)/dir\(i % 41)/clip\(i).mov"
            r.directory = (r.fullPath as NSString).deletingLastPathComponent
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.durationSeconds = 60
            r.sizeBytes = 1_000_000
            return r
        }
    }

    // MARK: - 1. Full job against a 100k-record catalog, within budget

    @Test("catalog registration appends the cleaned output at 100k records within budget",
          .timeLimit(.minutes(2)))
    func catalogRegistrationAppendsAt100k() async throws {
        let dir = try CleanupTestMedia.makeScratchDir("scale")
        defer { try? FileManager.default.removeItem(at: dir) }
        let srcPath = try TestMediaGenerator.generate(
            container: "mp4", streams: .videoAndAudio, duration: 2.0,
            prefix: "test_cleanup_scale")
        defer { TestMediaGenerator.cleanup(srcPath) }
        // Job reads the source from the record — park the file where the
        // test owns cleanup of the published sibling too.
        let ownedSrc = dir.appendingPathComponent("test_scale_src.mp4").path
        try FileManager.default.moveItem(atPath: srcPath, toPath: ownedSrc)

        let model = VideoScanModel()
        // durationSeconds 0 → estimatedOutputBytes 0 → scratch is the
        // system temp dir. Tests must never mount a real RAM disk.
        let source = makeCleanupSourceRecord(path: ownedSrc,
                                             durationSeconds: 0,
                                             fieldOrder: "tt")
        model.records = syntheticRecords(100_000) + [source]
        #expect(model.records.count == 100_001)

        let job = CleanupJob(record: source,
                             recipe: CleanupRecipeRegistry.vhsQuickClean,
                             model: model,
                             engine: StubCleanupEngine())
        let start = Date()
        job.start()
        await job.task?.value
        let elapsed = Date().timeIntervalSince(start)

        guard case .finished = job.state else {
            Issue.record("job did not finish: \(job.state)")
            return
        }
        // Registration: exactly one append (no duplicate, no wipe).
        #expect(model.records.count == 100_002)
        let published = model.records.last
        #expect(published?.fullPath == job.outputURL.path)
        #expect(published?.derivedFrom == source.id)
        #expect(published?.cleanupRecipeID == "vhs-quick-clean")
        #expect(published?.cleanupRecipeVersion == 1)
        // Source record got its File Journey note (in-place mutation, not
        // an array-level change).
        #expect(source.notes.contains("Created cleaned copy"))
        // Budget: stub render + one copy + one ffprobe + one O(100k)
        // firstIndex. An O(n²)-class regression lands in minutes, not
        // seconds.
        #expect(elapsed < 30.0,
                "Full cleanup job at 100k records took \(elapsed)s — catalog registration has regressed")
    }

    // MARK: - 2. Replace branch: stale record at the output path

    @Test("a stale catalog record at the output path is replaced, not duplicated")
    func catalogRegistrationReplacesStaleRecord() async throws {
        let dir = try CleanupTestMedia.makeScratchDir("scale_replace")
        defer { try? FileManager.default.removeItem(at: dir) }
        let srcPath = try TestMediaGenerator.generate(
            container: "mp4", streams: .videoAndAudio, duration: 2.0,
            prefix: "test_cleanup_replace")
        defer { TestMediaGenerator.cleanup(srcPath) }
        let ownedSrc = dir.appendingPathComponent("test_replace_src.mp4").path
        try FileManager.default.moveItem(atPath: srcPath, toPath: ownedSrc)

        let model = VideoScanModel()
        let source = makeCleanupSourceRecord(path: ownedSrc,
                                             durationSeconds: 0,
                                             fieldOrder: "tt")

        let job = CleanupJob(record: source,
                             recipe: CleanupRecipeRegistry.vhsQuickClean,
                             model: model,
                             engine: StubCleanupEngine())

        // Plant a STALE record already claiming the output path (the file
        // itself does not exist, so init-time uniquify did not bump the
        // name). A rescan-then-cleanup sequence can produce this shape.
        let stale = VideoRecord()
        stale.filename = job.outputURL.lastPathComponent
        stale.fullPath = job.outputURL.path
        model.records = syntheticRecords(1_000) + [source, stale]
        let countBefore = model.records.count

        job.start()
        await job.task?.value

        guard case .finished = job.state else {
            Issue.record("job did not finish: \(job.state)")
            return
        }
        #expect(model.records.count == countBefore,
                "Replace branch must swap the stale record in place, not append a duplicate")
        let atPath = model.records.filter { $0.fullPath == job.outputURL.path }
        #expect(atPath.count == 1)
        #expect(atPath.first?.id != stale.id, "The stale record object must be replaced")
        #expect(atPath.first?.cleanupRecipeID == "vhs-quick-clean")
    }

    // MARK: - 3. Submenu gate does no O(records) work

    @Test("Clean Up Video menu gate scales with jobs + registry, never with records")
    func cleanupMenuGateDoesNoORecordsWork() {
        // The registry the submenu iterates is a compile-time constant —
        // pin that it stays tiny (a per-row Menu building thousands of
        // entries would itself be a bug).
        #expect(CleanupRecipeRegistry.builtIn.count >= 1)
        #expect(CleanupRecipeRegistry.builtIn.count <= 8,
                "Submenu is built per catalog row — registry must stay small")

        let model = VideoScanModel()
        model.records = syntheticRecords(100_000)
        let center = MediaFileOperationsCenter()

        // The EXACT gate expression from CatalogContent+Table (kept in
        // sync by review; the point of the sensor is its complexity
        // class, which only depends on the inputs it consults).
        func gate(for rec: VideoRecord) -> Bool {
            let cleanupRunning = center.jobs.contains { job in
                guard job.state.isActive, let c = job as? CleanupJob else { return false }
                return c.record.id == rec.id
            }
            return !VolumeReachability.isReachable(path: rec.fullPath)
                || cleanupRunning
                || !(rec.streamType == .videoAndAudio || rec.streamType == .videoOnly)
        }

        // Warm the reachability cache once (first touch schedules a
        // background probe and returns the optimistic default).
        _ = gate(for: model.records[0])

        let start = Date()
        var blockedCount = 0
        for i in 0..<1_000 {
            if gate(for: model.records[i * 97 % model.records.count]) {
                blockedCount += 1
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        // 1,000 row-gate evaluations against a 100k catalog. An O(records)
        // gate would cost ≥ 10^8 record touches and blow far past this.
        #expect(elapsed < 1.0,
                "Menu gate took \(elapsed)s for 1,000 evaluations at 100k records — something now scans the catalog per row")
        // Sanity so the loop can't be optimized into nothing.
        #expect(blockedCount >= 0)
    }
}
