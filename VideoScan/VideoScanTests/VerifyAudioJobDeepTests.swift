// VerifyAudioJobDeepTests.swift
// Deep-test pass over the GH #132 P1 / #135 batch Verify Audio machinery
// (testing agent, 2026-07-24 overnight branch):
//
//   * Diagnosis-cache eviction under a REAL 200+ job batch — the 200-cap
//     FIFO must bound memory while every PERSISTED verdict survives
//     (evicted records lose only the instant "Verification Results…"
//     presentation, never their catalog verdict).
//   * Job-level gate semantics through the production dispatch path
//     (startVerifyAudio → gatePlan → mediaTechForPath classing): N jobs
//     against one HDD-classed volume acquire in dispatch order and never
//     overlap; SSD-classed jobs run concurrently with no gate at all.
//     (VerifyAudioJobTests pins the semaphore-level contract; these pin
//     the CLASSING — that gatePlan actually builds a 1-slot gate for
//     .hdd and none for .ssd.)
//
// C++ note: the "override" closures are injected test seams (≈ a
// std::function member replacing the real probe); the MainActor-isolated
// probe object below is how Swift does a mutex-guarded test recorder —
// isolation to the main actor IS the lock.

import Testing
import Foundation
@testable import VideoScan

// MARK: - Helpers

@MainActor
private func makeVerifyRecord(name: String, path: String) -> VideoRecord {
    let r = VideoRecord()
    r.filename = name
    r.fullPath = path
    r.directory = (path as NSString).deletingLastPathComponent
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    return r
}

private func healthyBatchDiagnosis() -> AudioVerifyDiagnosis {
    var shape = AudioVerifyShape()
    shape.audioStreams = 1
    shape.audioCodec = "pcm_s16le"
    shape.audioChannels = 2
    shape.containerDurationSeconds = 2.0
    return AudioVerifyDiagnosis(findings: [], shape: shape, balanceAnalysis: nil)
}

/// Main-actor-isolated concurrency recorder for the gate tests.
@MainActor
private final class GateProbe {
    var beginOrder: [String] = []
    var active = 0
    var maxActive = 0
    /// Names whose held diagnosis has been released by the test.
    var released: Set<String> = []
    func begin(_ name: String) {
        beginOrder.append(name)
        active += 1
        maxActive = max(maxActive, active)
    }
    func end() { active -= 1 }
}

/// Poll a main-actor condition with a hard timeout — deterministic
/// sequencing without ever hanging the suite on a regression.
@MainActor
private func waitUntil(
    timeoutMs: Int = 5_000,
    _ condition: () -> Bool
) async -> Bool {
    var waited = 0
    while !condition() {
        if waited >= timeoutMs { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
        waited += 10
    }
    return true
}

// MARK: - Cache eviction under a 200+ batch

@MainActor
@Suite("VerifyAudioJob — cache eviction under batch load", .serialized)
struct VerifyAudioCacheEvictionBatchTests {

    @Test func batchOf230BoundsTheCacheAndKeepsEveryPersistedVerdict() async {
        // Rick-scale batch: 230 records — 30 past the cap. Memory
        // pressure awareness is the contract: the cache must stay
        // bounded at exactly verifyDiagnosisCap entries while the
        // CATALOG verdict (the red-row marking) persists for all 230.
        #expect(MediaFileOperationsCenter.verifyDiagnosisCap == 200,
                "the documented 200-cap — a silent raise re-opens unbounded-growth review")

        let center = MediaFileOperationsCenter()
        let model = VideoScanModel()
        var jobs: [VerifyAudioJob] = []
        for i in 0..<230 {
            let rec = makeVerifyRecord(name: "vt\(i).mov",
                                       path: "/tmp/videoscan-tests/vt\(i).mov")
            model.records.append(rec)
            let job = center.startVerifyAudio(record: rec, model: model,
                                              diagnoseOverride: { _ in healthyBatchDiagnosis() })
            #expect(job != nil, "distinct records — no dedupe refusals expected")
            if let job { jobs.append(job) }
        }
        for job in jobs { await job.task?.value }

        // Every verdict persisted — eviction must never touch the catalog.
        #expect(model.records.count == 230)
        #expect(model.records.allSatisfy { $0.audioVerifyStatus == "ok" },
                "all 230 persisted verdicts intact")
        #expect(model.records.allSatisfy { $0.audioVerifyDate != nil })

        // Cache bounded at EXACTLY the cap: 200 cached, 30 evicted.
        let cached = model.records.filter { center.verifyDiagnosis(forRecordID: $0.id) != nil }
        let evicted = model.records.filter { center.verifyDiagnosis(forRecordID: $0.id) == nil }
        #expect(cached.count == MediaFileOperationsCenter.verifyDiagnosisCap,
                "FIFO cap held: \(cached.count) cached after 230 completions")
        #expect(evicted.count == 30)
        // The evicted records' state: instant "Verification Results…"
        // gone (cache nil), persisted verdict fully intact.
        #expect(evicted.allSatisfy { $0.audioVerifyStatus == "ok" && $0.audioVerifyDate != nil },
                "eviction dropped ONLY the cached presentation, never the verdict")
    }
}

// MARK: - Job-level gate classing (production dispatch path)

@MainActor
@Suite("VerifyAudioJob — per-disk gating at the job level", .serialized)
struct VerifyAudioJobGateClassingTests {

    /// A diagnosis override that records begin/end on `probe` and HOLDS
    /// until the test releases `name` — controllable serialization
    /// without wall-clock races.
    private func holdingOverride(
        _ name: String, probe: GateProbe
    ) -> @Sendable (String) async throws -> AudioVerifyDiagnosis {
        { _ in
            await MainActor.run { probe.begin(name) }
            var waited = 0
            while await MainActor.run(body: { !probe.released.contains(name) }) {
                if waited >= 5_000 { break }   // never hang the suite
                try? await Task.sleep(nanoseconds: 10_000_000)
                waited += 10
            }
            await MainActor.run { probe.end() }
            return healthyBatchDiagnosis()
        }
    }

    @Test func hddClassedJobsAcquireInDispatchOrderAndNeverOverlap() async {
        // Three VerifyAudioJobs against ONE volume the user classed HDD.
        // gatePlan must build the shared 1-slot gate (compareSlots(.hdd)
        // == 1), so the batch reads the disk one file at a time, in
        // dispatch order. Dispatch is interleaved with observed states
        // (begun / parked-behind-the-gate) so the acquire-order
        // assertion is deterministic, not a scheduling coin-flip.
        let center = MediaFileOperationsCenter()
        center.mediaTechForPath = { path in
            path.hasPrefix("/Volumes/SpinningRust") ? .hdd : .ssd
        }
        let model = VideoScanModel()
        let probe = GateProbe()

        func dispatch(_ name: String) -> VerifyAudioJob? {
            let rec = makeVerifyRecord(name: name,
                                       path: "/Volumes/SpinningRust/\(name)")
            model.records.append(rec)
            return center.startVerifyAudio(record: rec, model: model,
                                           diagnoseOverride: holdingOverride(name, probe: probe))
        }

        let j1 = dispatch("tape1.mov")
        #expect(await waitUntil { probe.beginOrder.contains("tape1.mov") },
                "job 1 must start diagnosing (it holds the only permit)")

        let j2 = dispatch("tape2.mov")
        #expect(await waitUntil { j2?.subtitle.hasPrefix("Waiting for") == true },
                "job 2 must park behind the volume gate and SAY so")
        let j3 = dispatch("tape3.mov")
        #expect(await waitUntil { j3?.subtitle.hasPrefix("Waiting for") == true },
                "job 3 must queue too")
        #expect(probe.beginOrder == ["tape1.mov"],
                "1-slot gate: nothing else may begin while job 1 holds the disk")
        #expect(probe.maxActive == 1)

        probe.released.insert("tape1.mov")
        #expect(await waitUntil { probe.beginOrder.count == 2 },
                "releasing job 1 admits exactly the NEXT waiter")
        #expect(probe.beginOrder == ["tape1.mov", "tape2.mov"],
                "acquire order is dispatch order (FIFO waiters)")

        probe.released.insert("tape2.mov")
        #expect(await waitUntil { probe.beginOrder.count == 3 })
        #expect(probe.beginOrder == ["tape1.mov", "tape2.mov", "tape3.mov"])
        probe.released.insert("tape3.mov")

        for job in [j1, j2, j3] { await job?.task?.value }
        #expect(probe.maxActive == 1,
                "HDD serialization held end-to-end — no overlap ever")
        #expect(model.records.allSatisfy { $0.audioVerifyStatus == "ok" },
                "everything queued behind the gate still completes + persists")
    }

    @Test func ssdClassedJobsRunConcurrentlyWithNoGate() async {
        // Same dispatch path, volume classed SSD → compareSlots returns
        // nil → gatePlan builds NO gate. Proof of concurrency: each
        // job's diagnosis refuses to finish until ALL THREE have begun —
        // possible only if they genuinely overlap. (If a gate crept in,
        // job 1 would time out alone and the begin count would sit at 1.)
        let center = MediaFileOperationsCenter()
        center.mediaTechForPath = { _ in .ssd }
        let model = VideoScanModel()
        let probe = GateProbe()

        let barrier: @Sendable (String) async throws -> AudioVerifyDiagnosis = { path in
            let name = (path as NSString).lastPathComponent
            await MainActor.run { probe.begin(name) }
            var waited = 0
            while await MainActor.run(body: { probe.beginOrder.count < 3 }) {
                if waited >= 3_000 { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
                waited += 10
            }
            await MainActor.run { probe.end() }
            return healthyBatchDiagnosis()
        }

        var jobs: [VerifyAudioJob] = []
        for i in 1...3 {
            let rec = makeVerifyRecord(name: "clip\(i).mov",
                                       path: "/Volumes/FastSSD/clip\(i).mov")
            model.records.append(rec)
            if let job = center.startVerifyAudio(record: rec, model: model,
                                                 diagnoseOverride: barrier) {
                jobs.append(job)
            }
        }
        for job in jobs { await job.task?.value }

        #expect(probe.beginOrder.count == 3)
        #expect(probe.maxActive == 3,
                "SSD-classed jobs must overlap — all three in flight at once (no gate)")
        #expect(model.records.allSatisfy { $0.audioVerifyStatus == "ok" })
    }
}
