// FootageCodex1674Tests.swift
// codex #1674 — the Find Similar Footage review (2026-09-23). One suite per
// finding, written RED first against 9cf2e81e, plus the sensor codex asked
// for (distinct recordings stay eligible in the Angel and visible in "One
// per footage"). Five-dimension checklist:
//   LOGIC     F1 (sampled ≠ Identical), F2 (component dates), F3 (apply
//             closure), F4 (decision revisions), F5 (bounded window)
//   SCALE     F5: 20k same-stem, equal-length, conflicting-date records
//   MEDIA     F1: two real 6 MiB `test_*` files, equal under FileHasher's
//             sampled windows and different in full (no codec involved —
//             the walk opens no media; the hash reads bytes)
//   ISOLATION every model test uses a sandboxed catalog + ledger
//   SENSOR    "two different recordings are both still offered"
// No real catalog is ever read here.

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Helpers

@MainActor
private enum C4 {
    static func model(_ label: String) throws -> (VideoScanModel, MasterArchiveTestSupport.Sandbox) {
        let sb = try MasterArchiveTestSupport.makeSandbox("footage1674_\(label)")
        let m = MasterArchiveTestSupport.makeModel(sb)
        m.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        return (m, sb)
    }

    static func rec(_ name: String, dir: String = "/Volumes/T/a", dur: Double, hash: String = "",
                    size: Int64 = 1000) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = dir + "/" + name
        r.directory = dir
        r.durationSeconds = dur
        r.frameRate = "29.97"
        r.sizeBytes = size
        r.contentHash = hash
        r.videoCodec = "h264"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return r
    }

    static func run(_ m: VideoScanModel, _ scope: FootageScope = .catalog) async -> FindSimilarFootageJob {
        let job = FindSimilarFootageJob(scope: scope, model: m)
        job.start()
        await job.task?.value
        return job
    }

    static func membership(_ g: UUID, size: Int, rank: Int) -> FootageMembership {
        FootageMembership(groupID: g, groupSize: size, confidence: .likely, role: rank == 0 ? .original : .related,
                          rank: rank, likelyOriginalID: g, originalInCatalog: true, evidence: [],
                          scannedAt: .distantPast, algorithmVersion: FootageGrouping.algorithmVersion)
    }

    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// Every record that has an answer agrees with the others about its
    /// group: groupSize == the number of records carrying that group id.
    static func consistent(_ recs: [VideoRecord]) -> Bool {
        var count: [UUID: Int] = [:]
        for r in recs { if let g = r.footage?.groupID { count[g, default: 0] += 1 } }
        return recs.allSatisfy { r in r.footage.map { count[$0.groupID] == $0.groupSize } ?? true }
    }

    /// Two real 6 MiB files whose FileHasher sampled windows are equal and
    /// whose full bytes differ (the difference sits between the first and
    /// the middle window). Named `test_*` (fixture convention).
    static func sampledTwins(in dir: URL) throws -> (URL, URL) {
        let size = 6 * 1024 * 1024
        var bytes = [UInt8](repeating: 0x5A, count: size)
        let a = dir.appendingPathComponent("test_sample_twin_a.bin")
        let b = dir.appendingPathComponent("test_sample_twin_b.bin")
        try Data(bytes).write(to: a)
        bytes[1024 * 1024 + 512 * 1024] = 0xA5      // 1.5 MiB: outside every sampled window
        try Data(bytes).write(to: b)
        return (a, b)
    }
}

// MARK: - F1 (P1): a sampled signature only NOMINATES

@Suite("codex #1674 F1 — equal SAMPLED signatures are never Identical / 'same bytes'", .serialized)
@MainActor
struct Footage1674SampledNotIdenticalTests {

    @Test("probe replica: equal segmented content hash, no whole-file digest → at most Likely, never 'same bytes'")
    func probeReplica() {
        let a = FootageInput(filename: "UnrelatedA.mov", sizeBytes: 6_291_456, contentHash: "v1:seg")
        let b = FootageInput(filename: "UnrelatedB.mov", sizeBytes: 6_291_456, contentHash: "v1:seg")
        let r = FootageGrouping.run([a, b])
        #expect(r.groups.allSatisfy { $0.confidence != .identical }, "\(r.groups.map(\.confidence))")
        let ev = r.memberships.values.flatMap(\.evidence)
        #expect(!ev.contains { $0.contains("same bytes") }, "\(ev)")
        #expect(!a.sameBytes(as: b), "sampled equality is not byte identity")
    }

    @Test("real 6 MiB twins (FileHasher sampled-equal, SHA-256 different) through the job → not Identical")
    func realTwinsThroughJob() async throws {
        let (m, sb) = try C4.model("f1real")
        defer { sb.cleanup() }
        let (fa, fb) = try C4.sampledTwins(in: sb.root)
        let ha = FileHasher.segmentedHash(path: fa.path), hb = FileHasher.segmentedHash(path: fb.path)
        try #require(!ha.isEmpty && ha == hb, "fixture must be sampled-equal")
        try #require(try C4.sha256(fa) != C4.sha256(fb), "fixture must differ in full")
        let a = C4.rec("UnrelatedA.mov", dir: fa.deletingLastPathComponent().path, dur: 0, hash: ha, size: 6_291_456)
        a.fullPath = fa.path
        let b = C4.rec("UnrelatedB.mov", dir: fb.deletingLastPathComponent().path, dur: 0, hash: hb, size: 6_291_456)
        b.fullPath = fb.path
        m.records = [a, b]
        _ = await C4.run(m)
        #expect(a.footage?.confidence != .identical && b.footage?.confidence != .identical)
        let ev = (a.footage?.evidence ?? []) + (b.footage?.evidence ?? [])
        #expect(!ev.contains { $0.contains("same bytes") }, "\(ev)")
    }

    @Test("a stored whole-file digest that no longer describes the file (rewritten) is not 'same bytes'")
    func staleDigestIsNotIdentical() async throws {
        let (m, sb) = try C4.model("f1stale")
        defer { sb.cleanup() }
        let fa = sb.root.appendingPathComponent("test_stale_a.bin"), fb = sb.root.appendingPathComponent("test_stale_b.bin")
        let body = Data(repeating: 7, count: 4096)
        try body.write(to: fa)
        try body.write(to: fb)
        let digest = try C4.sha256(fa)
        let a = C4.rec("A.mov", dur: 0, hash: "v1:same", size: 4096)
        a.fullPath = fa.path
        let b = C4.rec("B.mov", dur: 0, hash: "v1:same", size: 4096)
        b.fullPath = fb.path
        a.contentFixity = try #require(ContentFixity.captured(path: fa.path, digest: digest, byteCount: 4096))
        b.contentFixity = try #require(ContentFixity.captured(path: fb.path, digest: digest, byteCount: 4096))
        // b is rewritten in place at the same size after its digest was taken.
        try await Task.sleep(for: .milliseconds(20))
        try Data(repeating: 9, count: 4096).write(to: fb)
        m.records = [a, b]
        _ = await C4.run(m)
        #expect(b.footage?.confidence != .identical, "b's digest is stale — it proves nothing now")
        #expect(!(b.footage?.evidence ?? []).contains { $0.contains("same bytes") })
    }

    @Test("two real byte-identical files with CURRENT digests → Identical, 'same bytes (… checked current)'")
    func currentDigestsThroughJob() async throws {
        let (m, sb) = try C4.model("f1current")
        defer { sb.cleanup() }
        let fa = sb.root.appendingPathComponent("test_cur_a.bin"), fb = sb.root.appendingPathComponent("test_cur_b.bin")
        let body = Data(repeating: 3, count: 8192)
        try body.write(to: fa)
        try body.write(to: fb)
        let digest = try C4.sha256(fa)
        let a = C4.rec("Reunion.mov", dur: 0, size: 8192), b = C4.rec("Totally other.mov", dur: 0, size: 8192)
        a.fullPath = fa.path
        b.fullPath = fb.path
        a.contentFixity = try #require(ContentFixity.captured(path: fa.path, digest: digest, byteCount: 8192))
        b.contentFixity = try #require(ContentFixity.captured(path: fb.path, digest: digest, byteCount: 8192))
        m.records = [a, b]
        let job = await C4.run(m)
        #expect(a.footage?.confidence == .identical && a.footage?.groupID == b.footage?.groupID)
        #expect((a.footage?.evidence ?? []).contains { $0.contains("checked current") })
        #expect(job.summary?.digestsChecked == 2 && job.summary?.digestsCurrent == 2)
    }
}

// MARK: - DateKey ≡ ArchiveItemVersions.datesCompatible

@Suite("codex #1674 — DateKey answers exactly as datesCompatible")
struct Footage1674DateKeyTests {

    static let prefixes: [String?] = [nil, "1990-12-25", "1990-xx-xx", "1990", "1990-12", "xxxx-12-25", "xxxx",
                                      "1994-12-25", "1990-1x-25", "1990-12-2x", "1990-xx-25", "1990-11-25",
                                      "xxxx-xx-26"]

    @Test("every pair agrees")
    func table() {
        for a in Self.prefixes {
            for b in Self.prefixes {
                let want = ArchiveItemVersions.datesCompatible(a, b)
                let got = FootageGrouping.DateKey(a).compatible(with: FootageGrouping.DateKey(b))
                #expect(got == want, "\(a ?? "nil") vs \(b ?? "nil")")
            }
        }
    }
}

// MARK: - F5 cancellation inside the linking phase

@Suite("codex #1674 F5 — Stop is honoured INSIDE the linking phase")
struct Footage1674CancellationTests {

    @Test("a cancelled task stops the name window early and marks the result cancelled")
    func cancelledEarly() async {
        let xs = Footage1674WindowBoundTests.conflicting(sameYear: false)
        let t = Task { () -> FootageGrouping.Stats in
            var stats = FootageGrouping.Stats()
            let p = FootageGrouping.prepare(xs, options: .init(), stats: &stats)
            while !Task.isCancelled { await Task.yield() }
            _ = FootageGrouping.edges(p, stats: &stats)
            return stats
        }
        t.cancel()
        let stats = await t.value
        #expect(stats.cancelled)
        #expect(stats.windowExamined == 0, "examined \(stats.windowExamined) after the Stop")
    }
}

// MARK: - codex #1717 P3: Stop is polled INSIDE one huge name bucket

@Suite("codex #1717 P3 — the name window polls Stop inside a single bucket")
struct Footage1717InnerCancelTests {

    @Test("one 12k-member bucket: a Stop after the bucket starts is seen mid-bucket, cancelled = true")
    func cancelInsideOneBucket() {
        // Every file is "Christmas" at the same length, all undated — ONE
        // bucket, one partition. The outer (between-bucket) poll runs once,
        // before the bucket; Stop arrives just after it. Before the fix the
        // whole bucket ran to the end with Stop ignored.
        let xs = (0..<12_000).map { i in
            FootageInput(filename: "Christmas.mov", durationSeconds: 600, sizeBytes: Int64(i + 1))
        }
        var stats = FootageGrouping.Stats()
        let p = FootageGrouping.prepare(xs, options: .init(), stats: &stats)
        var b = FootageGrouping.EdgeBuilder(p: p)
        var polls = 0
        b.cancelCheck = { polls += 1; return polls >= 2 }   // the outer poll says go, the next says Stop
        b.nameAndDuration()
        #expect(b.cancelled, "Stop inside the bucket must be honoured (polls \(polls))")
        #expect(polls == 2, "stopped at the first inner poll")
        let everyWindow = xs.count * FootageGrouping.maxWindowExamined
        #expect(b.windowExamined <= FootageGrouping.cancelPollStride * FootageGrouping.maxWindowExamined,
                "examined \(b.windowExamined) (whole bucket ≈ \(everyWindow)) before honouring Stop")
    }

    @Test("never cancelled: the inner poll changes nothing — same edges as a run with no Stop")
    func noStopNoChange() {
        let xs = (0..<9_000).map { i in
            FootageInput(filename: "Christmas.mov", durationSeconds: 600 + Double(i % 7), sizeBytes: Int64(i + 1))
        }
        var s1 = FootageGrouping.Stats(), s2 = FootageGrouping.Stats()
        let p = FootageGrouping.prepare(xs, options: .init(), stats: &s1)
        _ = FootageGrouping.prepare(xs, options: .init(), stats: &s2)
        var a = FootageGrouping.EdgeBuilder(p: p), b = FootageGrouping.EdgeBuilder(p: p)
        var polls = 0
        b.cancelCheck = { polls += 1; return false }
        a.nameAndDuration(); b.nameAndDuration()
        #expect(!a.cancelled && !b.cancelled)
        #expect(polls > 1, "the inner poll ran (\(polls))")
        #expect(a.out == b.out && a.windowExamined == b.windowExamined)
    }
}

// MARK: - F2 (P2): component dates

@Suite("codex #1674 F2 — an undated bridge never joins two different dates")
struct Footage1674ComponentDateTests {

    @Test("probe replica: 1990-12-25 / undated / 1994-12-25 Christmas → the two dated files never share a group")
    func undatedBridge() {
        let a = FootageInput(filename: "1990-12-25 Christmas.mov", durationSeconds: 600)
        let m = FootageInput(filename: "Christmas.mov", durationSeconds: 600)
        let c = FootageInput(filename: "1994-12-25 Christmas.mov", durationSeconds: 600)
        let r = FootageGrouping.run([a, m, c])
        let ga = r.memberships[a.id]?.groupID, gc = r.memberships[c.id]?.groupID
        #expect(ga == nil || gc == nil || ga != gc, "1990 and 1994 joined through the undated file")
        #expect(r.groups.allSatisfy { $0.memberIDs.count <= 2 })
    }

    @Test("a partial date (1990-xx-xx) bridges only compatible days")
    func partialDates() {
        let a = FootageInput(filename: "1990-12-25 Christmas.mov", durationSeconds: 600)
        let p = FootageInput(filename: "1990-xx-xx Christmas.mov", durationSeconds: 600)
        let c = FootageInput(filename: "1990-12-26 Christmas.mov", durationSeconds: 600)
        let r = FootageGrouping.run([a, p, c])
        let ga = r.memberships[a.id]?.groupID, gc = r.memberships[c.id]?.groupID
        #expect(ga == nil || gc == nil || ga != gc, "12-25 and 12-26 joined through 1990-xx-xx")
    }
}

// MARK: - F3 (P2): scoped apply = connected closure of old + new groups

@Suite("codex #1674 F3 — a scoped run writes whole connected units", .serialized)
@MainActor
struct Footage1674ApplyClosureTests {

    /// Old group {A,B}; the new grouping is {B,C} (A no longer matches).
    private func fixture() -> (VideoRecord, VideoRecord, VideoRecord) {
        let a = C4.rec("Lake house dock.mov", dur: 50)
        let b = C4.rec("Wedding1988.mov", dur: 100)
        let c = C4.rec("Wedding1988.mov", dir: "/Volumes/U/c", dur: 100)
        let old = UUID()
        a.footage = C4.membership(old, size: 2, rank: 0)
        b.footage = C4.membership(old, size: 2, rank: 1)
        return (a, b, c)
    }

    @Test("old {A,B}, new {B,C}, scope A → A, B AND C are re-answered, consistently")
    func closureReachesC() async throws {
        let (m, sb) = try C4.model("f3scope")
        defer { sb.cleanup() }
        let (a, b, c) = fixture()
        m.records = [a, b, c]
        let result = FootageGrouping.run(m.footageInputs())
        let touched = VideoScanModel.footageTouchedIDs(result: result, inputs: m.footageInputs(), scope: .records([a.id]))
        #expect(touched.contains(c.id), "C joined B's new group — it must be written with it")
        _ = await C4.run(m, .records([a.id]))
        #expect(a.footage == nil)
        #expect(b.footage != nil && b.footage?.groupID == c.footage?.groupID)
        #expect(C4.consistent([a, b, c]))
    }

    @Test("Stop between slices never splits an old+new connected unit")
    func stopNeverSplitsUnit() async throws {
        let (m, sb) = try C4.model("f3stop")
        defer { sb.cleanup() }
        let (a, b, c) = fixture()
        let lone = C4.rec("Unrelated.mov", dur: 7)
        m.records = [a, b, c, lone]
        let result = FootageGrouping.run(m.footageInputs())
        var calls = 0
        let out = await m.applyFootage(result, touched: Set([a.id, b.id, c.id, lone.id]), sliceSize: 1,
                                       checkpoint: { calls += 1; return calls <= 1 })
        #expect(out.stopped)
        #expect(C4.consistent([a, b, c]), "A kept a group of 2 whose other member left it")
    }
}

// MARK: - F4 (P2): a decision made while a run is in flight

@Suite("codex #1674 F4 — a run never applies a snapshot older than the person's latest answer", .serialized)
@MainActor
struct Footage1674DecisionRevisionTests {

    @Test("Not same during a pause + the sheet's rerun request → no rejected group, the rerun happens")
    func pausedRunThenDecisionAndRequest() async throws {
        let (m, sb) = try C4.model("f4a")
        defer { sb.cleanup() }
        let a = C4.rec("Birthday1979.mov", dur: 300), b = C4.rec("Birthday1979.mov", dir: "/Volumes/U/b", dur: 300)
        m.records = [a, b]
        let center = MediaFileOperationsCenter()
        let first = center.startFindSimilarFootage(scope: .catalog, model: m)
        first.pause()                       // parks after reading the catalog
        try await Task.sleep(for: .milliseconds(300))
        await m.setFootageDecision(.notSame, between: a.id, and: b.id)?.value
        let second = center.startFindSimilarFootage(scope: .records([a.id, b.id]), model: m)
        #expect(!second.wasRefused, "the rerun is queued, not refused")
        first.resume()
        await first.task?.value
        await second.task?.value
        await first.followUp?.task?.value
        #expect(a.footage == nil && b.footage == nil, "the rejected group was written by a stale run")
        #expect(first.discardedStale)
        #expect(first.followUp != nil, "the discarded run queued its own fresh run")
    }

    @Test("Not same during a pause with NO rerun request → the stale run queues one itself")
    func pausedRunThenDecisionOnly() async throws {
        let (m, sb) = try C4.model("f4b")
        defer { sb.cleanup() }
        let a = C4.rec("Graduation1995.mov", dur: 300), b = C4.rec("Graduation1995.mov", dir: "/Volumes/U/b", dur: 300)
        m.records = [a, b]
        let center = MediaFileOperationsCenter()
        let first = center.startFindSimilarFootage(scope: .catalog, model: m)
        first.pause()
        try await Task.sleep(for: .milliseconds(300))
        await m.setFootageDecision(.notSame, between: a.id, and: b.id)?.value
        first.resume()
        await first.task?.value
        // Wait for any follow-up run the center holds.
        for _ in 0..<50 {
            let active = center.jobs.compactMap { $0 as? FindSimilarFootageJob }.filter { $0.state.isActive }
            if active.isEmpty { break }
            for j in active { await j.task?.value }
        }
        #expect(a.footage == nil && b.footage == nil, "the stale run's answer stood and nothing re-ran")
    }
}

// MARK: - F5 (P2): the name/length window is bounded by what it EXAMINES

@Suite("codex #1674 F5 — SCALE: conflicting dates cannot make the name window quadratic")
struct Footage1674WindowBoundTests {

    /// 20k records: one stem, one length, 20k different dates.
    static func conflicting(sameYear: Bool) -> [FootageInput] {
        (0..<20_000).map { i in
            let y = sameYear ? 1990 : 1900 + i % 100
            let mo = 1 + (i / 100) % 12, d = 1 + (i / 1200) % 28
            let date = String(format: "%04d-%02d-%02d", y, mo, d)
            return FootageInput(filename: "\(date) Christmas.mov", durationSeconds: 600, sizeBytes: Int64(i + 1))
        }
    }

    @Test("20k same-stem, equal-length, all-different-date records → zero groups, under budget",
          .timeLimit(.minutes(1)))
    func allDifferentDates() {
        let xs = Self.conflicting(sameYear: false)
        let clock = ContinuousClock()
        let t0 = clock.now
        let r = FootageGrouping.run(xs)
        let dt = clock.now - t0
        #expect(r.stats.groups == 0)
        #expect(dt < PerformanceLane.debugCeiling(.seconds(5)), "took \(dt)")
    }

    @Test("20k in ONE year (many equal dates) → only equal-date groups, under budget", .timeLimit(.minutes(1)))
    func oneYear() {
        let xs = Self.conflicting(sameYear: true)
        let clock = ContinuousClock()
        let t0 = clock.now
        let r = FootageGrouping.run(xs)
        let dt = clock.now - t0
        // 5 s locally; ×3 on a GitHub-hosted runner only (6.6 s there, run 36202513830).
        #expect(dt < PerformanceLane.debugCeiling(.seconds(5)), "took \(dt)")
        let prefix = Dictionary(uniqueKeysWithValues: xs.map { ($0.id, String($0.filename.prefix(10))) })
        for g in r.groups {
            #expect(Set(g.memberIDs.compactMap { prefix[$0] }).count == 1, "a group mixed different days")
        }
    }
}

// MARK: - Sensor: distinct recordings stay offered

@Suite("codex #1674 SENSOR — two different recordings are BOTH offered (Angel + One per footage)", .serialized)
@MainActor
struct Footage1674DistinctRecordingsSensorTests {

    private func angelEligible(_ recs: [VideoRecord]) -> [Bool] {
        let cands = recs.map { r in
            ArchiveAngelCandidate(filename: r.filename, starRating: 3, userDate: "1990", videoCodec: "dvvideo",
                                  footageGroupID: r.footage?.groupID, footageRank: r.footage?.rank,
                                  footageConfidence: r.footage?.confidence)
        }
        var rules = AngelRecommendationPolicy.builtIn.recommend
        rules.useAngelFloors = false
        return ArchiveAngelRecommendations.classify(cands, rules: rules).verdicts.map { $0.kind != .anotherCopy }
    }

    @Test("sampled-equal, whole-file digests CURRENT and different → both eligible, both visible")
    func sampledEqualFullDifferent() async throws {
        let (m, sb) = try C4.model("sensor1")
        defer { sb.cleanup() }
        let (fa, fb) = try C4.sampledTwins(in: sb.root)
        let h = FileHasher.segmentedHash(path: fa.path)
        let a = C4.rec("Tape A.mov", dur: 0, hash: h, size: 6_291_456)
        a.fullPath = fa.path
        a.partialMD5 = "same-sample"
        let b = C4.rec("Tape B.mov", dur: 0, hash: FileHasher.segmentedHash(path: fb.path), size: 6_291_456)
        b.fullPath = fb.path
        b.partialMD5 = "same-sample"
        a.contentFixity = try #require(ContentFixity.captured(path: fa.path, digest: try C4.sha256(fa), byteCount: 6_291_456))
        b.contentFixity = try #require(ContentFixity.captured(path: fb.path, digest: try C4.sha256(fb), byteCount: 6_291_456))
        m.records = [a, b]
        _ = await C4.run(m)
        #expect(angelEligible([a, b]) == [true, true])
        #expect(FootageOnePerGroup.filter([a, b]).count == 2)
    }

    @Test("1990 / undated / 1994 Christmas → the 1990 and 1994 tapes are both eligible and both visible")
    func twoChristmases() async throws {
        let (m, sb) = try C4.model("sensor2")
        defer { sb.cleanup() }
        let a = C4.rec("1990-12-25 Christmas.mov", dur: 600)
        let mid = C4.rec("Christmas.mov", dir: "/Volumes/U/m", dur: 600)
        let c = C4.rec("1994-12-25 Christmas.mov", dir: "/Volumes/U/c", dur: 600)
        m.records = [a, mid, c]
        _ = await C4.run(m)
        let visible = FootageOnePerGroup.filter([a, mid, c]).map(\.id)
        #expect(visible.contains(a.id) && visible.contains(c.id), "One per footage hid a different Christmas")
        let eligible = angelEligible([a, mid, c])
        #expect(eligible[0] && eligible[2], "the Angel folded one Christmas into the other")
    }
}
