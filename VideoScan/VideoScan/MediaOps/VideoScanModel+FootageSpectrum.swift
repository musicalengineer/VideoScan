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

    /// The chosen records as planner input, in the planner's reading order.
    /// Ids that no longer resolve are dropped.
    ///
    /// QA P2-3: a suggestion card can hand over hundreds of ids, and this runs
    /// on the main actor. So the ids are RANKED first (I/O-free: archive copy,
    /// preferred, size, name) and only then stat'ed, in that order, until
    /// `maxFiles` readable ones are found. The rest are not looked at: they
    /// are marked readable-unchecked, and the planner leaves them out as
    /// "over the limit" (they come after eight readable ones in the same
    /// order). Worst case = maxFiles + the offline ones before them.
    ///
    /// `readable` is injectable for tests; by default a file counts when its
    /// drive is connected and the file opens.
    func footageSpectrumCandidates(forIDs ids: [UUID], preferredFirst: UUID? = nil,
                                   readable: ((String) -> Bool)? = nil) -> [FootageSpectrumCandidate] {
        let isReadable = readable ?? { path in
            VolumeReachability.isReachable(path: path) && FileManager.default.isReadableFile(atPath: path)
        }
        var seen = Set<UUID>()
        let unranked = ids.compactMap { id -> FootageSpectrumCandidate? in
            guard seen.insert(id).inserted, let r = record(forID: id) else { return nil }
            return FootageSpectrumCandidate(id: r.id, filename: r.filename, path: r.fullPath, sizeBytes: r.sizeBytes,
                                            durationSeconds: r.durationSeconds, volumeLabel: "",
                                            isArchiveCopy: isArchiveElement(r), isReadable: true)
        }
        var ranked = FootageSpectrumPlanner.ordered(unranked, preferredFirst: preferredFirst)
        var found = 0
        for i in ranked.indices where found < FootageSpectrumPlanner.maxFiles {
            ranked[i].isReadable = isReadable(ranked[i].path)
            guard ranked[i].isReadable else { continue }
            ranked[i].volumeLabel = VolumeReachability.displayLabel(forPath: ranked[i].path)
            found += 1
        }
        return ranked
    }

    /// Start a comparison of `ids` as a user-started MFO job, and make it the
    /// one the Footage Spectrum window shows. Returns nil — and the caller
    /// opens NO window — when the Center refused the job outright (a remote
    /// viewer: Media File Operations run only on the master; QA P3-5). The
    /// caller opens the window otherwise; it shows "Preparing…" until the
    /// page exists, so nothing here waits.
    @discardableResult
    func startFootageSpectrum(ids: [UUID], title: String, preferredFirst: UUID? = nil,
                              center: MediaFileOperationsCenter, source: String) -> FootageSpectrumJob? {
        let candidates = footageSpectrumCandidates(forIDs: ids, preferredFirst: preferredFirst)
        log("Compare Footage (\(source)): \(candidates.count) video\(candidates.count == 1 ? "" : "s") chosen")
        let job = center.startedByUser {
            $0.startFootageSpectrum(candidates: candidates, title: title, preferredFirst: preferredFirst,
                                    console: { [weak self] line in self?.log(line) })
        }
        guard !job.refusedOnViewer else {
            log("Compare Footage: \(job.subtitle)")
            return nil
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
