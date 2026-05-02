import Testing
import Foundation
@testable import VideoScan

// Shared test helpers used across multiple test files.

/// Actor for counting concurrent tasks in async tests.
actor TestCounter {
    private var value = 0

    func increment() -> Int {
        value += 1
        return value
    }

    func decrement() {
        value -= 1
    }
}

/// Factory for creating VideoRecord instances pre-populated with duplicate metadata.
func makeDuplicateRecord(
    filename: String,
    streamType: StreamType,
    sizeBytes: Int64,
    durationSeconds: Double,
    partialMD5: String,
    resolution: String = "",
    videoCodec: String = "",
    audioCodec: String = "",
    timecode: String = ""
) -> VideoRecord {
    let record = VideoRecord()
    record.filename = filename
    record.streamTypeRaw = streamType.rawValue
    record.sizeBytes = sizeBytes
    record.durationSeconds = durationSeconds
    record.duration = Formatting.duration(durationSeconds)
    record.partialMD5 = partialMD5
    record.resolution = resolution
    record.videoCodec = videoCodec
    record.audioCodec = audioCodec
    record.audioChannels = audioCodec.isEmpty ? "" : "2"
    record.audioSampleRate = audioCodec.isEmpty ? "" : "48000 Hz"
    record.timecode = timecode
    record.isPlayable = "Yes"
    return record
}

/// Resolves the path to tests/fixtures/videos/ from any test file.
func testFixturesDir(from filePath: String = #filePath) -> String {
    let repoRoot = URL(fileURLWithPath: filePath)
        .deletingLastPathComponent()   // VideoScanTests/
        .deletingLastPathComponent()   // VideoScan/
        .deletingLastPathComponent()   // VideoScan/ (project)
    return repoRoot.appendingPathComponent("tests/fixtures/videos").path
}
