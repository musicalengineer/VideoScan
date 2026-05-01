import Foundation

// MARK: - Media Analyzer
//
// Pure-logic scoring engine that classifies catalog records as junk,
// family candidate, or unclassified based on metadata heuristics.
// No file I/O — works entirely from catalog data already in memory.
//
// Usage:
//   let result = MediaAnalyzer.score(record)
//   record.junkScore = result.junkScore
//   record.junkReasons = result.junkReasons
//   record.mediaDisposition = result.suggestedDisposition

enum MediaAnalyzer {

    struct AnalysisResult {
        let junkScore: Int
        let junkReasons: [String]
        let familyScore: Int
        let familyReasons: [String]
        let suggestedDisposition: MediaDisposition
    }

    // MARK: - Main Entry Point

    static func score(_ rec: VideoRecord) -> AnalysisResult {
        var junkScore = 0
        var junkReasons: [String] = []
        var familyScore = 0
        var familyReasons: [String] = []

        // --- Junk signals (positive = more likely junk) ---

        // Broken / unreadable
        if rec.streamType == .ffprobeFailed {
            junkScore += 5
            junkReasons.append("Probe failed — file may be corrupted")
        }

        if rec.streamType == .noStreams {
            junkScore += 5
            junkReasons.append("No audio or video streams found")
        }

        // Zero or near-zero content
        if rec.durationSeconds == 0 && rec.streamType != .ffprobeFailed {
            junkScore += 5
            junkReasons.append("Zero duration")
        }

        if rec.sizeBytes == 0 {
            junkScore += 5
            junkReasons.append("Zero-byte file")
        }

        // Very short clips (under 3 seconds) — almost always artifacts
        if rec.durationSeconds > 0 && rec.durationSeconds < 3.0 {
            junkScore += 2
            junkReasons.append("Very short (\(String(format: "%.1f", rec.durationSeconds))s)")
        }

        // Audio-only or video-only — check if paired before scoring as junk
        let hasPair = rec.pairedWith != nil || rec.pairGroupID != nil
        if rec.streamType == .audioOnly {
            if hasPair {
                // Has a matched partner — recoverable, not junk
                familyScore += 1
                familyReasons.append("Audio-only with matched video pair — recoverable")
            } else if rec.durationSeconds < 30 {
                junkScore += 3
                junkReasons.append("Short audio-only clip (<30s), no pair found")
            } else {
                junkScore += 1
                junkReasons.append("Audio-only file, no pair found")
            }
        }

        if rec.streamType == .videoOnly && !hasPair {
            junkScore += 1
            junkReasons.append("Video-only file, no audio pair found")
        } else if rec.streamType == .videoOnly && hasPair {
            familyScore += 1
            familyReasons.append("Video-only with matched audio pair — recoverable")
        }

        // Voicemail / VoIP signature
        if let sr = Int(rec.audioSampleRate), sr <= 8000 {
            junkScore += 2
            junkReasons.append("Low audio sample rate (\(rec.audioSampleRate) Hz) — voicemail/VoIP")
        }
        if rec.audioChannels == "1" && rec.audioSampleRate == "8000" {
            junkScore += 1
            junkReasons.append("Mono 8kHz — likely phone recording")
        }

        // Screen recording / screencast signatures
        let screencastResolutions = ["1920x1200", "2560x1440", "2560x1600", "1440x900", "1680x1050"]
        if screencastResolutions.contains(rec.resolution) && rec.streamType == .videoOnly {
            junkScore += 3
            junkReasons.append("Screencast resolution (\(rec.resolution)), no audio")
        }
        if screencastResolutions.contains(rec.resolution) && rec.durationSeconds < 10 {
            junkScore += 2
            junkReasons.append("Short clip at screencast resolution")
        }

        // Avid render / test patterns
        let pathLower = rec.fullPath.lowercased()
        let filenameLower = rec.filename.lowercased()

        if isAvidRenderFile(pathLower: pathLower, filenameLower: filenameLower) {
            junkScore += 3
            junkReasons.append("Avid render/precompute file")
        }

        // FCP scratch / render
        if isFCPRenderFile(pathLower: pathLower) {
            junkScore += 3
            junkReasons.append("Final Cut Pro render/scratch file")
        }

        // System / hidden directory artifacts
        if isSystemArtifact(pathLower: pathLower) {
            junkScore += 4
            junkReasons.append("System/hidden directory artifact")
        }

        // Test / temp / sample filename patterns
        if isTestOrTempFile(filenameLower: filenameLower) {
            junkScore += 2
            junkReasons.append("Filename suggests test/temp/sample content")
        }

        // NLE transition / render output patterns (xfade, dissolve, wipe, etc.)
        if isTransitionOrRenderFile(filenameLower: filenameLower) {
            junkScore += 3
            junkReasons.append("Filename suggests NLE transition or render output")
        }

        // Truncated file — size much smaller than expected for bitrate x duration
        if let truncated = isTruncated(rec), truncated {
            junkScore += 3
            junkReasons.append("File appears truncated (size << expected)")
        }

        // Duplicate extra copy (already classified by DuplicateDetector)
        if rec.duplicateDisposition == .extraCopy {
            junkScore += 3
            junkReasons.append("Duplicate extra copy (original exists)")
        }

        // Tiny resolution — too small for useful face detection
        if isTinyResolution(rec) {
            junkScore += 2
            junkReasons.append("Very low resolution — below usable threshold")
        }

        // --- Family candidate signals (positive = more likely family) ---

        // Home video codec signatures
        let codecScore = homeVideoCodecScore(rec)
        if codecScore.score > 0 {
            familyScore += codecScore.score
            familyReasons.append(codecScore.reason)
        }

        // Reasonable duration for home video (30s - 2h)
        if rec.durationSeconds >= 30 && rec.durationSeconds <= 7200 {
            if rec.streamType == .videoAndAudio {
                familyScore += 1
                familyReasons.append("Video+audio, reasonable duration")
            }
        }

        // Long-form content (>2 min) with video+audio is likely intentional
        if rec.durationSeconds > 120 && rec.streamType == .videoAndAudio {
            familyScore += 1
            familyReasons.append("Long-form video (\(Int(rec.durationSeconds / 60)) min)")
        }

        // Path hints suggesting family content
        let familyPathScore = familyPathSignals(pathLower: pathLower)
        if familyPathScore.score > 0 {
            familyScore += familyPathScore.score
            familyReasons.append(familyPathScore.reason)
        }

        // Standard camcorder resolutions
        if isCamcorderResolution(rec) {
            familyScore += 1
            familyReasons.append("Standard camcorder resolution (\(rec.resolution))")
        }

        // --- Classify ---

        // Check if this is a paired audio/video-only file → recoverable
        let isPairedHalf = hasPair &&
            (rec.streamType == .audioOnly || rec.streamType == .videoOnly)

        let disposition: MediaDisposition
        if isPairedHalf {
            disposition = .recoverable
        } else if junkScore >= 5 && familyScore < 2 {
            disposition = .suspectedJunk
        } else if familyScore >= 3 && junkScore < 3 {
            disposition = .important
        } else {
            disposition = .unreviewed
        }

        return AnalysisResult(
            junkScore: junkScore,
            junkReasons: junkReasons,
            familyScore: familyScore,
            familyReasons: familyReasons,
            suggestedDisposition: disposition
        )
    }

    // MARK: - Batch Analysis

    /// Score records and update their dispositions. Only overwrites
    /// records that are currently `.unreviewed` — user-set dispositions
    /// are never touched. Pass a subset to analyze selected files only.
    static func analyzeAll(_ records: [VideoRecord]) -> AnalysisSummary {
        var classified = 0
        var junkCount = 0
        var familyCount = 0
        var recoverableCount = 0
        var unchanged = 0

        for rec in records {
            let result = score(rec)
            rec.junkScore = result.junkScore
            rec.junkReasons = result.junkReasons

            if rec.mediaDisposition == .unreviewed {
                rec.mediaDisposition = result.suggestedDisposition
                if result.suggestedDisposition != .unreviewed {
                    classified += 1
                }
                if result.suggestedDisposition == .suspectedJunk { junkCount += 1 }
                if result.suggestedDisposition == .important { familyCount += 1 }
                if result.suggestedDisposition == .recoverable { recoverableCount += 1 }
            } else {
                unchanged += 1
            }
        }

        return AnalysisSummary(
            total: records.count,
            classified: classified,
            junkCount: junkCount,
            familyCount: familyCount,
            recoverableCount: recoverableCount,
            unchanged: unchanged,
            stillUnreviewed: records.filter { $0.mediaDisposition == .unreviewed }.count
        )
    }

    struct AnalysisSummary {
        let total: Int
        let classified: Int
        let junkCount: Int
        let familyCount: Int
        let recoverableCount: Int
        let unchanged: Int
        let stillUnreviewed: Int
    }

    // MARK: - Junk Heuristics

    private static func isAvidRenderFile(pathLower: String, filenameLower: String) -> Bool {
        // Avid render patterns: PHYSV01, precompute, sequence-named MXF
        if filenameLower.hasPrefix("physv01") { return true }
        if pathLower.contains("precompute") { return true }
        if pathLower.contains("avid mediafiles") && filenameLower.contains("sequence") { return true }
        // Numbered Avid render: 00000.PHYSV01.xxx.mxf
        if filenameLower.hasSuffix(".mxf") && filenameLower.contains("physv01") { return true }
        return false
    }

    private static func isFCPRenderFile(pathLower: String) -> Bool {
        if pathLower.contains("render files") { return true }
        if pathLower.contains(".fcpbundle") && pathLower.contains("render") { return true }
        if pathLower.contains("fcp scratch") { return true }
        if pathLower.contains("final cut") && pathLower.contains("render") { return true }
        return false
    }

    private static func isSystemArtifact(pathLower: String) -> Bool {
        let patterns = [
            ".spotlight-v100", ".fseventsd", ".trashes", ".temporaryitems",
            ".ds_store", "$recycle.bin", "system volume information",
            ".trash", "thumbs.db", "desktop.ini"
        ]
        return patterns.contains { pathLower.contains($0) }
    }

    private static func isTestOrTempFile(filenameLower: String) -> Bool {
        let prefixes = ["test_", "test-", "sample_", "sample-", "tmp_", "tmp-",
                        "untitled", "temp_", "temp-", "new recording"]
        let contains = ["_test.", "-test.", "_sample.", "_temp.", "_tmp."]
        if prefixes.contains(where: { filenameLower.hasPrefix($0) }) { return true }
        if contains.contains(where: { filenameLower.contains($0) }) { return true }
        return false
    }

    /// NLE-rendered transition or export-artifact filenames. These are almost
    /// always intermediate render output, not original camera media. Patterns
    /// are conservative — match on word-boundary delimiters so a clip named
    /// "wedding_dissolve_2010" matches but "kid named Wipeout" does not.
    private static func isTransitionOrRenderFile(filenameLower: String) -> Bool {
        // Strict prefixes (file STARTS with these — strong signal)
        let prefixes = [
            "xfade_", "xfade-",
            "crossfade_", "crossfade-", "cross_fade", "cross-fade",
            "dissolve_", "dissolve-",
            "wipe_", "wipe-",
            "transition_", "transition-",
            "fadein_", "fadein-", "fade_in_", "fade-in-",
            "fadeout_", "fadeout-", "fade_out_", "fade-out-",
            "render_", "render-",
            "export_", "export-"
        ]
        if prefixes.contains(where: { filenameLower.hasPrefix($0) }) { return true }

        // Word-boundary delimited middles (e.g., "myedit_xfade_v2.mov")
        let delimited = [
            "_xfade_", "-xfade-", "_xfade.",
            "_crossfade_", "-crossfade-", "_crossfade.",
            "_dissolve_", "-dissolve-", "_dissolve.",
            "_wipe_", "-wipe-", "_wipe.",
            "_transition_", "-transition-", "_transition.",
            "_fadein_", "_fade_in_", "_fadeout_", "_fade_out_",
            "_render_", "-render-", "_render.",
            "_export_", "-export-", "_export.",
            "_proxy_", "-proxy-", "_proxy."
        ]
        if delimited.contains(where: { filenameLower.contains($0) }) { return true }

        return false
    }

    private static func isTruncated(_ rec: VideoRecord) -> Bool? {
        // Need both bitrate and duration to estimate expected size
        guard rec.durationSeconds > 0, rec.sizeBytes > 0 else { return nil }
        // Parse total bitrate (e.g., "25000000" or "25 Mb/s")
        let bitrateStr = rec.totalBitrate.replacingOccurrences(of: " ", with: "")
        guard let bitrate = Double(bitrateStr), bitrate > 0 else { return nil }
        let expectedBytes = (bitrate / 8.0) * rec.durationSeconds
        // If actual size is less than 50% of expected, it's likely truncated
        return Double(rec.sizeBytes) < expectedBytes * 0.5
    }

    private static func isTinyResolution(_ rec: VideoRecord) -> Bool {
        let parts = rec.resolution.lowercased().split(separator: "x")
        guard parts.count == 2,
              let w = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let h = Int(parts[1].trimmingCharacters(in: .whitespaces))
        else { return false }
        return w * h < 160 * 120
    }

    // MARK: - Family Candidate Heuristics

    private static func homeVideoCodecScore(_ rec: VideoRecord) -> (score: Int, reason: String) {
        let codec = rec.videoCodec.lowercased()
        let res = rec.resolution
        let audio = rec.audioCodec.lowercased()

        // Mini-DV camcorder: dvvideo, 720x480, interlaced, PCM audio
        if codec == "dvvideo" {
            return (3, "DV camcorder codec — likely 1995-2008 home video")
        }

        // AVCHD camcorder: mpeg2video or h264, 1440x1080 or 1920x1080, interlaced
        if codec == "mpeg2video" && (res == "1440x1080" || res == "1920x1080") {
            return (3, "MPEG-2 HD — likely AVCHD camcorder (2007-2014)")
        }

        // iPhone / modern phone H.264
        if codec == "h264" && (res == "1920x1080" || res == "1280x720") &&
           !audio.isEmpty && audio != "none" {
            return (2, "H.264 HD with audio — likely phone or modern camera")
        }

        // HEVC / modern iPhone
        if codec == "hevc" && !audio.isEmpty {
            return (2, "HEVC with audio — likely modern phone/camera")
        }

        // Old digicam video mode
        if codec == "mjpeg" && rec.durationSeconds > 5 {
            return (1, "MJPEG — possibly old digital camera video mode")
        }

        // ProRes — could be Avid/FCP export of family content
        if codec.contains("prores") && rec.durationSeconds > 30 {
            return (1, "ProRes — may be edited family content")
        }

        return (0, "")
    }

    private static func familyPathSignals(pathLower: String) -> (score: Int, reason: String) {
        // Strong family-content indicators
        let strongTokens = ["vacation", "birthday", "christmas", "wedding",
                            "thanksgiving", "easter", "graduation", "recital",
                            "family", "holiday", "reunion"]
        for token in strongTokens {
            if pathLower.contains(token) {
                return (2, "Path contains '\(token)' — likely family event")
            }
        }

        // Name tokens (family member names boost score)
        let nameTokens = ["donna", "rick", "tim", "dan", "mike", "matt"]
        for name in nameTokens {
            if pathLower.contains("/\(name)/") || pathLower.contains("/\(name) ") ||
               pathLower.contains(" \(name)/") {
                return (2, "Path contains family name '\(name)'")
            }
        }

        // Year tokens in path (1990-2025 range suggests organized family archive)
        let yearPattern = try? NSRegularExpression(pattern: "\\b(199\\d|200\\d|201\\d|202[0-5])\\b")
        let range = NSRange(pathLower.startIndex..., in: pathLower)
        if let match = yearPattern?.firstMatch(in: pathLower, range: range) {
            let year = (pathLower as NSString).substring(with: match.range)
            return (1, "Path contains year '\(year)' — organized archive")
        }

        return (0, "")
    }

    private static func isCamcorderResolution(_ rec: VideoRecord) -> Bool {
        let camcorderRes = [
            "720x480", "720x486", "720x576",          // SD (NTSC/PAL)
            "1440x1080", "1920x1080", "1280x720",     // HD
            "3840x2160", "4096x2160"                   // 4K
        ]
        return camcorderRes.contains(rec.resolution)
    }
}
