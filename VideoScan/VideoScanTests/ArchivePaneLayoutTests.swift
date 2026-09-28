// ArchivePaneLayoutTests.swift
// Bug 2026-09-24 (Rick): the Archive header and the sidebar top slid under
// the window's title/tab bar once the Archive Angel list grew taller than
// the window. These tests pin the layout policy (logic) and the structure
// that enforces it (source sensors) — a UI test would need the M4's screen.

import Foundation
import CoreGraphics
import Testing
@testable import VideoScan

@Suite("Archive pane layout — header never under the chrome")
struct ArchivePaneLayoutTests {

    // MARK: Logic

    @Test func capIsAShareOfThePane() {
        #expect(ArchivePaneLayout.angelRegionCap(paneHeight: 1000) == 600)
        #expect(ArchivePaneLayout.angelRegionCap(paneHeight: 1301) == 780)
    }

    @Test func capHasAFloorForShortPanesAndBeforeMeasurement() {
        #expect(ArchivePaneLayout.angelRegionCap(paneHeight: 0) == ArchivePaneLayout.angelMinCap)
        #expect(ArchivePaneLayout.angelRegionCap(paneHeight: 250) == ArchivePaneLayout.angelMinCap)
        #expect(ArchivePaneLayout.angelRegionCap(paneHeight: .infinity) == ArchivePaneLayout.angelMinCap)
        #expect(ArchivePaneLayout.angelRegionCap(paneHeight: -5) == ArchivePaneLayout.angelMinCap)
    }

    @Test func shortContentIsHuggedNotPadded() {
        // Turndown closed: just the strip's one header line.
        #expect(ArchivePaneLayout.regionHeight(contentHeight: 52, cap: 600) == 52)
    }

    @Test func tallContentStopsAtTheCap() {
        #expect(ArchivePaneLayout.regionHeight(contentHeight: 5_000, cap: 600) == 600)
    }

    @Test func degenerateContentHeightsAreZero() {
        #expect(ArchivePaneLayout.regionHeight(contentHeight: 0, cap: 600) == 0)
        #expect(ArchivePaneLayout.regionHeight(contentHeight: -1, cap: 600) == 0)
        #expect(ArchivePaneLayout.regionHeight(contentHeight: .nan, cap: 600) == 0)
        #expect(ArchivePaneLayout.regionHeight(contentHeight: 100, cap: -10) == 0)
    }

    /// Sensor at the scale that broke: every page of rows Rick could open
    /// ("Show 10 more" up to 2,508 recommendations, ~130 pt a row when the
    /// buttons wrap) in any plausible pane — the Angel region never takes
    /// the space the header needs.
    @Test func headerAlwaysFitsWhateverTheListHolds() {
        let header: CGFloat = 45 + 90          // toolbar + progress bar, generous
        for pane in stride(from: CGFloat(500), through: 2_200, by: 50) {
            for rows in stride(from: 0, through: 2_508, by: 10) {
                let content = 52 + CGFloat(rows) * 130
                let region = ArchivePaneLayout.regionHeight(
                    contentHeight: content,
                    cap: ArchivePaneLayout.angelRegionCap(paneHeight: pane))
                #expect(region <= max(ArchivePaneLayout.angelMinCap, pane * ArchivePaneLayout.angelMaxFraction))
                if pane >= 600 { #expect(header + region <= pane) }
            }
        }
    }

    // MARK: Source sensors

    private var appSourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // VideoScanTests
            .deletingLastPathComponent()      // VideoScan (project dir)
            .appendingPathComponent("VideoScan")
    }

    private func source(_ file: String) throws -> String {
        try String(contentsOf: appSourceDir.appendingPathComponent(file), encoding: .utf8)
    }

    /// The strip is placed exactly once, and inside the bounded region.
    @Test func angelStripLivesInsideTheBoundedRegion() throws {
        let table = try source("ArchiveView+Table.swift")
        let region = try #require(table.range(of: "HuggingScrollRegion(maxHeight: ArchivePaneLayout.angelRegionCap("))
        let strip = try #require(table.range(of: "ArchiveAngelStrip("))
        #expect(region.upperBound < strip.lowerBound)
        // Nothing but whitespace/the closure brace between them.
        let between = table[region.upperBound..<strip.lowerBound]
        #expect(between.count < 80, "ArchiveAngelStrip must be the region's direct content")
        #expect(table.components(separatedBy: "ArchiveAngelStrip(").count - 1 == 1)
    }

    /// Both split panes clip at the bottom, never centre their overflow.
    @Test func splitPanesAreTopAlignedAndMayShrink() throws {
        let view = try source("ArchiveView.swift")
        let squashed = view.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
        #expect(squashed.contains(".frame(minWidth:260,idealWidth:300,maxWidth:380,minHeight:0,maxHeight:.infinity,alignment:.top)"))
        #expect(squashed.contains(".frame(minWidth:500,maxWidth:.infinity,minHeight:0,maxHeight:.infinity,alignment:.top)"))
    }

    /// Nothing in the Archive tab or the Angel's UI draws under the title bar.
    @Test func archiveTabNeverIgnoresTheSafeArea() throws {
        let fm = FileManager.default
        var files = ["ArchiveView.swift", "ArchiveView+Table.swift", "ArchiveView+Layout.swift",
                     "ArchiveView+Timeline.swift"]
        let angelUI = appSourceDir.appendingPathComponent("ArchiveAngel/UI")
        files += try fm.contentsOfDirectory(atPath: angelUI.path)
            .filter { $0.hasSuffix(".swift") }
            .map { "ArchiveAngel/UI/\($0)" }
        #expect(files.count > 5)
        for file in files {
            let s = try source(file)
            #expect(!s.contains(".ignoresSafeArea"), "\(file) ignores the safe area")
            #expect(!s.contains(".edgesIgnoringSafeArea"), "\(file) ignores the safe area")
        }
    }
}
