// ProbeGroupBoundedChildrenTests.swift
// GH #163 — Scan beachball: the probe TaskGroup used to enqueue ONE child
// per discovered file (≈400k on Projects) and only drain after the walk.
// The runtime's child bookkeeping is O(children) per removal, so cancel /
// drain went quadratic — all on the main actor (2026-08-18 sample: 2158 of
// 2181 main-thread samples inside TaskGroup::removeChildTask). Secondary:
// one appLog "NOT CATALOGED" line per gated file = one fsync per file on
// the main actor (359k on Projects).
//
// Fix under test (VideoScanModel+ProbeEngine): live children are bounded
// at `probeGroupLiveChildBound` (4× probe permits, min 16); discovered-but-
// not-enqueued URLs wait in a plain array; every outcome goes through ONE
// shared handler; gated lines ride GatedOutcomeLogBatcher → writeBatch.
//
// Dimensions (CLAUDE.md feature-test checklist):
//   Logic  — batcher preserves order, finish() lands everything.
//   Scale  — 100k synthetic files through the REAL walk → group → drain
//            pipeline (probe stubbed via `probeOutcomeStub`), time-budgeted.
//   Sensor — max live children ≤ bound (gauge seam); cancel at ~50%
//            returns < 2 s; main-actor pinger worst block < 250 ms; gated
//            lines all present + ordered before the trailing line, with
//            fsync count ≪ line count.
//
// Debug build. RED evidence: on the pre-fix engine the gauge is not
// reachable (no seam), but the same 100k run enqueued 100,000 children
// (max live == discovered) and cancel took O(n²) — see the issue's sample.

import Testing
import Foundation
@testable import VideoScan

// MARK: - Shared 100k fixture (built once per test process)

private enum BoundedChildrenFixture {
    static let fileCount = 100_000
    static let dirCount = 100

    /// 100k zero-byte EXTENSIONLESS files across 100 subdirectories.
    /// Extensionless so EVERY outcome — stubbed, cancelled-before-permit,
    /// and cancelled-in-probeAndRecord alike — carries ext == "" and is
    /// gated out (one "NOT CATALOGED" line each): the log assertions can
    /// then say "gated lines == completed" exactly. Files are created with
    /// open(2) — FileManager.createFile is ~5× slower at this count.
    static let root: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-gh163-100k-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var n = 0
        for d in 0..<dirCount {
            let sub = dir.appendingPathComponent(String(format: "d%03d", d), isDirectory: true)
            try! FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            for _ in 0..<(fileCount / dirCount) {
                let path = sub.appendingPathComponent(String(format: "blob%06d", n)).path
                let fd = open(path, O_CREAT | O_WRONLY, 0o644)
                precondition(fd >= 0, "fixture: open failed for \(path)")
                close(fd)
                n += 1
            }
        }
        precondition(n == fileCount)
        return dir
    }()
}

/// Main-actor liveness probe: sleeps `period` in a loop and records the
/// worst gap between wake-ups minus the period — i.e. the longest stretch
/// the main actor was busy and could not run this task.
@MainActor
private final class MainActorPinger {
    private(set) var worstBlockMs: Double = 0
    private var task: Task<Void, Never>?
    func start(periodMs: Double = 10) {
        task = Task { @MainActor in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(periodMs))
                let now = ContinuousClock.now
                let gapMs = (now - last) / .milliseconds(1)
                let block = gapMs - periodMs
                if block > worstBlockMs { worstBlockMs = block }
                last = now
            }
        }
    }
    func stop() { task?.cancel() }
}

@MainActor
@Suite("Probe group — bounded live children + batched gated log (GH #163)", .serialized)
struct ProbeGroupBoundedChildrenTests {

    /// Stubbed probe: 1 ms of real suspension per file — deliberately
    /// SLOWER than the walk (≈20 µs/file on SSD) so discovery runs ahead
    /// of probing and the group is pushed against its bound for most of
    /// the run, exactly like ffprobe (10–50 ms/file) vs a metadata walk.
    /// (A faster stub never reaches the bound and would not exercise the
    /// pending queue.) Then a gated-shape outcome (ffprobeFailed, ext ""
    /// — the Avid-blob shape).
    private static let gatedStub: @Sendable (URL) async -> ProbeOutcome = { url in
        try? await Task.sleep(for: .milliseconds(1))
        var o = ProbeOutcome()
        o.filename = url.lastPathComponent
        o.ext = ""
        o.fullPath = url.path
        o.directory = url.deletingLastPathComponent().path
        o.probe.isPlayable = "No"
        o.notes = "stub"
        o.probe.streamTypeRaw = StreamType.ffprobeFailed.rawValue
        return o
    }

    /// perfSettings is NOT written (its didSet persists to UserDefaults —
    /// settings-pollution class); the bound is computed from whatever the
    /// model restored, exactly as the engine does.
    private func makeModel() -> (VideoScanModel, ProbeGroupLiveChildrenGauge, bound: Int) {
        let model = VideoScanModel()
        model.scanOptions.probeExtensionless = true
        model.scanOptions.skipChecksums = true
        model.scanOptions.skipSmallFiles = false
        model.probeOutcomeStub = Self.gatedStub
        let gauge = ProbeGroupLiveChildrenGauge()
        model.probeGroupLiveChildrenGauge = gauge
        let bound = VideoScanModel.probeGroupLiveChildBound(probesLimit: model.perfSettings.probesPerVolume)
        return (model, gauge, bound)
    }

    private func makeLog(_ tag: String) throws -> PersistentLog {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-gh163-log-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = PersistentLog(name: "catalog", directory: dir)
        log.start(append: false)
        return log
    }

    /// Body lines with the "[HH:mm:ss] " stamp stripped.
    private func bodyLines(_ log: PersistentLog) throws -> [String] {
        try String(contentsOf: log.url, encoding: .utf8)
            .split(separator: "\n").dropFirst(2)
            .map { line -> String in
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return String(line) }
                return String(line[line.index(close, offsetBy: 2)...])
            }
    }

    // MARK: 1+3+4 — full 100k run: bound, main-actor liveness, batched log

    @Test("100k files: live children ≤ bound, main actor stays responsive, gated log complete + batched")
    func hundredKRunStaysBoundedAndResponsive() async throws {
        let root = BoundedChildrenFixture.root
        let (model, gauge, bound) = makeModel()
        #expect(bound >= 16)

        let log = try makeLog("full")
        let previousSink = appLog
        appLog = log
        defer { appLog = previousSink }

        let target = CatalogScanTarget(searchPath: root.path)
        let pinger = MainActorPinger()
        pinger.start()
        let clock = ContinuousClock()
        let started = clock.now
        let result = await model.runTargetProbeGroup(
            target: target, root: root.path, volName: "GH163",
            rootIsNetwork: false, ramMountPoint: nil)
        let elapsed = clock.now - started
        pinger.stop()
        // The trailing line finalize would write (discovery audit /
        // "Cancelled …") — must land AFTER every gated line.
        appLog.write("TRAILER")
        log.close()

        print("[GH163 full] discovered=\(result.discovered) completed=\(result.completed) maxLive=\(gauge.maxLive) bound=\(bound) worstMainBlockMs=\(Int(pinger.worstBlockMs)) elapsed=\(elapsed) fsyncs=\(log.synchronizeCount)")

        // Completeness / invariant.
        #expect(result.discovered == BoundedChildrenFixture.fileCount)
        #expect(result.completed == BoundedChildrenFixture.fileCount)
        #expect(result.completed <= result.discovered)
        #expect(result.records.isEmpty, "every stubbed outcome is gated — nothing may enter the catalog")

        // Sensor 1: the group never held more than `bound` live children.
        #expect(gauge.observations > 0, "gauge seam must be observed by the engine")
        #expect(gauge.maxLive <= bound,
                "max live children \(gauge.maxLive) exceeded bound \(bound) — GH #163 regression")
        #expect(gauge.current == 0, "all children drained")

        // Sensor 3: main-actor pinger.
        #expect(pinger.worstBlockMs < 250,
                "main actor blocked \(Int(pinger.worstBlockMs)) ms during the run (budget 250 ms)")

        // Scale budget (Debug, M-series): the pre-fix engine spends this
        // long just tearing children down.
        // 100k × 1 ms stub / 8 permits ≈ 12.5 s of pure probe time on
        // default prefs, plus walk + drain overhead.
        #expect(elapsed < .seconds(90), "100k stubbed scan took \(elapsed)")

        // Sensor 4: every gated line present, TRAILER last, fsyncs ≪ lines.
        let lines = try bodyLines(log)
        let gated = lines.filter { $0.hasPrefix("NOT CATALOGED — ") }
        #expect(gated.count == result.completed,
                "expected one NOT CATALOGED line per completed outcome (\(result.completed)), got \(gated.count)")
        #expect(Set(gated).count == gated.count, "no duplicate gated lines")
        let trailerIndex = lines.lastIndex(of: "TRAILER")
        #expect(trailerIndex != nil)
        if let trailerIndex {
            let after = lines[(trailerIndex + 1)...].filter { $0.hasPrefix("NOT CATALOGED") }
            #expect(after.isEmpty, "\(after.count) gated line(s) landed AFTER the trailing line")
            #expect(lines[..<trailerIndex].filter { $0.hasPrefix("NOT CATALOGED") }.count == gated.count)
        }
        let expectedBatches = (result.completed + GatedOutcomeLogBatcher.defaultFlushEvery - 1)
            / GatedOutcomeLogBatcher.defaultFlushEvery
        // + TRAILER's own fsync + a small margin.
        #expect(log.synchronizeCount <= expectedBatches + 4,
                "fsync count \(log.synchronizeCount) for \(gated.count) gated lines — batching regressed")
        #expect(log.synchronizeCount * 50 < gated.count, "fsyncs must be ≪ lines")
    }

    // MARK: 2 — cancel at ~50 % returns inside the budget, log still complete

    @Test("Cancel at ~50%: returns < 2 s (≤ bound children to tear down), gated log complete + ordered")
    func cancelMidScanReturnsPromptly() async throws {
        let root = BoundedChildrenFixture.root
        let (model, gauge, bound) = makeModel()

        let log = try makeLog("cancel")
        let previousSink = appLog
        appLog = log
        defer { appLog = previousSink }

        let target = CatalogScanTarget(searchPath: root.path)
        let scanTask = Task { @MainActor in
            await model.runTargetProbeGroup(
                target: target, root: root.path, volName: "GH163",
                rootIsNetwork: false, ramMountPoint: nil)
        }

        // Wait for roughly half the files to be probed (filesScanned ticks
        // every 20 completions inside processTargetProbeResult).
        let half = BoundedChildrenFixture.fileCount / 2
        for _ in 0..<6000 where target.filesScanned < half {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(target.filesScanned >= half, "scan never reached 50% (filesScanned=\(target.filesScanned))")

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        scanTask.cancel()
        let result = await scanTask.value
        let teardown = clock.now - cancelledAt

        appLog.write("TRAILER")
        log.close()

        print("[GH163 cancel] discovered=\(result.discovered) completed=\(result.completed) maxLive=\(gauge.maxLive) bound=\(bound) teardown=\(teardown) fsyncs=\(log.synchronizeCount)")
        #expect(teardown < .seconds(2), "cancel → return took \(teardown) (budget 2 s)")
        #expect(result.completed <= result.discovered)
        #expect(result.completed < BoundedChildrenFixture.fileCount, "cancel must not run to completion")
        #expect(gauge.maxLive <= bound, "max live \(gauge.maxLive) > bound \(bound)")
        #expect(gauge.current == 0)

        let lines = try bodyLines(log)
        let gated = lines.filter { $0.hasPrefix("NOT CATALOGED — ") }
        #expect(gated.count == result.completed,
                "after cancel: expected \(result.completed) gated lines, got \(gated.count)")
        if let trailerIndex = lines.lastIndex(of: "TRAILER") {
            #expect(lines[(trailerIndex + 1)...].allSatisfy { !$0.hasPrefix("NOT CATALOGED") },
                    "gated line(s) landed after the trailing line on the cancel path")
        } else {
            Issue.record("TRAILER missing")
        }
        #expect(log.synchronizeCount * 50 < max(gated.count, 1))
    }

    // MARK: Logic — the batcher itself

    @Test("GatedOutcomeLogBatcher: order preserved, finish() lands the partial tail, N/flushEvery batches")
    func batcherPreservesOrderAndFlushesTail() async throws {
        let sink = InMemoryLogSink()
        let batcher = GatedOutcomeLogBatcher(sink: sink, flushEvery: 7)
        let lines = (0..<100).map { "NOT CATALOGED — line \($0)" }
        for l in lines { batcher.append(l) }
        await batcher.finish()
        #expect(sink.lines == lines, "batched sink content must equal the appended lines, in order")
        #expect(batcher.batchesWritten == 15)   // 14 full batches of 7 + tail of 2
        // Idempotent finish; late append is never lost.
        await batcher.finish()
        batcher.append("late")
        #expect(sink.lines.last == "late")
    }

    @Test("GatedOutcomeLogBatcher on PersistentLog: one fsync per batch, lines byte-identical to write()")
    func batcherOnPersistentLogUsesOneFsyncPerBatch() async throws {
        let log = try makeLog("batcher")
        let batcher = GatedOutcomeLogBatcher(sink: log, flushEvery: 100)
        let lines = (0..<1_000).map { "NOT CATALOGED — extension can't vouch for it and ffprobe could not identify as media: /Volumes/X/blob\($0)" }
        for l in lines { batcher.append(l) }
        await batcher.finish()
        log.close()
        #expect(try bodyLines(log).prefix(1_000).elementsEqual(lines))
        #expect(log.synchronizeCount == 10, "1000 lines / 100 per batch = 10 fsyncs, got \(log.synchronizeCount)")
    }

    @Test("Bound formula: 4× permits, never below 16")
    func boundFormula() {
        #expect(VideoScanModel.probeGroupLiveChildBound(probesLimit: 1) == 16)
        #expect(VideoScanModel.probeGroupLiveChildBound(probesLimit: 4) == 16)
        #expect(VideoScanModel.probeGroupLiveChildBound(probesLimit: 8) == 32)
        #expect(VideoScanModel.probeGroupLiveChildBound(probesLimit: 16) == 64)
        #expect(VideoScanModel.probeGroupLiveChildBound(probesLimit: 0) == 16)
    }
}
