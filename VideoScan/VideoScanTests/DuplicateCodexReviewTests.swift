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
        model.duplicateKeeperSettings.lastElectionDescriptor = model.electionStamp(for: model.duplicateKeeperPolicy())

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
        #expect(model.duplicateKeeperSettings.lastElectionDescriptor == model.electionStamp(for: model.duplicateKeeperPolicy()))

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

    /// 100k records: the async snapshot lands, and the MAIN THREAD is never
    /// blocked for longer than the stated budget — including the
    /// synchronous DTO map (the one main-actor part of the snapshot).
    /// Measured directly (codex follow-up NOTE 5): a background thread
    /// keeps issuing `DispatchQueue.main.sync {}` pings for the whole
    /// operation; the longest ping IS the longest stretch main was busy.
    /// Budget 1.5 s worst-case main block; total < 60 s.
    ///
    /// The 100k SELECTION + ELECTION scale checks live in
    /// DuplicateCrossVolumeDeleteTests.selectionScale100k and
    /// DuplicateKeeperScaleTests.electionScale100k (referenced, not
    /// duplicated here).
    @Test("100k pre-delete snapshot: bounded main-thread block", .timeLimit(.minutes(2)))
    func snapshotAsyncBoundsMainThreadBlocking() async throws {
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

        // Background pinger: records the worst main-thread round trip.
        final class Probe: @unchecked Sendable {
            let lock = NSLock()
            var worst: Duration = .zero
            var stop = false
        }
        let probe = Probe()
        let pinger = Thread {
            while !probe.lock.withLock({ probe.stop }) {
                let t0 = ContinuousClock.now
                DispatchQueue.main.sync { }
                let dt = t0.duration(to: .now)
                probe.lock.withLock { if dt > probe.worst { probe.worst = dt } }
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        pinger.start()
        // Let the pinger establish a baseline before the snapshot starts.
        try await Task.sleep(for: .milliseconds(50))

        let start = ContinuousClock.now
        let path = await model.snapshotCatalogAsync(prefix: "pre-dup-crossvolume")
        let total = start.duration(to: .now)
        // Give the pinger one more turn after completion, then stop it.
        try await Task.sleep(for: .milliseconds(20))
        probe.lock.withLock { probe.stop = true }
        let worst = probe.lock.withLock { probe.worst }

        #expect(path != nil, "snapshot must land")
        #expect(FileManager.default.fileExists(atPath: path ?? ""))
        #expect(worst < .seconds(1.5), "main thread blocked \(worst) during a 100k snapshot (budget 1.5 s)")
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


// MARK: - Codex follow-up (377c5d4a review)

@MainActor
@Suite(.serialized)
struct DuplicateCarryOverLiveRowGuardTests {

    /// MAJOR 1: the extra's catalog row is replaced while byte-verify runs
    /// → the (verified identical) file is still deleted, but NOTHING is
    /// carried onto the master — neither human nor enrichment fields — and
    /// the console says why.
    @Test func replacedRowDuringVerifyDeletesButCarriesNothing() async throws {
        let dir = tempDir("DupLiveRow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let keeperURL = dir.appendingPathComponent("keeper.mov")
        let copyURL = dir.appendingPathComponent("copy.mov")
        let bytes = [UInt8](repeating: 4, count: FileHasher.segmentSize * 2)
        write(keeperURL, bytes); write(copyURL, bytes)
        let group = UUID()
        let extraID = UUID()
        let model = makeModel(dir)
        let master = dupRecord(path: keeperURL.path, size: Int64(bytes.count), group: group, disposition: .keep)
        let extra = VideoRecord(id: extraID)
        extra.fullPath = copyURL.path; extra.filename = "copy.mov"; extra.sizeBytes = Int64(bytes.count)
        extra.partialMD5 = "m"; extra.durationSeconds = 61
        extra.duplicateGroupID = group; extra.duplicateDisposition = .extraCopy; extra.duplicateConfidence = .high
        extra.starRating = 3; extra.userNotes = "stale human"; extra.audioTranscript = "stale transcript"
        model.records = [master, extra]

        let allowHashing = DispatchSemaphore(value: 0)
        let gate = NSLock()
        var paused = false, hashingStarted = false
        let hooks = SignatureVerification.Hooks(
            shouldCancel: { Task.isCancelled },
            didReadBlock: { _ in
                let first = gate.withLock { let f = !paused; paused = true; hashingStarted = true; return f }
                if first { allowHashing.wait() }
            })
        let deletion = Task { await model.deleteDuplicates(onVolume: dir.path, verificationHooks: hooks) }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if gate.withLock({ hashingStarted }) { break }
            await Task.yield()
        }
        #expect(gate.withLock { hashingStarted })
        // Replace the extra's row (new id, same path) while the worker holds.
        let replacement = VideoRecord()
        replacement.fullPath = copyURL.path; replacement.filename = "copy.mov"
        model.records = [master, replacement]
        allowHashing.signal()
        let result = await deletion.value

        #expect(result.deleted == 1)
        #expect(!FileManager.default.fileExists(atPath: copyURL.path))
        #expect(master.starRating == 0 && master.userNotes.isEmpty, "human merge skipped")
        #expect(master.audioTranscript == nil && master.notes.isEmpty, "enrichment merge skipped")
        try? await Task.sleep(nanoseconds: 400_000_000)   // console flush debounce (150 ms)
        let console = model.dashboard.consoleLines.joined(separator: "\n")
        #expect(console.contains("catalog changed during verification — carry-over skipped for copy.mov (file already verified and removed)"))
    }
}

@Suite("Codex follow-up NOTE 2 — re-election best match")
struct DuplicateReelectionBestMatchTests {

    /// After re-election the new keeper's best match is its STRONGEST
    /// scoring group-mate (Y, sharing hash+size), not the old keeper X.
    @Test func newKeeperBestMatchIsStrongestScoringMember() async {
        func makeGroup() -> [VideoRecord] {
            func rec(_ path: String, filename: String, md5: String, size: Int64, keep: Bool) -> VideoRecord {
                let r = VideoRecord()
                r.fullPath = path; r.filename = filename
                r.streamTypeRaw = StreamType.videoAndAudio.rawValue
                r.durationSeconds = 30; r.partialMD5 = md5; r.sizeBytes = size
                r.timecode = "01:00:00:00"
                r.duplicateConfidence = .high
                r.duplicateDisposition = keep ? .keep : .extraCopy
                return r
            }
            let g = UUID()
            let x = rec("/Volumes/CrucialX9/clip.mov", filename: "clip.mov", md5: "hx", size: 100, keep: true)          // old keeper
            let y = rec("/Volumes/CrucialX10/clip (1).mov", filename: "clip (1).mov", md5: "hz", size: 200, keep: false) // shares hash+size with Z
            let z = rec("/Volumes/FamilyArchive/clip.mov", filename: "clip.mov", md5: "hz", size: 200, keep: false)      // policy keeper
            for r in [x, y, z] { r.duplicateGroupID = g }
            return [x, y, z]
        }
        let policy = DuplicateKeeperPolicy(precedence: DuplicateKeeperSettings.defaultPrecedence)
        let (out, changed) = await DuplicateDetector.reelectKeepersDetached(makeGroup(), keeperPolicy: policy)
        #expect(changed == 1)
        let z = out.first { $0.fullPath.hasPrefix("/Volumes/FamilyArchive/") }
        let x = out.first { $0.fullPath.hasPrefix("/Volumes/CrucialX9/") }
        let y = out.first { $0.fullPath.hasPrefix("/Volumes/CrucialX10/") }
        #expect(z?.duplicateDisposition == .keep)
        #expect(z?.duplicateBestMatchFilename == "clip (1).mov", "strongest match is Y (hash+size), not old keeper X")
        #expect(x?.duplicateDisposition == .extraCopy && y?.duplicateDisposition == .extraCopy)
        #expect(x?.duplicateBestMatchFilename == "clip.mov" && y?.duplicateBestMatchFilename == "clip.mov",
                "non-keepers point at the new keeper")
    }
}

@MainActor
@Suite(.serialized)
struct DuplicateReelectionStampTests {

    /// NOTE 3: rows replaced during the re-election await ⇒ the policy is
    /// NOT stamped; the next Find Duplicates re-elects again.
    @Test func skippedRowsLeaveThePolicyUnstamped() async {
        let model = makeModel(tempDir("DupStamp"))
        model.scanTargets = [target("/Volumes/A"), target("/Volumes/B")]
        model.duplicateKeeperSettings.volumePrecedence = ["B", "A"]
        let g = UUID()
        let a = dupRecord(path: "/Volumes/A/x.mov", group: g, disposition: .keep, stamped: true)
        let b = dupRecord(path: "/Volumes/B/x.mov", group: g, disposition: .extraCopy, stamped: true)
        model.records = [a, b]
        model.duplicateReelectionAwaitHook = {
            // Replace row `a` with a fresh instance mid-pass.
            let a2 = dupRecord(path: "/Volumes/A/x.mov", group: g, disposition: .keep, stamped: true)
            model.records = [a2, b]
        }
        let policy = model.duplicateKeeperPolicy()
        _ = await model.reelectDuplicateKeepers(policy: policy)
        #expect(model.duplicateKeeperSettings.lastElectionDescriptor == nil, "must stay unstamped")
        #expect(model.isDuplicateKeeperPolicyStale)
        try? await Task.sleep(nanoseconds: 400_000_000)   // console flush debounce (150 ms)
        let console = model.dashboard.consoleLines.joined(separator: "\n")
        #expect(console.contains("1 row(s) changed during the pass — policy left unstamped"))

        // Without interference the stamp lands.
        model.duplicateReelectionAwaitHook = nil
        _ = await model.reelectDuplicateKeepers(policy: policy)
        #expect(!model.isDuplicateKeeperPolicyStale)
    }

    /// Codex final nit: through the FULL analyzeDuplicates() path, a
    /// re-election that skipped rows must leave the "re-elect" hint
    /// visible (the catalog is still policy-stale); a clean second run
    /// clears it.
    @Test func hintSurvivesSkippedRowsThroughAnalyzeDuplicates() async {
        let model = makeModel(tempDir("DupHint"))
        model.scanTargets = [target("/Volumes/A"), target("/Volumes/B")]
        model.duplicateKeeperSettings.volumePrecedence = ["B", "A"]
        let g = UUID()
        let a = dupRecord(path: "/Volumes/A/x.mov", group: g, disposition: .keep, stamped: true)
        let b = dupRecord(path: "/Volumes/B/x.mov", group: g, disposition: .extraCopy, stamped: true)
        model.records = [a, b]
        model.noteDuplicateKeeperSettingsChanged()
        #expect(model.duplicateReanalyzeHint == WorkingCopyCleanupText.reanalyzeHint)

        // Force a skipped row during the re-election inside Analyze.
        model.duplicateReelectionAwaitHook = {
            let a2 = dupRecord(path: "/Volumes/A/x.mov", group: g, disposition: .keep, stamped: true)
            model.records = [a2, b]
        }
        await model.analyzeDuplicates()
        #expect(model.isDuplicateKeeperPolicyStale, "stamp deliberately left stale")
        #expect(model.duplicateReanalyzeHint == WorkingCopyCleanupText.reanalyzeHint, "hint must survive")

        // Second run, no interference: stamp lands, hint clears.
        model.duplicateReelectionAwaitHook = nil
        await model.analyzeDuplicates()
        #expect(!model.isDuplicateKeeperPolicyStale)
        #expect(model.duplicateReanalyzeHint == nil)
        #expect(model.records.first { $0.fullPath.hasPrefix("/Volumes/B/") }?.duplicateDisposition == .keep)
    }

    /// NOTE 4 (isolation, CLAUDE.md dimension 4): the stamp carries the
    /// catalog identity. A stamp written for one catalog directory —
    /// poisoned into the shared settings — is stale for another catalog,
    /// so re-election is never suppressed across catalogs/viewer sessions.
    @Test func stampIsBoundToCatalogIdentity() async {
        let dirA = tempDir("DupCatA"), dirB = tempDir("DupCatB")
        defer { try? FileManager.default.removeItem(at: dirA); try? FileManager.default.removeItem(at: dirB) }
        let modelA = makeModel(dirA)
        let modelB = makeModel(dirB)
        for m in [modelA, modelB] {
            m.scanTargets = [target("/Volumes/A"), target("/Volumes/B")]
            m.duplicateKeeperSettings.volumePrecedence = ["A", "B"]
        }
        _ = await modelA.reelectDuplicateKeepers(policy: modelA.duplicateKeeperPolicy())
        let stampA = modelA.duplicateKeeperSettings.lastElectionDescriptor
        #expect(stampA?.hasPrefix("catalog=\(modelA.catalogStore.fileLocation);") == true)
        #expect(!modelA.isDuplicateKeeperPolicyStale)

        // Poison B's settings with A's stamp (same policy, other catalog).
        modelB.duplicateKeeperSettings.lastElectionDescriptor = stampA
        #expect(modelB.isDuplicateKeeperPolicyStale, "another catalog's stamp must not count")

        // And B's own Find Duplicates re-elects (keeper flips to policy order).
        let g = UUID()
        let a = dupRecord(path: "/Volumes/A/x.mov", group: g, disposition: .extraCopy, stamped: true)
        let b = dupRecord(path: "/Volumes/B/x.mov", group: g, disposition: .keep, stamped: true)
        modelB.records = [a, b]
        await modelB.analyzeDuplicates()
        #expect(a.duplicateDisposition == .keep && b.duplicateDisposition == .extraCopy)
        #expect(!modelB.isDuplicateKeeperPolicyStale)
    }
}
