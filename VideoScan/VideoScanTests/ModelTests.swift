import Testing
import Foundation
@testable import VideoScan

// MARK: - ToolLocator Tests

struct ToolLocatorTests {

    @Test func firstExecutableSelectsFirstExecutableCandidate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolLocatorTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let missing = dir.appendingPathComponent("missing").path
        let notExecutable = dir.appendingPathComponent("not-executable").path
        let executable = dir.appendingPathComponent("tool").path
        FileManager.default.createFile(atPath: notExecutable, contents: Data())
        FileManager.default.createFile(atPath: executable, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable
        )

        #expect(ToolLocator.firstExecutable(in: [missing, notExecutable, executable]) == executable)
    }

    @Test func firstExecutableReturnsNilWhenNoCandidateCanRun() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolLocatorTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("plain-file").path
        FileManager.default.createFile(atPath: path, contents: Data())

        #expect(ToolLocator.firstExecutable(in: [path]) == nil)
    }

    // MARK: - resolve(): env-var overrides + fallback (issue #60)
    // Tests the env-var override behavior added in 2026-05-11 so users can
    // point at non-standard tool installs without editing source.

    // regression: env override wins when set AND executable
    @Test func resolveEnvOverrideWinsWhenExecutable() {
        let resolved = ToolLocator.resolve(
            envVar: "VS_FFMPEG_PATH",
            candidates: ["/nonexistent/ffmpeg"],
            environment: ["VS_FFMPEG_PATH": "/bin/ls"],   // universally exec
            fallback: "/dev/null"
        )
        #expect(resolved == "/bin/ls")
    }

    // regression: env override must NOT win if the path isn't executable
    @Test func resolveEnvOverrideIgnoredWhenNotExecutable() {
        let resolved = ToolLocator.resolve(
            envVar: "VS_FFMPEG_PATH",
            candidates: ["/bin/ls"],
            environment: ["VS_FFMPEG_PATH": "/this/path/does/not/exist"],
            fallback: "/dev/null"
        )
        #expect(resolved == "/bin/ls",
            "Non-existent env override must fall through to candidates")
    }

    @Test func resolveEnvOverrideIgnoredWhenEmpty() {
        let resolved = ToolLocator.resolve(
            envVar: "VS_FFMPEG_PATH",
            candidates: ["/bin/ls"],
            environment: ["VS_FFMPEG_PATH": ""],
            fallback: "/dev/null"
        )
        #expect(resolved == "/bin/ls")
    }

    @Test func resolveCandidateUsedWhenEnvVarAbsent() {
        let resolved = ToolLocator.resolve(
            envVar: "VS_FFMPEG_PATH",
            candidates: ["/bin/ls"],
            environment: [:],
            fallback: "/dev/null"
        )
        #expect(resolved == "/bin/ls")
    }

    @Test func resolveSkipsNonExecutableAndPicksNext() {
        let resolved = ToolLocator.resolve(
            envVar: "VS_FFMPEG_PATH",
            candidates: [
                "/nonexistent/one",
                "/nonexistent/two",
                "/bin/ls",
                "/usr/bin/env"
            ],
            environment: [:],
            fallback: "/dev/null"
        )
        #expect(resolved == "/bin/ls")
    }

    @Test func resolveFallbackUsedWhenNothingExecutable() {
        let resolved = ToolLocator.resolve(
            envVar: "VS_FFMPEG_PATH",
            candidates: ["/nope/a", "/nope/b"],
            environment: [:],
            fallback: "/some/default/ffmpeg"
        )
        #expect(resolved == "/some/default/ffmpeg",
            "When neither env override nor any candidate is executable, fallback wins")
    }

    @Test func resolveEmptyFallbackSurfacesEmpty() {
        let resolved = ToolLocator.resolve(
            envVar: "VS_PYTHON_PATH",
            candidates: ["/nope/python3"],
            environment: [:],
            fallback: ""
        )
        #expect(resolved == "",
            "pythonPath callers gate on empty-string; fallback must surface empty when intentional")
    }

    // Sanity: production accessors return strings (non-empty for ffmpeg/ffprobe
    // because they fall back to a candidate; pythonPath may be empty if no
    // Python is installed — that's a contract callers depend on).
    @Test func productionAccessorsHaveStableSemantics() {
        #expect(!ToolLocator.ffmpegPath.isEmpty)
        #expect(!ToolLocator.ffprobePath.isEmpty)
        #expect(!ToolLocator.python312Path.isEmpty)
        // pythonPath may be "" — don't assert non-empty.
    }
}

// MARK: - StreamType Tests

struct StreamTypeTests {

    @Test func rawValues() {
        #expect(StreamType.videoAndAudio.rawValue == "Video+Audio")
        #expect(StreamType.videoOnly.rawValue == "Video only")
        #expect(StreamType.audioOnly.rawValue == "Audio only")
        #expect(StreamType.noStreams.rawValue == "No A/V streams")
        #expect(StreamType.ffprobeFailed.rawValue == "ffprobe failed")
    }

    @Test func needsCorrelation() {
        #expect(StreamType.videoOnly.needsCorrelation == true)
        #expect(StreamType.audioOnly.needsCorrelation == true)
        #expect(StreamType.videoAndAudio.needsCorrelation == false)
        #expect(StreamType.noStreams.needsCorrelation == false)
        #expect(StreamType.ffprobeFailed.needsCorrelation == false)
    }
}

// MARK: - VideoRecord Tests

struct VideoRecordTests {

    @Test func defaults() {
        let rec = VideoRecord()
        #expect(rec.filename.isEmpty)
        #expect(rec.sizeBytes == 0)
        #expect(rec.durationSeconds == 0)
        #expect(rec.streamType == .ffprobeFailed)
        #expect(rec.pairedWith == nil)
        #expect(rec.pairGroupID == nil)
        #expect(rec.pairConfidence == nil)
        #expect(rec.duplicateGroupID == nil)
        #expect(rec.duplicateConfidence == nil)
        #expect(rec.duplicateDisposition == .none)
        #expect(rec.wasCacheHit == false)
    }

    @Test func streamTypeParsing() {
        let rec = VideoRecord()
        rec.streamTypeRaw = "Video+Audio"
        #expect(rec.streamType == .videoAndAudio)

        rec.streamTypeRaw = "Video only"
        #expect(rec.streamType == .videoOnly)

        rec.streamTypeRaw = "Audio only"
        #expect(rec.streamType == .audioOnly)

        rec.streamTypeRaw = "garbage"
        #expect(rec.streamType == .ffprobeFailed)
    }

    @Test func uniqueIDs() {
        let a = VideoRecord()
        let b = VideoRecord()
        #expect(a.id != b.id)
    }
}

// MARK: - PairConfidence Tests

struct PairConfidenceTests {

    @Test func ordering() {
        #expect(PairConfidence.low < PairConfidence.medium)
        #expect(PairConfidence.medium < PairConfidence.high)
        #expect(!(PairConfidence.high < PairConfidence.low))
    }

    @Test func rawValues() {
        #expect(PairConfidence.high.rawValue == "High")
        #expect(PairConfidence.medium.rawValue == "Medium")
        #expect(PairConfidence.low.rawValue == "Low")
    }
}

// MARK: - DuplicateConfidence Tests

struct DuplicateConfidenceTests {

    @Test func ordering() {
        #expect(DuplicateConfidence.low < DuplicateConfidence.medium)
        #expect(DuplicateConfidence.medium < DuplicateConfidence.high)
    }
}

// MARK: - CatalogTargetStatus Tests

struct CatalogTargetStatusTests {

    @Test func activeStates() {
        #expect(CatalogTargetStatus.scanning.isActive == true)
        #expect(CatalogTargetStatus.paused.isActive == true)
        #expect(CatalogTargetStatus.discovering.isActive == true)
        #expect(CatalogTargetStatus.waitingForVolume.isActive == true)
        #expect(CatalogTargetStatus.idle.isActive == false)
        #expect(CatalogTargetStatus.complete.isActive == false)
        #expect(CatalogTargetStatus.stopped.isActive == false)
        #expect(CatalogTargetStatus.error.isActive == false)
        #expect(CatalogTargetStatus.resumable.isActive == false)
    }

    @Test func isPaused() {
        #expect(CatalogTargetStatus.paused.isPaused == true)
        #expect(CatalogTargetStatus.scanning.isPaused == false)
    }

    @Test func isIdle() {
        #expect(CatalogTargetStatus.idle.isIdle == true)
        #expect(CatalogTargetStatus.resumable.isIdle == true)
        #expect(CatalogTargetStatus.scanning.isIdle == false)
    }
}

// MARK: - ScanPhase Tests

struct ScanPhaseTests {

    @Test func allPhases() {
        #expect(ScanPhase.idle.rawValue == "Idle")
        #expect(ScanPhase.discovering.rawValue == "Discovering")
        #expect(ScanPhase.probing.rawValue == "Probing")
        #expect(ScanPhase.writingCSV.rawValue == "Writing CSV")
        #expect(ScanPhase.complete.rawValue == "Complete")
    }
}

// MARK: - ScanPerformanceSettings Tests

struct ScanPerformanceSettingsTests {

    @Test func defaultValues() {
        let s = ScanPerformanceSettings()
        #expect(s.probesPerVolume == 8)
        #expect(s.ramDiskGB == 16)
        #expect(s.prefetchMB == 50)
        #expect(s.combineConcurrency == 4)
        #expect(s.memoryFloorGB == 4)
    }
}

// MARK: - Discovered Volume Tests

struct DiscoveredVolumeTests {

    @Test func formattedSizes() {
        let vol = DiscoveredVolume(
            name: "TestDrive",
            path: "/Volumes/TestDrive",
            isNetwork: false,
            totalBytes: 1_000_000_000_000,
            freeBytes: 500_000_000_000,
            alreadyAdded: false
        )
        #expect(!vol.totalFormatted.isEmpty)
        #expect(!vol.usedFormatted.isEmpty)
        #expect(vol.isNetwork == false)
        #expect(vol.alreadyAdded == false)
    }

    @Test func networkVolumeFlag() {
        let vol = DiscoveredVolume(
            name: "NAS",
            path: "/Volumes/NAS",
            isNetwork: true,
            totalBytes: 4_000_000_000_000,
            freeBytes: 1_000_000_000_000,
            alreadyAdded: true
        )
        #expect(vol.isNetwork == true)
        #expect(vol.alreadyAdded == true)
    }
}

// MARK: - CombinePairItem Tests

struct CombinePairItemTests {

    @Test func storesVideoAndAudio() {
        let v = VideoRecord()
        v.filename = "video.mxf"
        v.fullPath = "/Volumes/Drive/video.mxf"
        let a = VideoRecord()
        a.filename = "audio.mxf"
        a.fullPath = "/Volumes/Drive/audio.mxf"

        let item = CombinePairItem(video: v, audio: a)
        #expect(item.video.filename == "video.mxf")
        #expect(item.audio.fullPath == "/Volumes/Drive/audio.mxf")
        #expect(item.id != UUID())
    }
}

// MARK: - RecognitionEngine Tests

struct RecognitionEngineTests {

    // regression: #9 — Pluggable FD architecture: all four engines (Vision, ArcFace, dlib, Hybrid) remain registered
    @Test func allCasesExist() {
        let engines = RecognitionEngine.allCases
        #expect(engines.count == 4)
        #expect(engines.contains(.vision))
        #expect(engines.contains(.arcface))
        #expect(engines.contains(.dlib))
        #expect(engines.contains(.hybrid))
    }

    // regression: #9 — Every engine must surface a UI title and short label (catches broken UI registry)
    @Test func titlesAreNonEmpty() {
        for engine in RecognitionEngine.allCases {
            #expect(!engine.title.isEmpty, "\(engine) has empty title")
            #expect(!engine.shortLabel.isEmpty, "\(engine) has empty shortLabel")
        }
    }

    @Test func symbolNamesAreValid() {
        for engine in RecognitionEngine.allCases {
            #expect(!engine.symbolName.isEmpty, "\(engine) has empty symbolName")
        }
    }
}

// MARK: - POIStorage Tests

struct POIStorageTests {

    @Test func sanitizeNormalizesName() {
        #expect(POIStorage.sanitize("Rick") == "rick")
        #expect(POIStorage.sanitize("Mary Beth") == "mary_beth")
        #expect(POIStorage.sanitize("  Timmy  ") == "timmy")
        #expect(POIStorage.sanitize("") == "reference")
        #expect(POIStorage.sanitize("   ") == "reference")
    }

    @Test func folderForReturnsPerPersonPath() {
        let donna = POIStorage.folder(for: "Donna")
        let rick = POIStorage.folder(for: "Rick")
        #expect(donna.lastPathComponent == "donna")
        #expect(rick.lastPathComponent == "rick")
        #expect(POIStorage.folder(for: "DONNA").path == donna.path)
    }

    @Test func profileURLEndsWithProfileJson() {
        let url = POIStorage.profileURL(for: "Rick")
        #expect(url.lastPathComponent == "profile.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "rick")
    }

    /// Pre-Gauntlet this asserted the PRODUCTION location
    /// (…/Application Support/VideoScan/POI). Since the settings-pollution
    /// fix on feature/gauntlet-v1, POIStorage.storeDir redirects to a
    /// per-process temp dir whenever TestEnvironment.isTestHost — which is
    /// ALWAYS true in this suite. So the contract this test can honestly
    /// pin from inside a test host is the ISOLATION contract; asserting
    /// the real Application Support path here would require resolving the
    /// user's real dirs — the exact pollution class the redirect kills.
    /// (The production branch has no injection seam today; if one is
    /// added, extend this with a production-shape assertion through it.)
    @Test func storeDirIsIsolatedPerProcessUnderTestHost() {
        let dir = POIStorage.storeDir
        // Redirected: under the temp dir, keyed to THIS process, and
        // nowhere near the real store.
        #expect(dir.lastPathComponent.hasPrefix("VideoScanTestPOI-"))
        #expect(dir.lastPathComponent
            .contains("\(ProcessInfo.processInfo.processIdentifier)"))
        #expect(dir.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(!dir.path.contains("Application Support"))
        // Created on access (same side-effect the production path has).
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path,
                                               isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test func migrationIdempotentWhenNothingToDo() {
        let first = POIStorage.migrateLegacyIfNeeded()
        let second = POIStorage.migrateLegacyIfNeeded()
        _ = first
        #expect(second == .notNeeded)
    }
}

// MARK: - CombineJobStatus Tests

struct CombineJobStatusTests {

    @Test func defaultPhaseIsQueued() {
        let job = CombineJobStatus(
            pairIndex: 0,
            videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 100, audioSizeBytes: 50,
            totalDurationSeconds: 10, videoOnline: true, audioOnline: true
        )
        #expect(job.phase == .queued)
        #expect(job.progressFraction == 0)
        #expect(job.isPaused == false)
        #expect(job.technique == .streamCopy)
    }

    @Test func estimatedBytes() {
        let job = CombineJobStatus(
            pairIndex: 0,
            videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 1_000_000, audioSizeBytes: 500_000,
            totalDurationSeconds: 10, videoOnline: true, audioOnline: true
        )
        #expect(job.estimatedBytes == 1_500_000)
    }

    @Test func bothOnlineRequiresBoth() {
        let online = CombineJobStatus(
            pairIndex: 0,
            videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 100, audioSizeBytes: 50,
            totalDurationSeconds: 10, videoOnline: true, audioOnline: true
        )
        #expect(online.bothOnline == true)

        let partial = CombineJobStatus(
            pairIndex: 0,
            videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 100, audioSizeBytes: 50,
            totalDurationSeconds: 10, videoOnline: true, audioOnline: false
        )
        #expect(partial.bothOnline == false)
    }

    @Test func elapsedNilWhenNotStarted() {
        let job = CombineJobStatus(
            pairIndex: 0,
            videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 100, audioSizeBytes: 50,
            totalDurationSeconds: 10, videoOnline: true, audioOnline: true
        )
        #expect(job.elapsed == nil)
    }

    @Test func elapsedComputesWhenStarted() {
        var job = CombineJobStatus(
            pairIndex: 0,
            videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 100, audioSizeBytes: 50,
            totalDurationSeconds: 10, videoOnline: true, audioOnline: true
        )
        job.startTime = Date().addingTimeInterval(-5)
        let elapsed = job.elapsed!
        #expect(elapsed >= 4.5 && elapsed <= 6.0)
    }

    @Test func phaseRawValues() {
        #expect(CombineJobStatus.CombinePhase.queued.rawValue == "Queued")
        #expect(CombineJobStatus.CombinePhase.buffering.rawValue == "Buffering")
        #expect(CombineJobStatus.CombinePhase.muxing.rawValue == "Muxing")
        #expect(CombineJobStatus.CombinePhase.verifying.rawValue == "Verifying")
        #expect(CombineJobStatus.CombinePhase.done.rawValue == "Verified")
        #expect(CombineJobStatus.CombinePhase.failed.rawValue == "Failed")
        #expect(CombineJobStatus.CombinePhase.skipped.rawValue == "Already Combined")
    }

    @Test func techniqueRawValues() {
        #expect(CombineJobStatus.CombineTechnique.streamCopy.rawValue == "Stream Copy")
        #expect(CombineJobStatus.CombineTechnique.reencodeProRes.rawValue == "Re-encode → ProRes")
        #expect(CombineJobStatus.CombineTechnique.reencodeH264.rawValue == "Re-encode → H.264")
    }
}

// MARK: - ArchiveHealth Tests

struct ArchiveHealthTests {

    private func makeRecord(
        streamType: String = "Video+Audio",
        disposition: MediaDisposition = .unreviewed,
        stage: ArchiveStage = .none,
        backups: [BackupEntry] = []
    ) -> VideoRecord {
        let rec = VideoRecord()
        rec.streamTypeRaw = streamType
        rec.mediaDisposition = disposition
        rec.archiveStage = stage
        rec.backupDestinations = backups
        return rec
    }

    private let sampleBackup = BackupEntry(
        name: "LTA_Crucial", kind: .local, date: Date()
    )

    @Test func junkIsNotApplicable() {
        let rec = makeRecord(disposition: .confirmedJunk)
        #expect(rec.archiveHealth == .notApplicable)

        let suspected = makeRecord(disposition: .suspectedJunk)
        #expect(suspected.archiveHealth == .notApplicable)
    }

    @Test func defaultRecordNeedsAttention() {
        let rec = makeRecord()
        #expect(rec.archiveHealth == .needsAttention)
    }

    @Test func reviewedButNotBackedUpIsInProgress() {
        let rec = makeRecord(disposition: .important)
        #expect(rec.archiveHealth == .inProgress)
    }

    @Test func healthyStageIsInProgress() {
        let rec = makeRecord(stage: .healthy)
        #expect(rec.archiveHealth == .inProgress)
    }

    @Test func fullyArchivedIsSafe() {
        let rec = makeRecord(
            disposition: .important,
            stage: .backedUp,
            backups: [sampleBackup]
        )
        #expect(rec.archiveHealth == .safe)
    }

    @Test func backedUpButAudioOnlyStillInProgress() {
        let rec = makeRecord(
            streamType: "Audio only",
            disposition: .important,
            stage: .backedUp,
            backups: [sampleBackup]
        )
        #expect(rec.archiveHealth == .inProgress)
    }

    @Test func backedUpWithNoDestinationsIsInProgress() {
        let rec = makeRecord(
            disposition: .important,
            stage: .backedUp,
            backups: []
        )
        #expect(rec.archiveHealth == .inProgress)
    }

    @Test func recoverableAndBackedUpIsSafe() {
        let rec = makeRecord(
            disposition: .recoverable,
            stage: .archived,
            backups: [sampleBackup]
        )
        #expect(rec.archiveHealth == .safe)
    }

    @Test func healthLabelsAndIcons() {
        #expect(ArchiveHealth.safe.label == "Safe")
        #expect(ArchiveHealth.inProgress.label == "In Progress")
        #expect(ArchiveHealth.needsAttention.label == "Needs Attention")
        #expect(ArchiveHealth.notApplicable.label == "")

        #expect(!ArchiveHealth.safe.icon.isEmpty)
        #expect(!ArchiveHealth.inProgress.icon.isEmpty)
        #expect(!ArchiveHealth.needsAttention.icon.isEmpty)
        #expect(ArchiveHealth.notApplicable.icon.isEmpty)
    }
}

// MARK: - DetectedPeople Codable Tests

struct DetectedPeopleTests {

    // regression: #46 — VideoRecord ships with empty detectedPeople by default (decoupling additive field)
    @Test func defaultsToEmpty() {
        let rec = VideoRecord()
        #expect(rec.detectedPeople.isEmpty)
    }

    // regression: #46 — Recognition results survive catalog encode/decode round-trip
    @Test func roundTrip() throws {
        let rec = VideoRecord()
        rec.filename = "holiday_1992.mov"
        rec.detectedPeople = ["Donna", "Timmy"]

        let data = try JSONEncoder().encode(VideoRecordDTO(rec))
        let decoded = try JSONDecoder().decode(VideoRecord.self, from: data)

        #expect(decoded.detectedPeople == ["Donna", "Timmy"])
    }

    // regression: #46 — Old catalog files (pre-decouple) decode cleanly: missing detectedPeople → empty array
    @Test func backwardCompatMissingField() throws {
        let rec = VideoRecord()
        rec.filename = "old_catalog_entry.mov"
        let data = try JSONEncoder().encode(VideoRecordDTO(rec))

        // Simulate an old catalog entry that never had the field:
        // remove "detectedPeople" key from the JSON
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "detectedPeople")
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(VideoRecord.self, from: stripped)
        #expect(decoded.detectedPeople.isEmpty)
    }

    // regression: #46 — Empty detectedPeople is omitted from JSON to keep catalog files compact
    @Test func emptyArrayNotEncoded() throws {
        let rec = VideoRecord()
        rec.filename = "no_people.mov"
        rec.detectedPeople = []

        let data = try JSONEncoder().encode(VideoRecordDTO(rec))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Empty array should be omitted to keep catalog JSON compact
        #expect(json["detectedPeople"] == nil)
    }
}

// MARK: - LifecycleStage Tests

struct LifecycleStageTests {

    // regression: #45 — Lifecycle field defaults to .cataloged so existing records flow into the new pipeline
    @Test func defaultIsCataloged() {
        let rec = VideoRecord()
        #expect(rec.lifecycleStage == .cataloged)
    }

    // regression: #45 — Lifecycle stage survives catalog round-trip (Archive tab depends on this)
    @Test func codableRoundTrip() throws {
        let rec = VideoRecord()
        rec.filename = "test.mov"
        rec.lifecycleStage = .archived

        let data = try JSONEncoder().encode(VideoRecordDTO(rec))
        let decoded = try JSONDecoder().decode(VideoRecord.self, from: data)

        #expect(decoded.lifecycleStage == .archived)
    }

    // regression: #45 — Pre-lifecycle catalog files decode cleanly: missing field → .cataloged default
    @Test func backwardCompatMissingField() throws {
        let rec = VideoRecord()
        rec.filename = "legacy.mov"
        let data = try JSONEncoder().encode(VideoRecordDTO(rec))

        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "lifecycleStage")
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(VideoRecord.self, from: stripped)
        #expect(decoded.lifecycleStage == .cataloged)
    }

    @Test func allCasesHaveRawValues() {
        #expect(LifecycleStage.cataloged.rawValue == "Cataloged")
        #expect(LifecycleStage.reviewing.rawValue == "In Triage")
        #expect(LifecycleStage.archived.rawValue == "Archived")
    }
}
