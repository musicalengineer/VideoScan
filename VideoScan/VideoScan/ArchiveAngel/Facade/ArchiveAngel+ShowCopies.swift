// ArchiveAngel+ShowCopies.swift
// The façade's Show Copies… entry points (Consolidation S4). Read-only: the
// answer is a value (ArchiveAngelShowCopiesRequest) a sheet presents; no
// job, no MFO row, nothing written. Every call logs START + result.

import Foundation
import OSLog

private let showCopiesFacadeLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "archiveAngel")

extension ArchiveAngel {

    /// The copies of `recordID`'s recording, assessed — for a caller that
    /// presents the sheet itself (the Review sheet's "Copies…", which is
    /// already a sheet). nil when the record is gone from the catalog.
    func copies(of recordID: UUID) -> ArchiveAngelShowCopiesRequest? {
        showCopiesFacadeLog.info("showCopies START — \(recordID.uuidString, privacy: .public)")
        guard let catalog, let seed = catalog.record(forID: recordID) else {
            showCopiesFacadeLog.info("showCopies — not shown: the record is no longer in the catalog")
            catalog?.angelLog("Archive Angel: Show Copies — that file is no longer in the catalog.")
            return nil
        }
        let request = ArchiveAngelCopyFamily.request(for: seed, catalog: catalog)
        showCopiesFacadeLog.info("showCopies done — \(seed.filename, privacy: .public): \(request.familyCount) record(s) · \(request.assessment.headline, privacy: .public)")
        return request
    }

    /// The catalog right-click's Archive Angel ▸ Show Copies…: assess and
    /// present through ArchiveAngelShowCopiesHost (one sheet at a time —
    /// asking again replaces the one showing).
    func showCopies(of recordID: UUID) {
        showCopiesPresenter.request = copies(of: recordID)
    }
}
