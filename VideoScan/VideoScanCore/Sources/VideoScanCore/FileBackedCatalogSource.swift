// FileBackedCatalogSource.swift (VideoScanCore)
// The linchpin of the out-of-process design: a PreviewCatalogSource that
// reads the eligible sweep work-list from the PERSISTED catalog.json,
// with NO dependency on VideoScanModel or any live app state. Stage 1's
// CLI helper injects THIS to drive the same engine out-of-process.
//
// Eligibility is computed by the SHARED `previewSweepCandidates(from:...)`
// mapping that the app's model-backed adapter also calls — so the two
// sources CANNOT drift on the rule. What the parity test pins is that the
// file READ path (decode catalog.json) reconstructs the same records the
// live model holds, hence the same eligible set.
//
// Deliberately NOT reproduced from CatalogStore.decode: pairedWith
// rewiring and pair revalidation (eligibility reads only streamType /
// path / container / codec / duration / derived-unanalyzable — none
// depend on pairing) and the version-refusal / .prev fallback policy
// (Stage-1 catalog-freshness concern — see report). Volume reachability is
// a RUNTIME check inside the impl, injected so tests never poison a shared
// reachability cache.

import Foundation

// MARK: - Shared eligibility mapping (single source of truth)

/// Map catalog records to sweep candidates under the ONE eligibility rule:
/// video-bearing (videoOnly / videoAndAudio — the only shapes that can
/// yield a frame) AND on a reachable volume. Both the file-backed source
/// and the app's model-backed adapter call this, so the rule can never
/// diverge between them.
public func previewSweepCandidates(from records: [VideoRecord],
                                   isReachable: (String) -> Bool) -> [PreviewSweepCandidate] {
    records.compactMap { rec in
        guard rec.streamType == .videoOnly || rec.streamType == .videoAndAudio,
              isReachable(rec.fullPath) else {
            return nil
        }
        return PreviewSweepCandidate(path: rec.fullPath,
                                     container: rec.container,
                                     videoCodec: rec.videoCodec,
                                     likelyUnanalyzable: rec.isLikelyUnanalyzable,
                                     durationSeconds: rec.durationSeconds)
    }
}

// MARK: - File-backed source

public struct FileBackedCatalogSource: PreviewCatalogSource {

    /// Path to the persisted catalog.json (Application Support in
    /// production).
    public let catalogURL: URL

    /// Runtime volume reachability — injected (never a shared SWR cache in
    /// tests).
    public let isReachable: @Sendable (String) -> Bool

    public init(catalogURL: URL,
                isReachable: @escaping @Sendable (String) -> Bool) {
        self.catalogURL = catalogURL
        self.isReachable = isReachable
    }

    public func eligibleCandidates() async -> [PreviewSweepCandidate] {
        guard let records = Self.loadRecords(from: catalogURL) else { return [] }
        return previewSweepCandidates(from: records, isReachable: isReachable)
    }

    /// Decode just the `records` array from a catalog.json, using the SAME
    /// date strategy (.iso8601) as CatalogStore.decode. Returns nil on a
    /// missing/malformed file (the sweep then plans nothing this run).
    public static func loadRecords(from url: URL) -> [VideoRecord]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(CatalogFile.self, from: data) else {
            return nil
        }
        return file.records
    }

    /// Minimal decodable mirror of catalog.json's top level — only the
    /// `records` array matters for eligibility. Tolerates a missing key
    /// (empty catalog) exactly like CatalogSnapshot's decodeIfPresent.
    private struct CatalogFile: Decodable {
        let records: [VideoRecord]
        private enum CodingKeys: String, CodingKey { case records }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            records = try c.decodeIfPresent([VideoRecord].self, forKey: .records) ?? []
        }
    }
}
