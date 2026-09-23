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
// Cost: one pass over the active records to index them (O(n), once per
// pass — `Index`), then the family walk (O(family) hops, all lookups). Runs on the main actor when a person asks —
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

    /// The catalog's active records indexed for the family walk — built
    /// ONCE per pass (a Show Copies, a Prepare batch, a Promote) so a batch
    /// of N rows costs one O(n) index plus N small walks, not N catalog
    /// passes. (≈ a C++ struct of hash maps built up front.)
    struct Index {
        let byID: [UUID: VideoRecord]
        let children: [UUID: [VideoRecord]]
        let byHash: [String: [VideoRecord]]
        let byGroup: [UUID: [VideoRecord]]
        /// WHOLE-FILE digest candidates (ContentFixity), keyed by
        /// `ArchiveAngelCopyFamily.fullDigestKeys`. The only content evidence
        /// that may authorise fact inheritance (codex #1654 P1-1: `contentHash`
        /// is a SAMPLED signature) — and only for records whose fixity a stat
        /// confirmed fresh (codex #1659, ArchiveAngelFixityCheck).
        let byDigest: [String: [VideoRecord]]

        @MainActor
        init(active: [VideoRecord]) {
            var byID: [UUID: VideoRecord] = [:]
            byID.reserveCapacity(active.count)
            var children: [UUID: [VideoRecord]] = [:]
            var byHash: [String: [VideoRecord]] = [:]
            var byGroup: [UUID: [VideoRecord]] = [:]
            var byDigest: [String: [VideoRecord]] = [:]
            for r in active {
                byID[r.id] = r
                if let d = r.derivedFrom { children[d, default: []].append(r) }
                if !r.contentHash.isEmpty { byHash[r.contentHash, default: []].append(r) }
                if let g = r.duplicateGroupID { byGroup[g, default: []].append(r) }
                for k in ArchiveAngelCopyFamily.fullDigestKeys(r) { byDigest[k, default: []].append(r) }
            }
            self.byID = byID; self.children = children; self.byHash = byHash; self.byGroup = byGroup
            self.byDigest = byDigest
        }

        @MainActor
        init(catalog: any AngelCatalog) {
            self.init(active: catalog.activeRecordsForCopyFamily())
        }
    }

    /// Everything the catalog knows to be the same recording as `seed`:
    /// its duplicate group, its lineage (derivedFrom both ways,
    /// transitive), its archive copy / promotion source, and any record
    /// with the same non-empty content signature. Present records only.
    @MainActor
    static func collect(seed: VideoRecord, catalog: any AngelCatalog) -> [VideoRecord] {
        collect(seed: seed, index: Index(catalog: catalog), catalog: catalog)
    }

    /// The same walk over a prebuilt index (one index per batch).
    @MainActor
    static func collect(seed: VideoRecord, index: Index, catalog: any AngelCatalog) -> [VideoRecord] {
        walk(seed: seed, index: index, catalog: catalog)
    }

    /// The whole-file digest key a record's catalogue CLAIMS
    /// ("sha256:<hex>:<bytes>") — a CANDIDATE only. It may authorise
    /// anything only once `ArchiveAngelFixityCheck` has confirmed, with a
    /// stat, that the stored ContentFixity still describes the file NOW
    /// (`describesFileNow`: volume (UUID), inode, size, mtime AND ctime) — codex
    /// #1659: a same-size rewrite keeps the size but not the stamp. A bare
    /// ArchiveFixity (no stamp) never counts on its own; an archive copy
    /// joins through its own verified ContentFixity or the promotion link.
    @MainActor
    static func fullDigestKeys(_ r: VideoRecord) -> [String] {
        guard let f = r.contentFixity, f.isUsableForVerification, !f.digest.isEmpty,
              f.byteCount > 0, f.byteCount == r.sizeBytes else { return [] }
        return ["sha256:\(f.digest.lowercased()):\(f.byteCount)"]
    }

    @MainActor
    private static func walk(seed: VideoRecord, index: Index, catalog: any AngelCatalog) -> [VideoRecord] {
        var family: [UUID: VideoRecord] = [seed.id: seed]
        var queue: [VideoRecord] = [seed]
        var hops = 0
        while let r = queue.popLast(), hops < 10_000 {
            hops += 1
            var related: [VideoRecord] = []
            // Group members (the active records sharing the group id — the
            // same set the Helper's `active.filter` pass found, now indexed).
            if let g = r.duplicateGroupID { related += index.byGroup[g] ?? [] }
            if let d = r.derivedFrom, let parent = index.byID[d] { related.append(parent) }
            related += index.children[r.id] ?? []
            if let copy = catalog.masterArchiveCopy(of: r) { related.append(copy) }
            if let src = catalog.promotionSource(of: r) { related.append(src) }
            if !r.contentHash.isEmpty { related += index.byHash[r.contentHash] ?? [] }
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
