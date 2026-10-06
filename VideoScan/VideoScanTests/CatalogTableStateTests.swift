import Foundation
import SwiftUI
import Testing
@testable import VideoScan

// Catalog files table state (2026-10-06, Catalog focus plan).
// Supersedes the R1 `filesTableFocused` pins: the per-table focus flag is
// gone, replaced by ONE `@FocusState var focusedPane: CatalogPane?` in
// CatalogView. The focus design's source sensors live in
// CatalogFocusPlanSensorTests.swift; real clicks and keys are pinned by
// VideoScanUITests/Gauntlet/CatalogKeyboardUITests.swift. This file keeps
// the logic + scale pins for the rows the table draws.

// MARK: - Empty volume pick = all files (scale)

@MainActor
@Suite("Catalog empty volume pick shows every file without an extra pass")
struct CatalogAllVolumesDefaultTests {

    private func rows(_ n: Int) -> [VideoRecord] {
        (0..<n).map { i in
            let r = VideoRecord()
            r.filename = "v\(i).mov"
            r.fullPath = "/Volumes/V\(i % 4)/v\(i).mov"
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            return r
        }
    }

    private func filtered(_ records: [VideoRecord], volumes: Set<String>) -> [VideoRecord] {
        CatalogContent(
            records: records,
            selectedIDs: .constant([]),
            focusedPane: FocusState<CatalogPane?>().projectedValue,
            sortOrder: .constant([]),
            searchText: "",
            searchHitCount: .constant(0),
            filterTargetPaths: volumes,
            showPairsOnly: false,
            viewFilters: [],
            showDisconnectedMedia: true,   // no reachability probes in a unit test
            showRemoved: false,
            previewImage: nil,
            previewFilename: "",
            previewOfflineVolumeName: nil,
            showInspector: .constant(false),
            onSort: { _ in },
            onSelect: { _ in },
            onClearPreview: {}
        ).computeFiltered()
    }

    @Test func emptyPickIsEveryVolumeAndAPickNarrows() {
        let all = rows(8)
        #expect(filtered(all, volumes: []).count == 8)
        #expect(filtered(all, volumes: ["/Volumes/V1"]).map(\.filename) == ["v1.mov", "v5.mov"])
    }

    @Test func allVolumes100kStaysUnderBudget() {
        let all = rows(100_000)
        let t0 = Date()
        let out = filtered(all, volumes: [])
        let elapsed = Date().timeIntervalSince(t0)
        #expect(out.count == 100_000)
        #expect(elapsed < PerformanceLane.debugCeiling(seconds: 1.0), "all-volumes filter took \(elapsed)s for 100k records")
    }
}

// MARK: - Selection prune: logic + scale (074bacb6)

@Suite("Catalog filter change keeps the visible file selection")
struct CatalogSelectionPruneTests {

    private func rows(_ n: Int) -> [VideoRecord] {
        (0..<n).map { i in
            let r = VideoRecord()
            r.filename = "v\(i).mov"
            r.fullPath = "/Volumes/V\(i % 4)/v\(i).mov"
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            return r
        }
    }

    @Test func keepsVisibleDropsHidden() {
        let all = rows(10)
        let picked: Set<UUID> = [all[1].id, all[5].id, all[8].id]
        let visible = [all[0], all[1], all[2], all[8]]
        #expect(CatalogSelectionPrune.visibleSelection(picked, rows: visible) == [all[1].id, all[8].id])
    }

    @Test func emptySelectionAndFullyVisibleSelectionAreUnchanged() {
        let all = rows(5)
        #expect(CatalogSelectionPrune.visibleSelection([], rows: all).isEmpty)
        let picked: Set<UUID> = [all[0].id, all[4].id]
        #expect(CatalogSelectionPrune.visibleSelection(picked, rows: all) == picked)
        #expect(CatalogSelectionPrune.visibleSelection(picked, rows: []).isEmpty, "a filter that hides everything drops the selection")
    }

    /// Scale (checklist dimension 2): runs on every filter trigger.
    @Test func prune100kRowsStaysUnderBudget() {
        let all = rows(100_000)
        let picked = Set(all.prefix(1_000).map(\.id)).union([UUID()])
        let t0 = Date()
        let kept = CatalogSelectionPrune.visibleSelection(picked, rows: all)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(kept.count == 1_000)
        #expect(elapsed < PerformanceLane.debugCeiling(seconds: 0.25), "prune took \(elapsed)s for 100k rows")
    }
}
