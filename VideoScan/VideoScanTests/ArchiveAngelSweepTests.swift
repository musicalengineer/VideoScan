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
                       enabled: Bool = true,
                       attention: ArchiveAngelAttentionStore? = nil,
                       playHistory: (@Sendable ([String]) async -> [String: ArchiveAngelPlayHistory.Reading])? = nil,
                       now: Date? = nil) -> (ArchiveAngelSweep, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_angel_sweep_\(UUID().uuidString.prefix(8))", isDirectory: true)
    let store = ArchiveAngelEvidenceStore(directory: dir)
    let sweep = ArchiveAngelSweep(store: store)
    var cfg = ArchiveAngelSweep.Configuration(candidates: { candidates }, isExternallyBusy: busy)
    cfg.playHistory = playHistory ?? { paths in
        // Deterministic stand-in for Spotlight: every 10th file was played.
        var out: [String: ArchiveAngelPlayHistory.Reading] = [:]
        for (i, p) in paths.enumerated() where i % 10 == 0 { out[p] = .init(useCount: 3, lastUsed: nil) }
        return out
    }
    if let attention { cfg.attentionState = { (attention.revision, attention.lastEventAt) } }
    if let now { cfg.now = { now } }
    cfg.sliceSize = sliceSize
    cfg.checkpointEvery = checkpointEvery
    cfg.pausePollMilliseconds = 20
    cfg.quietSeconds = 0
    cfg.log = log
    sweep.configure(cfg, enabled: enabled)
    return (sweep, dir)
}

/// A latch a test holds shut while it does something, then opens.
private final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    func open() { lock.withLock { isOpen = true } }
    func wait() async {
        while !(lock.withLock { isOpen }) { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
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

    @Test("codex 2026-09-20 #5: a skip recorded WHILE scoring runs makes the finished evidence stale — the pick walks; a rescore after the skip is trusted again")
    @MainActor
    func skipDuringScoringMakesEvidenceStale() async {
        let attention = ArchiveAngelAttentionStore()
        attention.replace(from: [])                       // launch: loaded, revision 1, no events
        var candidates: [ArchiveAngelCandidate] = []
        for i in 0..<20 {
            candidates.append(.init(filename: "tape\(i).mov", fullPath: "/Volumes/T/tape\(i).mov",
                                    durationSeconds: 3600 + Double(i), starRating: 2))
        }
        let gate = TestGate()
        let (sweep, dir) = makeSweep(candidates: candidates, sliceSize: 5, attention: attention,
                                     playHistory: { _ in await gate.wait(); return [:] })
        defer { try? FileManager.default.removeItem(at: dir) }
        let revisionAtSnapshot = attention.revision
        sweep.run(reason: "test")
        for _ in 0..<200 {                                 // scoring has started and is parked on the gate
            if case .scoring = sweep.status { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .scoring = sweep.status else { Issue.record("expected .scoring, got \(sweep.status)"); return }
        // The person skips a file mid-sweep. (MediaLedgerEvent keeps `at`
        // at millisecond resolution; the store's lastEventAt is the truth.)
        attention.note([MediaLedgerEvent(at: Date(), event: .angelSkipped, recordID: candidates[0].id, contentKey: "",
                                         filename: candidates[0].filename, fullPath: candidates[0].fullPath, by: .rick)])
        let skipAt = attention.lastEventAt
        #expect(skipAt != nil && attention.revision == revisionAtSnapshot + 1)
        gate.open()
        for _ in 0..<300 {                                 // the FIRST run finishes (no rerun queued)
            if case .done = sweep.status { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .done = sweep.status else { Issue.record("expected .done, got \(sweep.status)"); return }
        let store = sweep.store
        let project: (UUID) -> ArchiveAngelCandidate? = { id in candidates.first { $0.id == id } }
        #expect(store.attentionRevision == revisionAtSnapshot, "stamped with the revision it was scored under")
        #expect(store.attentionLastEventAt == nil, "…and its newest event: none")
        #expect(store.computedAt.map { $0 > skipAt! } == true, "the finish line is AFTER the skip — the old date-vs-computedAt check trusted this")
        #expect(ArchiveAngelJob.selectFromEvidence(store: store, count: 3, now: Date(),
                                                   attentionChangedAt: attention.lastEventAt,
                                                   attentionRevision: attention.revision, project: project) == nil,
                "scored under an older attention state → walk")
        #expect(ArchiveAngelJob.selectFromEvidence(store: store, count: 3, now: Date(),
                                                   attentionChangedAt: attention.lastEventAt, project: project) == nil,
                "the date fallback alone (the job's old call shape) refuses it too")
        // A rescore now (nothing new since) is trusted.
        await sweep.runAndWait(reason: "rescore")
        #expect(store.attentionRevision == attention.revision)
        #expect(store.attentionLastEventAt == skipAt)
        // QA on S3: Prepare follows the classes; this fixture is about the
        // attention stamp, so it asks for the pre-S3 score order
        // (`recommend.prepare: []`).
        var scoreOrder = AngelRecommendationPolicy.builtIn
        scoreOrder.recommend.prepare = []
        #expect(ArchiveAngelJob.selectFromEvidence(store: store, count: 3, now: Date(), policy: scoreOrder,
                                                   attentionChangedAt: attention.lastEventAt,
                                                   attentionRevision: attention.revision, project: project)?.selection.picks.count == 3)
    }

    @Test("codex 2026-09-20 #6: cached/walk EQUIVALENCE with a skipped file, its never-proposed sibling, and a fresh variant of a favourite — the same batch either way")
    @MainActor
    func cachedPickEqualsWalkWithFamilyAttention() async {
        let now = Date()
        let day = 86_400.0
        var seen = ArchiveAngelAttention.none; seen.note(.angelProposed, at: now - day)
        var skippedTwice = ArchiveAngelAttention.none
        skippedTwice.note(.angelProposed, at: now - 3 * day)
        skippedTwice.note(.angelSkipped, at: now - 2 * day); skippedTwice.note(.angelSkipped, at: now - day)
        var cs: [ArchiveAngelCandidate] = []
        for i in 0..<10 {   // proposed favourites: 3★ whole tapes, 165 each
            cs.append(.init(filename: String(format: "fav%02d.mov", i), fullPath: "/V/F/fav\(i).mov",
                            durationSeconds: 3600 + Double(12 - i), starRating: 3, attention: seen))
        }
        // Skipped twice (→ 41) and its never-proposed sibling (family share → 82, NOT fresh).
        cs.append(.init(filename: "Thanksgiving_2009.mov", fullPath: "/V/T/Thanksgiving_2009.mov",
                        durationSeconds: 3600, starRating: 3, attention: skippedTwice))
        let sibling = ArchiveAngelCandidate(filename: "Thanksgiving_2009_clip1.mov", fullPath: "/V/T/Thanksgiving_2009_clip1.mov",
                                            durationSeconds: 3600, starRating: 3)
        cs.append(sibling)
        // A fresh share-out of fav00 (25): one per family — fav00 wins, so it must not satisfy the fresh scan.
        let favClip = ArchiveAngelCandidate(filename: "fav00_clip1.mov", fullPath: "/V/F/fav00_clip1.mov", durationSeconds: 900)
        cs.append(favClip)
        // Four genuinely fresh files, distinct scores 40 / 35 / 30 / 25.
        var fresh: [ArchiveAngelCandidate] = []
        for i in 0..<4 {
            fresh.append(.init(filename: "new\(i).mov", fullPath: "/V/N/new\(i).mov", durationSeconds: 900, tagCount: 3 - i))
        }
        cs.append(contentsOf: fresh)
        // Production order: projection → derivatives → the family pass → (walk | sweep).
        ArchiveAngelScorer.markDerivatives(&cs)
        ArchiveAngelScorer.applyFamilyAttention(&cs, now: now)
        #expect(cs.first { $0.id == sibling.id }?.familySkips == 2)

        // QA on S3: the cache and the walk must agree under the SAME policy.
        // This fixture exercises attention (fresh C/D files, undated
        // favourites), so it uses the pre-S3 score order (`prepare: []`);
        // ArchiveAngelS3QATests pins the class order.
        var scoreOrder = AngelRecommendationPolicy.builtIn
        scoreOrder.recommend.prepare = []
        let walk = ArchiveAngelScorer.select(cs, count: 10, policy: scoreOrder, now: now, byClass: true)
        let walkIDs = walk.picks.map(\.candidate.id)
        #expect(walkIDs.count == 10)
        #expect(Set(walkIDs).intersection(fresh.prefix(3).map(\.id)).count == 3, "the three best fresh files")
        #expect(!walkIDs.contains(sibling.id) && !walkIDs.contains(favClip.id))

        let (sweep, dir) = makeSweep(candidates: cs, attention: ArchiveAngelAttentionStore(),
                                     playHistory: { _ in [:] }, now: now)
        defer { try? FileManager.default.removeItem(at: dir) }
        await sweep.runAndWait(reason: "test")
        #expect(sweep.store.record(for: sibling.id)?.familySkips == 2, "the family pass's result is in the record")
        let byID = Dictionary(uniqueKeysWithValues: cs.map { ($0.id, $0) })
        let cached = ArchiveAngelJob.selectFromEvidence(store: sweep.store, count: 10, now: now, policy: scoreOrder) { id in
            // The job's projection is per record: attention yes, the family pass no.
            guard var c = byID[id] else { return nil }
            c.familySkips = 0; c.familyKey = ""
            return c
        }
        #expect(cached?.selection.picks.map(\.candidate.id) == walkIDs, "same batch from the cache as from the walk")
        #expect(cached?.selection.picks.map(\.score) == walk.picks.map(\.score))
        #expect(cached?.selection.picks.map { $0.evidence.map(\.line) } == walk.picks.map { $0.evidence.map(\.line) }, "same why-lines, 'New to you' included")
    }

    @Test("settings: missing key = ON; explicit false = OFF; save round-trips")
    func settings() {
        let suite = UserDefaults(suiteName: "test_angel_sweep_settings_\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.description) }
        // The setting lives in ArchiveAngelSettings since consolidation S2 (same key).
        #expect(ArchiveAngelSettings.restored(from: suite).sweepEnabled)
        ArchiveAngelSettings.saveSweepEnabled(false, to: suite)
        #expect(!ArchiveAngelSettings.restored(from: suite).sweepEnabled)
        ArchiveAngelSettings.saveSweepEnabled(true, to: suite)
        #expect(ArchiveAngelSettings.restored(from: suite).sweepEnabled)
    }
}
