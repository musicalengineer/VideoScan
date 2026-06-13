import Foundation

// MARK: - Catalog-wide metadata scan candidate selection
//
// Pure helper that picks which catalog records are eligible for a
// catalog-wide caption / transcription run. Per the 2026-06-04
// roadmap decisions (Q5 option c):
//
//   - lifecycleStage in {Cataloged, Workbench} — skips Archived,
//     Deleted, Trashed, In Triage. The intent is "live media we
//     might still consume", not media already retired.
//   - purgedAt == nil — never offer to re-process a record the user
//     has explicitly removed.
//   - mediaDisposition != .confirmedJunk — Rick 2026-06-13: junk is
//     a deliberate "do not analyze, just waiting to be culled" state.
//     Pre-rename it was being analyzed and wasting hours of Whisper
//     time on files the user had already decided to delete.
//   - file lives under a reachable scan target — only what we can
//     actually open. Offline volumes queue automatically for the next
//     run once they're mounted again.
//
// Filtering by *video presence* (streamType) is left to the per-
// engine caller because captioning and audio-transcription have
// different requirements (caption needs video frames; transcript
// needs audio). Doing it here would conflate them.

/// Return the subset of `records` eligible for a catalog-wide
/// metadata scan. `reachableVolumePaths` is the list of scan target
/// search paths whose volumes are currently mounted.
///
/// Records whose `fullPath` doesn't start with any reachable target
/// path are excluded — those volumes will be re-scanned automatically
/// the next time the user kicks the operation off.
nonisolated func pfCatalogWideMetadataCandidates(
    records: [VideoRecord],
    reachableVolumePaths: [String]
) -> [VideoRecord] {
    // Empty reachability list ⇒ no work — explicit short-circuit
    // avoids matching every record against an empty prefix.
    guard !reachableVolumePaths.isEmpty else { return [] }
    let prefixes = reachableVolumePaths.filter { !$0.isEmpty }
    guard !prefixes.isEmpty else { return [] }

    return records.filter { rec in
        // Lifecycle gate — only live media.
        let stage = rec.lifecycleStage
        guard stage == .cataloged || stage == .workbench else { return false }
        // Never re-process a purged record.
        guard rec.purgedAt == nil else { return false }
        // Junk is a "do not analyze" state — the user has already
        // decided to cull these. Analyzing them wastes Whisper time
        // (potentially hours on bad audio) and inflates the dial's
        // Remaining count with files that should never be on the work
        // list to begin with.
        guard rec.mediaDisposition != .confirmedJunk else { return false }
        // Reachable volume.
        return prefixes.contains { rec.fullPath.hasPrefix($0) }
    }
}

/// Sub-filter for the captioning engine: candidates that have video
/// frames. Captioning the audio-only stream of an MXF would just
/// produce N captions of "(black frame)".
nonisolated func pfCatalogWideCaptionCandidates(
    _ candidates: [VideoRecord]
) -> [VideoRecord] {
    candidates.filter { r in
        r.streamType == .videoAndAudio || r.streamType == .videoOnly
    }
}

/// Sub-filter for the transcription engine: candidates that have an
/// audio track. Transcribing a video-only file is wasted Whisper time.
nonisolated func pfCatalogWideTranscriptCandidates(
    _ candidates: [VideoRecord]
) -> [VideoRecord] {
    candidates.filter { r in
        r.streamType == .videoAndAudio || r.streamType == .audioOnly
    }
}
