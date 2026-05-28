import Foundation

extension VideoScanModel {

    // MARK: - Combine Batch Planning
    //
    // Decides, for each (video, audio) pair in a bulk Combine batch,
    // whether it can run as-is, can run with a UMID-substituted copy of
    // an offline source on a reachable volume, or is blocked. Pulled out
    // as a pure function — no logging, no UI, no model state mutation —
    // so every scenario can be unit-tested by injecting reachability.
    //
    // Step 2B-1 of [[project_archive_combine_pipeline_order]].

    struct CombineBatchPlan {
        struct Item {
            let originalVideo: VideoRecord
            let originalAudio: VideoRecord
            let resolvedVideo: VideoRecord
            let resolvedAudio: VideoRecord
            let videoSubstituted: Bool
            let audioSubstituted: Bool
            /// Non-nil when the pair can't be combined — either source is
            /// offline and no reachable substitute exists. Human-readable so
            /// it can feed straight into logs and the pre-flight sheet.
            let blockReason: String?

            var isRunnable: Bool { blockReason == nil }
            var isSubstituted: Bool { videoSubstituted || audioSubstituted }
        }

        let items: [Item]
        var runnable: [Item] { items.filter(\.isRunnable) }
        var substituted: [Item] { items.filter(\.isSubstituted) }
        var blocked: [Item] { items.filter { !$0.isRunnable } }
    }

    /// Build a `CombineBatchPlan` for the given pairs.
    ///
    /// For each pair: if a source is unreachable, look up UMID-matched
    /// substitutes via `findSubstitutes(for:)` and pick the first reachable
    /// one. If no reachable substitute exists, the pair is blocked.
    ///
    /// `isReachable` is injectable for tests — production passes
    /// `VolumeReachability.isReachable(path:)`. Tests pass a closure that
    /// returns predetermined values per path so reachability can be
    /// simulated without touching real volumes.
    func prepareCombineBatch(
        pairs: [(video: VideoRecord, audio: VideoRecord)],
        isReachable: (String) -> Bool = { VolumeReachability.isReachable(path: $0) }
    ) -> CombineBatchPlan {
        var items: [CombineBatchPlan.Item] = []
        items.reserveCapacity(pairs.count)

        for pair in pairs {
            let (resolvedVideo, videoSub, videoBlock) = resolveSide(
                source: pair.video, sideLabel: "video", isReachable: isReachable
            )
            let (resolvedAudio, audioSub, audioBlock) = resolveSide(
                source: pair.audio, sideLabel: "audio", isReachable: isReachable
            )

            let reasons = [videoBlock, audioBlock].compactMap { $0 }
            items.append(.init(
                originalVideo: pair.video,
                originalAudio: pair.audio,
                resolvedVideo: resolvedVideo,
                resolvedAudio: resolvedAudio,
                videoSubstituted: videoSub,
                audioSubstituted: audioSub,
                blockReason: reasons.isEmpty ? nil : reasons.joined(separator: ", ")
            ))
        }
        return CombineBatchPlan(items: items)
    }

    /// Returns (resolved record, was-substituted, block-reason). At most
    /// one of substituted/blocked is true; if the original is reachable
    /// both are false and resolved == original.
    private func resolveSide(
        source: VideoRecord,
        sideLabel: String,
        isReachable: (String) -> Bool
    ) -> (resolved: VideoRecord, substituted: Bool, blockReason: String?) {
        if isReachable(source.fullPath) {
            return (source, false, nil)
        }
        // Source offline — look for a UMID-matched reachable copy.
        if let sub = findSubstitutes(for: source).first(where: { isReachable($0.fullPath) }) {
            return (sub, true, nil)
        }
        // Offline, no substitute. Distinguish "we never had a UMID to look
        // up" from "we had a UMID but no reachable copy" — both block, but
        // the user-facing reason differs.
        let reason = source.materialPackageUMID.isEmpty
            ? "\(sideLabel) offline (no UMID — re-scan to enable substitute lookup)"
            : "\(sideLabel) offline (no reachable copy)"
        return (source, false, reason)
    }
}
