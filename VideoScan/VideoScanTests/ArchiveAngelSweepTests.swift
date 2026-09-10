// ArchiveAngelSweepTests.swift
// Archive Angel Assessment sweep — SCALE (100k synthetic candidates under a
// Debug ceiling, main-actor slices bounded), pacing (busy → parks, resumes
// when clear), the setting (disabled → never runs), and the log contract
// (exactly start + checkpoints + finish, never per record). Isolated:
// injected store directory, injected play-history, no defaults.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
private func makeSweep(candidates: [ArchiveAngelCandidate],
                       busy: @escaping @MainActor () -> Bool = { false },
                       sliceSize: Int = 500, checkpointEvery: Int = 5_000,
                       log: @escaping @MainActor (String) -> Void = { _ in },
                       enabled: Bool = true) -> (ArchiveAngelSweep, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_angel_sweep_\(UUID().uuidString.prefix(8))", isDirectory: true)
    let store = ArchiveAngelEvidenceStore(directory: dir)
    let sweep = ArchiveAngelSweep(store: store)
    var cfg = ArchiveAngelSweep.Configuration(candidates: { candidates }, isExternallyBusy: busy)
    cfg.playHistory = { paths in
        // Deterministic stand-in for Spotlight: every 10th file was played.
        var out: [String: ArchiveAngelPlayHistory.Reading] = [:]
        for (i, p) in paths.enumerated() where i % 10 == 0 { out[p] = .init(useCount: 3, lastUsed: nil) }
        return out
    }
    cfg.sliceSize = sliceSize
    cfg.checkpointEvery = checkpointEvery
    cfg.pausePollMilliseconds = 20
    cfg.quietSeconds = 0
    cfg.log = log
    sweep.configure(cfg, enabled: enabled)
    return (sweep, dir)
}

private func synthetic(_ n: Int) -> [ArchiveAngelCandidate] {
    var out: [ArchiveAngelCandidate] = []
    out.reserveCapacity(n)
    let base = Date(timeIntervalSince1970: 700_000_000)
    for i in 0..<n {
        out.append(.init(filename: "v\(i).mov", fullPath: "/Volumes/T/v\(i).mov", sizeBytes: Int64(i),
                         durationSeconds: Double(i % 9000), starRating: i % 4,
                         mediaDisposition: i % 50 == 0 ? .confirmedJunk : .unreviewed,
                         junkScore: i % 7, confirmedPeople: i % 5 == 0 ? ["Donna"] : [],
                         detectedPeople: i % 3 == 0 ? ["Tim"] : [], hasUserNotes: i % 11 == 0,
                         tagCount: i % 4, inferredRecordDate: base.addingTimeInterval(Double(i) * 3600),
                         inferredDateConfidence: Float(i % 100) / 100))
    }
    return out
}

@Suite("Archive Angel Assessment — sweep", .serialized)
struct ArchiveAngelSweepTests {

    @Test("SCALE: 100k candidates assessed under 10 s; no main-actor slice over 50 ms (Debug ceilings)")
    @MainActor
    func scale() async {
        let (sweep, dir) = makeSweep(candidates: synthetic(100_000))
        defer { try? FileManager.default.removeItem(at: dir) }
        let started = ContinuousClock.now
        await sweep.runAndWait(reason: "test")
        let elapsed = ContinuousClock.now - started
        guard case .done = sweep.status else { Issue.record("expected .done, got \(sweep.status)"); return }
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(10)), "100k assessment took \(elapsed)")
        let sliceCeiling = PerformanceLane.debugCeiling(.milliseconds(50))
        let ceilingSecs = Double(sliceCeiling.components.seconds) + Double(sliceCeiling.components.attoseconds) / 1e18
        #expect(sweep.longestSliceSeconds <= ceilingSecs, "longest main-actor slice \(sweep.longestSliceSeconds) s")
        #expect(sweep.store.file?.complete == true)
        #expect(sweep.store.consideredCount == 100_000)
        #expect(sweep.store.eligibleCount > 0)
        #expect(sweep.store.candidateCount > 0)
        #expect(sweep.store.candidateCount <= sweep.store.eligibleCount)
        #expect(FileManager.default.fileExists(atPath: sweep.store.fileURL.path), "evidence saved to the injected dir")
        // Rejections were graded X; the floor's reasons are counted.
        #expect((sweep.store.rejectionCounts()[.junk] ?? 0) > 0)
    }

    @Test("log contract: start + one line per 5,000 + finish — never per record")
    @MainActor
    func logContract() async {
        var lines: [String] = []
        let (sweep, dir) = makeSweep(candidates: synthetic(1_200), sliceSize: 100, checkpointEvery: 500,
                                     log: { lines.append($0) })
        defer { try? FileManager.default.removeItem(at: dir) }
        await sweep.runAndWait(reason: "nightly")
        #expect(lines.count == 4, "\(lines)")
        #expect(lines.first == "Archive Angel Assessment: assessing 1,200 records (reason: nightly)")
        #expect(lines[1] == "Archive Angel Assessment: 500 of 1,200")
        #expect(lines[2] == "Archive Angel Assessment: 1,000 of 1,200")
        #expect(lines.last?.hasPrefix("Archive Angel Assessment: done: A ") == true)
        #expect(lines.last?.contains("excluded") == true)
        #expect(lines.last?.hasSuffix(" s") == true)
    }

    @Test("busy → parks with a reason, then finishes once the app is free")
    @MainActor
    func parksWhileBusy() async {
        var busy = true
        let (sweep, dir) = makeSweep(candidates: synthetic(300), busy: { busy })
        defer { try? FileManager.default.removeItem(at: dir) }
        sweep.run(reason: "test")
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard case .paused(let reason) = sweep.status else {
            Issue.record("expected .paused, got \(sweep.status)"); return
        }
        #expect(reason.contains("another job"))
        #expect(!sweep.store.isLoaded, "nothing written while parked")
        busy = false
        await sweep.runAndWait(reason: "ignored — a run is in flight")
        // runAndWait queued a rerun; wait for both to settle.
        for _ in 0..<200 {
            if case .done = sweep.status { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .done = sweep.status else { Issue.record("expected .done, got \(sweep.status)"); return }
        #expect(sweep.store.consideredCount == 300)
    }

    @Test("disabled → run is a no-op and status says so; enabling restores idle")
    @MainActor
    func disabled() async {
        var calls = 0
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_angel_sweep_off_\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sweep = ArchiveAngelSweep(store: ArchiveAngelEvidenceStore(directory: dir))
        sweep.configure(.init(candidates: { calls += 1; return synthetic(10) }, isExternallyBusy: { false }),
                        enabled: false)
        #expect(sweep.status == .disabled)
        await sweep.runAndWait(reason: "test")
        sweep.rescoreNow()
        sweep.noteCatalogChanged()
        #expect(calls == 0)
        #expect(!sweep.store.isLoaded)
        sweep.setEnabled(true)
        #expect(sweep.status == .idle)
        sweep.stop()
    }

    @Test("continuous: re-scores on a period while enabled; stop() ends it")
    @MainActor
    func periodic() async {
        var runs = 0
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_angel_sweep_periodic_\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sweep = ArchiveAngelSweep(store: ArchiveAngelEvidenceStore(directory: dir))
        var cfg = ArchiveAngelSweep.Configuration(candidates: { runs += 1; return synthetic(20) },
                                                  isExternallyBusy: { false })
        cfg.playHistory = { _ in [:] }
        cfg.periodicSeconds = 0.15
        sweep.configure(cfg, enabled: true)
        for _ in 0..<60 {
            if runs >= 2 { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(runs >= 2, "two periodic runs expected within 1.5 s, got \(runs)")
        sweep.stop()
        let after = runs
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(runs == after, "no runs after stop()")
    }

    @Test("cadence sensor: 15-minute period, 1-minute edit debounce, 90 s launch delay — Rick 2026-09-10 (no 3 am)")
    @MainActor
    func cadenceDefaults() {
        let cfg = ArchiveAngelSweep.Configuration(candidates: { [] }, isExternallyBusy: { false })
        #expect(cfg.periodicSeconds == 900)
        #expect(cfg.catalogChangeDebounceSeconds == 60)
        #expect(cfg.launchDelaySeconds == 90)
    }

    @Test("settings: missing key = ON; explicit false = OFF; save round-trips")
    func settings() {
        let suite = UserDefaults(suiteName: "test_angel_sweep_settings_\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.description) }
        #expect(ArchiveAngelSweepSettings.restored(from: suite).enabled)
        var s = ArchiveAngelSweepSettings()
        s.enabled = false
        s.save(to: suite)
        #expect(!ArchiveAngelSweepSettings.restored(from: suite).enabled)
        s.enabled = true
        s.save(to: suite)
        #expect(ArchiveAngelSweepSettings.restored(from: suite).enabled)
    }
}
