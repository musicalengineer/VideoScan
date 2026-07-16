// TrimTestSupport.swift
// Shared fixtures for the Trim Master five-dimension suite. Media
// generation reuses CleanupTestMedia (same synthetic testsrc+sine
// convention, `test_` prefix, temp-dir output) — this file adds only the
// trim-specific pieces: a record factory that populates the fields the
// trim path reads (videoCodec drives the accuracy class), and a video
// packet counter for the frame-exactness assertions.

import Foundation
@testable import VideoScan

// MARK: - Record factory

/// Minimal catalog record pointing at a real on-disk fixture, shaped the
/// way TrimJob reads it: fullPath / durationSeconds / videoCodec /
/// streamTypeRaw / sizeBytes drive preflight, classification, and the
/// free-space estimate.
@MainActor
func makeTrimSourceRecord(path: String,
                          durationSeconds: Double,
                          videoCodec: String,
                          streamType: StreamType = .videoAndAudio) -> VideoRecord {
    let r = VideoRecord()
    r.filename = (path as NSString).lastPathComponent
    r.fullPath = path
    r.directory = (path as NSString).deletingLastPathComponent
    r.durationSeconds = durationSeconds
    r.videoCodec = videoCodec
    r.streamTypeRaw = streamType.rawValue
    let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
    r.sizeBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
    return r
}

// MARK: - Packet counting (frame-exactness oracle)

enum TrimTestProbe {

    /// Number of video packets in the file — for intra-only codecs this
    /// IS the frame count, so an exact-cut assertion can be made in
    /// frames rather than fuzzy seconds.
    static func videoPacketCount(_ path: String) throws -> Int {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: CleanupTestMedia.ffprobePath)
        proc.arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-count_packets",
            "-show_entries", "stream=nb_read_packets",
            "-of", "csv=p=0",
            path
        ]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        // MXF probes emit a trailing comma ("85,") — keep only the
        // leading digit run.
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(while: \.isNumber) ?? ""
        guard let n = Int(text) else {
            throw CleanupTestMedia.CleanupFixtureError.ffprobeFailed(
                status: proc.terminationStatus, stderr: "unparseable packet count: \(text)")
        }
        return n
    }

    /// Raw "pts_time,flags" CSV of the first `sampleCount` video packets —
    /// feed to TrimKeyframeProbe.allSampledPacketsAreKeyframes.
    static func keyframeFlagCSV(_ path: String, sampleCount: Int = 30) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: CleanupTestMedia.ffprobePath)
        proc.arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-read_intervals", "%+#\(sampleCount)",
            "-show_entries", "packet=pts_time,flags",
            "-of", "csv=p=0",
            path
        ]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
