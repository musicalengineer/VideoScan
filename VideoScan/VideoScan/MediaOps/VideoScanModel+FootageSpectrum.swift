// VideoScanModel+FootageSpectrum.swift
// The model's side of "Compare Footage…" (Footage Spectrum trial,
// 2026-10-03): chosen record ids → the planner's candidates, and the one
// entry point the Triage table, the suggestion cards and the window's
// "Compare Again" all use.
//
// Called from EVENT HANDLERS only. O(ids): each id goes through the model's
// id index (`record(forID:)`); the catalog is never walked.
//
// "Archive copy" is the model's canonical predicate `isArchiveElement` (a
// promoted copy, or a file inside the Master Archive root) — the same
// question every background writer asks, not a second rule.

import Combine
import Foundation

extension VideoScanModel {

    /// The chosen records as planner input, in the order given. Ids that no
    /// longer resolve are dropped. `readable` is injectable for tests; by
    /// default a file counts when its drive is connected and the file opens.
    func footageSpectrumCandidates(forIDs ids: [UUID],
                                   readable: ((String) -> Bool)? = nil) -> [FootageSpectrumCandidate] {
        let isReadable = readable ?? { path in
            VolumeReachability.isReachable(path: path) && FileManager.default.isReadableFile(atPath: path)
        }
        return ids.compactMap { record(forID: $0) }.map { r in
            FootageSpectrumCandidate(id: r.id, filename: r.filename, path: r.fullPath, sizeBytes: r.sizeBytes,
                                     durationSeconds: r.durationSeconds,
                                     volumeLabel: VolumeReachability.displayLabel(forPath: r.fullPath),
                                     isArchiveCopy: isArchiveElement(r), isReadable: isReadable(r.fullPath))
        }
    }

    /// Start a comparison of `ids` as a user-started MFO job, and make it the
    /// one the Footage Spectrum window shows. The caller opens the window
    /// (FootageSpectrumWindowOpener) — it shows "Preparing…" until the page
    /// exists, so nothing here waits.
    @discardableResult
    func startFootageSpectrum(ids: [UUID], title: String, preferredFirst: UUID? = nil,
                              center: MediaFileOperationsCenter, source: String) -> FootageSpectrumJob {
        let candidates = footageSpectrumCandidates(forIDs: ids)
        log("Compare Footage (\(source)): \(candidates.count) video\(candidates.count == 1 ? "" : "s") chosen")
        let job = center.startedByUser {
            $0.startFootageSpectrum(candidates: candidates, title: title, preferredFirst: preferredFirst,
                                    console: { [weak self] line in self?.log(line) })
        }
        FootageSpectrumViewer.shared.show(job)
        return job
    }

    /// "Show These in the Catalog" from the window: the compared files.
    func showFootageSpectrumInCatalog(_ job: FootageSpectrumJob) {
        let ids = Set(job.plan?.recordIDs ?? job.requestedIDs)
        guard !ids.isEmpty else { return }
        showInCatalog(focus: ids, label: "Compared footage: \(job.title)")
    }
}

/// Which comparison the Footage Spectrum window shows. One window, the
/// newest run; the MFO row's "Open" puts an older one back.
@MainActor
final class FootageSpectrumViewer: ObservableObject {
    static let shared = FootageSpectrumViewer()

    @Published private(set) var job: FootageSpectrumJob?

    func show(_ job: FootageSpectrumJob) {
        self.job = job
    }
}
