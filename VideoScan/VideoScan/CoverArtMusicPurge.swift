import Foundation

// MARK: - Cover-Art Music Purge (catalog maintenance, 2026-07-20)
//
// One-time (re-runnable) cleanup for a specific class of mis-cataloged
// records: commercial music files (iTunes MP3/M4A/M4P purchases) whose
// EMBEDDED COVER ART registered as a "video" stream during scanning, so
// they landed in the catalog as if they were home video. A read-only
// dry-run of Rick's live catalog counted exactly 2,231 such records —
// all carrying a fake video codec of `mjpeg` (2,146) or `png` (85).
//
// The scanner fix already on main (545258f, attached_pic classifier)
// stops NEW ones. This purge removes the EXISTING strays. Files on disk
// are never touched — only catalog records are removed.
//
// The identification predicate is a PURE function of catalog metadata
// (ext + videoCodec + streamType) — zero filesystem calls — so it is
// trivially unit-testable and is reused by BOTH the live count shown in
// the confirmation sheet and the removal itself. One rule, one code
// path: the count you confirm is exactly the set that gets removed.
//
// Why the three-part AND protects real footage:
//   1. ext ∈ audioExtensions — a real Motion-JPEG `.mov`/`.avi` has a
//      NON-audio extension, so it never matches. Only files whose
//      extension already says "this is audio" are eligible.
//   2. videoCodec ∈ {mjpeg, png} — the two codecs embedded cover art
//      actually reports. A music file with a real (non-cover-art) video
//      stream would be a genuine music video, not this class.
//   3. streamType is video (videoAndAudio / videoOnly) — records already
//      classified audioOnly are left alone; they're correct as-is.
//
// (Swift `enum` with only static members ≈ a C++ namespace — no
// instances, just a scoping shell for free functions.)

enum CoverArtMusicPurge {

    /// The two fake video codecs embedded cover art reports. Lowercased;
    /// compare against `videoCodec.lowercased()`.
    static let coverArtCodecs: Set<String> = ["mjpeg", "png"]

    /// PURE predicate — true iff `record` is a cover-art-music purge
    /// candidate. All three conditions must hold (see file header):
    ///   • extension is an audio extension, AND
    ///   • video codec is a cover-art codec (mjpeg / png), AND
    ///   • stream type is video (videoAndAudio or videoOnly).
    ///
    /// No filesystem access; safe to call over the whole catalog on the
    /// main actor. Reused by the count and the removal.
    static func isCandidate(_ record: VideoRecord) -> Bool {
        // 1. Audio extension gate — protects real .mov/.avi motion-JPEG.
        guard AnalysisScope.audioExtensions.contains(record.ext.lowercased()) else {
            return false
        }
        // 2. Cover-art codec gate.
        guard coverArtCodecs.contains(record.videoCodec.lowercased()) else {
            return false
        }
        // 3. Stream type must be video — leave already-audioOnly rows alone.
        switch record.streamType {
        case .videoAndAudio, .videoOnly:
            return true
        case .audioOnly, .noStreams, .ffprobeFailed:
            return false
        }
    }

    /// Every matching record in `records`. Order preserved.
    static func candidates(in records: [VideoRecord]) -> [VideoRecord] {
        records.filter(isCandidate)
    }

    /// IDs of every matching record — the removal key set. `Set` so the
    /// removal pass is O(1) per record.
    static func candidateIDs(in records: [VideoRecord]) -> Set<UUID> {
        var ids = Set<UUID>()
        for r in records where isCandidate(r) { ids.insert(r.id) }
        return ids
    }

    /// Count of matching records. Cheap single pass — safe to call from a
    /// view body that needs the live badge/confirmation number.
    static func count(in records: [VideoRecord]) -> Int {
        var n = 0
        for r in records where isCandidate(r) { n += 1 }
        return n
    }
}
