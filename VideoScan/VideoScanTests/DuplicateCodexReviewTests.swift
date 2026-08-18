import Foundation
import Testing
@testable import VideoScan

// MARK: - Codex review fixes (2026-08-18) — sensors
//
//   A. enrichment carry-over on verified delete (separate from the human
//      merge; fills holes only, never overwrites the master)
//   B. stale keeper policy ⇒ Find Duplicates re-elects ALL groups
//   C. hub/keeper decoupling — A–B–C with a high-precedence peripheral A
//      classifies all three
//   D. pre-delete snapshot encodes/writes off-main (scale sensor)
//   E. snapshot failure on a mixed batch fixes skipped/summary
//   + real media-matrix fixtures on the working-copy delete path

@MainActor
private func makeModel(_ dir: URL) -> VideoScanModel {
    let model = VideoScanModel()
    model.catalogStore = CatalogStore(directory: dir)
    return model
}

@MainActor
private func target(_ path: String, role: VolumeRole = .workspace) -> CatalogScanTarget {
    let t = CatalogScanTarget(searchPath: path)
    t.role = role
    // init probes the real filesystem (/Volumes/A doesn't exist here);
    // pin "plugged in" explicitly so the tests own the fact.
    t.isReachable = true
    return t
}

@MainActor
private func dupRecord(path: String, size: Int64 = 1, group: UUID,
                       disposition: DuplicateDisposition, stamped: Bool = false) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.sizeBytes = size
    r.partialMD5 = "m"
    r.durationSeconds = 61.0
    r.duplicateGroupID = group
    r.duplicateDisposition = disposition
    r.duplicateConfidence = .high
    if stamped { r.dupAnalyzedAt = Date() }
    return r
}

private func write(_ url: URL, _ bytes: [UInt8]) {
    FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
}

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - A. Enrichment inheritance

@MainActor
@Suite("Codex A — enrichment carry-over")
struct DuplicateEnrichmentInheritanceTests {

    private func richExtra() -> VideoRecord {
        let e = VideoRecord()
        e.fullPath = "/Volumes/CrucialX9/reel.mov"
        e.originalFullPath = "/Volumes/OldBook/reel.mov"
        e.audioTranscript = "happy birthday dear Timmy"
        e.audioTranscriptModel = "whisper-small"
        e.audioTranscriptDate = Date(timeIntervalSince1970: 1_000)
        e.sceneCaptions = [SceneCaption(timestamp: 1, text: "kids at a table")]
        e.sceneCaptionModel = "qwen2.5-vl"
        e.sceneCaptionDate = Date(timeIntervalSince1970: 2_000)
        e.dossierProcessedAt = Date(timeIntervalSince1970: 3_000)
        e.dossierProcessedBy = "dossier-1"
        e.detectedPeople = ["Donna", "Timmy"]
        e.inferredRecordDate = Date(timeIntervalSince1970: 4_000)
        e.inferredDateConfidence = 0.8
        e.avidClipName = "Reel 12"; e.avidMobID = "mob-1"; e.avidMaterialUUID = "uuid-1"
        e.avidBinFile = "bin.avb"; e.avidMobType = "Master"; e.avidMediaPath = "/avid/reel12"
        e.avidTapeName = "TAPE12"; e.avidEditRate = 29.97; e.avidTracks = "V1, A1-A2"
        return e
    }

    /// Every enrichment field is carried when the master lacks it, and the
    /// provenance journey line names the removed path AND its origin.
    @Test func carriesEveryFieldIntoAnEmptyMaster() {
        let model = VideoScanModel()
        let master = VideoRecord(); master.fullPath = "/Volumes/FamilyArchive/reel.mov"
        let extra = richExtra()
        let carried = model.applyEnrichmentInheritance(from: extra, to: master,
                                                       removedAt: Date(timeIntervalSince1970: 1_787_000_000))
        #expect(Set(carried) == ["transcript", "captions", "dossier", "detected people",
                                 "inferred date", "Avid identity", "provenance note"], "\(carried)")
        #expect(master.audioTranscript == "happy birthday dear Timmy")
        #expect(master.audioTranscriptModel == "whisper-small")
        #expect(master.audioTranscriptDate == Date(timeIntervalSince1970: 1_000))
        #expect(master.sceneCaptions.count == 1 && master.sceneCaptionModel == "qwen2.5-vl")
        #expect(master.sceneCaptionDate == Date(timeIntervalSince1970: 2_000))
        #expect(master.dossierProcessedAt == Date(timeIntervalSince1970: 3_000) && master.dossierProcessedBy == "dossier-1")
        #expect(master.detectedPeople == ["Donna", "Timmy"])
        #expect(master.inferredRecordDate == Date(timeIntervalSince1970: 4_000) && master.inferredDateConfidence == 0.8)
        #expect(master.avidClipName == "Reel 12" && master.avidMobID == "mob-1" && master.avidMaterialUUID == "uuid-1")
        #expect(master.avidBinFile == "bin.avb" && master.avidMobType == "Master" && master.avidMediaPath == "/avid/reel12")
        #expect(master.avidTapeName == "TAPE12" && master.avidEditRate == 29.97 && master.avidTracks == "V1, A1-A2")
        #expect(master.notes.contains("copy at /Volumes/CrucialX9/reel.mov (from /Volumes/OldBook/reel.mov) removed 2026-08-1"), "\(master.notes)")
        #expect(master.notes.hasSuffix("; identical bytes"))
        #expect(master.userNotes.isEmpty, "provenance goes to machine notes, never userNotes")
    }

    /// Nothing on the master is ever overwritten — field by field.
    @Test func neverOverwritesMastersExistingValues() {
        let model = VideoScanModel()
        let master = VideoRecord(); master.fullPath = "/Volumes/FamilyArchive/reel.mov"
        master.audioTranscript = "MASTER transcript"; master.audioTranscriptModel = "m-model"
        master.sceneCaptions = [SceneCaption(timestamp: 0, text: "MASTER caption")]; master.sceneCaptionModel = "m-cap"
        master.dossierProcessedAt = Date(timeIntervalSince1970: 9); master.dossierProcessedBy = "m-dossier"
        master.detectedPeople = ["Rick"]
        master.inferredRecordDate = Date(timeIntervalSince1970: 99); master.inferredDateConfidence = 0.1
        master.avidClipName = "MASTER clip"; master.avidEditRate = 25
        master.notes = "existing journey"
        let extra = richExtra()

        let carried = model.applyEnrichmentInheritance(from: extra, to: master)

        #expect(master.audioTranscript == "MASTER transcript" && master.audioTranscriptModel == "m-model")
        #expect(master.sceneCaptions.first?.text == "MASTER caption" && master.sceneCaptionModel == "m-cap")
        #expect(master.dossierProcessedAt == Date(timeIntervalSince1970: 9) && master.dossierProcessedBy == "m-dossier")
        #expect(master.detectedPeople == ["Rick"], "detectedPeople only when master's is empty")
        #expect(master.inferredRecordDate == Date(timeIntervalSince1970: 99) && master.inferredDateConfidence == 0.1)
        #expect(master.avidClipName == "MASTER clip" && master.avidEditRate == 25)
        // Empty Avid sub-fields on the master DO fill (field-by-field).
        #expect(master.avidMobID == "mob-1")
        #expect(carried == ["Avid identity", "provenance note"], "\(carried)")
        #expect(master.notes.hasPrefix("existing journey\ncopy at "))
    }

    /// A bare extra carries only the provenance line; the human merge
    /// (repair rules) is untouched by this function.
    @Test func bareExtraCarriesOnlyProvenanceAndLeavesHumanFieldsAlone() {
        let model = VideoScanModel()
        let master = VideoRecord(); let extra = VideoRecord()
        extra.fullPath = "/Volumes/X/a.mov"
        extra.starRating = 3; extra.userNotes = "human"
        let carried = model.applyEnrichmentInheritance(from: extra, to: master)
        #expect(carried == ["provenance note"])
        #expect(master.starRating == 0 && master.userNotes.isEmpty)
        #expect(master.notes.hasPrefix("copy at /Volumes/X/a.mov removed "))
    }

    /// The real delete path runs BOTH merges on the verified outcome.
    @Test func verifiedDeleteCarriesEnrichmentOntoMaster() async throws {
        let dir = tempDir("DupEnrich")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<9_000).map { UInt8($0 % 19) }
        let k = dir.appendingPathComponent("a.mov"); write(k, bytes)
        let e = dir.appendingPathComponent("a copy.mov"); write(e, bytes)
        let model = makeModel(dir)
        let g = UUID()
        let master = dupRecord(path: k.path, size: 9_000, group: g, disposition: .keep)
        let extra = dupRecord(path: e.path, size: 9_000, group: g, disposition: .extraCopy)
        extra.audioTranscript = "the transcript"
        extra.starRating = 2
        model.records = [master, extra]
        let result = await model.deleteDuplicates(onVolume: dir.path)
        #expect(result.deleted == 1)
        #expect(master.audioTranscript == "the transcript")
        #expect(master.starRating == 2)
        #expect(master.notes.contains("copy at \(e.path) removed"))
    }
}

// MARK: - B. Stale policy ⇒ re-election

@MainActor
@Suite(.serialized)
struct DuplicateStalePolicyReelectionTests {

    /// Integration sensor: two stamped, grouped records (ledger says "up to
    /// date"); reorder the precedence list; Find Duplicates re-elects the
    /// keeper; a second run under the same policy changes nothing.
    @Test func reorderingPrecedenceReelectsStampedGroups() async {
        let model = makeModel(tempDir("DupStale"))
        model.scanTargets = [target("/Volumes/A"), target("/Volumes/B")]
        model.duplicateKeeperSettings.volumePrecedence = ["A", "B"]
        let g = UUID()
        let a = dupRecord(path: "/Volumes/A/x.mov", group: g, disposition: .keep, stamped: true)
        let b = dupRecord(path: "/Volumes/B/x.mov", group: g, disposition: .extraCopy, stamped: true)
        model.records = [a, b]
        // Stamp the ledger as "elected under [A, B]".
        model.duplicateKeeperSettings.lastElectionDescriptor = model.duplicateKeeperPolicy().electionDescriptor

        await model.analyzeDuplicates()
        #expect(a.duplicateDisposition == .keep && b.duplicateDisposition == .extraCopy, "same policy ⇒ no change")
        #expect(model.duplicateStatus == "Duplicates up to date")

        model.duplicateKeeperSettings.volumePrecedence = ["B", "A"]
        model.noteDuplicateKeeperSettingsChanged()
        #expect(model.duplicateReanalyzeHint == WorkingCopyCleanupText.reanalyzeHint)

        await model.analyzeDuplicates()
        #expect(b.duplicateDisposition == .keep, "B is now the master")
        #expect(a.duplicateDisposition == .extraCopy, "old keeper becomes an extra by its own (high) confidence")
        #expect(a.duplicateBestMatchFilename == b.filename)
        #expect(a.duplicateGroupID == g && b.duplicateGroupID == g, "grouping untouched")
        #expect(model.duplicateReanalyzeHint == nil)
        #expect(model.duplicateKeeperSettings.lastElectionDescriptor == model.duplicateKeeperPolicy().electionDescriptor)

        // Third run: nothing stale, nothing new.
        await model.analyzeDuplicates()
        #expect(b.duplicateDisposition == .keep && a.duplicateDisposition == .extraCopy)
        #expect(model.duplicateStatus == "Duplicates up to date")
    }

    /// Reachability / retirement changes are part of the descriptor too
    /// (the 8/14 strand): unplugging the keeper's drive re-elects.
    @Test func reachabilityChangeIsPartOfTheDescriptor() {
        let model = makeModel(tempDir("DupStale2"))
        model.scanTargets = [target("/Volumes/A"), target("/Volumes/B")]
        let before = model.duplicateKeeperPolicy().electionDescriptor
        model.scanTargets[0].isReachable = false
        let offline = model.duplicateKeeperPolicy().electionDescriptor
        model.scanTargets[0].retiredAt = Date()
        let retired = model.duplicateKeeperPolicy().electionDescriptor
        #expect(before != offline && offline != retired)
        // The toggle is NOT part of it (it doesn't move keepers).
        model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = true
        #expect(model.duplicateKeeperPolicy().electionDescriptor == retired)
    }
}

// MARK: - C. Hub / keeper decoupling

@Suite("Codex C — non-clique grouping")
struct DuplicateHubKeeperDecouplingTests {

    /// A–B (hash) and B–C (timecode) score; A–C does not. A sits on the
    /// top-precedence drive. Hub = B (best connected); keeper = A; ALL
    /// three are classified in ONE group.
    @Test func peripheralHighPrecedenceKeeperDoesNotShrinkTheGroup() {
        func rec(_ path: String, md5: String, size: Int64, timecode: String, rich: Bool) -> VideoRecord {
            let r = VideoRecord()
            r.fullPath = path; r.filename = (path as NSString).lastPathComponent
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.durationSeconds = 30; r.duration = Formatting.duration(30)
            r.partialMD5 = md5; r.sizeBytes = size; r.timecode = timecode
            r.isPlayable = "Yes"
            if rich { r.resolution = "1280x720"; r.videoCodec = "h264"; r.audioCodec = "aac"; r.audioChannels = "2"; r.audioSampleRate = "48000 Hz" }
            return r
        }
        let a = rec("/Volumes/LaCieWorkspace/clip.mov", md5: "h1", size: 1_000, timecode: "", rich: true)
        let b = rec("/Volumes/CrucialX9/clip.mov", md5: "h1", size: 1_000, timecode: "01:00:00:00", rich: true)
        let c = rec("/Volumes/CrucialX9/sub/clip.mov", md5: "h2", size: 2_000, timecode: "01:00:00:00", rich: false)
        let policy = DuplicateKeeperPolicy(precedence: DuplicateKeeperSettings.defaultPrecedence)

        let summary = DuplicateDetector.analyze(records: [c, b, a], keeperPolicy: policy)

        #expect(summary.groups == 1)
        #expect(a.duplicateGroupID != nil && a.duplicateGroupID == b.duplicateGroupID && b.duplicateGroupID == c.duplicateGroupID,
                "all three classified in one group (C was dropped before the fix)")
        #expect(a.duplicateDisposition == .keep, "policy keeper is the peripheral high-precedence copy")
        #expect(b.duplicateDisposition != .keep && c.duplicateDisposition != .keep)
        #expect(c.duplicateDisposition == .review || c.duplicateDisposition == .extraCopy)
    }
}

// MARK: - D. Off-main snapshot (scale sensor)

@MainActor
@Suite(.serialized)
struct DuplicateSnapshotOffMainTests {

    /// 100k records: the async snapshot lands, and while its encode/write
    /// runs the main actor stays responsive (ping latency well under the
    /// beachball threshold). Only the DTO map runs on main.
    @Test("100k pre-delete snapshot keeps main responsive", .timeLimit(.minutes(2)))
    func snapshotAsyncKeepsMainResponsive() async throws {
        let dir = tempDir("DupSnapScale")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        var catalog: [VideoRecord] = []
        catalog.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.fullPath = "/Volumes/CrucialX9/reel\(i % 500)/clip\(i).mov"
            r.filename = "clip\(i).mov"; r.sizeBytes = Int64(i); r.durationSeconds = 12
            catalog.append(r)
        }
        model.records = catalog

        let start = ContinuousClock.now
        let job = Task { await model.snapshotCatalogAsync(prefix: "pre-dup-crossvolume") }
        // Let the DTO map (main) finish, then ping main while encoding.
        try await Task.sleep(for: .milliseconds(200))
        var worstPing: Duration = .zero
        for _ in 0..<20 {
            let t0 = ContinuousClock.now
            await Task.yield()
            let ping = t0.duration(to: .now)
            if ping > worstPing { worstPing = ping }
            try await Task.sleep(for: .milliseconds(20))
        }
        let path = await job.value
        let total = start.duration(to: .now)

        #expect(path != nil, "snapshot must land")
        #expect(FileManager.default.fileExists(atPath: path ?? ""))
        #expect(worstPing < .milliseconds(250), "main actor blocked during snapshot encode: worst ping \(worstPing)")
        #expect(total < .seconds(60), "100k snapshot took \(total)")
    }
}

// MARK: - E. Snapshot failure on a mixed batch fixes skipped/summary

@MainActor
@Suite(.serialized)
struct DuplicateSnapshotFailureAccountingTests {

    @Test func mixedBatchSnapshotFailureCountsDroppedAsSkipped() async throws {
        let dir = tempDir("DupSnapFail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let keeperVol = dir.appendingPathComponent("RaidLike", isDirectory: true)
        let extraVol = dir.appendingPathComponent("SsdLike", isDirectory: true)
        try FileManager.default.createDirectory(at: keeperVol, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extraVol, withIntermediateDirectories: true)
        let model = makeModel(dir)
        model.scanTargets = [target(keeperVol.path), target(extraVol.path)]
        model.duplicateKeeperSettings.volumePrecedence = [keeperVol.path, extraVol.path]
        model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = true
        model.catalogStore.isReadOnly = true      // injected snapshot failure

        let bytes = (0..<6_000).map { UInt8($0 % 7) }
        let k = keeperVol.appendingPathComponent("a.mov"); write(k, bytes)
        let cross1 = extraVol.appendingPathComponent("a copy.mov"); write(cross1, bytes)
        let cross2 = extraVol.appendingPathComponent("a copy 2.mov"); write(cross2, bytes)
        let sameK = extraVol.appendingPathComponent("b.mov"); write(sameK, bytes)
        let sameE = extraVol.appendingPathComponent("b copy.mov"); write(sameE, bytes)
        let g1 = UUID(), g2 = UUID()
        model.records = [
            dupRecord(path: k.path, size: 6_000, group: g1, disposition: .keep),
            dupRecord(path: cross1.path, size: 6_000, group: g1, disposition: .extraCopy),
            dupRecord(path: cross2.path, size: 6_000, group: g1, disposition: .extraCopy),
            dupRecord(path: sameK.path, size: 6_000, group: g2, disposition: .keep),
            dupRecord(path: sameE.path, size: 6_000, group: g2, disposition: .extraCopy),
        ]
        let sel = model.duplicateDeletionSelection(onVolume: extraVol.path)
        #expect(sel.crossVolumeCount == 2 && sel.sameVolumeCount == 1 && sel.skippedCount == 0)

        let result = await model.deleteDuplicates(onVolume: extraVol.path)
        #expect(result.deleted == 1, "same-drive extra only")
        #expect(result.skipped == 2, "the two dropped working copies are reported as skipped")
        #expect(FileManager.default.fileExists(atPath: cross1.path) && FileManager.default.fileExists(atPath: cross2.path))
        #expect(!FileManager.default.fileExists(atPath: sameE.path))
    }
}

// MARK: - Media matrix on the working-copy delete path

@MainActor
@Suite(.serialized)
struct DuplicateWorkingCopyMediaMatrixTests {

    struct Case: Sendable, CustomStringConvertible {
        let label: String, filename: String, videoCodec: String, extraVideoArgs: [String], audioCodec: String, size: String, rate: String
        var description: String { label }
    }
    nonisolated static let cases = [
        Case(label: "mp4/h264+aac", filename: "test_wc_matrix.mp4", videoCodec: "libx264", extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac", size: "320x240", rate: "25"),
        Case(label: "mov/prores+pcm", filename: "test_wc_matrix.mov", videoCodec: "prores", extraVideoArgs: [], audioCodec: "pcm_s16le", size: "320x240", rate: "25"),
        Case(label: "mkv/ffv1+pcm", filename: "test_wc_matrix.mkv", videoCodec: "ffv1", extraVideoArgs: [], audioCodec: "pcm_s16le", size: "320x240", rate: "25"),
        Case(label: "mxf/mpeg2+pcm", filename: "test_wc_matrix.mxf", videoCodec: "mpeg2video", extraVideoArgs: ["-g", "15"], audioCodec: "pcm_s16le", size: "720x576", rate: "25"),
        Case(label: "avi/dv+pcm", filename: "test_wc_matrix.avi", videoCodec: "dvvideo", extraVideoArgs: ["-pix_fmt", "yuv411p"], audioCodec: "pcm_s16le", size: "720x480", rate: "30000/1001"),
    ]

    /// Real ffmpeg fixtures: master on the higher-ranked drive, working
    /// copy (byte-identical copy) on the SSD-like drive; ON mode removes
    /// the working copy, keeps the master, carries a transcript.
    @Test("working-copy delete across the media matrix", .timeLimit(.minutes(3)), arguments: cases)
    func workingCopyDeleteMediaMatrix(testCase: Case) async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable, "ffmpeg is a required project dependency")
        let dir = try VerifyAudioTestMedia.makeScratchDir("wc-matrix")
        defer { try? FileManager.default.removeItem(at: dir) }
        let keeperVol = dir.appendingPathComponent("RaidLike", isDirectory: true)
        let extraVol = dir.appendingPathComponent("SsdLike", isDirectory: true)
        try FileManager.default.createDirectory(at: keeperVol, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extraVol, withIntermediateDirectories: true)

        let source = try VerifyAudioTestMedia.generate(into: keeperVol, name: testCase.filename,
                                                       videoCodec: testCase.videoCodec, extraVideoArgs: testCase.extraVideoArgs,
                                                       audioCodec: testCase.audioCodec, size: testCase.size, rate: testCase.rate)
        let copyURL = extraVol.appendingPathComponent("test_copy_" + testCase.filename)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copyURL)
        let size = ((try FileManager.default.attributesOfItem(atPath: source))[.size] as? NSNumber)?.int64Value ?? 0

        let model = makeModel(dir)
        model.scanTargets = [target(keeperVol.path), target(extraVol.path)]
        model.duplicateKeeperSettings.volumePrecedence = [keeperVol.path, extraVol.path]
        model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = true
        let g = UUID()
        let master = dupRecord(path: source, size: size, group: g, disposition: .keep)
        let copy = dupRecord(path: copyURL.path, size: size, group: g, disposition: .extraCopy)
        copy.audioTranscript = "matrix transcript"
        model.records = [master, copy]

        let result = await model.deleteDuplicates(onVolume: extraVol.path)
        #expect(result.deleted == 1, "\(testCase.label): working copy survived")
        #expect(FileManager.default.fileExists(atPath: source), "\(testCase.label): master must survive")
        #expect(!FileManager.default.fileExists(atPath: copyURL.path))
        #expect(master.audioTranscript == "matrix transcript", "\(testCase.label): enrichment carried")
    }
}
