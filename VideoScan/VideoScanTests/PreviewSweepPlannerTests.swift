// PreviewSweepPlannerTests.swift
// LOGIC dimension for the background preview sweep (2026-07-27):
// the one-listing cache index, the in-memory work diff, the pure
// pacing decision, and the persisted setting (default OFF + injected-
// defaults round trip — settings-pollution class).
//
// Everything here is pure — no disk, no media, no service. The
// orchestration state machine is pinned in PreviewSweepServiceTests;
// scale in PreviewSweepScaleTests; end-to-end in
// PreviewSweepMediaMatrixTests.

import Testing
import Foundation
@testable import VideoScan

struct PreviewSweepPlannerTests {

    // Convenience: a 64-hex-ish key (real keys are SHA256 hex; the
    // planner only needs distinct strings).
    private let keyA = String(repeating: "a", count: 64)
    private let keyB = String(repeating: "b", count: 64)
    private let keyC = String(repeating: "c", count: 64)

    private func candidate(path: String = "/Volumes/T/x.mkv",
                           container: String = "Matroska / WebM",
                           codec: String = "ffv1",
                           unanalyzable: Bool = false,
                           duration: Double = 8) -> PreviewSweepCandidate {
        PreviewSweepCandidate(path: path, container: container, videoCodec: codec,
                              likelyUnanalyzable: unanalyzable, durationSeconds: duration)
    }

    // MARK: - Tier filename parser (PreviewDiskCache)

    @Test("parseTierFilename round-trips both tiers and rejects junk")
    func tierFilenameParse() {
        let best = PreviewDiskCache.parseTierFilename("\(keyA)-best.jpg")
        #expect(best?.key == keyA && best?.tier == .best)
        let fast = PreviewDiskCache.parseTierFilename("\(keyA)-fast.jpg")
        #expect(fast?.key == keyA && fast?.tier == .fast)

        #expect(PreviewDiskCache.parseTierFilename("-best.jpg") == nil)      // empty key
        #expect(PreviewDiskCache.parseTierFilename("\(keyA)-best.png") == nil)
        #expect(PreviewDiskCache.parseTierFilename("\(keyA)-best") == nil)
        #expect(PreviewDiskCache.parseTierFilename("tmp-1234") == nil)
        #expect(PreviewDiskCache.parseTierFilename(".DS_Store") == nil)
        // Strip payloads are NOT tier payloads.
        #expect(PreviewDiskCache.parseTierFilename("\(keyA)-strip-0-of-4-500.jpg") == nil)
    }

    // MARK: - Cache index build

    @Test("index: tier files land in the right sets; totalBytes sums everything")
    func indexTiers() {
        let index = PreviewSweepPlanner.buildCacheIndex(files: [
            ("\(keyA)-best.jpg", 100),
            ("\(keyB)-fast.jpg", 50),
            ("tmp-abc", 25),            // crashed-write leftover: bytes count, no index
            (".DS_Store", 10)           // junk: bytes count, no index
        ])
        #expect(index.bestKeys == [keyA])
        #expect(index.fastKeys == [keyB])
        #expect(index.completeStripKeys.isEmpty)
        #expect(index.totalBytes == 185)
    }

    @Test("index: complete strip set indexes; partial set does not")
    func indexStripCompleteness() {
        // Complete 3-frame set under keyA; keyB missing index 1.
        let index = PreviewSweepPlanner.buildCacheIndex(files: [
            ("\(keyA)-strip-0-of-3-100.jpg", 1),
            ("\(keyA)-strip-1-of-3-200.jpg", 1),
            ("\(keyA)-strip-2-of-3-300.jpg", 1),
            ("\(keyB)-strip-0-of-3-100.jpg", 1),
            ("\(keyB)-strip-2-of-3-300.jpg", 1)
        ])
        #expect(index.completeStripKeys == [keyA])
    }

    @Test("index: mixed count fields and unparseable strip-prefix names poison the key — mirrors completeStripSet strictness")
    func indexStripPoisoning() {
        let index = PreviewSweepPlanner.buildCacheIndex(files: [
            // keyA: complete 2-set PLUS a leftover from an older 3-set →
            // mixed counts, must NOT read complete (lookupFilmstrip would
            // return nil for exactly this shape).
            ("\(keyA)-strip-0-of-2-100.jpg", 1),
            ("\(keyA)-strip-1-of-2-200.jpg", 1),
            ("\(keyA)-strip-0-of-3-100.jpg", 1),
            // keyB: complete 2-set PLUS an unparseable name under the
            // strip prefix (hand-crafted / corrupted) — poisoned.
            ("\(keyB)-strip-0-of-2-100.jpg", 1),
            ("\(keyB)-strip-1-of-2-200.jpg", 1),
            ("\(keyB)-strip-garbage.jpg", 1),
            // keyC: clean complete 2-set — the control.
            ("\(keyC)-strip-0-of-2-100.jpg", 1),
            ("\(keyC)-strip-1-of-2-200.jpg", 1)
        ])
        #expect(index.completeStripKeys == [keyC])
    }

    // MARK: - Work diff

    @Test("diff: best still present → no still work; fast-only or nothing → needs best")
    func diffStills() {
        let index = PreviewSweepPlanner.buildCacheIndex(files: [
            ("\(keyA)-best.jpg", 1),
            ("\(keyB)-fast.jpg", 1)
        ])
        // AVFoundation-routed records (h264/mp4) — no strip side at all.
        let recs = [
            PreviewSweepKeyedCandidate(candidate: candidate(path: "/v/a.mp4", container: "QuickTime / MOV", codec: "h264"), key: keyA),
            PreviewSweepKeyedCandidate(candidate: candidate(path: "/v/b.mp4", container: "QuickTime / MOV", codec: "h264"), key: keyB),
            PreviewSweepKeyedCandidate(candidate: candidate(path: "/v/c.mp4", container: "QuickTime / MOV", codec: "h264"), key: keyC)
        ]
        let items = PreviewSweepPlanner.workItems(candidates: recs, index: index)
        #expect(items.map(\.key) == [keyB, keyC])   // keyA fully covered
        #expect(items.allSatisfy { $0.needsBestStill && !$0.needsFilmstrip })
    }

    @Test("diff: strips ONLY for ffmpegDirect routes; complete strip suppresses strip work")
    func diffStrips() throws {
        let index = PreviewSweepPlanner.buildCacheIndex(files: [
            ("\(keyA)-best.jpg", 1),
            ("\(keyA)-strip-0-of-2-100.jpg", 1),
            ("\(keyA)-strip-1-of-2-200.jpg", 1),
            ("\(keyB)-best.jpg", 1)
        ])
        let recs = [
            // ffmpegDirect (mkv/ffv1), fully covered → NO item.
            PreviewSweepKeyedCandidate(candidate: candidate(path: "/v/a.mkv"), key: keyA),
            // ffmpegDirect, best present but no strip → strip-only item.
            PreviewSweepKeyedCandidate(candidate: candidate(path: "/v/b.mkv"), key: keyB),
            // avFoundation route with NOTHING cached → best only, never a strip.
            PreviewSweepKeyedCandidate(candidate: candidate(path: "/v/c.mp4", container: "QuickTime / MOV", codec: "h264"), key: keyC)
        ]
        let items = PreviewSweepPlanner.workItems(candidates: recs, index: index)
        try #require(items.count == 2)
        #expect(items[0].key == keyB && !items[0].needsBestStill && items[0].needsFilmstrip)
        #expect(items[1].key == keyC && items[1].needsBestStill && !items[1].needsFilmstrip)
    }

    @Test("diff: likelyUnanalyzable forces the ffmpegDirect strip side (recovered Avid MXF shape)")
    func diffUnanalyzableMXF() throws {
        let recs = [PreviewSweepKeyedCandidate(
            candidate: candidate(path: "/v/tape.mxf",
                                 container: "MXF (Material eXchange Format)",
                                 codec: "mpeg2video",
                                 unanalyzable: true),
            key: keyA)]
        let items = PreviewSweepPlanner.workItems(candidates: recs,
                                                  index: PreviewSweepCacheIndex())
        try #require(items.count == 1)
        #expect(items[0].needsBestStill && items[0].needsFilmstrip)
    }

    @Test("work item volumeRoot matches the MediaVolumeGate keying")
    func volumeRootKeying() {
        let item = PreviewSweepWorkItem(
            candidate: candidate(path: "/Volumes/MyBook/sub/x.mkv"),
            key: keyA, needsBestStill: true, needsFilmstrip: false)
        #expect(item.volumeRoot == "/Volumes/MyBook")
        let internalItem = PreviewSweepWorkItem(
            candidate: candidate(path: "/Users/rickb/Movies/x.mkv"),
            key: keyB, needsBestStill: true, needsFilmstrip: false)
        #expect(internalItem.volumeRoot == "/")
    }

    // MARK: - Pacing decision

    @Test("pacing: recent interaction pauses; interaction outranks thermal in the reported reason")
    func pacingInteraction() {
        let now: CFAbsoluteTime = 1000
        #expect(PreviewSweepPacing.action(lastInteraction: 995, now: now,
                                          quietSeconds: 10, thermalState: .nominal)
                == .pauseForInteraction)
        #expect(PreviewSweepPacing.action(lastInteraction: 995, now: now,
                                          quietSeconds: 10, thermalState: .critical)
                == .pauseForInteraction)
        // Quiet window elapsed → proceed.
        #expect(PreviewSweepPacing.action(lastInteraction: 985, now: now,
                                          quietSeconds: 10, thermalState: .nominal)
                == .proceed)
        // Never interacted → proceed.
        #expect(PreviewSweepPacing.action(lastInteraction: nil, now: now,
                                          quietSeconds: 10, thermalState: .nominal)
                == .proceed)
    }

    @Test("pacing: thermal .serious/.critical park the sweep; .fair does not")
    func pacingThermal() {
        let now: CFAbsoluteTime = 1000
        for state in [ProcessInfo.ThermalState.serious, .critical] {
            #expect(PreviewSweepPacing.action(lastInteraction: nil, now: now,
                                              quietSeconds: 10, thermalState: state)
                    == .pauseForThermal)
        }
        #expect(PreviewSweepPacing.action(lastInteraction: nil, now: now,
                                          quietSeconds: 10, thermalState: .fair)
                == .proceed)
    }

    @Test("pacing: externallyBusy (precacher running) parks with HIGHEST priority — reported as browse-pause")
    func pacingExternallyBusy() {
        let now: CFAbsoluteTime = 1000
        // No interaction, cool thermals — but the precacher is running.
        #expect(PreviewSweepPacing.action(lastInteraction: nil, now: now,
                                          quietSeconds: 10, thermalState: .nominal,
                                          externallyBusy: true)
                == .pauseForInteraction)
        // Outranks even thermal in the reported reason.
        #expect(PreviewSweepPacing.action(lastInteraction: nil, now: now,
                                          quietSeconds: 10, thermalState: .critical,
                                          externallyBusy: true)
                == .pauseForInteraction)
        // Cleared → falls through to the normal ladder.
        #expect(PreviewSweepPacing.action(lastInteraction: nil, now: now,
                                          quietSeconds: 10, thermalState: .nominal,
                                          externallyBusy: false)
                == .proceed)
    }

    // MARK: - Persisted setting (injected defaults — settings-pollution class)

    @Test("settings: OFF by default, from init and from empty defaults")
    func settingsDefaultOff() throws {
        #expect(PreviewSweepSettings().enabled == false)
        let suite = "PreviewSweepPlannerTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(PreviewSweepSettings.restored(from: defaults).enabled == false)
    }

    @Test("settings: save/restore round trip through injected defaults")
    func settingsRoundTrip() throws {
        let suite = "PreviewSweepPlannerTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var s = PreviewSweepSettings()
        s.enabled = true
        s.save(to: defaults)
        #expect(PreviewSweepSettings.restored(from: defaults).enabled == true)

        s.enabled = false
        s.save(to: defaults)
        #expect(PreviewSweepSettings.restored(from: defaults).enabled == false)
    }

    @Test("settings: poisoned stored value (wrong type) falls back to OFF")
    func settingsPoisonedValue() throws {
        let suite = "PreviewSweepPlannerTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("garbage", forKey: PreviewSweepSettings.enabledKey)
        // bool(forKey:) on a non-boolean string reads false — fail-safe off.
        #expect(PreviewSweepSettings.restored(from: defaults).enabled == false)
    }
}
