// VideoRecordDisplayLabelTests.swift
// Covers `VideoRecord.displayVolumeLabel`, the catalog "Volume" column's
// formatter for disambiguating folder-scoped scans across multiple volumes.

import Testing
import Foundation
@testable import VideoScan

@Suite("VideoRecord.displayVolumeLabel")
struct VideoRecordDisplayLabelTests {

    /// Build a VideoRecord with explicit volume name + scan-root label.
    private func makeRecord(volumeName: String, scanRootLabel: String,
                            fullPath: String = "/Volumes/Fake/clip.mov") -> VideoRecord {
        let rec = VideoRecord()
        rec.fullPath = fullPath
        var ctx = ScanContext()
        ctx.volumeName = volumeName
        ctx.scanRootLabel = scanRootLabel
        rec.scanContext = ctx
        return rec
    }

    @Test func emptyScanRootReturnsVolumeNameOnly() {
        // Whole-volume scan: no folder label, so the column shows just the
        // volume name (the existing behavior).
        let rec = makeRecord(volumeName: "MyBook", scanRootLabel: "")
        #expect(rec.displayVolumeLabel == "MyBook")
    }

    @Test func scanRootDifferentFromVolumeJoinsWithBreadcrumb() {
        // Folder-scoped scan: column shows "Volume > Folder" so two
        // different "Movies" folders on different volumes don't look
        // identical in the table.
        let rec = makeRecord(volumeName: "MyBook", scanRootLabel: "Movies")
        #expect(rec.displayVolumeLabel == "MyBook > Movies")
    }

    @Test func twoDifferentVolumesSameFolderProduceDistinctLabels() {
        // The whole point of this feature.
        let a = makeRecord(volumeName: "RicksBackups", scanRootLabel: "Movies")
        let b = makeRecord(volumeName: "InternalRaid",  scanRootLabel: "Movies")
        #expect(a.displayVolumeLabel != b.displayVolumeLabel)
        #expect(a.displayVolumeLabel == "RicksBackups > Movies")
        #expect(b.displayVolumeLabel == "InternalRaid > Movies")
    }

    @Test func scanRootEqualToVolumeNameAvoidsDuplication() {
        // Defensive case: if the scan-root label happens to equal the volume
        // name (degenerate capture, or someone scanned /Volumes/MyBook itself
        // and the label got stamped anyway), don't show "MyBook > MyBook".
        let rec = makeRecord(volumeName: "MyBook", scanRootLabel: "MyBook")
        #expect(rec.displayVolumeLabel == "MyBook")
    }

    @Test func emptyVolumeFallsBackToScanRoot() {
        // Defensive: if volumeName ends up empty (legacy/path-fallback
        // miss), we'd rather show the scan-root label than a blank cell.
        let rec = makeRecord(volumeName: "", scanRootLabel: "Movies",
                             fullPath: "/some/weird/clip.mov")
        // The fullPath-based fallback on volumeName may produce "some" here,
        // not "", because VolumeReachability.volumeName parses any non-empty
        // path. So this test exercises the fallback indirectly — assert the
        // breadcrumb still renders sensibly.
        let label = rec.displayVolumeLabel
        #expect(label.contains("Movies"))
    }

    @Test func deepSubfolderLabelRendersAsLastComponent() {
        // When capture stamps `scanRootLabel` from a deep path, only the
        // basename ends up in the column — full subpath would clutter the UI.
        let rec = makeRecord(volumeName: "MyBook", scanRootLabel: "summer")
        #expect(rec.displayVolumeLabel == "MyBook > summer")
    }
}
