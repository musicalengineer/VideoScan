import Testing
import Foundation
@testable import VideoScan

// MARK: - RemoveScanTargetTests
//
// Covers the Catalog volume context-menu "Remove from List" /
// "Remove Selected" action, which is wired to `removeScanTarget`.
//
// DATA-SAFETY CONTRACT (codex C1): "Remove from List" is a LIST
// operation. It must take the target out of `scanTargets` (and run the
// good cleanup: cancel task, stop timer, clear probe cache) but it must
// NOT delete the user's catalog records. Records under the removed
// volume become orphans and stay in the catalog for history — exactly
// the orphan semantics of `deleteScanTarget`.
//
// Before the fix, `removeScanTarget` did
//   records.removeAll { $0.fullPath.hasPrefix(target.searchPath) }
//   saveCatalogNow()
// which permanently destroyed and persisted-away every record under the
// volume with no confirmation. These tests pin the corrected behavior.

@Suite(.serialized) @MainActor
struct RemoveScanTargetTests {

    private func makeRecord(volumeRootPath: String, leaf: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = leaf
        r.fullPath = volumeRootPath + "/" + leaf
        r.directory = volumeRootPath
        r.sizeBytes = 1
        r.partialMD5 = "h-\(leaf)"
        return r
    }

    // MARK: - 1. Records are PRESERVED (the core data-safety guarantee)

    // regression: codex C1 — "Remove from List" must not delete catalog records.
    @Test
    func removeScanTarget_preservesCatalogRecords() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()
        model.records = []

        let doomed = CatalogScanTarget(searchPath: "/Volumes/FamilyMedia")
        model.scanTargets = [doomed]

        let r1 = makeRecord(volumeRootPath: "/Volumes/FamilyMedia", leaf: "donna_1998.mov")
        let r2 = makeRecord(volumeRootPath: "/Volumes/FamilyMedia", leaf: "kids_2001.mov")
        let r3 = makeRecord(volumeRootPath: "/Volumes/FamilyMedia/sub", leaf: "deep.mov")
        model.records = [r1, r2, r3]

        model.removeScanTarget(doomed)

        // Target gone from the list...
        #expect(!model.scanTargets.contains(where: { $0.id == doomed.id }))
        // ...but every catalog record is still present (orphaned, not deleted).
        #expect(model.records.count == 3)
        #expect(model.records.contains(where: { $0.fullPath == "/Volumes/FamilyMedia/donna_1998.mov" }))
        #expect(model.records.contains(where: { $0.fullPath == "/Volumes/FamilyMedia/kids_2001.mov" }))
        #expect(model.records.contains(where: { $0.fullPath == "/Volumes/FamilyMedia/sub/deep.mov" }))
    }

    // MARK: - 2. Records on OTHER volumes are untouched

    // regression: codex C1 — removal must not disturb sibling-volume records.
    @Test
    func removeScanTarget_leavesOtherVolumesAlone() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()
        model.records = []

        let doomed = CatalogScanTarget(searchPath: "/Volumes/Drive")
        let keep = CatalogScanTarget(searchPath: "/Volumes/Drive Backup")
        model.scanTargets = [doomed, keep]

        let onDoomed = makeRecord(volumeRootPath: "/Volumes/Drive", leaf: "a.mov")
        let onSibling = makeRecord(volumeRootPath: "/Volumes/Drive Backup", leaf: "b.mov")
        model.records = [onDoomed, onSibling]

        model.removeScanTarget(doomed)

        #expect(model.records.count == 2)
        #expect(model.scanTargets.contains(where: { $0.searchPath == "/Volumes/Drive Backup" }))
    }
}
