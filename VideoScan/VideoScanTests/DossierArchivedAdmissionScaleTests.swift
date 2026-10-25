import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Dossier admission: truth table, scale, isolation, sensor, media
//
// Companion to DossierArchivedAdmissionTests (the red-first logic pins).
// Five dimensions (CLAUDE.md feature-test checklist):
//   logic      the admission truth table by stage + the selection tally
//   scale      100k synthetic records (20 % archived, 20 % in triage,
//              2,000 footage groups): candidate selection and the
//              carry-over index inside explicit budgets
//   isolation  poisoned UserDefaults (Analysis Scope, stale active /
//              queued volumes), no Master Archive designation, and no
//              per-batch state leaking into the next batch
//   sensor     a FamilyArchive-shaped catalog ends a full pass with every
//              eligible video carrying text, one decode per footage group,
//              and the OUTCOME coverage line naming the stage gate
//   media      mp4/h264, mov/prores, mkv/ffv1+pcm, mxf, avi/dv: a REAL
//              frame-reading runner over a LOCKED archived file — the file
//              is read, never written
// (For Rick: `ContinuousClock().measure { }` is a monotonic stopwatch —
// std::chrono::steady_clock around a lambda.)

/// Reads real frames through the production extractor (AVFoundation, then
/// the ffmpeg fallback) and reports one scene per decoded frame. No VLM.
actor FrameReadingDossierRunner: CaptionRunner {
    nonisolated let modelID = "frame-reader"
    func caption(videoPath: String, atTimestamps timestamps: [Double]) async throws -> [SceneCaption] { [] }
    func dossier(videoPath: String, atTimestamps timestamps: [Double]) async throws -> DossierExtraction {
        let frames = try await extractFramesForCaptioning(from: URL(fileURLWithPath: videoPath),
                                                          atTimestamps: timestamps)
        let scenes = frames.filter { $0.frame.isSuccess }
            .map { SceneCaption(timestamp: $0.timestamp, text: "frame decoded") }
        return DossierExtraction(scenes: scenes, dates: [], texts: [])
    }
}

@MainActor
@Suite("Dossier admission — truth table, scale, isolation, sensor", .serialized)
struct DossierArchivedAdmissionScaleTests {

    typealias F = DossierAdmissionFixtures

    // MARK: - Logic: the truth table by stage

    /// Rick 2026-10-10: Dossier admits Cataloged, Workbench, In Triage and
    /// Archived; never Trashed or Deleted. The caption sweep's pool is
    /// unchanged (live media only).
    static let dossierExpected: [LifecycleStage: Bool] = [
        .cataloged: true, .workbench: true, .reviewing: true, .archived: true,
        .trashed: false, .deletedPermanently: false,
    ]
    static let captionExpected: [LifecycleStage: Bool] = [
        .cataloged: true, .workbench: true, .reviewing: false, .archived: false,
        .trashed: false, .deletedPermanently: false,
    ]

    @Test("admission by stage", arguments: LifecycleStage.allCases)
    func admissionTruthTable(_ stage: LifecycleStage) throws {
        let expectedDossier = try #require(Self.dossierExpected[stage] as Bool?, "a new LifecycleStage needs a ruling: \(stage)")
        let expectedCaption = try #require(Self.captionExpected[stage] as Bool?)
        let r = VideoRecord()
        r.fullPath = "/Volumes/TestLacie/a.mov"; r.filename = "a.mov"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.lifecycleStage = stage
        let dossier = pfDossierCandidates(records: [r], reachableVolumePaths: ["/Volumes/TestLacie"])
        let caption = pfCatalogWideMetadataCandidates(records: [r], reachableVolumePaths: ["/Volumes/TestLacie"])
        #expect(dossier.count == (expectedDossier ? 1 : 0), "dossier pool, \(stage.rawValue)")
        #expect(caption.count == (expectedCaption ? 1 : 0), "caption pool unchanged, \(stage.rawValue)")
    }

    /// The other gates still hold inside the widened pool: an archived row
    /// that is purged, set aside, confirmed junk or DRM is not admitted.
    @Test func otherGatesStillApplyToArchivedRows() {
        func archived(_ name: String) -> VideoRecord {
            let r = VideoRecord()
            r.fullPath = "/Volumes/TestLacie/\(name)"; r.filename = name
            r.lifecycleStage = .archived
            return r
        }
        let purged = archived("p.mov"); purged.purgedAt = Date()
        let aside = archived("s.mov"); aside.setAsideReason = "test"
        let junk = archived("j.mov"); junk.mediaDisposition = .confirmedJunk
        let drm = archived("d.m4v"); drm.drmProtected = true
        let ok = archived("ok.mov")
        let out = pfDossierCandidates(records: [purged, aside, junk, drm, ok], reachableVolumePaths: ["/Volumes/TestLacie"])
        #expect(out.map(\.filename) == ["ok.mov"])
    }

    @Test func selectionTallyCountsEveryReason() {
        func rec(_ path: String, _ stage: LifecycleStage) -> VideoRecord {
            let r = VideoRecord(); r.fullPath = path; r.filename = (path as NSString).lastPathComponent
            r.lifecycleStage = stage
            return r
        }
        let records = [
            rec("/Volumes/TestOn/a.mov", .archived), rec("/Volumes/TestOn/b.mov", .archived),
            rec("/Volumes/TestOn/c.mov", .reviewing), rec("/Volumes/TestOn/d.mov", .cataloged),
            rec("/Volumes/TestOff/e.mov", .archived),          // offline
            rec("/Volumes/TestOn/f.mov", .trashed),            // stage
            rec("/Volumes/TestOn/g.mov", .deletedPermanently), // stage
        ]
        let s = pfDossierCandidateSelection(records: records, reachableVolumePaths: ["/Volumes/TestOn"])
        #expect(s.candidates.count == 4)
        #expect(s.archived == 2 && s.inTriage == 1)
        #expect(s.offline == 1, "eligible but not connected — skipped, not failed")
        #expect(s.notEligibleByStage == 2)
    }

    // MARK: - Scale: 100k records

    /// 100k records — 20 % Archived, 20 % In Triage, 2,000 footage groups of
    /// 5, 2,000 byte-twin pairs, 10 % on an offline volume. Candidate
    /// selection < 50 ms; the carry-over index plus a donor lookup for every
    /// candidate < 500 ms (Release budgets; Debug gets 4×, load-aware).
    @Test("scale: 100k candidate selection + carry-over index", .timeLimit(.minutes(2)))
    func scale100k() {
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        let groups = (0..<2_000).map { _ in UUID() }
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.fullPath = (i % 10 == 9 ? "/Volumes/TestOffline/" : "/Volumes/TestArchive/") + "c\(i).mov"
            r.filename = "c\(i).mov"
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.durationSeconds = 600
            switch i % 5 {
            case 0: r.lifecycleStage = .archived
            case 1: r.lifecycleStage = .reviewing
            case 2: r.lifecycleStage = .trashed
            default: r.lifecycleStage = .cataloged
            }
            if i < 10_000 {
                r.footage = FootageMembership(groupID: groups[i / 5], groupSize: 5, confidence: .likely,
                                              role: .copy, rank: i % 5, likelyOriginalID: r.id,
                                              originalInCatalog: true, evidence: [], scannedAt: Date(),
                                              algorithmVersion: 1)
                if i % 5 == 0 {   // one donor per group, covering both channels
                    r.sceneCaptions = [SceneCaption(timestamp: 1, text: "scene")]
                    r.audioTranscript = "words"
                    r.dossierProcessedAt = Date()
                }
            } else if i < 14_000 {
                r.partialMD5 = "twin-\(i / 2)"; r.sizeBytes = 1_000
                if i % 2 == 0 {
                    r.sceneCaptions = [SceneCaption(timestamp: 1, text: "scene")]
                    r.audioTranscript = "words"; r.dossierProcessedAt = Date()
                }
            }
            recs.append(r)
        }
        let clock = ContinuousClock()
        var selection = DossierCandidateSelection()
        let tSelect = clock.measure {
            selection = pfDossierCandidateSelection(records: recs, reachableVolumePaths: ["/Volumes/TestArchive"])
        }
        // i%5==2 Trashed (20,000); i%10==9 offline (10,000, all eligible).
        #expect(selection.candidates.count == 70_000, "\(selection.candidates.count)")
        #expect(selection.offline == 10_000 && selection.notEligibleByStage == 20_000)
        // Release budget 50 ms (the doc's number); Debug is unoptimized
        // (measured 52 ms Debug on the M4 Max) — the house pattern.
        let selectBudget = PerformanceLane.loadAwareDebugCeiling(
            PerformanceLane.isDebugBuild ? .milliseconds(200) : .milliseconds(50))
        #expect(tSelect < selectBudget, "selection took \(tSelect)")

        var donors = 0
        let tIndex = clock.measure {
            let index = DossierCarryOverIndex(records: recs, candidates: selection.candidates)
            for c in selection.candidates where c.dossierProcessedAt == nil && index.donor(for: c) != nil {
                donors += 1
            }
        }
        // Footage: ranks 1, 3, 4 receive (rank 2 is Trashed); rank 4 is
        // offline in every other group → 1,000×3 + 1,000×2 = 5,000.
        // Byte twins: the odd member of each pair receives unless Trashed
        // (i%10==7) or offline (i%10==9) → 2,000 × 3/5 = 1,200.
        #expect(donors == 6_200, "carry-over found \(donors) recipients")
        let indexBudget = PerformanceLane.loadAwareDebugCeiling(
            PerformanceLane.isDebugBuild ? .seconds(2) : .milliseconds(500))
        #expect(tIndex < indexBudget, "index + lookups took \(tIndex)")
        print("DossierAdmissionScale: selection \(tSelect), index+lookups \(tIndex)")
    }

    // MARK: - Isolation: poisoned state

    /// Poisoned UserDefaults (audio scope on with an excluded extension, a
    /// stale active volume and queue) and NO Master Archive designation:
    /// the stage gate and the archived read-only rule do not move.
    @Test func poisonedDefaultsAndNoDesignationDoNotChangeAdmission() async throws {
        let suite = "test_dossier_admit_poison_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AnalysisScope.includeAudioKey)
        defaults.set(["mov"], forKey: AnalysisScope.excludedExtensionsKey)
        defaults.set(["/Volumes/TestStaleVolume"], forKey: CaptionOrchestrator.activeVolumesPrefsKey)
        defaults.set(["/Volumes/TestStaleQueued"], forKey: CaptionOrchestrator.queuedVolumesPrefsKey)

        let sb = try F.Sandbox("poison")
        defer { sb.cleanup() }
        sb.model.masterArchive = nil
        let archived = sb.record("test_poison_archived.mov", stage: .archived)
        archived.inferredRecordDate = F.utc(1985); archived.inferredDateReason = "filed as 1985"
        let triage = sb.record("test_poison_triage.mov", stage: .reviewing)
        sb.model.records = [archived, triage]
        #expect(sb.model.isDossierReadOnly(archived), "Archived stage is read-only with no designation")
        #expect(!sb.model.isDossierReadOnly(triage))

        let stub = StubDossierRunner(modelID: "stub-poison")
        let orch = CaptionOrchestrator(runnerFactory: { stub }, defaults: defaults)
        await orch.startCatalogWideDossier(model: sb.model)
        #expect(await stub.countCalled() == 2, "video records pass whatever the audio scope says")
        #expect(archived.inferredRecordDate == F.utc(1985), "date frozen without a designation")
        #expect(triage.dossierProcessedAt != nil)
    }

    /// Per-batch state never leaks: after a batch the carry-over index, the
    /// retry switch and the admission tally are cleared, so a later direct
    /// loop run (or a batch with different candidates) can't inherit them.
    @Test func batchStateIsClearedOnSettle() async throws {
        let sb = try F.Sandbox("settle")
        defer { sb.cleanup() }
        let r = sb.record("test_settle.mov", stage: .archived)
        sb.model.records = [r]
        let stub = StubDossierRunner(modelID: "stub-settle")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        await orch.startCatalogWideDossier(model: sb.model)
        #expect(orch.dossierCarryOver == nil && orch.dossierAdmission == nil && !orch.dossierRetriesNeedsReformat)
        _ = await orch.startAnalyzing(volumePrefix: r.fullPath, model: sb.model, transcriber: nil, force: true,
                                      ignoringScope: true)
        #expect(orch.dossierCarryOver == nil && orch.dossierAdmission == nil && !orch.dossierRetriesNeedsReformat)
    }

    // MARK: - SENSOR: a FamilyArchive-shaped catalog

    /// Archived masters inside the archive root, an In Triage byte twin, an
    /// equal-length re-encode in a footage group, a Trashed copy and an
    /// archived master on an offline drive. After ONE full pass: every
    /// eligible video carries text, exactly one decode per footage group,
    /// the archived files are untouched, and the OUTCOME coverage line
    /// names the carry-over and the stage gate.
    @Test func familyArchiveShapedPassLeavesNoEligibleVideoWithoutText() async throws {
        let sb = try F.Sandbox("sensor")
        defer { sb.cleanup() }
        let root = sb.dir.appendingPathComponent("Breen_Family_Archive", isDirectory: true)
        let video = root.appendingPathComponent("30_Video/1980-1989/1984", isDirectory: true)
        try FileManager.default.createDirectory(at: video, withIntermediateDirectories: true)
        sb.model.masterArchive = MasterArchiveDesignation(targetPath: sb.dir.path, rootPath: root.path)

        func master(_ name: String) -> VideoRecord {
            let r = sb.record(name, stage: .archived)
            let path = video.appendingPathComponent(name).path
            try? FileManager.default.moveItem(atPath: r.fullPath, toPath: path)
            r.fullPath = path; r.directory = video.path
            r.derivationKind = ArchivePromotion.derivationKind
            _ = lchflags(path, UInt32(UF_IMMUTABLE))
            return r
        }
        let tape = master("1984-11-xx_test_Thanksgiving.mkv")
        tape.partialMD5 = "md5-tape"; tape.sizeBytes = 1
        let triageCopy = sb.record("test_Thanksgiving_copy.mkv", stage: .reviewing)
        triageCopy.partialMD5 = "md5-tape"; triageCopy.sizeBytes = 1
        let g = UUID()
        let wedding = master("1987-xx-xx_test_Wedding.mov")
        wedding.durationSeconds = 3_600
        wedding.footage = DossierArchivedAdmissionTests.footage(g, .likely, original: wedding, rank: 0)
        let improved = master("1987-xx-xx_test_Wedding_improved.mp4")
        improved.durationSeconds = 3_600
        improved.footage = DossierArchivedAdmissionTests.footage(g, .likely, original: wedding, rank: 1)
        let trashed = sb.record("test_old_export.mov", stage: .trashed)
        let offline = VideoRecord()
        offline.fullPath = "/Volumes/TestOfflineFamilyDrive/test_far.mov"; offline.filename = "test_far.mov"
        offline.streamTypeRaw = StreamType.videoAndAudio.rawValue; offline.lifecycleStage = .archived
        // Video-only fixtures: this pass runs with no transcriber, and a
        // donor must cover every channel its recipient has (QA P2-a).
        for r in [tape, triageCopy, wedding, improved] { r.streamTypeRaw = StreamType.videoOnly.rawValue }
        sb.model.records = [tape, triageCopy, wedding, improved, trashed, offline]
        let shaBefore = [tape, wedding, improved].map { MasterArchiveTestSupport.sha256(ofFile: $0.fullPath) }

        let sink = InMemoryLogSink()
        let previous = appLog
        appLog = sink
        defer { appLog = previous }
        let stub = StubDossierRunner(modelID: "stub-sensor")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        await orch.startCatalogWideDossier(model: sb.model)

        let eligible = pfDossierCandidates(records: sb.model.records, reachableVolumePaths: [sb.dir.path])
        let withoutText = eligible.filter { $0.sceneCaptions.isEmpty && ($0.audioTranscript ?? "").isEmpty }
        #expect(withoutText.isEmpty, "eligible videos with no text after a full pass: \(withoutText.map(\.filename))")
        #expect(await stub.countCalled() == 2, "one decode per footage group (tape + wedding)")
        #expect(trashed.dossierProcessedAt == nil && offline.dossierProcessedAt == nil)
        #expect([tape, wedding, improved].map { MasterArchiveTestSupport.sha256(ofFile: $0.fullPath) } == shaBefore)

        let coverage = sink.lines.first { $0.contains("Dossier: coverage —") } ?? ""
        #expect(coverage.contains("2 carried over from same-footage copies"), "\(coverage)")
        #expect(coverage.contains("admitted 3 Archived + 1 In Triage"), "\(coverage)")
        #expect(coverage.contains("1 eligible on offline volumes"), "\(coverage)")
        #expect(coverage.contains("1 not eligible (stage"), "OUTCOME must carry the stage-exclusion count: \(coverage)")
        #expect(sink.lines.contains { $0.contains("Dossier: admitted 3 Archived + 1 In Triage") }, "START names the admission")
        // Log privacy: no transcript / caption text in any line.
        #expect(!sink.lines.contains { $0.contains("stub scene") })
    }

    // MARK: - Media matrix: a real read of a locked archived file

    struct MatrixCase: CustomTestStringConvertible, Sendable {
        let name: String, videoCodec: String, extra: [String], audioCodec: String, size: String, rate: String
        var testDescription: String { name }
    }

    nonisolated static let matrix: [MatrixCase] = [  // Swift 6: the @Test macro reads it off the actor
        .init(name: "test_dossier_admit.mp4", videoCodec: "libx264", extra: ["-preset", "ultrafast", "-pix_fmt", "yuv420p"],
              audioCodec: "aac", size: "320x240", rate: "25"),
        .init(name: "test_dossier_admit.mov", videoCodec: "prores", extra: [], audioCodec: "pcm_s16le", size: "320x240", rate: "25"),
        .init(name: "test_dossier_admit.mkv", videoCodec: "ffv1", extra: [], audioCodec: "pcm_s16le", size: "320x240", rate: "25"),
        .init(name: "test_dossier_admit.mxf", videoCodec: "mpeg2video", extra: ["-g", "15", "-aspect", "4:3"],
              audioCodec: "pcm_s16le", size: "720x576", rate: "25"),
        .init(name: "test_dossier_admit.avi", videoCodec: "dvvideo", extra: ["-pix_fmt", "yuv411p", "-aspect", "4:3"],
              audioCodec: "pcm_s16le", size: "720x480", rate: "30000/1001"),
    ]

    @Test("an archived file is read, never written", .timeLimit(.minutes(2)), arguments: matrix)
    func archivedFileIsReadNeverWritten(_ c: MatrixCase) async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let sb = try F.Sandbox("matrix")
        defer { sb.cleanup() }
        let path = try VerifyVideoTestMedia.generate(into: sb.dir, name: c.name, videoCodec: c.videoCodec,
                                                     extraVideoArgs: c.extra, audioCodec: c.audioCodec,
                                                     size: c.size, rate: c.rate)
        let r = VideoRecord()
        r.fullPath = path; r.filename = c.name; r.directory = sb.dir.path
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.durationSeconds = 2.0
        r.lifecycleStage = .archived
        r.inferredRecordDate = F.utc(1985); r.inferredDateReason = "filed as 1985"
        #expect(lchflags(path, UInt32(UF_IMMUTABLE)) == 0)
        sb.model.records = [r]
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let sha = MasterArchiveTestSupport.sha256(ofFile: path)
        let listing = try FileManager.default.contentsOfDirectory(atPath: sb.dir.path).sorted()
        let rowBefore = try F.persisted(r)

        let orch = CaptionOrchestrator(runnerFactory: { FrameReadingDossierRunner() })
        await orch.startCatalogWideDossier(model: sb.model)

        #expect(!r.sceneCaptions.isEmpty, "\(c.name): frames were read and the dossier banked")
        #expect(MasterArchiveTestSupport.sha256(ofFile: path) == sha)
        let after = try FileManager.default.attributesOfItem(atPath: path)
        #expect((after[.modificationDate] as? Date) == (attrs[.modificationDate] as? Date))
        #expect((after[.size] as? NSNumber) == (attrs[.size] as? NSNumber))
        #expect(try FileManager.default.contentsOfDirectory(atPath: sb.dir.path).sorted() == listing,
                "\(c.name): nothing written beside the archived file")
        let changed = F.changedKeys(rowBefore, try F.persisted(r))
        #expect(changed.isSubset(of: F.dossierKeys), "\(c.name): \(changed.subtracting(F.dossierKeys).sorted())")
    }
}
