// TargetRemovalSafetyTests.swift
// Regression suite for the 2026-07-01 target-removal data loss: removing
// two folder targets silently deleted 2,720 catalog records (including
// dossier enrichment). QA flagged `resetTarget` as still lacking the
// tripwire/snapshot treatment the scan merge got.
//
// Pinned contract for record removal scoped to a scan target's root:
//   (a) >50 records → a catalog.pre-target-removal.<stamp>.json snapshot
//       is written FIRST (CatalogStore.writeSnapshot pipeline, same
//       pattern as catalog.pre-merge.*); no snapshot → no deletion
//       (fail-safe degrade, same as the scan-merge tripwire);
//   (b) ONE prominent log line carries the removal count;
//   (c) records still covered by ANOTHER registered target's root
//       (component-boundary PathScope check) are KEPT — removing a folder
//       target under a volume target must not delete records the volume
//       target owns.
//
// Red/green: both tests below FAIL against the pre-fix resetTarget
// (unconditional removeAll, no snapshot, no coverage check).

import Testing
import Foundation
@testable import VideoScan

@Suite(.serialized) @MainActor
struct TargetRemovalSafetyTests {

    private func makeRecord(dir: String, leaf: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = leaf
        r.fullPath = dir + "/" + leaf
        r.directory = dir
        r.sizeBytes = 1
        r.partialMD5 = "h-\(leaf)"
        return r
    }

    // MARK: - 1. Coverage check: broader target keeps the records

    @Test func recordsCoveredByBroaderTargetSurviveReset() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()
        model.records = []

        // Volume target OWNS everything under it; the folder target is a
        // narrower scope nested inside it.
        let volumeTarget = CatalogScanTarget(searchPath: "/Volumes/FamilyMedia")
        let folderTarget = CatalogScanTarget(searchPath: "/Volumes/FamilyMedia/Avid Projects")
        model.scanTargets = [volumeTarget, folderTarget]

        let inFolder = makeRecord(dir: "/Volumes/FamilyMedia/Avid Projects", leaf: "donna_1998.mxf")
        let outside = makeRecord(dir: "/Volumes/FamilyMedia", leaf: "kids_2001.mov")
        model.records = [inFolder, outside]

        model.resetTarget(folderTarget)

        // The volume target still covers the folder's records — they must
        // survive the folder target's reset.
        #expect(model.records.contains(where: { $0.fullPath == inFolder.fullPath }),
                "Records under a folder target that is ALSO covered by a registered volume target must survive the folder target's reset")
        #expect(model.records.contains(where: { $0.fullPath == outside.fullPath }))
    }

    // MARK: - 2. Uncovered removal >50 records writes the safety snapshot

    @Test func uncoveredResetOver50RecordsWritesSnapshot() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-target-removal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = VideoScanModel()
        // Inject a store so the snapshot writes into OUR temp dir, never
        // the user's real Application Support (same convention as the
        // scan-merge tripwire tests).
        model.catalogStore = CatalogStore(directory: tmp)
        model.scanTargets.removeAll()

        let solo = CatalogScanTarget(searchPath: "/Volumes/SoloDrive")
        model.scanTargets = [solo]
        model.records = (0..<60).map { makeRecord(dir: "/Volumes/SoloDrive/clips", leaf: "clip\($0).mov") }

        model.resetTarget(solo)

        // Records are genuinely uncovered → the reset may remove them, but
        // ONLY after writing the recovery snapshot.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        let snapshots = names.filter { $0.hasPrefix("catalog.pre-target-removal.") && $0.hasSuffix(".json") }
        #expect(snapshots.count == 1,
                "Removing \(60) uncovered records must write exactly one catalog.pre-target-removal.<stamp>.json snapshot first — found \(snapshots)")
        #expect(model.records.isEmpty,
                "After a snapshotted reset the uncovered records are removed")

        // The snapshot must round-trip: it is the ONLY undo for this op.
        if let snap = snapshots.first {
            let data = try Data(contentsOf: tmp.appendingPathComponent(snap))
            #expect(!data.isEmpty)
        }
    }

    // MARK: - 3. Small removals stay snapshot-free (no false alarms)

    @Test func smallUncoveredResetDoesNotWriteSnapshot() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-target-removal-small-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)
        model.scanTargets.removeAll()

        let solo = CatalogScanTarget(searchPath: "/Volumes/SoloDrive")
        model.scanTargets = [solo]
        model.records = (0..<5).map { makeRecord(dir: "/Volumes/SoloDrive/clips", leaf: "clip\($0).mov") }

        model.resetTarget(solo)

        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        #expect(!names.contains(where: { $0.hasPrefix("catalog.pre-target-removal.") }),
                "≤50 removed records must not spam snapshots")
        #expect(model.records.isEmpty)
    }
}
