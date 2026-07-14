import Foundation
import Testing
@testable import VideoScan

// MARK: - RecordPathIndex tests (perf ride-along 2026-07-14)
//
// Pins the O(1) fullPath → VideoRecord lookup that replaced the
// per-file `records.first(where: { $0.fullPath == path })` linear
// scan in applyDossier and the full-catalog candidate pass in
// single-file startAnalyzing. On Rick's ~103k-record catalog every
// multi-selected Analyze file paid two O(records) MainActor passes.
//
// Dimensions per the feature-test checklist:
//   Logic  — hit / miss / self-verifying stale hit
//   Scale  — 100k synthetic records + explicit time budget (sensor)
//   Isolation — no global state touched (pure class + model instance)
//   Sensor — stale-after-rescan: a same-count records-array swap must
//            never hand back an orphaned record instance (writes to
//            it would be silently lost)

@MainActor
private func pathRecord(_ fullPath: String) -> VideoRecord {
    let r = VideoRecord()
    r.filename = (fullPath as NSString).lastPathComponent
    r.fullPath = fullPath
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    r.durationSeconds = 3.0
    r.lifecycleStage = .cataloged
    return r
}

// MARK: - Pure index unit tests

@MainActor
@Suite("RecordPathIndex")
struct RecordPathIndexTests {

    @Test("hit: returns the record for a cataloged path, O(1) after one build")
    func hitReturnsRecord() {
        let idx = RecordPathIndex()
        let recs = [pathRecord("/v/a.mp4"), pathRecord("/v/b.mp4"), pathRecord("/v/c.mp4")]
        #expect(idx.record(forPath: "/v/b.mp4", in: recs, revision: 0) === recs[1])
        #expect(idx.record(forPath: "/v/a.mp4", in: recs, revision: 0) === recs[0])
        #expect(idx.rebuildCount == 1, "two hits at the same version must share one build")
    }

    @Test("miss: unknown path returns nil without a rebuild storm")
    func missReturnsNil() {
        let idx = RecordPathIndex()
        let recs = [pathRecord("/v/a.mp4")]
        #expect(idx.record(forPath: "/v/none.mp4", in: recs, revision: 0) == nil)
        #expect(idx.record(forPath: "", in: recs, revision: 0) == nil)
        #expect(idx.rebuildCount == 1)
    }

    @Test("revision bump invalidates: in-place fullPath rewrite is visible")
    func revisionBumpInvalidates() {
        let idx = RecordPathIndex()
        let rec = pathRecord("/v/old.mp4")
        let recs = [rec]
        #expect(idx.record(forPath: "/v/old.mp4", in: recs, revision: 0) === rec)

        // Bucket-D-adoption shape: fullPath rewritten in place, count
        // unchanged, model bumps volumeAggregatesRevision.
        rec.fullPath = "/v/new.mp4"
        #expect(idx.record(forPath: "/v/new.mp4", in: recs, revision: 1) === rec)
        #expect(idx.record(forPath: "/v/old.mp4", in: recs, revision: 1) == nil,
                "the old path must not resolve after the rewrite")
    }

    @Test("self-verifying hit: a stale map entry whose record moved is never returned")
    func selfVerifyingHit() {
        let idx = RecordPathIndex()
        let rec = pathRecord("/v/old.mp4")
        let recs = [rec]
        _ = idx.record(forPath: "/v/old.mp4", in: recs, revision: 0)

        // Pathological: fullPath rewritten WITHOUT a revision bump
        // (no such call site today — this is the belt-and-braces).
        rec.fullPath = "/v/new.mp4"
        #expect(idx.record(forPath: "/v/old.mp4", in: recs, revision: 0) == nil,
                "hit verification must reject an entry whose fullPath no longer matches")
        #expect(idx.record(forPath: "/v/new.mp4", in: recs, revision: 0) === rec,
                "miss fallback must find the moved record and rebuild")
    }

    @Test("count change invalidates: add/remove rebuilds")
    func countChangeInvalidates() {
        let idx = RecordPathIndex()
        var recs = [pathRecord("/v/a.mp4")]
        _ = idx.record(forPath: "/v/a.mp4", in: recs, revision: 0)
        recs.append(pathRecord("/v/b.mp4"))
        #expect(idx.record(forPath: "/v/b.mp4", in: recs, revision: 0) === recs[1])
    }
}

// MARK: - Model integration (the actual applyDossier hot path)

@MainActor
@Suite("VideoScanModel path lookup")
struct ModelPathLookupTests {

    @Test("record(forPath:) resolves through the model")
    func modelLookupHitAndMiss() {
        let model = VideoScanModel()
        let a = pathRecord("/v/a.mp4")
        model.records = [a, pathRecord("/v/b.mp4")]
        #expect(model.record(forPath: "/v/a.mp4") === a)
        #expect(model.record(forPath: "/v/zzz.mp4") == nil)
    }

    @Test("sensor: stale-after-rescan — a same-count array swap must resolve to the NEW instance")
    func staleAfterRescanSwap() {
        let model = VideoScanModel()
        let old = pathRecord("/v/clip.mp4")
        model.records = [old]
        #expect(model.record(forPath: "/v/clip.mp4") === old)

        // Rescan shape: new VideoRecord instances, SAME paths, SAME
        // count — the exact hole a count-only staleness check misses.
        // records' didSet invalidates the index on array replacement.
        let fresh = pathRecord("/v/clip.mp4")
        model.records = [fresh]
        #expect(model.record(forPath: "/v/clip.mp4") === fresh,
                "lookup after a rescan swap must return the record that is IN the catalog — writes to the orphaned old instance would be silently lost")
    }

    @Test("applyDossier writes to the current instance after a rescan swap")
    func applyDossierAfterSwapHitsCurrentInstance() {
        let model = VideoScanModel()
        let old = pathRecord("/v/clip.mp4")
        model.records = [old]
        _ = model.record(forPath: "/v/clip.mp4")   // warm the index on the OLD array

        let fresh = pathRecord("/v/clip.mp4")
        model.records = [fresh]

        let extraction = DossierExtraction(
            scenes: [SceneCaption(timestamp: 1.0, text: "scene")],
            dates: [], texts: []
        )
        let applied = model.applyDossier(extraction, to: "/v/clip.mp4",
                                         vlmModel: "stub-vlm", transcript: nil,
                                         whisperModel: nil)
        #expect(applied)
        #expect(fresh.dossierProcessedAt != nil, "the record in the catalog must be stamped")
        #expect(old.dossierProcessedAt == nil, "the orphaned pre-rescan instance must NOT eat the writeback")
    }

    @Test("applyDossier to an uncataloged path still returns false")
    func applyDossierUnknownPathFalse() {
        let model = VideoScanModel()
        model.records = [pathRecord("/v/a.mp4")]
        let applied = model.applyDossier(.empty, to: "/v/ghost.mp4",
                                         vlmModel: "stub-vlm", transcript: nil,
                                         whisperModel: nil)
        #expect(applied == false)
    }

    // MARK: Scale sensor

    @Test("scale sensor: 2,000 lookups over 100k records inside the budget")
    func scaleSensor100k() {
        let model = VideoScanModel()
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            recs.append(pathRecord("/Volumes/Big/dir\(i % 100)/clip\(i).mp4"))
        }
        model.records = recs

        // 2,000 O(1) lookups + one O(n) index build. The old linear
        // scan would be 2,000 × 100k = 200M iterations — far outside
        // this budget. 2s is deliberately generous for CI/M1 headroom;
        // M4 Max runs this in tens of milliseconds.
        let t0 = CFAbsoluteTimeGetCurrent()
        var found = 0
        for i in stride(from: 0, to: 100_000, by: 50) {
            if model.record(forPath: "/Volumes/Big/dir\(i % 100)/clip\(i).mp4") != nil {
                found += 1
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        #expect(found == 2_000)
        #expect(elapsed < 2.0, "2,000 indexed lookups took \(elapsed)s — index is not O(1)")
    }
}

// MARK: - Single-file startAnalyzing fast path

@MainActor
@Suite("startAnalyzing single-file fast path")
struct SingleFileFastPathTests {

    @Test("exact-path batch analyzes exactly that file")
    func exactPathBatchRunsThatFile() async throws {
        let root = NSTemporaryDirectory() + "vs-fastpath-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let p0 = root + "a.mp4", p1 = root + "b.mp4"
        FileManager.default.createFile(atPath: p0, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: p1, contents: Data("x".utf8))

        let model = VideoScanModel()
        model.records = [pathRecord(p0), pathRecord(p1)]

        let stub = StubDossierRunner(modelID: "stub-fastpath")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        let ran = await orch.startAnalyzing(volumePrefix: p0, model: model,
                                            ignoringScope: true)
        #expect(ran)
        #expect(await stub.pathsCalled() == [p0],
                "single-file batch must analyze exactly the selected file")
    }

    @Test("fast path still honors the candidate gates (confirmedJunk is refused work)")
    func fastPathHonorsGates() async throws {
        let root = NSTemporaryDirectory() + "vs-fastpath-junk-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let p = root + "junk.mp4"
        FileManager.default.createFile(atPath: p, contents: Data("x".utf8))

        let model = VideoScanModel()
        let rec = pathRecord(p)
        rec.mediaDisposition = .confirmedJunk
        model.records = [rec]

        let stub = StubDossierRunner(modelID: "stub-fastpath-junk")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        let ran = await orch.startAnalyzing(volumePrefix: p, model: model,
                                            ignoringScope: true)
        // Same contract as before: empty candidate set is a completed
        // (nothing-to-do) run — but the runner must never be invoked.
        #expect(ran)
        #expect(await stub.pathsCalled() == [],
                "confirmedJunk must not reach the runner via the fast path")
        #expect(rec.dossierProcessedAt == nil)
    }
}
