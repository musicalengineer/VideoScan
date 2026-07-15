import Foundation
import os

// MARK: - Catalog-scope gate (video-only catalog, 2026-07-15)
//
// The post-scan half of Rick's video-only-catalog directive. The walker
// already skipped stills and music BEFORE any per-file I/O
// (FilesystemWalker + CatalogScopePolicy.extensionAlwaysExcluded); what
// reaches this gate is the probed record set, from which AMBIGUOUS AUDIO
// (wav/aif/…, audio-only MXF, anything that probed audio-only) is
// admitted only with strict evidence of belonging to video.
//
// Evidence = the existing Correlate machinery's pairing bar — see
// CatalogScopeEvidence in CatalogScopePolicy.swift for the exact tiers.
// The scoring runs OFF the main actor over Sendable snapshots (the
// catalog is ~103k records; the pooling/scoring loop must never ride the
// UI thread — Approachable Concurrency note: a plain `nonisolated async`
// would run on the CALLER's actor, hence `@concurrent`).
//
// HARD INVARIANT: any record that is already part of a recovered/
// correlated/combined MXF pair — or whose same-path predecessor in the
// catalog is — is admitted WITHOUT classification (before scoring).
// Pair carryover in commitScanResults rewires the pair onto the fresh
// instance; dropping it here would orphan the partner.
//
// Excluded files are NOT cataloged (they are re-dropped identically on
// every rescan, so nothing creeps back). Files on disk are never
// touched. "Find Missing Audio" (future aggressive-search option) is
// the escape hatch for hunting audio that this bar excluded — it can
// rebuild CatalogScopeEvidence with looser pools without changing these
// rules.

let catalogScopeLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "catalogScope")

extension VideoScanModel {

    /// Outcome tallies for one gate pass (summary logging + tests).
    struct CatalogScopeGateOutcome {
        var admitted: [VideoRecord] = []
        /// Ambiguous audio excluded — no video link found.
        var unlinkedAudioExcluded = 0
        /// Ambiguous audio kept — video-linked per the correlator bar.
        var linkedAudioKept = 0
        /// Records admitted without classification because they (or their
        /// same-path predecessor) are part of an existing pair.
        var pairProtectedKept = 0
        /// Belt-and-braces: stills/music that somehow reached the probe
        /// stage (e.g. scope toggled on between walk and finalize).
        var stillOrMusicExcluded = 0
    }

    /// Apply the video-only catalog scope to a finished scan's records,
    /// BEFORE they are merged into the catalog. Returns what may be
    /// cataloged. No-op (passthrough) when the toggle is off.
    func applyCatalogScopeGate(
        targetRecords: [VideoRecord],
        volName: String,
        audit: DiscoveryAuditCollector? = nil
    ) async -> CatalogScopeGateOutcome {
        var outcome = CatalogScopeGateOutcome()
        guard catalogScopeSettings.videoAndLinkedAudioOnly, !targetRecords.isEmpty else {
            outcome.admitted = targetRecords
            return outcome
        }

        // Same-path predecessors that are pair-protected: their fresh
        // replacement instance must be admitted so commitScanResults'
        // pair carryover can rewire the pairing onto it.
        let protectedPaths = Set(
            records.lazy
                .filter { CatalogScopePolicy.isPairProtected($0) }
                .map(\.fullPath)
        )

        var ambiguous: [VideoRecord] = []
        for rec in targetRecords {
            if CatalogScopePolicy.isPairProtected(rec) || protectedPaths.contains(rec.fullPath) {
                outcome.admitted.append(rec)
                outcome.pairProtectedKept += 1
                continue
            }
            switch CatalogScopePolicy.classify(ext: rec.ext, streamTypeRaw: rec.streamTypeRaw) {
            case .video, .extensionless:
                outcome.admitted.append(rec)
            case .still, .music:
                outcome.stillOrMusicExcluded += 1
                appLog.write("NOT CATALOGED — outside catalog scope (still image / music format): \(rec.fullPath)")
            case .ambiguousAudio:
                ambiguous.append(rec)
            }
        }

        if !ambiguous.isEmpty {
            // Evidence pool: every video-only record the catalog will hold
            // after this merge — current catalog (minus soft-removed) plus
            // this scan's own batch (an Avid pair often arrives together).
            var videoSnaps: [CorrelationScorer.Snap] = []
            for r in records where !r.isPurged && !r.isSetAside && r.streamType == .videoOnly {
                videoSnaps.append(CorrelationScorer.snap(r))
            }
            for r in targetRecords where r.streamType == .videoOnly {
                videoSnaps.append(CorrelationScorer.snap(r))
            }
            let audioSnaps = ambiguous.map { CorrelationScorer.snap($0) }

            let linkedIDs = await Self.evaluateVideoLinks(videoSnaps: videoSnaps,
                                                          audioSnaps: audioSnaps)
            for rec in ambiguous {
                if linkedIDs.contains(rec.id) {
                    outcome.admitted.append(rec)
                    outcome.linkedAudioKept += 1
                } else {
                    outcome.unlinkedAudioExcluded += 1
                    appLog.write("NOT CATALOGED — audio with no video link (catalog scope; a future Find Missing Audio pass can search for it): \(rec.fullPath)")
                }
            }
        }

        audit?.catalogScopeAudioJudged(linkedKept: outcome.linkedAudioKept,
                                       unlinkedExcluded: outcome.unlinkedAudioExcluded)

        let excluded = outcome.unlinkedAudioExcluded + outcome.stillOrMusicExcluded
        if excluded > 0 || outcome.linkedAudioKept > 0 {
            // ONE summary line per scan (fa24921 console etiquette).
            log("  Catalog scope (\(volName)): kept \(outcome.linkedAudioKept) audio file(s) that belong to a video, left out \(outcome.unlinkedAudioExcluded) audio file(s) with no matching video\(outcome.stillOrMusicExcluded > 0 ? " and \(outcome.stillOrMusicExcluded) photo/music file(s)" : "").")
            catalogScopeLog.info("Scope gate \(volName, privacy: .public): admitted=\(outcome.admitted.count) linkedAudioKept=\(outcome.linkedAudioKept) unlinkedAudioExcluded=\(outcome.unlinkedAudioExcluded) stillOrMusic=\(outcome.stillOrMusicExcluded) pairProtected=\(outcome.pairProtectedKept)")
        }
        return outcome
    }

    /// Off-main evidence pass: build the structural indexes once and judge
    /// every ambiguous audio snap. Pure over Sendable values.
    // #if guard: the nightly CI's Xcode 16.4 (Swift 6.1) knows
    // `@concurrent` only as a deprecated alias of `@Sendable`; pre-6.2 a
    // nonisolated async static already runs off-actor.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func evaluateVideoLinks(
        videoSnaps: [CorrelationScorer.Snap],
        audioSnaps: [CorrelationScorer.Snap]
    ) async -> Set<UUID> {
        let evidence = CatalogScopeEvidence(videoSnaps: videoSnaps)
        var linked = Set<UUID>()
        for a in audioSnaps where evidence.isVideoLinked(a) {
            linked.insert(a.id)
        }
        return linked
    }
}
