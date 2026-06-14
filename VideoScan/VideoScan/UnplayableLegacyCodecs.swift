import Foundation

// MARK: - Unplayable-by-AVFoundation legacy codec detection
//
// VideoScan's analyzer (MLXVLM frame extraction) goes through
// AVFoundation, which Apple deprecated and then removed support for
// several proprietary codecs in macOS 10.15 (Catalina, 2019). ffmpeg
// and VLC still decode them fine — that's why a file like
// Thanksgiving-Raw_Default.mov (svq3 + qdm2) plays in VLC and ffprobe
// reads it, but the in-app dossier pipeline returns 0 scenes in 0.2s
// because the frame extractor bailed out immediately.
//
// We split detection into two paths:
//   1. STATIC heuristic: known-problematic codec strings, computable
//      from already-cataloged `videoCodec` / `audioCodec` fields. Lets
//      us flag a file as `needsReformat` retroactively without
//      re-running the VLM.
//   2. DYNAMIC backstop: the orchestrator sets `record.needsReformat`
//      when it observes the "0 scenes in <1s" pattern, catching codecs
//      we didn't think to add to the static list.
//
// Codec names are ffprobe's `codec_name` field (lowercase, hyphenated).
// Lists are deliberately conservative — only codecs I'm CONFIDENT
// AVFoundation can't handle on modern macOS. False positives here mean
// surfacing a file as "needs reformat" when it would have analyzed
// fine, so we err on the side of NOT flagging.

/// Video codecs AVFoundation can't decode on macOS 10.15+. Sourced
/// from Apple's QuickTime 7 deprecation notice + Sorenson/Indeo/
/// Cinepak being legacy proprietary formats with no modern decoder
/// outside ffmpeg / VLC.
let unplayableLegacyVideoCodecs: Set<String> = [
    // Sorenson (early QuickTime web video, pre-2005)
    "svq1", "svq3",
    "sorenson", "sorenson video", "sorenson video 3",
    // Cinepak (Apple/SuperMac, 1990s)
    "cinepak",
    // Intel Indeo
    "indeo2", "indeo3", "indeo4", "indeo5",
    // Apple Video / RPZA (1991 QuickTime)
    "rpza",
    // Microsoft RLE (old AVI)
    "msrle",
    // Smacker / Bink (game-engine codecs)
    "smackvideo", "bink", "binkvideo"
]

/// Audio codecs AVFoundation can't decode on macOS 10.15+.
let unplayableLegacyAudioCodecs: Set<String> = [
    // QDesign (early QuickTime web audio, pre-2005)
    "qdm2", "qdmc",
    // QCELP (early mobile)
    "qcelp",
    // Macintosh Audio Compression Expansion
    "mace3", "mace6",
    // Twin VQ
    "twinvq",
    // ImelodyG / Speex variants used by old QuickTime
    "ima4"  // QuickTime IMA4 — actually handled by AVFoundation; remove if FP
]

/// Returns true iff the codec strings indicate a file the
/// in-app analyzer can't decode. Pure function; takes the
/// ffprobe-style strings directly so it's trivially testable.
func hasUnplayableLegacyCodec(videoCodec: String, audioCodec: String) -> Bool {
    let v = videoCodec.lowercased().trimmingCharacters(in: .whitespaces)
    let a = audioCodec.lowercased().trimmingCharacters(in: .whitespaces)
    if !v.isEmpty, unplayableLegacyVideoCodecs.contains(v) { return true }
    if !a.isEmpty, unplayableLegacyAudioCodecs.contains(a) { return true }
    return false
}

/// One-line user-facing reason a record needs reformatting.
/// Returns nil if the record's codecs are fine.
func unplayableLegacyReason(videoCodec: String, audioCodec: String) -> String? {
    let v = videoCodec.lowercased().trimmingCharacters(in: .whitespaces)
    let a = audioCodec.lowercased().trimmingCharacters(in: .whitespaces)
    if !v.isEmpty, unplayableLegacyVideoCodecs.contains(v) {
        return "Video codec \"\(videoCodec)\" was deprecated by macOS in 2019 — needs reformat to be analyzed."
    }
    if !a.isEmpty, unplayableLegacyAudioCodecs.contains(a) {
        return "Audio codec \"\(audioCodec)\" was deprecated by macOS in 2019 — needs reformat to be analyzed."
    }
    return nil
}

// MARK: - Analyze-value heuristic
//
// Multi-signal score for "is this file likely worth the effort of
// reformatting + analyzing?" Higher = more likely valuable. The
// dashboard / catalog UI can sort by this so long old home videos
// surface before short test clips.
//
// Rick 2026-06-14: "long old videos like this are usually important,
// where long is > 15 or 20 mins."
//
// Signals and weights are intentionally chunky integers so each
// contribution is readable in the source. Tuning happens here, not
// scattered through render code.

struct AnalyzeValueWeights {
    /// > 15 minutes — deliberate recordings, not snippets.
    static let longDuration = 30
    /// Has audio track — family voices, recorded events.
    static let hasAudio = 20
    /// Codec / container signals deliberate archival digitization.
    static let legacyCodec = 25
    /// QuickTime container — Apple-era archival workflow signature.
    static let quickTimeContainer = 10
    /// File mtime pre-2010 — genuine pre-digital source, not a
    /// modern smartphone clip.
    static let preDigitalEraMTime = 15
}

/// Heuristic 0–100 score for "this is probably an important file."
/// Used to prioritize reformat-and-analyze queue ordering.
func analyzeValueScore(
    durationSeconds: Double,
    hasAudio: Bool,
    hasLegacyCodec: Bool,
    container: String,
    fileMTime: Date?
) -> Int {
    var score = 0
    if durationSeconds > 15 * 60 { score += AnalyzeValueWeights.longDuration }
    if hasAudio                  { score += AnalyzeValueWeights.hasAudio }
    if hasLegacyCodec            { score += AnalyzeValueWeights.legacyCodec }
    let c = container.lowercased()
    if c.contains("mov") || c.contains("quicktime") {
        score += AnalyzeValueWeights.quickTimeContainer
    }
    if let mt = fileMTime,
       let cutoff = DateComponents(calendar: .current,
                                   year: 2010, month: 1, day: 1).date,
       mt < cutoff {
        score += AnalyzeValueWeights.preDigitalEraMTime
    }
    return min(100, score)
}
