// MissingAudioFinderTests.swift
// "Find Missing Audio" (GH #111, Rick 2026-09-11) — the five dimensions:
//   Logic        — stem normalization (incl. Avid MXF names), each tier,
//                  duration refusal, ranking, cancel, progress.
//   Media matrix — synthetic ffmpeg fixtures (`test_` prefix): mp4/h264
//                  video-only + wav / aac(m4a) / OP-Atom mxf audio at
//                  sibling paths, one mkv/ffv1+pcm negative; real
//                  FileManager lister + real ffprobe; Pair ingests the
//                  wav through the model's single-file probe path.
//   Scale        — tier a over 100k hidden records; tier c over a 10k-file
//                  synthetic tree bounded by the probe cap and walk cap.
//   Isolation    — injected roots only; the finder never lists a
//                  directory outside the roots it was given (recording
//                  fake FS as the oracle); no real /Volumes walk.
//   Sensor       — setAsideAudioIsStillFindable: Tidy sets an unlinked
//                  wav aside through applyTidyCatalog, the finder returns
//                  it as a tier-a candidate, Pair restores + correlates.

import Foundation
import Testing
@testable import VideoScan

// MARK: - Fakes

/// In-memory directory tree that RECORDS every listing it serves — the
/// isolation oracle. (`@unchecked Sendable` + lock ≈ a mutex-guarded
/// struct handed across threads.)
final class FakeMissingAudioFS: MissingAudioFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var tree: [String: [MissingAudioFinder.DirectoryEntry]] = [:]
    private var listedPaths: [String] = []

    init(files: [String]) {
        var dirs = Set<String>()
        for f in files {
            let parent = (f as NSString).deletingLastPathComponent
            tree[parent, default: []].append(.init(path: f, isDirectory: false))
            var d = parent
            while !d.isEmpty && d != "/" {
                if !dirs.insert(d).inserted { break }
                let p = (d as NSString).deletingLastPathComponent
                tree[p, default: []].append(.init(path: d, isDirectory: true))
                d = p
            }
        }
    }

    var listed: [String] { lock.withLock { listedPaths } }

    func children(of directory: String) -> [MissingAudioFinder.DirectoryEntry] {
        lock.withLock {
            listedPaths.append(directory)
            return tree[directory] ?? []
        }
    }
}

/// Table-driven probe that counts calls; optional per-call delay so a
/// cancel test can interrupt mid-tier.
final class FakeMissingAudioProbe: MissingAudioDurationProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: MissingAudioFinder.ProbeResult]
    private var callPaths: [String] = []
    var delayNanos: UInt64 = 0
    var fallback: MissingAudioFinder.ProbeResult?

    init(_ table: [String: MissingAudioFinder.ProbeResult] = [:],
         fallback: MissingAudioFinder.ProbeResult? = nil) {
        self.table = table
        self.fallback = fallback
    }

    var calls: [String] { lock.withLock { callPaths } }

    func probe(path: String) async -> MissingAudioFinder.ProbeResult? {
        lock.withLock { callPaths.append(path) }
        if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
        return lock.withLock { table[path] ?? fallback }
    }
}

private func audio(_ seconds: Double) -> MissingAudioFinder.ProbeResult {
    .init(durationSeconds: seconds, hasVideo: false, hasAudio: true)
}

private func testConfig(cap: Int = 200, walk: Int = 250_000) -> MissingAudioFinder.Config {
    var c = MissingAudioFinder.Config(audioExtensions: ["wav", "aif", "m4a", "aac"],
                                      skipDirNames: [".Trashes", "Music"])
    c.maxFilesProbed = cap
    c.maxEntriesWalked = walk
    return c
}

private func reunionVideo() -> MissingAudioFinder.VideoTarget {
    .init(id: UUID(), filename: "reunion_1994.mov",
          fullPath: "/Volumes/T/video/reunion_1994.mov",
          directory: "/Volumes/T/video", durationSeconds: 300)
}

private func hidden(_ filename: String, dir: String, duration: Double,
                    state: MissingAudioFinder.CatalogState = .setAside(reason: "unlinked-audio"),
                    id: UUID = UUID()) -> MissingAudioFinder.HiddenAudio {
    .init(snap: .init(id: id, filename: filename, directory: dir,
                      durationSeconds: duration, dateCreatedRaw: nil,
                      timecode: "", tapeName: ""),
          fullPath: dir + "/" + filename, state: state)
}

@MainActor
private func rec(_ filename: String, stream: StreamType, dir: String,
                 duration: Double) -> VideoRecord {
    let r = VideoRecord()
    r.filename = filename
    r.ext = (filename as NSString).pathExtension.uppercased()
    r.streamTypeRaw = stream.rawValue
    r.directory = dir
    r.fullPath = dir + "/" + filename
    r.durationSeconds = duration
    r.sizeBytes = 1_000_000
    return r
}

// MARK: - Logic: stem normalization

@Suite("Find Missing Audio — stem normalization")
struct MissingAudioStemTests {
    private func stem(_ s: String) -> String { MissingAudioFinder.normalizedStem(s) }

    @Test("Avid bare V/A hex names fold to one stem")
    func avidBareVA() {
        #expect(stem("00000.V14BB2CE9D.mxf") == stem("00000.A14BB2CE9D.mxf"))
        #expect(stem("00001.V14D1BBD3F.mxf") != stem("00001.V14D1BBD3E.mxf"))
    }

    @Test("Avid OMFI tape-name shape folds across mxf/wav")
    func omfiTapeName() {
        #expect(stem("NewTape9V01.4B9C1586.8D8520.mxf") == stem("NewTape9A01.4B9C1586.8D8510.wav"))
        #expect(stem("NewTape9V01.4B9C1586.8D8520.mxf") == "newtape9.4b9c1586")
        #expect(stem("NewTape9V01.4B9C1586.8D8520.mxf") != stem("NewTape10V01.4B9C1586.8D8520.mxf"))
    }

    @Test("Common audio suffixes and case are ignored")
    func suffixes() {
        #expect(stem("holiday_audio.wav") == "holiday")
        #expect(stem("holiday.A1.wav") == "holiday")
        #expect(stem("holiday-a.wav") == "holiday")
        #expect(stem("holiday_A2.aif") == "holiday")
        #expect(stem("Holiday.MOV") == "holiday")
        #expect(stem("party_L.wav") == "party")
        #expect(stem("party_stereo_mix.wav") == "party")
        #expect(stem("tape9v01.mov") == stem("tape9a01.wav"))
        #expect(stem("clip_v.mov") == stem("clip_a.wav"))
    }

    @Test("Different clips stay different; a whole name is never stripped")
    func negatives() {
        #expect(stem("family_1987.mov") != stem("family_1988.wav"))
        #expect(stem("a.wav") == "a")
        #expect(stem("audio.wav") == "audio")
        #expect(stem("audio_audio.wav") == "audio")
        #expect(!MissingAudioFinder.stemsMatch("x.mov", "y.wav"))
    }
}

// MARK: - Logic: evaluate + tiers + ranking

@Suite("Find Missing Audio — tiers and ranking")
struct MissingAudioTierTests {

    @Test("Tier a: set-aside audio matched by stem + duration, zero disk I/O")
    func tierASetAsideByStem() {
        let v = reunionVideo()
        let id = UUID()
        let h = [hidden("reunion_1994_audio.wav", dir: "/Volumes/T/audio", duration: 300.4, id: id)]
        let (cands, report) = MissingAudioFinder.hiddenCatalogCandidates(video: v, hidden: h, config: testConfig())
        #expect(cands.count == 1)
        #expect(report.examined == 1 && report.matched == 1)
        let c = try! #require(cands.first)
        #expect(c.tier == .hiddenCatalogRecords)
        #expect(c.reasons.contains("stem") && c.reasons.contains("duration"))
        #expect(c.catalogRecordID == id)
        #expect(c.catalogState == .setAside(reason: "unlinked-audio"))
        #expect(c.correlateWillAccept)
        #expect(abs((c.durationDelta ?? 0) - 0.4) < 0.001)
    }

    @Test("Tier a: purged same-folder audio matches on duration + directory")
    func tierAPurgedSameFolder() {
        let v = reunionVideo()
        let h = [hidden("take3.wav", dir: "/Volumes/T/video", duration: 300.2, state: .purged)]
        let (cands, _) = MissingAudioFinder.hiddenCatalogCandidates(video: v, hidden: h, config: testConfig())
        #expect(cands.count == 1)
        #expect(cands.first?.reasons == ["duration", "directory"])
        #expect(cands.first?.catalogState == .purged)
    }

    @Test("Tier a: incompatible duration is refused (GH #125); unknown + no signal is below floor")
    func tierARefusals() {
        let v = reunionVideo()
        let h = [hidden("x.wav", dir: "/Volumes/T/elsewhere", duration: 12),
                 hidden("y.wav", dir: "/Volumes/T/elsewhere", duration: 0)]
        let (cands, report) = MissingAudioFinder.hiddenCatalogCandidates(video: v, hidden: h, config: testConfig())
        #expect(cands.isEmpty)
        #expect(report.durationRefused == 1)
        #expect(report.examined == 2)
    }

    @Test("Tier a: an exact Avid key match with unknown duration is Correlate-acceptable")
    func tierAAvidKeyUnknownDuration() {
        let v = MissingAudioFinder.VideoTarget(
            id: UUID(), filename: "NewTape9V01.4B9C1586.8D8520.mxf",
            fullPath: "/Volumes/T/Avid MediaFiles/MXF/1/NewTape9V01.4B9C1586.8D8520.mxf",
            directory: "/Volumes/T/Avid MediaFiles/MXF/1", durationSeconds: 0)
        let h = [hidden("NewTape9A01.4B9C1586.8D8510.wav", dir: "/Volumes/T/OMFI MediaFiles", duration: 0)]
        let (cands, _) = MissingAudioFinder.hiddenCatalogCandidates(video: v, hidden: h, config: testConfig())
        #expect(cands.first?.reasons == ["filename"])
        #expect(cands.first?.correlateWillAccept == true)
    }

    @Test("Tier b: same folder by duration; sibling folder by stem; short take refused; mkv ignored")
    func tierBNearby() async {
        let v = reunionVideo()
        let fs = FakeMissingAudioFS(files: [
            "/Volumes/T/video/reunion_1994.mov",
            "/Volumes/T/video/take.wav",
            "/Volumes/T/audio/reunion_1994.A1.wav",
            "/Volumes/T/other/noise.wav",
            "/Volumes/T/other/reunion_1994.mkv",
            "/Volumes/T/README.txt",
        ])
        let probe = FakeMissingAudioProbe([
            "/Volumes/T/video/take.wav": audio(300.5),
            "/Volumes/T/audio/reunion_1994.A1.wav": audio(300.0),
            "/Volumes/T/other/noise.wav": audio(5),
        ])
        var budget = MissingAudioFinder.ProbeBudget(cap: 200)
        let (cands, report) = await MissingAudioFinder.nearbyFolderCandidates(
            video: v, config: testConfig(), fileSystem: fs, probe: probe,
            budget: &budget, excludingPaths: [], progress: nil)
        let paths = Set(cands.map(\.path))
        #expect(paths == ["/Volumes/T/video/take.wav", "/Volumes/T/audio/reunion_1994.A1.wav"])
        #expect(report.examined == 3)
        #expect(report.probed == 3)
        #expect(report.durationRefused == 1)
        #expect(!report.truncated)
        let take = cands.first { $0.filename == "take.wav" }
        #expect(take?.reasons == ["duration", "directory"])
        let a1 = cands.first { $0.filename == "reunion_1994.A1.wav" }
        #expect(a1?.reasons.first == "stem")
        #expect(a1?.tier == .nearbyFolders)
        #expect(a1?.catalogState == .notInCatalog)
        // Stem matches are probed FIRST.
        #expect(probe.calls.first == "/Volumes/T/audio/reunion_1994.A1.wav")
    }

    @Test("Tier b: a file with a picture is never the audio half")
    func tierBVideoPlusAudioSkipped() async {
        let v = reunionVideo()
        let fs = FakeMissingAudioFS(files: ["/Volumes/T/video/reunion_1994_audio.m4a"])
        let probe = FakeMissingAudioProbe([
            "/Volumes/T/video/reunion_1994_audio.m4a": .init(durationSeconds: 300, hasVideo: true, hasAudio: true),
        ])
        var budget = MissingAudioFinder.ProbeBudget(cap: 200)
        let (cands, _) = await MissingAudioFinder.nearbyFolderCandidates(
            video: v, config: testConfig(), fileSystem: fs, probe: probe,
            budget: &budget, excludingPaths: [], progress: nil)
        #expect(cands.isEmpty)
    }

    @Test("Tier c: walks every root for the stem, honours skip dirs and hidden dirs")
    func tierCWalk() async {
        let v = reunionVideo()
        let fs = FakeMissingAudioFS(files: [
            "/Volumes/A/x/unrelated.wav",
            "/Volumes/A/.hidden/reunion_1994.wav",
            "/Volumes/B/x/y/z/REUNION_1994_audio.wav",
            "/Volumes/B/Music/reunion_1994.wav",
        ])
        let probe = FakeMissingAudioProbe(fallback: audio(300.1))
        var budget = MissingAudioFinder.ProbeBudget(cap: 200)
        let (cands, report, cancelled) = await MissingAudioFinder.scanRootCandidates(
            video: v, roots: ["/Volumes/A", "/Volumes/B"], config: testConfig(),
            fileSystem: fs, probe: probe, budget: &budget, excludingPaths: [], progress: nil)
        #expect(!cancelled)
        #expect(cands.map(\.path) == ["/Volumes/B/x/y/z/REUNION_1994_audio.wav"])
        #expect(cands.first?.tier == .allScanRoots)
        #expect(cands.first?.reasons.contains("stem") == true)
        #expect(report.probed == 1)
        #expect(!fs.listed.contains("/Volumes/B/Music"))
        #expect(!fs.listed.contains("/Volumes/A/.hidden"))
    }

    @Test("Tier c: probe cap — an unprobed MXF needs a stem match; report says truncated")
    func tierCProbeCap() async {
        let v = reunionVideo()
        let fs = FakeMissingAudioFS(files: [
            "/Volumes/A/a/reunion_1994.wav",
            "/Volumes/A/b/reunion_1994.mxf",
        ])
        let probe = FakeMissingAudioProbe(fallback: audio(300))
        var budget = MissingAudioFinder.ProbeBudget(cap: 1)
        let (cands, report, _) = await MissingAudioFinder.scanRootCandidates(
            video: v, roots: ["/Volumes/A"], config: testConfig(cap: 1),
            fileSystem: fs, probe: probe, budget: &budget, excludingPaths: [], progress: nil)
        #expect(probe.calls.count == 1)
        #expect(report.truncated)
        #expect(cands.count == 2)
        let mxf = cands.first { $0.filename == "reunion_1994.mxf" }
        #expect(mxf?.durationSeconds == nil)
        #expect(mxf?.correlateWillAccept == true, "exact key match carries an unprobed MXF through Correlate's gate")
    }

    @Test("Whole search: a hidden record found again on disk shows once, as tier a")
    func searchDedupesAcrossTiers() async {
        let v = reunionVideo()
        let id = UUID()
        let h = [hidden("reunion_1994_audio.wav", dir: "/Volumes/T/audio", duration: 300.4, id: id)]
        let fs = FakeMissingAudioFS(files: ["/Volumes/T/audio/reunion_1994_audio.wav"])
        let probe = FakeMissingAudioProbe(fallback: audio(300.4))
        let r = await MissingAudioFinder.search(video: v, hidden: h, roots: ["/Volumes/T"],
                                               config: testConfig(), fileSystem: fs, probe: probe)
        #expect(r.candidates.count == 1)
        #expect(r.candidates.first?.tier == .hiddenCatalogRecords)
        #expect(r.candidates.first?.catalogRecordID == id)
        #expect(probe.calls.isEmpty, "a known record is never re-probed")
        #expect(r.reports.map(\.tier) == [.hiddenCatalogRecords, .nearbyFolders, .allScanRoots])
    }

    @Test("Ranking: Correlate-acceptable first, then score, then cheaper tier, then smaller delta")
    func ranking() {
        func c(_ name: String, tier: MissingAudioFinder.Tier, score: Int, delta: Double?, accept: Bool) -> MissingAudioFinder.Candidate {
            .init(id: UUID(), path: "/x/\(name)", tier: tier, score: score, reasons: [],
                  durationSeconds: nil, durationDelta: delta, catalogRecordID: nil,
                  catalogState: .notInCatalog, correlateWillAccept: accept)
        }
        let input = [
            c("d", tier: .allScanRoots, score: 9, delta: 0.1, accept: false),
            c("c", tier: .allScanRoots, score: 4, delta: nil, accept: true),
            c("b", tier: .nearbyFolders, score: 4, delta: 0.9, accept: true),
            c("a", tier: .hiddenCatalogRecords, score: 7, delta: 0.5, accept: true),
            c("b2", tier: .nearbyFolders, score: 4, delta: 0.2, accept: true),
        ]
        let names = MissingAudioFinder.rank(input).map(\.filename)
        #expect(names == ["a", "b2", "b", "c", "d"])
    }

    @Test("Cancel token: a cancelled task stops the search early and says so")
    func cancelStopsSearch() async {
        let v = reunionVideo()
        var files: [String] = []
        for i in 0..<100 { files.append("/Volumes/T/video/take\(i).wav") }
        let fs = FakeMissingAudioFS(files: files)
        let probe = FakeMissingAudioProbe(fallback: audio(300))
        probe.delayNanos = 50_000_000   // 50 ms per probe → 5 s uncancelled
        let task = Task {
            await MissingAudioFinder.search(video: v, hidden: [], roots: [],
                                            config: testConfig(), fileSystem: fs, probe: probe)
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        task.cancel()
        let r = await task.value
        #expect(r.cancelled)
        #expect(probe.calls.count < 100)
    }

    @Test("Progress is reported per tier")
    func progressReported() async {
        let v = reunionVideo()
        let fs = FakeMissingAudioFS(files: ["/Volumes/T/video/take.wav"])
        let probe = FakeMissingAudioProbe(fallback: audio(300))
        final class Sink: @unchecked Sendable {
            let lock = NSLock(); var tiers: [MissingAudioFinder.Tier] = []
            func add(_ t: MissingAudioFinder.Tier) { lock.withLock { tiers.append(t) } }
        }
        let sink = Sink()
        _ = await MissingAudioFinder.search(video: v, hidden: [hidden("z.wav", dir: "/q", duration: 1)],
                                            roots: ["/Volumes/T"], config: testConfig(),
                                            fileSystem: fs, probe: probe) { sink.add($0.tier) }
        let tiers = sink.lock.withLock { sink.tiers }
        #expect(tiers.contains(.hiddenCatalogRecords))
        #expect(tiers.contains(.nearbyFolders))
    }
}

// MARK: - Scale

@Suite("Find Missing Audio — scale")
struct MissingAudioScaleTests {

    @Test("Tier a over 100k hidden records inside a 5 s budget", .timeLimit(.minutes(1)))
    func tierA100k() {
        let v = reunionVideo()
        var h: [MissingAudioFinder.HiddenAudio] = []
        h.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let name = i % 25_000 == 0 ? "reunion_1994_audio.wav" : "clip_\(i).wav"
            h.append(hidden(name, dir: "/Volumes/T/audio\(i % 1000)", duration: Double(i % 4000)))
        }
        let t0 = Date()
        let (cands, report) = MissingAudioFinder.hiddenCatalogCandidates(video: v, hidden: h, config: testConfig())
        let elapsed = Date().timeIntervalSince(t0)
        #expect(elapsed < 5.0, "tier a took \(elapsed)s over 100k records")
        #expect(report.examined == 100_000)
        // Every candidate must carry a real signal: the planted stem
        // matches (i = 0 has duration 0 → unknown → stem-only; the other
        // planted ones have incompatible durations → refused) or a
        // duration coincidence (i % 4000 ≈ 300 — Correlate's own
        // thin-pool rule admits those, so the finder lists them too).
        #expect(cands.count >= 1)
        #expect(cands.contains { $0.filename == "reunion_1994_audio.wav" })
        #expect(cands.allSatisfy { $0.reasons.contains("stem") || $0.reasons.contains("duration") })
        #expect(cands.count < 200, "a 100k catalog must not flood the list: \(cands.count)")
    }

    @Test("Tier c over a 10k-file synthetic tree is bounded by the probe cap", .timeLimit(.minutes(1)))
    func tierC10kBoundedByProbeCap() async {
        let v = reunionVideo()
        var files: [String] = []
        for d in 0..<100 {
            for f in 0..<100 {
                // Every file matches the stem — the worst case for the cap.
                files.append("/Volumes/Big/dir\(d)/reunion_1994_a\(f % 10).wav")
            }
        }
        let fs = FakeMissingAudioFS(files: files)
        let probe = FakeMissingAudioProbe(fallback: audio(300))
        let t0 = Date()
        let r = await MissingAudioFinder.search(video: v, hidden: [], roots: ["/Volumes/Big"],
                                                config: testConfig(cap: 200), fileSystem: fs, probe: probe)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(elapsed < 5.0, "tier c took \(elapsed)s")
        #expect(probe.calls.count == 200, "probe cap is the bound, got \(probe.calls.count)")
        let c = r.reports.first { $0.tier == .allScanRoots }
        #expect(c?.truncated == true)
        // Probed matches + at most the same number again judged by name only.
        #expect(r.candidates.count <= 400)
    }

    @Test("Tier c walk cap bounds directory entries examined")
    func tierCWalkCap() async {
        let v = reunionVideo()
        var files: [String] = []
        for d in 0..<100 { for f in 0..<100 { files.append("/Volumes/Big/dir\(d)/other\(f).wav") } }
        let fs = FakeMissingAudioFS(files: files)
        let probe = FakeMissingAudioProbe(fallback: audio(300))
        var budget = MissingAudioFinder.ProbeBudget(cap: 200)
        let (_, report, _) = await MissingAudioFinder.scanRootCandidates(
            video: v, roots: ["/Volumes/Big"], config: testConfig(walk: 1_000),
            fileSystem: fs, probe: probe, budget: &budget, excludingPaths: [], progress: nil)
        #expect(report.truncated)
        #expect(report.examined <= 1_000)
        #expect(probe.calls.isEmpty)
    }
}

// MARK: - Isolation

@Suite("Find Missing Audio — isolation")
struct MissingAudioIsolationTests {

    @Test("The finder never lists a directory outside the injected roots (plus the video's own neighbourhood)")
    func neverOutsideRoots() async {
        let v = MissingAudioFinder.VideoTarget(
            id: UUID(), filename: "x.mov", fullPath: "/Volumes/A/video/x.mov",
            directory: "/Volumes/A/video", durationSeconds: 10)
        let fs = FakeMissingAudioFS(files: [
            "/Volumes/A/video/x.mov", "/Volumes/A/audio/x.wav",
            "/Volumes/B/deep/x_audio.wav",
            "/Volumes/C/x.wav", "/Volumes/C/sub/x.wav",
            "/Users/rickb/Movies/x.wav",
        ])
        let probe = FakeMissingAudioProbe(fallback: audio(10))
        let r = await MissingAudioFinder.search(video: v, hidden: [], roots: ["/Volumes/A", "/Volumes/B"],
                                                config: testConfig(), fileSystem: fs, probe: probe)
        let allowed = ["/Volumes/A", "/Volumes/B"]
        for dir in fs.listed {
            #expect(allowed.contains { dir == $0 || dir.hasPrefix($0 + "/") }, "listed outside roots: \(dir)")
        }
        #expect(!fs.listed.contains("/Volumes"))
        #expect(!fs.listed.contains("/"))
        #expect(!r.candidates.contains { $0.path.hasPrefix("/Volumes/C") || $0.path.hasPrefix("/Users") })
        for p in probe.calls {
            #expect(allowed.contains { p.hasPrefix($0 + "/") }, "probed outside roots: \(p)")
        }
    }

    @Test("With no roots, only the video's folder, its parent and siblings are listed")
    func nearbyOnlyWithoutRoots() {
        let v = MissingAudioFinder.VideoTarget(
            id: UUID(), filename: "x.mov", fullPath: "/Volumes/A/2001/video/x.mov",
            directory: "/Volumes/A/2001/video", durationSeconds: 10)
        let fs = FakeMissingAudioFS(files: [
            "/Volumes/A/2001/video/x.mov", "/Volumes/A/2001/audio/x.wav",
            "/Volumes/A/2001/audio/deeper/x.wav", "/Volumes/A/2002/x.wav",
        ])
        let dirs = MissingAudioFinder.nearbyDirectories(for: v, fileSystem: fs)
        #expect(Set(dirs) == ["/Volumes/A/2001/video", "/Volumes/A/2001", "/Volumes/A/2001/audio"])
        #expect(!dirs.contains("/Volumes/A/2001/audio/deeper"))
        #expect(!dirs.contains("/Volumes/A/2002"))
    }

    @Test("Model entry point: injected roots and lister — no scan target is consulted, no real disk")
    @MainActor
    func modelUsesInjectedRoots() async {
        let model = VideoScanModel()
        let video = rec("x.mov", stream: .videoOnly, dir: "/Volumes/Fake/video", duration: 10)
        model.records = [video]
        let fs = FakeMissingAudioFS(files: ["/Volumes/Fake/audio/x.wav"])
        let probe = FakeMissingAudioProbe(fallback: audio(10))
        let r = await model.findMissingAudio(for: video.id, roots: ["/Volumes/Fake"],
                                             fileSystem: fs, probe: probe)
        #expect(r?.candidates.map(\.path) == ["/Volumes/Fake/audio/x.wav"])
        for dir in fs.listed { #expect(dir.hasPrefix("/Volumes/Fake"), "listed \(dir)") }
        #expect(model.scanTargets.isEmpty)
        // An unpaired, active video-only record is required.
        let audioRec = rec("y.wav", stream: .audioOnly, dir: "/Volumes/Fake", duration: 10)
        model.records.append(audioRec)
        #expect(await model.findMissingAudio(for: audioRec.id, roots: [], fileSystem: fs, probe: probe) == nil)
    }
}

// MARK: - Media matrix (real ffmpeg fixtures, real lister, real ffprobe)

@Suite("Find Missing Audio — media matrix", .serialized)
struct MissingAudioMediaMatrixTests {

    /// root/clips/test_mm_reunion.mp4 (h264, no audio)
    /// root/audio/test_mm_reunion.wav        pcm      — sibling folder
    /// root/audio/test_mm_reunion_audio.m4a  aac      — sibling folder
    /// root/avid/test_mm_reunion.A1.mxf      OP-Atom pcm — sibling folder
    /// root/other/test_mm_reunion.mkv        ffv1+pcm — NEGATIVE (has a picture)
    /// root/other/test_mm_reunion_short.wav  1 s      — NEGATIVE (duration refused)
    private func makeTree() throws -> (root: URL, video: String) {
        let root = try CleanupTestMedia.makeScratchDir("missingaudio")
        for sub in ["clips", "audio", "avid", "other"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(sub),
                                                    withIntermediateDirectories: true)
        }
        let video = try CleanupTestMedia.generate(
            into: root.appendingPathComponent("clips"), name: "test_mm_reunion.mp4",
            duration: 4.0, size: "160x120", rate: "25", videoCodec: "libx264",
            extraVideoArgs: ["-preset", "ultrafast"], audioCodec: nil)
        let sine = ["-f", "lavfi", "-i", "sine=frequency=440:duration=4:sample_rate=48000"]
        try CleanupTestMedia.runFFmpeg(sine + ["-c:a", "pcm_s16le"],
                                       output: root.appendingPathComponent("audio/test_mm_reunion.wav").path)
        try CleanupTestMedia.runFFmpeg(sine + ["-c:a", "aac"],
                                       output: root.appendingPathComponent("audio/test_mm_reunion_audio.m4a").path)
        try CleanupTestMedia.runFFmpeg(sine + ["-c:a", "pcm_s16le", "-f", "mxf_opatom"],
                                       output: root.appendingPathComponent("avid/test_mm_reunion.A1.mxf").path)
        try CleanupTestMedia.runFFmpeg(
            ["-f", "lavfi", "-i", "testsrc=duration=4:size=160x120:rate=25"] + sine
                + ["-c:v", "ffv1", "-c:a", "pcm_s16le"],
            output: root.appendingPathComponent("other/test_mm_reunion.mkv").path)
        try CleanupTestMedia.runFFmpeg(
            ["-f", "lavfi", "-i", "sine=frequency=440:duration=1:sample_rate=48000", "-c:a", "pcm_s16le"],
            output: root.appendingPathComponent("other/test_mm_reunion_short.wav").path)
        return (root, video)
    }

    @Test("wav / aac / OP-Atom mxf at sibling paths are found; mkv with a picture and a short take are not",
          .timeLimit(.minutes(2)))
    func siblingAudioFound() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let (root, videoPath) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let v = MissingAudioFinder.VideoTarget(
            id: UUID(), filename: "test_mm_reunion.mp4", fullPath: videoPath,
            directory: (videoPath as NSString).deletingLastPathComponent, durationSeconds: 4.0)
        var config = MissingAudioFinder.Config.standard(modelAudioExtensions: ["wav", "m4a", "aac"],
                                                         skipDirNames: [])
        config.maxFilesProbed = 50
        let r = await MissingAudioFinder.search(
            video: v, hidden: [], roots: [root.path], config: config,
            fileSystem: FileManagerMissingAudioFileSystem(),
            probe: FFprobeMissingAudioDurationProbe())

        let names = Set(r.candidates.map(\.filename))
        #expect(names == ["test_mm_reunion.wav", "test_mm_reunion_audio.m4a", "test_mm_reunion.A1.mxf"],
                "got \(names)")
        #expect(!names.contains("test_mm_reunion.mkv"))
        #expect(!names.contains("test_mm_reunion_short.wav"))
        for c in r.candidates {
            #expect(c.tier == .nearbyFolders, "\(c.filename) came from \(c.tier)")
            #expect((c.durationDelta ?? 99) < 0.5, "\(c.filename) Δ=\(String(describing: c.durationDelta))")
            #expect(c.correlateWillAccept, "\(c.filename) should clear Correlate's gate")
        }
        let wav = r.candidates.first { $0.filename == "test_mm_reunion.wav" }
        #expect(wav?.reasons.contains("filename") == true)
        let mxf = r.candidates.first { $0.filename == "test_mm_reunion.A1.mxf" }
        #expect(mxf?.reasons.contains("stem") == true)
        let b = r.reports.first { $0.tier == .nearbyFolders }
        #expect(b?.durationRefused == 1)
    }

    @Test("Pair ingests an on-disk wav through the single-file probe and records the pair via Correlate",
          .timeLimit(.minutes(2)))
    @MainActor
    func pairIngestsAndCorrelates() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let (root, videoPath) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = VideoScanModel()
        let video = await model.probeFile(url: URL(fileURLWithPath: videoPath))
        try #require(video.streamType == .videoOnly)
        model.records = [video]

        let r = try #require(await model.findMissingAudio(for: video.id, roots: [root.path]))
        let wav = try #require(r.candidates.first { $0.filename == "test_mm_reunion.wav" })
        #expect(wav.catalogState == .notInCatalog)

        let outcome = await model.pairMissingAudio(videoID: video.id, candidate: wav)
        guard case .paired(let audioID, _) = outcome else {
            Issue.record("expected .paired, got \(outcome)")
            return
        }
        #expect(model.records.count == 2)
        let audio = try #require(model.record(forID: audioID))
        #expect(audio.streamType == .audioOnly)
        #expect(video.pairedWith === audio)
        #expect(audio.pairedWith === video)
        #expect(video.pairGroupID != nil && video.pairGroupID == audio.pairGroupID)
        // Source files untouched: still exactly the five fixtures + video.
        let wavAttrs = try FileManager.default.attributesOfItem(atPath: wav.path)
        #expect((wavAttrs[.size] as? NSNumber)?.intValue ?? 0 > 0)
        #expect(FileManager.default.fileExists(atPath: videoPath))
    }

    @Test("Pair refuses a file that is not audio-only, leaving the catalog untouched",
          .timeLimit(.minutes(2)))
    @MainActor
    func pairRefusesVideoPlusAudio() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let (root, videoPath) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = VideoScanModel()
        let video = await model.probeFile(url: URL(fileURLWithPath: videoPath))
        model.records = [video]
        let bogus = MissingAudioFinder.Candidate(
            id: UUID(), path: root.appendingPathComponent("other/test_mm_reunion.mkv").path,
            tier: .nearbyFolders, score: 4, reasons: ["stem"], durationSeconds: nil,
            durationDelta: nil, catalogRecordID: nil, catalogState: .notInCatalog,
            correlateWillAccept: false)
        let outcome = await model.pairMissingAudio(videoID: video.id, candidate: bogus)
        guard case .notAudioOnly = outcome else {
            Issue.record("expected .notAudioOnly, got \(outcome)")
            return
        }
        #expect(model.records.count == 1)
        #expect(video.pairedWith == nil)
    }
}

// MARK: - Sensor

@MainActor
@Suite("Find Missing Audio — sensor")
struct MissingAudioSensorTests {

    /// REGRESSION SENSOR (GH #111): audio that Tidy set aside as
    /// "unlinked" must remain findable for its video, and Pair must put it
    /// back and record the pair through the normal Correlate. If this
    /// goes red, Rick's ruthless-Tidy safety net is gone.
    @Test("setAsideAudioIsStillFindable")
    func setAsideAudioIsStillFindable() async {
        let model = VideoScanModel()
        let video = rec("reunion_1994.mov", stream: .videoOnly, dir: "/Volumes/T/video", duration: 300)
        // Different folder, no Avid key → no structural evidence → Tidy
        // declines it as unlinked. Duration matches within the gate.
        let audio = rec("reunion_1994_audio.wav", stream: .audioOnly, dir: "/Volumes/T/audio", duration: 300.4)
        model.records = [video, audio]

        let plan = await model.computeTidyCatalogPlan()
        #expect(plan.unlinkedAudioCount == 1)
        #expect(model.applyTidyCatalog(plan) == 1)
        #expect(audio.setAsideReason == CatalogScopePolicy.SetAsideReason.unlinkedAudio.rawValue)
        let countBefore = model.records.count

        let fs = FakeMissingAudioFS(files: [])
        let probe = FakeMissingAudioProbe()
        let r = await model.findMissingAudio(for: video.id, roots: [], fileSystem: fs, probe: probe)
        let cand = r?.candidates.first
        #expect(cand?.tier == .hiddenCatalogRecords)
        #expect(cand?.catalogRecordID == audio.id)
        #expect(cand?.catalogState == .setAside(reason: "unlinked-audio"))
        #expect(cand?.correlateWillAccept == true)
        #expect(probe.calls.isEmpty && fs.listed.isEmpty == false || fs.listed.isEmpty)

        guard let cand else { return }
        let outcome = await model.pairMissingAudio(videoID: video.id, candidate: cand)
        guard case .paired(let audioID, _) = outcome else {
            Issue.record("expected .paired, got \(outcome)")
            return
        }
        #expect(audioID == audio.id)
        #expect(audio.setAsideReason == nil, "Pair restores the set-aside record")
        #expect(!audio.isSetAside)
        #expect(video.pairedWith === audio)
        #expect(audio.pairedWith === video)
        #expect(video.pairConfidence != nil)
        #expect(model.records.count == countBefore, "Pair never adds or removes records for a catalog candidate")
    }

    @Test("Purged audio is findable and Pair restores it")
    func purgedAudioIsFindable() async {
        let model = VideoScanModel()
        let video = rec("take.mov", stream: .videoOnly, dir: "/Volumes/T/v", duration: 120)
        let audio = rec("take.wav", stream: .audioOnly, dir: "/Volumes/T/v", duration: 120.3)
        model.records = [video, audio]
        #expect(model.purgeRecords(ids: [audio.id]) == 1)
        #expect(audio.isPurged)

        let r = await model.findMissingAudio(for: video.id, roots: [],
                                             fileSystem: FakeMissingAudioFS(files: []),
                                             probe: FakeMissingAudioProbe())
        let cand = r?.candidates.first
        #expect(cand?.catalogState == .purged)
        guard let cand else { return }
        let outcome = await model.pairMissingAudio(videoID: video.id, candidate: cand)
        guard case .paired = outcome else {
            Issue.record("expected .paired, got \(outcome)")
            return
        }
        #expect(!audio.isPurged)
        #expect(video.pairedWith === audio)
    }

    @Test("Pair is atomic: when Correlate declines, the set-aside state comes back")
    func pairAtomicOnDecline() async {
        let model = VideoScanModel()
        let video = rec("reunion_1994.mov", stream: .videoOnly, dir: "/Volumes/T/video", duration: 300)
        let stranger = rec("stranger.wav", stream: .audioOnly, dir: "/Volumes/T/elsewhere", duration: 0)
        stranger.setAsideReason = CatalogScopePolicy.SetAsideReason.unlinkedAudio.rawValue
        model.records = [video, stranger]
        let forced = MissingAudioFinder.Candidate(
            id: UUID(), path: stranger.fullPath, tier: .hiddenCatalogRecords, score: 4,
            reasons: ["stem"], durationSeconds: nil, durationDelta: nil,
            catalogRecordID: stranger.id, catalogState: .setAside(reason: "unlinked-audio"),
            correlateWillAccept: false)
        let outcome = await model.pairMissingAudio(videoID: video.id, candidate: forced)
        #expect(outcome == .correlateDeclined)
        #expect(stranger.setAsideReason == CatalogScopePolicy.SetAsideReason.unlinkedAudio.rawValue)
        #expect(video.pairedWith == nil)
        #expect(stranger.pairedWith == nil)
        #expect(model.records.count == 2)
    }

    @Test("Pair refuses when the video is already paired or read-only")
    func pairGuards() async {
        let model = VideoScanModel()
        let video = rec("v.mov", stream: .videoOnly, dir: "/Volumes/T/v", duration: 10)
        let audio = rec("v.wav", stream: .audioOnly, dir: "/Volumes/T/v", duration: 10)
        model.records = [video, audio]
        let cand = MissingAudioFinder.Candidate(
            id: UUID(), path: audio.fullPath, tier: .hiddenCatalogRecords, score: 8,
            reasons: ["filename", "duration", "directory"], durationSeconds: 10, durationDelta: 0,
            catalogRecordID: audio.id, catalogState: .active, correlateWillAccept: true)
        model.isReadOnly = true
        #expect(await model.pairMissingAudio(videoID: video.id, candidate: cand) == .readOnly)
        model.isReadOnly = false
        video.pairedWith = audio; audio.pairedWith = video
        #expect(await model.pairMissingAudio(videoID: video.id, candidate: cand) == .videoUnavailable)
    }
}
