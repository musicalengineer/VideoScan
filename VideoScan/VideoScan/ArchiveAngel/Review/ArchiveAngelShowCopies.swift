// ArchiveAngelShowCopies.swift
// "Show Copies…" — the Archive Angel's READ-ONLY answer to "which of these
// copies is the original?" (Consolidation S4, Rick 2026-09-22: the old
// Promote Helper goes away; Assess Copies survives only as this view). It
// is reached from a Review row ("Copies…") and the catalog's right-click
// (Archive Angel ▸ Show Copies…). Promoting is the Angel's job: "Prepare
// with Archive Angel" (a batch of one) verifies and balances the audio,
// then Review → Promote.
//
// The family walk and the projection below are MOVED unchanged from the
// retired AssessCopiesJob (Promote-Helper slice 2, 2026-08-19); the
// decision itself is the pure CopyFamilyAssessor, untouched. The catalog
// is reached through the AngelCatalog seam only.
//
// Cost: one pass over the active records to index them (O(n)), then the
// family walk (O(family) hops; a duplicate group costs one pass over the
// active records, as before). Runs on the main actor when a person asks —
// never in a view body. At 100k records it is well under a second
// (ArchiveAngelShowCopiesTests pins the budget).

import Combine
import Foundation
import OSLog
import VideoScanCore

private let showCopiesLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "archiveAngel")

/// `.sheet(item:)` payload: one recording's copies, assessed.
struct ArchiveAngelShowCopiesRequest: Identifiable, Equatable {
    let id = UUID()
    /// The record the person asked about.
    let seedID: UUID
    let seedFilename: String
    /// Catalog records found to be the same recording (the seed included).
    let familyCount: Int
    let assessment: CopyFamilyAssessment
}

/// Holds the catalog's Show Copies sheet state apart from the façade's
/// other published values, so the sheet host re-renders only when THIS
/// changes (not on every recommendation recount).
@MainActor
final class ArchiveAngelShowCopiesPresenter: ObservableObject {
    @Published var request: ArchiveAngelShowCopiesRequest?
}

enum ArchiveAngelCopyFamily {

    /// Everything the catalog knows to be the same recording as `seed`:
    /// its duplicate group, its lineage (derivedFrom both ways,
    /// transitive), its archive copy / promotion source, and any record
    /// with the same non-empty content signature. Present records only.
    @MainActor
    static func collect(seed: VideoRecord, catalog: any AngelCatalog) -> [VideoRecord] {
        let active = catalog.activeRecordsForCopyFamily()
        var byID: [UUID: VideoRecord] = [:]
        byID.reserveCapacity(active.count)
        var children: [UUID: [VideoRecord]] = [:]
        var byHash: [String: [VideoRecord]] = [:]
        for r in active {
            byID[r.id] = r
            if let d = r.derivedFrom { children[d, default: []].append(r) }
            if !r.contentHash.isEmpty { byHash[r.contentHash, default: []].append(r) }
        }
        var family: [UUID: VideoRecord] = [seed.id: seed]
        var queue: [VideoRecord] = [seed]
        var hops = 0
        while let r = queue.popLast(), hops < 10_000 {
            hops += 1
            var related: [VideoRecord] = []
            if let g = r.duplicateGroupID {
                // Group members: one pass over active (groups are small
                // relative to the catalog; a per-group index is unnecessary
                // at catalog sizes the app targets).
                related += active.filter { $0.duplicateGroupID == g }
            }
            if let d = r.derivedFrom, let parent = byID[d] { related.append(parent) }
            related += children[r.id] ?? []
            if let copy = catalog.masterArchiveCopy(of: r) { related.append(copy) }
            if let src = catalog.promotionSource(of: r) { related.append(src) }
            if !r.contentHash.isEmpty { related += byHash[r.contentHash] ?? [] }
            for x in related where family[x.id] == nil {
                family[x.id] = x
                queue.append(x)
            }
        }
        return family.values.sorted { $0.fullPath < $1.fullPath }
    }

    /// The assessor's Sendable inputs, with the duplicate-keeper volume facts.
    @MainActor
    static func projectInputs(_ family: [VideoRecord], catalog: any AngelCatalog) -> [CopyFamilyInput] {
        let policy = catalog.duplicateKeeperPolicy()
        return family.map { r in
            let facts = policy.facts(forPath: r.fullPath)
            // Rows that predate stream classification carry an empty raw
            // (→ .ffprobeFailed); infer the shape from the codecs so an
            // old-but-healthy DV is not written off as damaged.
            let streamType: StreamType = {
                if !r.streamTypeRaw.isEmpty { return r.streamType }
                if r.videoCodec.isEmpty { return r.audioCodec.isEmpty ? .ffprobeFailed : .audioOnly }
                return r.audioCodec.isEmpty ? .videoOnly : .videoAndAudio
            }()
            return CopyFamilyInput(
                id: r.id,
                fullPath: r.fullPath,
                filename: r.filename,
                sizeBytes: r.sizeBytes,
                durationSeconds: r.durationSeconds,
                videoCodec: r.videoCodec,
                audioCodec: r.audioCodec,
                container: r.container.isEmpty ? r.ext.lowercased() : r.container,
                resolution: r.resolution,
                frameRate: r.frameRate,
                scanType: r.scanType,
                audioChannels: r.audioChannels,
                audioSampleRate: r.audioSampleRate,
                bitDepth: r.bitDepth,
                streamType: streamType,
                isPlayable: r.isPlayable.isEmpty || r.isPlayable == "Yes",
                contentHash: r.contentHash,
                derivedFrom: r.derivedFrom,
                derivationKind: r.derivationKind,
                cleanupRecipeID: r.cleanupRecipeID,
                embeddedCreationDate: r.embeddedCreationDate,
                originMake: r.originMake,
                audioVerifyStatus: r.audioVerifyStatus,
                isReachable: facts?.isReachable ?? VolumeReachability.isReachable(path: r.fullPath),
                isRetired: facts?.isRetired ?? false,
                isMasterArchive: facts?.isMasterArchive ?? false,
                isArchiveCopy: catalog.isArchiveCopy(r),
                volumeScore: policy.precedenceScore(forPath: r.fullPath, facts: facts),
                humanScore: DuplicateKeeperPolicy.humanMetadataScore(r))
        }
    }

    /// The whole Show Copies answer for `seed`: family → inputs → assessment.
    @MainActor
    static func request(for seed: VideoRecord, catalog: any AngelCatalog) -> ArchiveAngelShowCopiesRequest {
        let family = collect(seed: seed, catalog: catalog)
        let assessment = CopyFamilyAssessor.assess(projectInputs(family, catalog: catalog))
        showCopiesLog.debug("show copies: \(seed.filename, privacy: .public) — \(family.count) record(s), \(assessment.headline, privacy: .public)")
        return ArchiveAngelShowCopiesRequest(seedID: seed.id, seedFilename: seed.filename,
                                             familyCount: family.count, assessment: assessment)
    }
}
