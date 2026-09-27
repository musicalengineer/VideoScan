// HallieTestAssetConfiguration.swift
// GH #205 (2026-09-27): Hallie answers that attach a family photo must not
// read the HOST's published asset configuration under test — whether the
// real archive happens to be mounted would decide the result (the
// settings-pollution class). Tests hand `Context(assetConfiguration:)` one
// of these instead.

import Foundation
@testable import VideoScan

extension FamilyAssetConfiguration {
    /// An asset lookup that finds nothing: its root never exists.
    static let emptyForTests: FamilyAssetConfiguration = {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoScanTests-no-family-assets-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        return FamilyAssetConfiguration(
            roots: FamilyAssetStore.Roots(assets: base.appendingPathComponent("assets", isDirectory: true),
                                          thumbnailCache: base.appendingPathComponent("cache", isDirectory: true)),
            access: .readOnly, legacyGEDCOMDirectory: nil)
    }()

    /// A read-only lookup rooted at `assets` (a fixture `40_Family_Tree`).
    static func fixture(assets: URL) -> FamilyAssetConfiguration {
        FamilyAssetConfiguration(
            roots: FamilyAssetStore.Roots(assets: assets,
                                          thumbnailCache: assets.deletingLastPathComponent()
                                            .appendingPathComponent("cache", isDirectory: true)),
            access: .readOnly, legacyGEDCOMDirectory: nil)
    }
}
