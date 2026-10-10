import Foundation

// MARK: - Catalog-wide metadata scan candidate selection
//
// Pure helpers that pick which catalog records are eligible for a
// catalog-wide caption / dossier run. Gates, in order:
//
//   - lifecycle stage — per pool (below).
//   - purgedAt == nil — never offer to re-process a record the user
//     has explicitly removed.
//   - setAsideReason == nil — set-aside cruft is out of every pipeline.
//   - mediaDisposition != .confirmedJunk — Rick 2026-06-13: junk is
//     a deliberate "do not analyze, just waiting to be culled" state.
//   - !drmProtected — ciphertext would eat hours of Whisper.
//   - file lives under a reachable scan target — only what we can
//     actually open. Offline volumes queue automatically for the next
//     run once they're mounted again.
//
// TWO POOLS, two stage sets:
//
//   * `LifecycleStage.liveMediaStages` {Cataloged, Workbench} — the
//     single-prompt caption sweep (2026-06-04 roadmap, Q5 option c:
//     "live media we might still consume"). Unchanged.
//   * `LifecycleStage.dossierStages` adds {Archived, In Triage} — Rick
//     2026-10-10: Dossier (captions + transcript) also analyzes archived
//     and in-triage media. It is read-only analysis that writes catalog
//     metadata only; the archived-row write rule lives in applyDossier
//     and the orchestrator (`VideoScanModel.isDossierReadOnly`). Before
//     this, every FamilyArchive master was dropped here, because Promote
//     creates archive copies as `.archived`
//     (docs/design/segments_and_content_coverage_2026_10_10.md §2).
//     Trashed and Deleted stay out.
//
// Filtering by *video presence* (streamType) is left to the per-
// engine caller because captioning and audio-transcription have
// different requirements (caption needs video frames; transcript
// needs audio). Doing it here would conflate them.
//
// (For Rick: a `Set<LifecycleStage>` constant is the C++ equivalent of a
// `static const std::unordered_set<Stage>`; `contains` is O(1).)

extension LifecycleStage {
    /// The caption sweep's pool: live media only (2026-06-04, Q5c).
    nonisolated static let liveMediaStages: Set<LifecycleStage> = [.cataloged, .workbench]

    /// Dossier's pool (Rick 2026-10-10): live media plus Archived and In
    /// Triage. Trashed / Deleted are never analyzed.
    nonisolated static let dossierStages: Set<LifecycleStage> = [.cataloged, .workbench, .reviewing, .archived]
}

/// Where a record stands in the Dossier pool, by stage and by the
/// needs-reformat flag — the ONE answer the dashboard coverage
/// (`CatalogCoverage`) and the Analyze coverage (`AnalyzeCoverageInput`)
/// read, so "eligible" means what the batch will actually process.
/// (≈ a C++ `enum class` with a constructor from a record.)
enum DossierPoolStatus: Equatable, Sendable {
    /// In the pool and due (or done).
    case admitted
    /// In the pool by stage, but flagged needs-reformat with no dossier
    /// yet: batches skip it until an explicit retry.
    case awaitingReformat
    /// Trashed / Deleted — never analyzed.
    case retired

    nonisolated init(_ r: VideoRecord) {
        if !LifecycleStage.dossierStages.contains(r.lifecycleStage) {
            self = .retired
        } else if r.needsReformat && r.dossierProcessedAt == nil {
            self = .awaitingReformat
        } else {
            self = .admitted
        }
    }
}

/// Every gate except reachability: stage, purge, set-aside, junk, DRM.
/// Shared by the candidate filters and the admission tally so the two can
/// never disagree.
nonisolated func pfMetadataCandidateIsEligible(
    _ rec: VideoRecord,
    admitting stages: Set<LifecycleStage>
) -> Bool {
    // Lifecycle gate — per pool.
    guard stages.contains(rec.lifecycleStage) else { return false }
    // Never re-process a purged record.
    guard rec.purgedAt == nil else { return false }
    // Set-aside records (video-only catalog scope, 2026-07-15) are out
    // of every analysis pipeline — hidden cruft, not work items.
    guard rec.setAsideReason == nil else { return false }
    // Junk is a "do not analyze" state — the user has already decided
    // to cull these.
    guard rec.mediaDisposition != .confirmedJunk else { return false }
    // DRM-protected files (e.g. FairPlay m4v/m4p iTunes purchases) cannot
    // be decoded without authorization. The orchestrator sets
    // drmProtected on first encounter; later runs skip here without
    // paying the probe cost.
    return !rec.drmProtected
}

/// Return the subset of `records` eligible for a catalog-wide
/// metadata scan. `reachableVolumePaths` is the list of scan target
/// search paths whose volumes are currently mounted. `stages` picks the
/// pool; the default is the caption sweep's live-media pool.
///
/// Records whose `fullPath` doesn't start with any reachable target
/// path are excluded — those volumes will be re-scanned automatically
/// the next time the user kicks the operation off.
nonisolated func pfCatalogWideMetadataCandidates(
    records: [VideoRecord],
    reachableVolumePaths: [String],
    admitting stages: Set<LifecycleStage> = LifecycleStage.liveMediaStages
) -> [VideoRecord] {
    // Empty reachability list ⇒ no work — explicit short-circuit
    // avoids matching every record against an empty prefix.
    let prefixes = reachableVolumePaths.filter { !$0.isEmpty }
    guard !prefixes.isEmpty else { return [] }
    return records.filter { rec in
        pfMetadataCandidateIsEligible(rec, admitting: stages)
            && prefixes.contains { rec.fullPath.hasPrefix($0) }
    }
}

/// What a Dossier candidate pass admitted and why the rest stayed out —
/// the START line's "N Archived + M In Triage admitted; K offline" so the
/// run never silently shrinks (design doc §2.4 item 3).
struct DossierCandidateSelection {
    /// Eligible AND on a reachable volume — the work list.
    var candidates: [VideoRecord] = []
    /// Of `candidates`, how many are Archived / In Triage (newly admitted
    /// 2026-10-10).
    var archived = 0
    var inTriage = 0
    /// Eligible by every gate but on a volume that is not connected:
    /// skipped with a reason, never counted as failed.
    var offline = 0
    /// Live (not purged / set aside) records whose stage keeps them out:
    /// Trashed / Deleted.
    var notEligibleByStage = 0
}

/// One pass over `records`: Dossier's candidate list plus the admission
/// tally. O(records × reachable prefixes); no disk I/O.
nonisolated func pfDossierCandidateSelection(
    records: [VideoRecord],
    reachableVolumePaths: [String]
) -> DossierCandidateSelection {
    let prefixes = reachableVolumePaths.filter { !$0.isEmpty }
    let stages = LifecycleStage.dossierStages
    var out = DossierCandidateSelection()
    for rec in records {
        guard pfMetadataCandidateIsEligible(rec, admitting: stages) else {
            if rec.purgedAt == nil, rec.setAsideReason == nil, !stages.contains(rec.lifecycleStage) {
                out.notEligibleByStage += 1
            }
            continue
        }
        guard prefixes.contains(where: { rec.fullPath.hasPrefix($0) }) else {
            out.offline += 1
            continue
        }
        out.candidates.append(rec)
        switch rec.lifecycleStage {
        case .archived: out.archived += 1
        case .reviewing: out.inTriage += 1
        default: break
        }
    }
    return out
}

/// Dossier's candidate list (the selection without the tally).
nonisolated func pfDossierCandidates(
    records: [VideoRecord],
    reachableVolumePaths: [String]
) -> [VideoRecord] {
    pfDossierCandidateSelection(records: records, reachableVolumePaths: reachableVolumePaths).candidates
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
