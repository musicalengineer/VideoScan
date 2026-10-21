// VideoScanModel+ViewerCatalog.swift
// The model's two seams for CatalogSync phase 2 (2026-10-19):
//   - viewer: `showViewerCatalog` swaps in the records of the master's
//     sealed catalog.sqlite (read-only, through CatalogViewerSnapshot.load —
//     the master's own read path), or keeps the frozen catalog.json on
//     screen with the "older catalog" label;
//   - master: `viewerSnapshotSource` lends the session's store and its
//     commit-first door to CatalogSnapshotPublisher.
//
// A viewer never writes: the snapshot is opened sealed (writes refused by
// the store), the records it yields are shown under the viewer's read-only
// mode (CatalogStore.isReadOnly / ViewerModeCenter), and no committer is
// installed — `catalogCutover` stays empty on a viewer, so every save
// funnel goes to the read-only CatalogStore and is refused there.

import Foundation
import VideoScanCore

extension VideoScanModel {

    /// Show what a viewer's synced folder holds. Returns the banner's status.
    /// A snapshot that will not open leaves the records on screen as they
    /// were (the last good catalog) and says why.
    func showViewerCatalog(_ source: CatalogViewerSnapshot.Source) async -> ViewerCatalogStatus {
        guard ViewerModeCenter.shared.isViewer else {
            return .refused("this Mac is the master — it never reads the viewer copy")
        }
        return await CatalogViewerSnapshot.show(source, note: { [weak self] in self?.catalogAuthorityNote($0) },
                                                adopt: { [weak self] result in
            guard let self else { return }
            records = result.records
            searchIndex.rebuild(records: records)
        })
    }

    /// What the master's snapshot publisher borrows, read on every tick:
    /// nil while catalog.json is the authority (no committer installed).
    /// `catalogWriterTitle`: the MFO center's first live, unpaused
    /// catalog-writing job (GH #350, MediaOps/CatalogWriterJobs.swift) —
    /// with a scan, the writers the publisher waits for (CatalogWriteActivity).
    func viewerSnapshotSource(catalogWriterTitle: @escaping () -> String? = { nil }) -> CatalogSnapshotPublisher.Source {
        let folder = URL(fileURLWithPath: catalogStore.fileLocation).deletingLastPathComponent()
        return CatalogSnapshotPublisher.Source(
            store: { [weak self] in
                guard let committer = self?.catalogCutover.committer else { return nil }
                return CatalogSnapshotPublisher.Store(repository: committer.repository,
                                                      commitFirst: { committer.commitBeforeSafetyCopy() })
            },
            latchURL: folder.appendingPathComponent(CatalogAuthority.latchFileName),
            busy: { [weak self] in
                CatalogWriteActivity.words(catalogWriterTitle: catalogWriterTitle(), scanning: self?.isScanning ?? false)
            })
    }
}
