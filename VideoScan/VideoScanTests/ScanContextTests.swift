// ScanContextTests.swift
// Covers the `scanRootLabel` field added so the catalog UI can disambiguate
// multiple folder-scoped scans with the same folder name across volumes.

import Testing
import Foundation
@testable import VideoScan

@Suite("ScanContext scanRootLabel")
struct ScanContextScanRootLabelTests {

    // MARK: - subfolderLabel helper

    @Test func wholeVolumeRootReturnsNil() {
        #expect(ScanContext.subfolderLabel(forScanRootPath: "/Volumes/MyBook") == nil)
    }

    @Test func wholeVolumeRootWithTrailingSlashReturnsNil() {
        #expect(ScanContext.subfolderLabel(forScanRootPath: "/Volumes/MyBook/") == nil)
    }

    @Test func subfolderReturnsBasename() {
        #expect(ScanContext.subfolderLabel(forScanRootPath: "/Volumes/MyBook/Movies") == "Movies")
    }

    @Test func deepSubfolderReturnsLastComponent() {
        // Should be the LAST component, not the joined subpath.
        #expect(ScanContext.subfolderLabel(forScanRootPath: "/Volumes/MyBook/Movies/2024/summer") == "summer")
    }

    @Test func filesystemRootReturnsNil() {
        #expect(ScanContext.subfolderLabel(forScanRootPath: "/") == nil)
    }

    @Test func emptyPathReturnsNil() {
        #expect(ScanContext.subfolderLabel(forScanRootPath: "") == nil)
    }

    @Test func userHomeSubfolderReturnsBasename() {
        // Non-/Volumes paths: any non-root path is treated as a subfolder
        // because the system disk's volume name doesn't naturally embed a
        // useful tail.
        #expect(ScanContext.subfolderLabel(forScanRootPath: "/Users/rickb/Movies") == "Movies")
    }

    // MARK: - Codable round-trip

    @Test func codableRoundTripPreservesScanRootLabel() throws {
        var ctx = ScanContext()
        ctx.scanHost = "MacStudio"
        ctx.volumeName = "MyBook"
        ctx.scanRootLabel = "Movies"

        let encoded = try JSONEncoder().encode(ctx)
        let decoded = try JSONDecoder().decode(ScanContext.self, from: encoded)
        #expect(decoded.scanRootLabel == "Movies")
        #expect(decoded.volumeName == "MyBook")
        #expect(decoded.scanHost == "MacStudio")
    }

    @Test func legacyJSONWithoutScanRootLabelDecodesAsEmpty() throws {
        // Simulate a record written before scanRootLabel existed: just other
        // fields, no `scanRootLabel` key. Must decode without crashing.
        let legacyJSON = #"{"scanHost":"MacStudio","volumeName":"MyBook"}"#
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(ScanContext.self, from: data)
        #expect(decoded.scanRootLabel == "")
        #expect(decoded.volumeName == "MyBook")
    }

    @Test func emptyScanRootLabelOmittedFromEncoding() throws {
        // Keep snapshot deltas minimal: when scanRootLabel is empty (the
        // common whole-volume-scan case), it should NOT appear in JSON.
        var ctx = ScanContext()
        ctx.scanHost = "MacStudio"
        ctx.volumeName = "MyBook"
        // scanRootLabel stays default ""

        let data = try JSONEncoder().encode(ctx)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!json.contains("scanRootLabel"))
    }

    // MARK: - capture(for:scanRootPath:) integration

    @Test func captureWithVolumeRootPathLeavesLabelEmpty() {
        // Real on-disk URL doesn't matter for the label logic — capture just
        // forwards `scanRootPath` into the helper. Use a path under /tmp so
        // resourceValues calls don't crash.
        let url = URL(fileURLWithPath: "/tmp/example.mov")
        let ctx = ScanContext.capture(for: url, scanRootPath: "/Volumes/MyBook")
        #expect(ctx.scanRootLabel == "")
    }

    @Test func captureWithSubfolderPathStampsLabel() {
        let url = URL(fileURLWithPath: "/tmp/example.mov")
        let ctx = ScanContext.capture(for: url, scanRootPath: "/Volumes/MyBook/Movies")
        #expect(ctx.scanRootLabel == "Movies")
    }

    @Test func captureWithNilScanRootLeavesLabelEmpty() {
        // Backfill / legacy paths pass nil. Must produce no label.
        let url = URL(fileURLWithPath: "/tmp/example.mov")
        let ctx = ScanContext.capture(for: url, scanRootPath: nil)
        #expect(ctx.scanRootLabel == "")
    }
}
