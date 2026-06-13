import Testing
import Foundation
@testable import VideoScan

// MARK: - pfCatalogWideMetadataCandidates
//
// Tests the candidate-filter for catalog-wide caption / transcript
// runs. Per 2026-06-04 roadmap Q5 option (c):
//   - lifecycleStage in {Cataloged, Workbench}
//   - purgedAt == nil
//   - fullPath under a reachable volume
//
// The downstream per-engine filters (caption needs video frames,
// transcript needs audio) are separate sub-filters.

struct CatalogWideMetadataCandidatesTests {

    private func record(
        path: String = "/v/clip.mov",
        stage: LifecycleStage = .cataloged,
        purgedAt: Date? = nil,
        streamType: StreamType = .videoAndAudio,
        mediaDisposition: MediaDisposition = .unreviewed,
        drmProtected: Bool = false
    ) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.lifecycleStage = stage
        r.purgedAt = purgedAt
        r.streamTypeRaw = streamType.rawValue
        r.mediaDisposition = mediaDisposition
        r.drmProtected = drmProtected
        return r
    }

    // MARK: lifecycle gate

    @Test func includesCataloged() {
        let r = record(path: "/Volumes/Lacie/a.mov", stage: .cataloged)
        let out = pfCatalogWideMetadataCandidates(records: [r], reachableVolumePaths: ["/Volumes/Lacie"])
        #expect(out.count == 1)
    }

    @Test func includesWorkbench() {
        let r = record(path: "/Volumes/Lacie/a.mov", stage: .workbench)
        let out = pfCatalogWideMetadataCandidates(records: [r], reachableVolumePaths: ["/Volumes/Lacie"])
        #expect(out.count == 1)
    }

    @Test func excludesArchived() {
        let r = record(path: "/Volumes/Lacie/a.mov", stage: .archived)
        let out = pfCatalogWideMetadataCandidates(records: [r], reachableVolumePaths: ["/Volumes/Lacie"])
        #expect(out.isEmpty)
    }

    @Test func excludesDeletedAndTrashed() {
        let deleted = record(path: "/Volumes/Lacie/a.mov", stage: .deletedPermanently)
        let trashed = record(path: "/Volumes/Lacie/b.mov", stage: .trashed)
        let out = pfCatalogWideMetadataCandidates(records: [deleted, trashed], reachableVolumePaths: ["/Volumes/Lacie"])
        #expect(out.isEmpty)
    }

    // MARK: purge gate

    @Test func excludesPurgedRecords() {
        let purged = record(path: "/Volumes/Lacie/a.mov", purgedAt: Date())
        let out = pfCatalogWideMetadataCandidates(records: [purged], reachableVolumePaths: ["/Volumes/Lacie"])
        #expect(out.isEmpty)
    }

    // MARK: junk gate (Rick 2026-06-13)
    //
    // confirmedJunk is a deliberate "do not analyze, awaiting cull"
    // state. Before this filter, the dossier orchestrator would
    // re-analyze them every batch and waste Whisper time.

    @Test func excludesConfirmedJunkRecords() {
        let junk = record(path: "/Volumes/Lacie/a.mov", mediaDisposition: .confirmedJunk)
        let out = pfCatalogWideMetadataCandidates(records: [junk], reachableVolumePaths: ["/Volumes/Lacie"])
        #expect(out.isEmpty)
    }

    @Test func includesSuspectedJunkRecords() {
        // suspected ≠ confirmed; we still process so the dossier can
        // help the user decide.
        let suspect = record(path: "/Volumes/Lacie/a.mov", mediaDisposition: .suspectedJunk)
        let out = pfCatalogWideMetadataCandidates(records: [suspect], reachableVolumePaths: ["/Volumes/Lacie"])
        #expect(out.count == 1)
    }

    // MARK: DRM gate (Rick 2026-06-13)
    //
    // Encrypted files (FairPlay m4v/m4p from defunct iTunes accounts)
    // can't be decoded — Whisper would burn hours on ciphertext.
    // The orchestrator probes lazily via AVAsset.hasProtectedContent
    // on first encounter and persists drmProtected=true; this filter
    // makes the subsequent runs cheap.

    @Test func excludesDRMProtectedRecords() {
        let drm = record(path: "/Volumes/Lacie/a.m4v", drmProtected: true)
        let out = pfCatalogWideMetadataCandidates(records: [drm], reachableVolumePaths: ["/Volumes/Lacie"])
        #expect(out.isEmpty)
    }

    // MARK: reachability gate

    @Test func excludesRecordsOnOfflineVolume() {
        let offline = record(path: "/Volumes/Seagate2TB/a.mov")
        let out = pfCatalogWideMetadataCandidates(
            records: [offline],
            reachableVolumePaths: ["/Volumes/Lacie"])
        #expect(out.isEmpty)
    }

    @Test func handlesMultipleReachableVolumes() {
        let onA = record(path: "/Volumes/A/a.mov")
        let onB = record(path: "/Volumes/B/b.mov")
        let onC = record(path: "/Volumes/C/c.mov")
        let out = pfCatalogWideMetadataCandidates(
            records: [onA, onB, onC],
            reachableVolumePaths: ["/Volumes/A", "/Volumes/B"])
        #expect(out.count == 2)
        #expect(out.map(\.filename).sorted() == ["a.mov", "b.mov"])
    }

    @Test func emptyReachabilityYieldsEmpty() {
        let r = record(path: "/Volumes/Lacie/a.mov")
        let out = pfCatalogWideMetadataCandidates(records: [r], reachableVolumePaths: [])
        #expect(out.isEmpty)
    }

    @Test func emptyStringPrefixesFiltered() {
        // Defensive: an empty searchPath in the targets list shouldn't
        // cause every record to match (since "" is a prefix of every
        // string).
        let r = record(path: "/Volumes/Lacie/a.mov")
        let out = pfCatalogWideMetadataCandidates(records: [r], reachableVolumePaths: ["", ""])
        #expect(out.isEmpty, "Empty-string prefixes must not match everything")
    }

    // MARK: sub-filters

    @Test func captionSubFilterTakesVideoBearingStreams() {
        let va = record(path: "/v/a.mov", streamType: .videoAndAudio)
        let v = record(path: "/v/b.mov", streamType: .videoOnly)
        let a = record(path: "/v/c.wav", streamType: .audioOnly)
        let none = record(path: "/v/d.bin", streamType: .noStreams)
        let out = pfCatalogWideCaptionCandidates([va, v, a, none])
        #expect(out.count == 2)
        #expect(Set(out.map(\.filename)) == Set(["a.mov", "b.mov"]))
    }

    @Test func transcriptSubFilterTakesAudioBearingStreams() {
        let va = record(path: "/v/a.mov", streamType: .videoAndAudio)
        let v = record(path: "/v/b.mov", streamType: .videoOnly)
        let a = record(path: "/v/c.wav", streamType: .audioOnly)
        let none = record(path: "/v/d.bin", streamType: .noStreams)
        let out = pfCatalogWideTranscriptCandidates([va, v, a, none])
        #expect(out.count == 2)
        #expect(Set(out.map(\.filename)) == Set(["a.mov", "c.wav"]))
    }
}
