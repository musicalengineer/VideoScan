import Foundation
import Testing
@testable import VideoScan

// MARK: - Dashboard refresh gating + row equality tests
// (perf/dashboard-render, 2026-07-14)
//
// Invalidation sources #2–#4 of the dashboard render loop:
//   #2 refreshCounts wrote @State volumeRates/volumeCoverage every 1 s
//      tick even when nothing changed → pfRefreshVolumeCoverage now
//      returns nil on a no-change tick (ZERO @State writes).
//   #3/#4 row views re-rendered on every clock tick / body pass →
//      Equatable conformances gate their bodies.
//
// Dimensions (feature-test checklist):
//   Logic  — gating semantics, RateTracker sample gate, row equality
//   Scale  — 100k synthetic records through the refilter with an
//            explicit time budget (production catalog is ~103k)
//   Sensor — noChangeTick* and the 100k budget are the regression
//            sensors ("NO O(records) work on an idle tick")

// MARK: Fixtures

@MainActor
private func coverageRecord(fullPath: String,
                            dossiered: Bool = false) -> VideoRecord {
    let r = VideoRecord()
    r.filename = (fullPath as NSString).lastPathComponent
    r.fullPath = fullPath
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    r.durationSeconds = 3.0
    r.lifecycleStage = .cataloged
    if dossiered { r.dossierProcessedAt = Date() }
    return r
}

@MainActor
private func makeRecords(perVolume: Int,
                         volumes: [String]) -> [VideoRecord] {
    var out: [VideoRecord] = []
    out.reserveCapacity(perVolume * volumes.count)
    for vol in volumes {
        for i in 0..<perVolume {
            out.append(coverageRecord(fullPath: vol + "clip_\(i).mp4",
                                      dossiered: i % 2 == 0))
        }
    }
    return out
}

// MARK: - pfRefreshVolumeCoverage gating

@MainActor
@Suite("Dashboard coverage refresh gating")
struct DossierDashboardRefreshTests {

    private let volumes = ["/Volumes/CovA/", "/Volumes/CovB/"]

    @Test("first pass populates coverage and rates")
    func firstPassPopulates() {
        let records = makeRecords(perVolume: 10, volumes: volumes)
        let out = pfRefreshVolumeCoverage(
            coverage: [:], rates: [:],
            lastKey: [-1], key: [1, 0, records.count],
            volumePrefixes: volumes, records: records,
            scope: AnalysisScope(), now: Date()
        )
        #expect(out != nil)
        #expect(out?.coverage[volumes[0]]?.total == 10)
        #expect(out?.coverage[volumes[0]]?.dossiered == 5)
        #expect(out?.coverage[volumes[1]]?.total == 10)
        #expect(out?.rates.count == 2)
        #expect(out?.lastKey == [1, 0, records.count])
    }

    @Test("SENSOR (negative): a no-change tick returns nil — ZERO @State writes")
    func noChangeTickWritesNothing() throws {
        let records = makeRecords(perVolume: 10, volumes: volumes)
        let key = [7, 0, records.count]
        let now = Date()
        let first = pfRefreshVolumeCoverage(
            coverage: [:], rates: [:], lastKey: [-1], key: key,
            volumePrefixes: volumes, records: records,
            scope: AnalysisScope(), now: now
        )
        let state = try #require(first)

        // Ticks 2…5: same key, same counts — every one must be nil so
        // the view performs zero @State writes and the body is never
        // invalidated by the timer.
        var cov = state.coverage, rates = state.rates, lastKey = state.lastKey
        for tick in 1...4 {
            let out = pfRefreshVolumeCoverage(
                coverage: cov, rates: rates, lastKey: lastKey, key: key,
                volumePrefixes: volumes, records: records,
                scope: AnalysisScope(),
                now: now.addingTimeInterval(Double(tick))
            )
            #expect(out == nil, "idle tick \(tick) produced a write")
            if let out {   // keep going honestly if the gate leaks
                cov = out.coverage; rates = out.rates; lastKey = out.lastKey
            }
        }
    }

    @Test("a moved key recomputes and reports the change")
    func keyMoveRecomputes() throws {
        var records = makeRecords(perVolume: 10, volumes: volumes)
        let key1 = [1, 0, records.count]
        let now = Date()
        let first = pfRefreshVolumeCoverage(
            coverage: [:], rates: [:], lastKey: [-1], key: key1,
            volumePrefixes: volumes, records: records,
            scope: AnalysisScope(), now: now
        )
        let s1 = try #require(first)

        // Catalog grows → key moves → coverage must refresh.
        records.append(coverageRecord(fullPath: volumes[0] + "new.mp4"))
        let key2 = [1, 0, records.count]
        let second = pfRefreshVolumeCoverage(
            coverage: s1.coverage, rates: s1.rates, lastKey: s1.lastKey, key: key2,
            volumePrefixes: volumes, records: records,
            scope: AnalysisScope(), now: now.addingTimeInterval(1)
        )
        #expect(second != nil, "a moved key must produce a write")
        #expect(second?.coverage[volumes[0]]?.total == 11)
        #expect(second?.lastKey == key2,
                "lastKey must persist even when counts barely move — otherwise every later tick re-runs the O(records) refilter")
    }

    @Test("SCALE: 100k records × 3 volumes — refilter within budget, idle tick near-free")
    func scale100k() throws {
        let vols = ["/Volumes/Big1/", "/Volumes/Big2/", "/Volumes/Big3/"]
        // ~34k per volume ≈ 102k total — production catalog shape.
        let records = makeRecords(perVolume: 34_000, volumes: vols)
        let key = [3, 1, records.count]
        let now = Date()

        let clock = ContinuousClock()
        var result: DossierCoverageRefreshResult?
        let refilter = clock.measure {
            result = pfRefreshVolumeCoverage(
                coverage: [:], rates: [:], lastKey: [-1], key: key,
                volumePrefixes: vols, records: records,
                scope: AnalysisScope(), now: now
            )
        }
        let s = try #require(result)
        #expect(s.coverage[vols[0]]?.total == 34_000)
        // Budget: the catalog-changed pass is O(records × volumes) by
        // design and runs OFF the render path (timer callback, gated).
        // 5 s is generous even for the M1 nightly runner; M4 does this
        // in well under a second.
        #expect(refilter < .seconds(5),
                "100k refilter took \(refilter) — exceeds the explicit budget")

        // The idle tick at the same scale must not touch records at all.
        let idle = clock.measure {
            let out = pfRefreshVolumeCoverage(
                coverage: s.coverage, rates: s.rates, lastKey: s.lastKey, key: key,
                volumePrefixes: vols, records: records,
                scope: AnalysisScope(), now: now.addingTimeInterval(1)
            )
            #expect(out == nil)
        }
        #expect(idle < .milliseconds(250),
                "idle tick at 100k took \(idle) — it must be O(volumes), not O(records)")
    }

    @Test("scope flip moves the key ingredient (hashValue) the view feeds in")
    func scopeChangesKeyIngredient() {
        var scopeOn = AnalysisScope()
        scopeOn.includeAudioOnly = true
        #expect(AnalysisScope().hashValue != scopeOn.hashValue
                || AnalysisScope() != scopeOn,
                "scope flip must be distinguishable so the coverage key moves")
    }
}

// MARK: - RateTracker sample gate

@Suite("RateTracker sample gate")
struct RateTrackerSampleGateTests {

    @Test("SENSOR (negative): an unchanged count leaves the tracker value-identical")
    func unchangedCountIsValueIdentical() {
        var r = RateTracker()
        let t0 = Date(timeIntervalSince1970: 1_000)
        r.record(count: 5, at: t0)
        let before = r
        // Idle dashboard ticks: same count, advancing clock.
        for s in 1...30 {
            r.record(count: 5, at: t0.addingTimeInterval(Double(s)))
        }
        #expect(r == before,
                "idle ticks mutated the tracker — every dashboard tick becomes a guaranteed @State write again")
    }

    @Test("a changed count still appends and computes the rate")
    func changedCountStillTracks() {
        var r = RateTracker()
        let t0 = Date(timeIntervalSince1970: 1_000)
        r.record(count: 100, at: t0)
        r.record(count: 100, at: t0.addingTimeInterval(30))   // gated
        r.record(count: 106, at: t0.addingTimeInterval(60))   // appends
        #expect(r.perMinute == 6.0)
        #expect(r.hasEnoughSamples)
    }

    @Test("window trimming still runs on gated ticks (stalled volume decays honestly)")
    func trimmingRunsOnGatedTicks() {
        var r = RateTracker(window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        r.record(count: 0, at: t0)
        r.record(count: 10, at: t0.addingTimeInterval(10))
        #expect(r.hasEnoughSamples)
        // Long idle stretch: counts frozen at 10. Once both samples age
        // past the 60 s window they trim out — rate honestly returns to
        // the "—" state instead of showing a stale number forever.
        r.record(count: 10, at: t0.addingTimeInterval(200))
        #expect(r.hasEnoughSamples == false)
        #expect(r.perMinute == 0)
    }

    @Test("reset (count decrease) still clears and restarts")
    func resetStillWorks() {
        var r = RateTracker()
        let t0 = Date(timeIntervalSince1970: 1_000)
        r.record(count: 100, at: t0)
        r.record(count: 150, at: t0.addingTimeInterval(60))
        r.record(count: 10, at: t0.addingTimeInterval(120))   // reset
        #expect(r.perMinute == 0)
        #expect(r.hasEnoughSamples == false)
    }
}

// MARK: - Equatable row views (body-skip gates)

@MainActor
@Suite("Dashboard row equality")
struct DossierDashboardRowEqualityTests {

    private func lane(startedAt: Date) -> PipelineLane {
        PipelineLane(id: UUID(), path: "/Volumes/X/a.mov", filename: "a.mov",
                     stageName: "MLXVLM", verb: "extracting scenes…",
                     startedAt: startedAt, isVideoOnly: false,
                     hasCaptions: false, hasTranscript: false,
                     transcriptFailed: false)
    }

    private func completed() -> CompletedActivity {
        CompletedActivity(id: UUID(), filename: "a.mov", path: "/Volumes/X/a.mov",
                          vlmSeconds: 11.2, whisperSeconds: 6.4, note: nil,
                          syncedAt: Date(), isVideoOnly: false,
                          hasCaptions: true, hasTranscript: true,
                          transcriptFailed: false)
    }

    @Test("ActiveLaneRow: equal within the same displayed second, unequal across it")
    func activeLaneRowSecondBucket() {
        let t0 = Date()
        let l = lane(startedAt: t0)
        let a = ActiveLaneRow(lane: l, now: t0.addingTimeInterval(10.2), onSkip: { _ in })
        let b = ActiveLaneRow(lane: l, now: t0.addingTimeInterval(10.7), onSkip: { _ in })
        let c = ActiveLaneRow(lane: l, now: t0.addingTimeInterval(11.2), onSkip: { _ in })
        #expect(a == b, "sub-second clock jitter must not re-render the row")
        #expect(a != c, "the displayed elapsed second MUST re-render (truthful readout)")
    }

    @Test("ActiveLaneRow: lane content change re-renders at equal clock")
    func activeLaneRowContentChange() {
        let t0 = Date()
        var l2 = lane(startedAt: t0)
        l2.hasCaptions = true
        let now = t0.addingTimeInterval(5)
        let a = ActiveLaneRow(lane: lane(startedAt: t0), now: now, onSkip: { _ in })
        let b = ActiveLaneRow(lane: l2, now: now, onSkip: { _ in })
        #expect(a != b)
    }

    @Test("CompletedActivityRow: clock is ignored, item changes are not")
    func completedRowEquality() {
        let item = completed()
        let a = CompletedActivityRow(item: item, now: .distantPast, onShowInCatalog: { _ in })
        let b = CompletedActivityRow(item: item, now: Date(), onShowInCatalog: { _ in })
        #expect(a == b, "the completed row never displays 'now' — ticks must not re-render it")
        let c = CompletedActivityRow(item: completed(), now: .distantPast, onShowInCatalog: { _ in })
        #expect(a != c, "a different completion (new id) must re-render")
    }

    @Test("DossierVolumeRow: equality tracks displayed inputs, ignores closures")
    func volumeRowEquality() {
        let target = CatalogScanTarget(searchPath: "/Volumes/RowEq/")
        func row(pos: Int?, analyzing: Bool = false) -> DossierVolumeRow {
            DossierVolumeRow(target: target,
                             coverage: CatalogCoverage(total: 10, dossiered: 5, eligible: 10),
                             isAnalyzing: analyzing, isPaused: false, isSelected: false,
                             queuePosition: pos,
                             onSelect: {}, onAnalyze: {}, onDequeue: {},
                             onPause: {}, onResume: {}, onStop: {})
        }
        #expect(row(pos: nil) == row(pos: nil),
                "fresh closures must not defeat the body-skip gate")
        #expect(row(pos: nil) != row(pos: 1),
                "'Queued (#1)' must re-render — queue UI stays truthful")
        #expect(row(pos: nil) != row(pos: nil, analyzing: true),
                "analyzing flip must re-render")
    }
}
