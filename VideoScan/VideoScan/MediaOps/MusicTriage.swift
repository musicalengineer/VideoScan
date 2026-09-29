// MusicTriage.swift
// GH #124 layer 2 — pure detection logic for the music-library triage
// suggestion chip ("N files look like music-library audio — review &
// remove?"). Nag-button pattern: the chip PERFORMS the fix on click
// (opens the review sheet whose one button batch-soft-deletes via the
// EXISTING purgeRecords path — no new deletion machinery, existing undo
// banner arms).
//
// PRECISION RULE (pinned by MusicTriageTests — the load-bearing part):
// the chip must NEVER suggest audio that belongs to the video mission:
//   * MXF audio halves — excluded unconditionally by extension. Every
//     orphaned Avid audio essence file is .mxf; music never is.
//   * Correlated audio — anything with a pair link (pairedWith /
//     pairGroupID) is settled A/V history.
//   * Video-adjacent audio — same-stem-as-video via the SAME heuristic
//     correlate uses (CorrelationScorer.filenameCorrelationKey), so a
//     "Wedding1994.wav" next to "Wedding1994.mov" is protected even
//     before correlate has run.
// Only after those vetoes does a record qualify by looking like music:
// audio-only stream shape AND (music-library path marker OR music
// extension). False negatives are fine (the user can still purge
// manually); false positives are the failure mode this file is
// engineered against.
//
// All functions nonisolated + pure — same testability contract as
// CatalogQueries. Cost: one O(n) pass to build the video stem-key set +
// one O(n) pass over audio rows (each doing O(1) set lookups). Budgeted
// at 100k records by MusicTriageTests. Memory: the stem-key set holds
// one short String per video-bearing record (~25k × ~40 B ≈ 1 MB worst
// case on Rick's catalog) — bounded, freed on return.

import Foundation

enum MusicTriage {

    /// Music-file extensions (lowercased). The chip's extension rule —
    /// per the issue: mp3/m4a/ogg/aac/wma. `m4p`/`m4b` added: protected
    /// AAC and audiobooks are pure iTunes-store artifacts that can ONLY
    /// come from a music library. Deliberately does NOT include wav/aif/
    /// flac/caf — those are plausible family-audio capture formats and
    /// qualify only via a library path marker.
    static let musicExtensions: Set<String> = [
        "mp3", "m4a", "m4p", "m4b", "ogg", "aac", "wma"
    ]

    /// Path markers derived from the canonical scan-time skip set
    /// (SkipCategories.musicLibraryDirs) so layer 2 (catalog triage) and
    /// layer 3 (scan prevention) can never drift — a tree the scanner
    /// would skip is a tree the chip flags. Two bundle-shaped markers
    /// ride along because bundles are matched by extension at scan time
    /// but appear as plain path segments in already-cataloged records.
    static let pathMarkers: [String] = {
        var markers = SkipCategories.musicLibraryDirs.map { "/\($0)/" }
        markers.append(".musiclibrary/")   // Music Library.musiclibrary bundle
        markers.append(".itlp/")           // iTunes LP bundle
        return markers
    }()

    /// True if the path walks through an iTunes / Music.app library
    /// tree. Component-bounded contains ("/itunes/") so a family folder
    /// like "/Wedding/Music/" — deliberately NOT a marker — stays clean.
    static func pathLooksLikeMusicLibrary(_ fullPath: String) -> Bool {
        let p = fullPath.lowercased()
        return pathMarkers.contains { p.contains($0) }
    }

    /// The correlation stem-key set for every ACTIVE record that could be
    /// (or become) video: any non-audio-only shape, INCLUDING ffprobeFailed
    /// and noStreams — a damaged Avid video file must still protect its
    /// same-stem audio sibling. Keys are lowercased so the veto is
    /// case-insensitive like the rest of the filename heuristics.
    static func videoStemKeys(in records: [VideoRecord]) -> Set<String> {
        var keys = Set<String>()
        keys.reserveCapacity(records.count / 4)
        for rec in records where rec.streamType != .audioOnly && !rec.isPurged {
            keys.insert(CorrelationScorer.filenameCorrelationKey(rec.filename).lowercased())
        }
        return keys
    }

    /// The chip's candidate set: IDs of active records that look like
    /// music-library audio AND survive every precision veto. Order
    /// follows the input records array (stable for the review sheet).
    static func candidateIDs(in records: [VideoRecord]) -> [UUID] {
        let videoKeys = videoStemKeys(in: records)
        var out: [UUID] = []
        for rec in records {
            guard candidateVerdict(rec, videoStemKeys: videoKeys) else { continue }
            out.append(rec.id)
        }
        return out
    }

    /// Single-record verdict, exposed for the truth-table tests.
    /// `videoStemKeys` is precomputed by the caller (one pass, not per
    /// record — the O(n²) trap this signature exists to avoid).
    static func candidateVerdict(_ rec: VideoRecord, videoStemKeys: Set<String>) -> Bool {
        // Active records only — purged rows are already gone from the
        // default view, set-aside rows are already handled by Tidy.
        guard !rec.isPurged, !rec.isSetAside else { return false }
        // Stream shape: audio-only, decided by ffprobe/MXF-header
        // evidence, not by extension.
        guard rec.streamType == .audioOnly else { return false }
        // PRECISION VETO 1 — MXF is the Avid essence container; an
        // audio-only MXF is a pair half (found or future), never music.
        guard rec.ext.lowercased() != "mxf" else { return false }
        // PRECISION VETO 2 — correlated audio is settled A/V history.
        guard rec.pairedWith == nil, rec.pairGroupID == nil else { return false }
        // PRECISION VETO 3 — same-stem-as-video (correlate's own key).
        let key = CorrelationScorer.filenameCorrelationKey(rec.filename).lowercased()
        guard !videoStemKeys.contains(key) else { return false }
        // Qualifier: looks like music — library path OR music extension.
        return musicExtensions.contains(rec.ext.lowercased())
            || pathLooksLikeMusicLibrary(rec.fullPath)
    }
}
