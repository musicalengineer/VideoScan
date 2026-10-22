// AvidIDBackfillTests.swift
// The capture side of the Avid pair-matcher fix (Rick 2026-10-22): the
// render signal, "Fill In Avid IDs" (plan, compare-and-set fill, the MFO
// job with offline drives skipped and counted, the release it ends with),
// the synthetic-ffmpeg media matrix, and the poisoned-catalog launch
// (isolation: stored links between a render and non-MXF audio are released
// at load — and the release is WRITTEN — while genuine pairs are kept).
//
// Every media fixture is synthetic (testsrc / sine, `test_` names, temp
// dirs). No personal media.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Logic: the render signal and the fill

@Suite("Avid IDs — render signal and fill") @MainActor
struct AvidIDFillLogicTests {

    @Test func renderNamesAreRecognisedAndClipNamesAreNot() {
        for render in ["Boston.Sequence updated.03,Title,13", "MiscKids,Soft Sky,9",
                       "AllVideosStereo.Exported.01,Video Mixdown,1", "Untitled Sequence.02,Audio Suite PlugIn Effect,12",
                       "AllVideosStereo,Audio Dissolve,2.new.01"] {
            #expect(AvidRenderSignal.nameLooksLikeRender(render), "\(render)")
        }
        for clip in ["00002", "00045.new.03", "clip-2010-03-26 12;35;39.mov", "TONE: 1000 Hz @ -14.0 dB.1",
                     "JeffBeck2 Bin.01", "Christmas, 1985", "IMG_0906.MOV", ""] {
            #expect(!AvidRenderSignal.nameLooksLikeRender(clip), "\(clip)")
        }
    }

    @Test func thePrecomputeMarkerIsFoundInUTF16BigEndianAtAnyOffset() {
        let marker = Data(AvidRenderSignal.precomputeMarker)
        for pad in [0, 1, 7, 102_437] {
            #expect(AvidRenderSignal.headerHasPrecomputeMarker(Data(repeating: 0x06, count: pad) + marker + Data([0, 0])), "pad \(pad)")
        }
        #expect(!AvidRenderSignal.headerHasPrecomputeMarker(Data("Precompute Source Mob".utf8)))
        #expect(!AvidRenderSignal.headerHasPrecomputeMarker(marker.dropLast()))
        #expect(!AvidRenderSignal.headerHasPrecomputeMarker(Data()))
    }

    @Test func tagsBecomeTheThreeFields() {
        let p = AvidIDBackfill.avidIDs(formatTags: ["material_package_umid": "0xUMID", "material_package_name": "00002"], header: nil)
        #expect(p == AvidIDProbe(umid: "0xUMID", name: "00002", isRender: false))
        let r = AvidIDBackfill.avidIDs(formatTags: [:], header: Data(AvidRenderSignal.precomputeMarker))
        #expect(r.isRender && !r.hasAnyID)
    }

    @Test func theFillOnlyFillsEmptyFieldsAndNeverClearsARender() {
        let rec = AvidPairFixture.record("00002.V1.mxf", .videoOnly, duration: 1, umid: "KEEP")
        rec.isAvidRender = true
        #expect(AvidIDBackfill.fill(AvidIDProbe(umid: "OTHER", name: "00002", isRender: false), into: rec))
        #expect(rec.materialPackageUMID == "KEEP" && rec.materialPackageName == "00002" && rec.isAvidRender)
        #expect(!AvidIDBackfill.fill(AvidIDProbe(), into: rec))
    }

    @Test func thePlanIsLiveMXFRowsMissingAnID() {
        let missing = AvidPairFixture.record("a.mxf", .videoOnly, duration: 1)
        let half = AvidPairFixture.record("b.MXF", .audioOnly, duration: 1, umid: "U")
        let full = AvidPairFixture.record("c.mxf", .audioOnly, duration: 1, umid: "U", name: "c")
        let mov = AvidPairFixture.record("d.mov", .videoOnly, duration: 1)
        let gone = AvidPairFixture.record("e.mxf", .videoOnly, duration: 1)
        gone.removal = .removedFromCatalog(at: Date(), reason: .userRemoved)
        let plan = AvidIDBackfill.plan(records: [missing, half, full, mov, gone])
        #expect(plan.map(\.filename) == ["a.mxf", "b.MXF"])
    }

    /// Scale: the plan over 100k rows (3.7k MXF) is one linear pass.
    @Test func thePlanAt100kIsLinear() {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            records.append(AvidPairFixture.record(i % 27 == 0 ? "\(i).V1.mxf" : "test_\(i).mov", .videoOnly, duration: 1,
                                                  directory: "/Volumes/test_V\(i % 7)"))
        }
        let clock = ContinuousClock()
        let started = clock.now
        let plan = AvidIDBackfill.plan(records: records)
        let elapsed = started.duration(to: clock.now)
        #expect(plan.count == 3_704)
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(2)), "plan at 100k took \(elapsed)")
    }
}

// MARK: - The MFO job (stub prober — no ffprobe, no media)

@Suite("Avid IDs — Fill In Avid IDs job", .serialized) @MainActor
struct AvidIDBackfillJobTests {
    typealias F = AvidPairFixture

    @Test func fillsOnlineFilesSkipsOfflineDrivesAndReleasesWhatTheIDsDisprove() async throws {
        let model = VideoScanModel()
        // A stored pair that only the IDs can disprove (two different clips).
        let v = F.record("00005.PHYSV01.91_4D4D228565.mxf", .videoOnly, duration: 4)
        let a = F.record("00041.A24D1BD29D.mxf", .audioOnly, duration: 4)
        // A genuine stored pair the IDs confirm (consolidate counters differ).
        let gv = F.record("00045.PHYSV01.EB.mxf", .videoOnly, duration: 6)
        let ga = F.record("00045.PHYSA02.86.mxf", .audioOnly, duration: 6)
        let render = F.record("Boston.Sequence upd4C6B6468.mxf", .videoOnly, duration: 2)
        let offline = F.record("00099.V1.mxf", .videoOnly, duration: 1, directory: "/Volumes/test_Unplugged/MXF/1")
        let notFound = F.record("00098.V1.mxf", .videoOnly, duration: 1)
        let unreadable = F.record("00097.V1.mxf", .videoOnly, duration: 1)
        F.link(v, a)
        F.link(gv, ga)
        model.records = [v, a, gv, ga, render, offline, notFound, unreadable]
        let probes: [String: AvidIDProbe] = [
            v.fullPath: AvidIDProbe(umid: "U5", name: "00005.new.05"),
            a.fullPath: AvidIDProbe(umid: "U41", name: "00041"),
            gv.fullPath: AvidIDProbe(umid: "UV45", name: "00045.new.03"),
            ga.fullPath: AvidIDProbe(umid: "UA45", name: "00045.new.02"),
            render.fullPath: AvidIDProbe(umid: "UR", name: "Boston.Sequence updated.03,Title,13", isRender: true),
        ]
        let job = AvidIDBackfillJob(model: model)
        job.proberForTesting = { path in probes[path] }
        job.volumeOnline = { !$0.hasPrefix("/Volumes/test_Unplugged") }
        job.fileExists = { !$0.hasSuffix("00098.V1.mxf") }
        job.saveCatalogForTesting = { true }
        job.start()
        await job.task?.value

        guard case .finished = job.state else { Issue.record("job ended \(job.state)"); return }
        let t = job.totals
        #expect(t.total == 8 && t.done == 8)
        #expect(t.filled == 5 && t.renders == 1)
        #expect(t.offline == 1 && t.notFound == 1 && t.failed == 1)
        #expect(t.releasedPairs == 1)
        #expect(v.materialPackageName == "00005.new.05" && render.isAvidRender)
        #expect(v.pairedWith == nil && a.pairedWith == nil, "two different clips — released")
        #expect(gv.pairedWith === ga, "the same clip under two consolidate counters — kept")
        #expect(job.released.first?.line.contains("different Avid clips") == true)
        #expect(offline.materialPackageName.isEmpty)
        #expect(job.problems.map(\.kind).sorted { "\($0)" < "\($1)" } == [.failed, .notFound, .offline])
    }

    @Test func refusedOnAReadOnlyCatalog() async {
        let model = VideoScanModel()
        model.isReadOnly = true
        let job = AvidIDBackfillJob(model: model)
        job.start()
        await job.task?.value
        #expect(job.wasRefused)
    }
}

// MARK: - Media matrix (real ffmpeg fixtures, real ffprobe)

@Suite("Avid IDs — media matrix", .serialized) @MainActor
struct AvidIDMediaMatrixTests {

    private func makeFixtures() throws -> [String: URL] {
        let dir = try CleanupTestMedia.makeScratchDir("avidids")
        func run(_ args: [String], _ name: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try CleanupTestMedia.runFFmpeg(args, output: url.path)
            return url
        }
        let pic = ["-f", "lavfi", "-i", "testsrc=size=720x480:rate=30000/1001:duration=2"]
        let tone = ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2"]
        let dv = ["-c:v", "dvvideo", "-pix_fmt", "yuv411p"]
        return [
            // OP-Atom V and A of one clip: same name tag, DIFFERENT UMIDs (ffmpeg
            // mints one per file — exactly the consolidate case).
            "v": try run(pic + dv + ["-metadata", "material_package_name=test_00002", "-f", "mxf_opatom"], "test_00002.V14D1BBD84.mxf"),
            "a": try run(tone + ["-c:a", "pcm_s16le", "-metadata", "material_package_name=test_00002", "-f", "mxf_opatom"],
                         "test_00002.A14B9428E6.mxf"),
            "render": try run(pic + dv + ["-metadata", "material_package_name=test_seq.01,Title,3", "-f", "mxf_opatom"],
                              "test_seq.0A4C6B6468.mxf"),
            "mp4": try run(pic + ["-c:v", "libx264", "-preset", "ultrafast", "-an"], "test_ctl.mp4"),
            "mov": try run(pic + ["-c:v", "prores_ks", "-profile:v", "0", "-an"], "test_ctl.mov"),
            "mkv": try run(pic + tone + ["-c:v", "ffv1", "-c:a", "pcm_s16le"], "test_ctl.mkv"),
            "avi": try run(pic + dv + ["-an"], "test_ctl.avi"),
            "wav": try run(tone + ["-c:a", "pcm_s16le"], "test_ctl.wav"),
        ]
    }

    private func scanned(_ url: URL) async throws -> VideoRecord {
        let (probe, _) = await ScanEngine.runFFProbe(url: url)
        let rec = VideoRecord()
        rec.filename = url.lastPathComponent
        rec.directory = url.deletingLastPathComponent().path
        rec.fullPath = url.path
        var outcome = ProbeOutcome()
        ScanEngine.applyProbeOrFallback(outcome: &outcome, url: url, path: url.path, probe: probe, stderrTrimmed: "")
        rec.apply(outcome.probe)
        return rec
    }

    @Test func opAtomVideoAndAudioOfOneClipPairAndARenderNeverDoes() async throws {
        guard CleanupTestMedia.toolsAvailable else { Issue.record("ffmpeg/ffprobe missing"); return }
        let f = try makeFixtures()
        defer { try? FileManager.default.removeItem(at: f["v"]!.deletingLastPathComponent()) }
        let v = try await scanned(f["v"]!)
        let a = try await scanned(f["a"]!)
        let render = try await scanned(f["render"]!)
        // Capture at scan.
        #expect(v.materialPackageName == "test_00002" && a.materialPackageName == "test_00002")
        #expect(!v.materialPackageUMID.isEmpty && v.materialPackageUMID != a.materialPackageUMID)
        #expect(render.isAvidRender && !v.isAvidRender && !a.isAvidRender)
        #expect(v.streamType == .videoOnly && a.streamType == .audioOnly)
        // The backfill's own read agrees with the scan.
        let probed = try #require(await AvidIDBackfill.probe(path: f["v"]!.path))
        #expect(probed.name == "test_00002" && probed.umid == v.materialPackageUMID && !probed.isRender)
        // The rule.
        #expect(AvidPairEvidence.judge(video: AvidPairSide(v), audio: AvidPairSide(a)) == .sameClip("same Avid clip name \"test_00002\""))
        #expect(CorrelationScorer.findBestPair(for: v, in: [v, a, render], durationTolerance: 1, timestampTolerance: 5)?.audio === a)
        a.durationSeconds = render.durationSeconds
        #expect(CorrelationScorer.findBestPair(for: render, in: [render, a], durationTolerance: 1, timestampTolerance: 5) == nil)
    }

    @Test func controlsMp4MovMkvAviAreUnaffected() async throws {
        guard CleanupTestMedia.toolsAvailable else { Issue.record("ffmpeg/ffprobe missing"); return }
        let f = try makeFixtures()
        defer { try? FileManager.default.removeItem(at: f["v"]!.deletingLastPathComponent()) }
        let wav = try await scanned(f["wav"]!)
        let mxfVideo = try await scanned(f["v"]!)
        for key in ["mp4", "mov", "mkv", "avi"] {
            let ctl = try await scanned(f[key]!)
            #expect(ctl.materialPackageName.isEmpty && !ctl.isAvidRender, "\(key)")
            ctl.streamTypeRaw = StreamType.videoOnly.rawValue    // the mkv carries sound; judge it as a V-only row
            #expect(AvidPairEvidence.judge(video: AvidPairSide(ctl), audio: AvidPairSide(wav)) == .notAvid, "\(key)")
            #expect(CorrelationScorer.findBestPair(for: ctl, in: [ctl, wav], durationTolerance: 1, timestampTolerance: 5)?.audio === wav,
                    "\(key): today's scoring still pairs a non-MXF video with its sound")
        }
        // …and the same .wav is refused for the MXF video.
        #expect(CorrelationScorer.findBestPair(for: mxfVideo, in: [mxfVideo, wav], durationTolerance: 1, timestampTolerance: 5) == nil)
    }
}

// MARK: - Isolation: a poisoned catalog.sqlite launch

@Suite("Avid IDs — poisoned stored links at launch", .serialized) @MainActor
struct AvidPairLaunchReleaseTests {

    /// Shape four live fixture rows into a render ↔ Logic-sample link and a
    /// genuine consolidated clip, commit them as STORED links, relaunch.
    @Test func renderToNonMXFLinksAreReleasedAtLaunchAndTheReleaseIsWritten() async throws {
        let scene = try CutoverScene.make("avid_pairs"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let render = try scene.record(.healthy)
        let sample = try scene.record(.stalePrint)
        let clipV = try scene.record(.curatedConflictA)
        let clipA = try scene.record(.curatedConflictB)
        shape(render, "Boston.Sequence upd4C6B6468.mxf", .videoOnly, name: "Boston.Sequence updated.03,Title,13", render: true)
        shape(sample, "KONTBSTR1X32", .audioOnly, name: "")
        shape(clipV, "00002.V14D1BBD84.mxf", .videoOnly, name: "00002")
        shape(clipA, "00002.A14B9428E6.mxf", .audioOnly, name: "00002")
        AvidPairFixture.link(render, sample)
        AvidPairFixture.link(clipV, clipA)
        #expect(scene.model.saveCatalogNow())
        #expect(try await storedPartner(of: render, in: scene) == sample.id, "the poison is stored")

        try await scene.relaunch()

        let r2 = try scene.record(.healthy), s2 = try scene.record(.stalePrint)
        let v2 = try scene.record(.curatedConflictA), a2 = try scene.record(.curatedConflictB)
        #expect(r2.pairedWith == nil && s2.pairedWith == nil && r2.pairGroupID == nil)
        #expect(v2.pairedWith === a2 && a2.pairedWith === v2)
        #expect(r2.isAvidRender && v2.materialPackageName == "00002", "the Avid fields round-trip through probe_extra")
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("released pair: Boston.Sequence upd4C6B6468.mxf \u{2194} KONTBSTR1X32 —")
                    || log.contains("released pair: KONTBSTR1X32 \u{2194} Boston.Sequence upd4C6B6468.mxf —"), Comment(rawValue: log))
        // The launch commit wrote the release: the store itself no longer links them.
        #expect(scene.model.saveCatalogNow())
        #expect(try await storedPartner(of: r2, in: scene) == nil)
        #expect(try await storedPartner(of: v2, in: scene) == a2.id)
    }

    private func shape(_ r: VideoRecord, _ filename: String, _ stream: StreamType, name: String, render: Bool = false) {
        r.filename = filename
        r.streamTypeRaw = stream.rawValue
        r.container = filename.hasSuffix(".mxf") ? "MXF (Material eXchange Format)" : "AIFF"
        r.durationSeconds = 2
        r.materialPackageName = name
        r.isAvidRender = render
    }

    /// The partner the STORE holds for `r` — read with no re-validation.
    private func storedPartner(of r: VideoRecord, in scene: CutoverScene) async throws -> UUID? {
        let repository = GRDBCatalogRepository(host: "avid-pairs-test")
        _ = await repository.open(at: scene.databaseURL)
        let built: SQLiteCatalogLoader.LoadResult
        do {
            built = try SQLiteCatalogLoader.build(try await CatalogLoad.read(repository))
        } catch {
            await repository.close()
            throw error
        }
        await repository.close()
        return built.records.first { $0.id == r.id }?.pairedWith?.id
    }
}
