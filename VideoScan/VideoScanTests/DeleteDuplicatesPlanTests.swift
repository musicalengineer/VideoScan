// DeleteDuplicatesPlanTests.swift
// The saved plan, the store, the rate/ETA math and the resume offer —
// everything that is pure or file-only (no VideoScanModel). The job's
// behaviour with a live catalog is in DeleteDuplicatesJobTests.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempRoot(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_dupplan_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func entry(_ name: String, size: Int64 = 1_000, status: DeleteDuplicatesPlan.EntryStatus = .pending)
    -> DeleteDuplicatesPlan.Entry {
    var e = DeleteDuplicatesPlan.Entry(id: UUID(), path: "/Volumes/SanDisk/\(name)", filename: name, sizeBytes: size,
                                       keeperID: UUID(), keeperPath: "/Volumes/LaCie/\(name)", keeperFilename: name,
                                       keeperStamp: nil)
    e.status = status
    return e
}

private func plan(_ entries: [DeleteDuplicatesPlan.Entry], catalog: String = "/tmp/cat/catalog.json") -> DeleteDuplicatesPlan {
    DeleteDuplicatesPlan(volumePath: "/Volumes/SanDisk", catalogLocation: catalog, crossVolumeMode: false,
                         skippedBeforePlan: 0, summaryLine: "\(entries.count) same-drive extras", entries: entries)
}

// MARK: - Rate / ETA (table-tested)

@Suite("DeleteDuplicatesRate — pure ETA math")
struct DeleteDuplicatesRateTests {

    @Test func noEstimateBeforeFivePairs() {
        var r = DeleteDuplicatesRate()
        for _ in 0..<4 { r.add(bytes: 1_000_000, seconds: 1) }
        #expect(r.bytesPerSecond == 1_000_000)
        #expect(r.secondsRemaining(remainingBytes: 10_000_000) == nil, "ETA only after ≥ 5 pairs")
        r.add(bytes: 1_000_000, seconds: 1)
        #expect(r.secondsRemaining(remainingBytes: 10_000_000) == 10)
    }

    @Test func rateIsOverTheLastTwentyPairsOnly() {
        var r = DeleteDuplicatesRate()
        for _ in 0..<20 { r.add(bytes: 100, seconds: 1) }          // 100 B/s — the keeper's slow first reads
        for _ in 0..<20 { r.add(bytes: 1_000, seconds: 1) }        // 1 kB/s — cruising
        #expect(r.bytesPerSecond == 1_000, "old samples must have fallen out of the window")
        #expect(r.samples.count == DeleteDuplicatesRate.window)
        #expect(r.pairsSeen == 40)
    }

    @Test func zeroSecondsYieldsNoRate() {
        var r = DeleteDuplicatesRate()
        for _ in 0..<6 { r.add(bytes: 10, seconds: 0) }
        #expect(r.bytesPerSecond == nil)
        #expect(r.secondsRemaining(remainingBytes: 1) == nil)
    }

    @Test(arguments: [
        (30.0, "under a minute left"),
        (240.0, "about 4 min left"),
        (3_600.0, "about 1 h left"),
        (7_800.0, "about 2 h 10 min left"),
        (86_400.0 + 60, "about 24 h 1 min left"),
    ])
    func etaTextTable(seconds: Double, expected: String) {
        #expect(DeleteDuplicatesRate.etaText(seconds: seconds) == expected)
    }

    @Test func subtitleReadsAsRickAskedFor() {
        var c = DeleteDuplicatesPlan.Counts()
        c.total = 2_992; c.deleted = 3; c.refused = 1; c.totalBytes = 3_000_000_000_000; c.settledBytes = 5_000_000_000
        var r = DeleteDuplicatesRate()
        // 1.4 GB/s over five pairs; 2,995 GB left ≈ 2,139 s… scale so the ETA is 2 h 10 min.
        let bps = Double(c.totalBytes - c.settledBytes) / 7_800.0
        for _ in 0..<5 { r.add(bytes: Int64(bps), seconds: 1) }
        let text = DeleteDuplicatesRate.subtitle(counts: c, rate: r)
        #expect(text.hasPrefix("verified 4 of 2,992 · 3 deleted · 1 refused · "))
        #expect(text.hasSuffix("/s · about 2 h 10 min left"), Comment(rawValue: text))
    }

    @Test func subtitleOmitsWhatIsNotKnownYetAndSaysPaused() {
        var c = DeleteDuplicatesPlan.Counts(); c.total = 10
        #expect(DeleteDuplicatesRate.subtitle(counts: c, rate: DeleteDuplicatesRate()) == "verified 0 of 10")
        // Rick 2026-09-20 evening: a paused run says where it holds.
        #expect(DeleteDuplicatesRate.subtitle(counts: c, rate: DeleteDuplicatesRate(), paused: true) == "Paused at 0 of 10")
    }
}

// MARK: - Plan counts / offer / transitions

@Suite("DeleteDuplicatesPlan — counts and offer")
struct DeleteDuplicatesPlanShapeTests {

    @Test func countsAndFractionAreByBytes() {
        var p = plan([entry("a", size: 100), entry("b", size: 300), entry("c", size: 600)])
        p.set(p.entries[0].id, .deleted)
        p.set(p.entries[1].id, .refused, note: "differs")
        let c = p.counts
        #expect(c.total == 3 && c.deleted == 1 && c.refused == 1 && c.pending == 1)
        #expect(c.settledBytes == 400 && c.totalBytes == 1_000 && c.freedBytes == 100)
        #expect(c.fraction == 0.4, "progress is bytes verified over total duplicate bytes")
        #expect(p.remainingCount == 1 && p.isResumable)
        #expect(p.entries[1].note == "differs" && p.entries[1].settledAt != nil)
    }

    @Test func resumeOfferSentence() {
        var p = plan((0..<2_992).map { entry("f\($0).mov") })
        for e in p.entries.prefix(1_789) { p.set(e.id, .deleted) }
        #expect(p.resumeOffer == "Resume deleting duplicates on SanDisk — 1,203 of 2,992 remaining?")
    }

    @Test func skipRemainingSettlesOnlyUnsettledRows() {
        var p = plan([entry("a", status: .deleted), entry("b"), entry("c", status: .verifying)])
        #expect(p.skipRemaining(reason: "cancelled") == 2)
        #expect(p.entries.map(\.status) == [.deleted, .skipped, .skipped])
        #expect(p.remainingCount == 0 && !p.isResumable)
        p.finishedAt = Date()
        #expect(!p.isResumable)
    }

    @Test func snapshotStalenessRule() throws {
        let dir = tempRoot("stale"); defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = dir.appendingPathComponent("catalog.json"); try Data("{}".utf8).write(to: catalog)
        let snap = dir.appendingPathComponent("snap.json"); try Data("{}".utf8).write(to: snap)
        let old = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: snap.path)
        #expect(DeleteDuplicatesJob.snapshotIsStale(snapshotPath: snap.path, takenAt: old, catalogLocation: catalog.path))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: snap.path)
        #expect(!DeleteDuplicatesJob.snapshotIsStale(snapshotPath: snap.path, takenAt: nil, catalogLocation: catalog.path))
        #expect(DeleteDuplicatesJob.snapshotIsStale(snapshotPath: nil, takenAt: nil, catalogLocation: catalog.path), "no snapshot = stale")
        #expect(DeleteDuplicatesJob.snapshotIsStale(snapshotPath: dir.appendingPathComponent("missing").path,
                                                     takenAt: Date(), catalogLocation: catalog.path))
    }
}

// MARK: - Store: save / load / list / done / isolation / scale

@Suite("DeleteDuplicatesPlanStore")
struct DeleteDuplicatesPlanStoreTests {

    @Test func saveLoadListAndMoveToDone() throws {
        let root = tempRoot("store"); defer { try? FileManager.default.removeItem(at: root) }
        var p = plan([entry("a"), entry("b")])
        try DeleteDuplicatesPlanStore.save(p, root: root)
        let url = DeleteDuplicatesPlanStore.planURL(for: p.id, root: root)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let back = try DeleteDuplicatesPlanStore.load(url: url)
        // ISO-8601 keeps whole seconds, so compare the fields, not the dates.
        #expect(back.id == p.id && back.entries == p.entries && back.volumePath == p.volumePath
                && back.catalogLocation == p.catalogLocation && back.finishedAt == nil)

        var listed = DeleteDuplicatesPlanStore.unfinishedPlans(root: root, log: { _ in })
        #expect(listed.map(\.id) == [p.id])

        p.set(p.entries[0].id, .deleted); p.set(p.entries[1].id, .refused, note: "x")
        p.finishedAt = Date(); p.outcome = "completed"
        try DeleteDuplicatesPlanStore.save(p, root: root)
        listed = DeleteDuplicatesPlanStore.unfinishedPlans(root: root, log: { _ in })
        #expect(listed.isEmpty, "a finished plan is never offered")

        try DeleteDuplicatesPlanStore.moveToDone(p, root: root)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let done = DeleteDuplicatesPlanStore.doneURL(for: p.id, root: root).appendingPathComponent("plan.json")
        #expect(FileManager.default.fileExists(atPath: done.path), "kept for the log under done/")
        #expect(try DeleteDuplicatesPlanStore.load(url: done).outcome == "completed")
        // Filing the same id twice does not clobber the first record.
        try DeleteDuplicatesPlanStore.save(p, root: root)
        try DeleteDuplicatesPlanStore.moveToDone(p, root: root)
        let doneNames = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("done").path)
        #expect(doneNames.count == 2)
    }

    @Test func unreadablePlanIsNamedAndLeftAlone() throws {
        let root = tempRoot("unreadable"); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let dir = DeleteDuplicatesPlanStore.directory(for: id, root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("plan.json"))
        var lines: [String] = []
        let plans = DeleteDuplicatesPlanStore.unfinishedPlans(root: root, log: { lines.append($0) })
        #expect(plans.isEmpty)
        #expect(lines.count == 1 && lines[0].contains(id.uuidString) && lines[0].contains("left in place"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("plan.json").path))
    }

    @Test func orderedWriterDropsStaleGenerations() async throws {
        let root = tempRoot("writer"); defer { try? FileManager.default.removeItem(at: root) }
        var p = plan([entry("a")])
        let writer = DeleteDuplicatesPlanWriter()
        p.log = ["gen 2"]
        let wroteNewer = try await writer.write(p, root: root, generation: 2)
        #expect(wroteNewer)
        p.log = ["gen 1 — stale"]
        let wroteStale = try await writer.write(p, root: root, generation: 1)
        #expect(wroteStale == false)
        let back = try DeleteDuplicatesPlanStore.load(url: DeleteDuplicatesPlanStore.planURL(for: p.id, root: root))
        #expect(back.log == ["gen 2"])
    }

    /// QA MINOR 4: the writer remembers the last generation per plan id, so
    /// a same-process resume can seed its counter and never be dropped.
    @Test func orderedWriterExposesLastGeneration() async throws {
        let root = tempRoot("lastgen"); defer { try? FileManager.default.removeItem(at: root) }
        let p = plan([entry("a")])
        let writer = DeleteDuplicatesPlanWriter()
        #expect(await writer.lastGeneration(for: p.id) == 0)
        _ = try await writer.write(p, root: root, generation: 7)
        #expect(await writer.lastGeneration(for: p.id) == 7)
        #expect(await writer.lastGeneration(for: UUID()) == 0)
    }

    /// Isolation: under the test host the store root is per-process scratch,
    /// never Rick's App Support — so a job started through the normal entry
    /// point in any test cannot write (or offer) real plans.
    @Test func testHostRootIsScratchNotAppSupport() {
        let root = DeleteDuplicatesPlanStore.defaultRoot.path
        #expect(TestEnvironment.isTestHost)
        #expect(root == DeleteDuplicatesPlanStore.testHostRoot.path)
        #expect(!root.contains("Application Support"))
        #expect(root.contains("delete-duplicates-\(ProcessInfo.processInfo.processIdentifier)"))
    }

    @Test("10k-pair plan saves and loads under budget", .timeLimit(.minutes(1)))
    func scaleTenThousandPairs() throws {
        let root = tempRoot("scale"); defer { try? FileManager.default.removeItem(at: root) }
        let stamp = FileIdentityStamp(device: 1, inode: 2, size: 3, mtimeNs: 4)
        var entries: [DeleteDuplicatesPlan.Entry] = []
        entries.reserveCapacity(10_000)
        for i in 0..<10_000 {
            var e = entry("copy-\(i).mov", size: 2_000_000_000)
            e.keeperStamp = stamp
            entries.append(e)
        }
        var p = plan(entries)
        let start = ContinuousClock.now
        try DeleteDuplicatesPlanStore.save(p, root: root)
        let saved = start.duration(to: .now)
        let loadStart = ContinuousClock.now
        let back = try DeleteDuplicatesPlanStore.load(url: DeleteDuplicatesPlanStore.planURL(for: p.id, root: root))
        let loaded = loadStart.duration(to: .now)
        #expect(back.entries.count == 10_000)
        #expect(saved < .seconds(3), "10k-entry save took \(saved)")
        #expect(loaded < .seconds(3), "10k-entry load took \(loaded)")
        // Counting is O(n) once per pair, so it must be cheap too.
        let countStart = ContinuousClock.now
        p.set(p.entries[5_000].id, .deleted)
        _ = p.counts
        #expect(countStart.duration(to: .now) < .seconds(1))
    }
}
