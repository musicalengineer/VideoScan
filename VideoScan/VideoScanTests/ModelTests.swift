import Testing
import Foundation
@testable import VideoScan

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
        #expect(CatalogTargetStatus.idle.isActive == false)
        #expect(CatalogTargetStatus.complete.isActive == false)
        #expect(CatalogTargetStatus.stopped.isActive == false)
        #expect(CatalogTargetStatus.error.isActive == false)
    }

    @Test func isPaused() {
        #expect(CatalogTargetStatus.paused.isPaused == true)
        #expect(CatalogTargetStatus.scanning.isPaused == false)
    }

    @Test func isIdle() {
        #expect(CatalogTargetStatus.idle.isIdle == true)
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

    @Test func allCasesExist() {
        let engines = RecognitionEngine.allCases
        #expect(engines.count == 4)
        #expect(engines.contains(.vision))
        #expect(engines.contains(.arcface))
        #expect(engines.contains(.dlib))
        #expect(engines.contains(.hybrid))
    }

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

    @Test func storeDirIsUnderApplicationSupport() {
        let dir = POIStorage.storeDir
        #expect(dir.path.contains("Application Support"))
        #expect(dir.path.contains("VideoScan"))
        #expect(dir.lastPathComponent == "POI")
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
