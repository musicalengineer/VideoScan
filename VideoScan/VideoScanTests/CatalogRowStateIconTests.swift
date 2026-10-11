// CatalogRowStateIconTests.swift
// The Filename column's state-glyph ladder, pinned as it was spelled inline
// in CatalogContent.catalogTableBase before the 2026-10-10 extraction:
// purged › set aside › superseded › unanalyzable › workspace › pair glyph ›
// none, with each glyph's symbol and colour.

import XCTest
import SwiftUI
@testable import VideoScan
import VideoScanCore

final class CatalogRowStateIconTests: XCTestCase {

    private func record(purged: Bool = false, setAside: Bool = false, superseded: Bool = false,
                        needsReformat: Bool = false, workspace: Bool = false,
                        stream: StreamType = .videoAndAudio) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = "/Volumes/T/a.mov"
        r.filename = "a.mov"
        r.streamTypeRaw = stream.rawValue
        if purged { r.purgedAt = Date() }
        if setAside { r.setAsideReason = "still-image" }
        if superseded { r.supersededByID = UUID() }
        r.needsReformat = needsReformat
        r.workspaceActive = workspace
        return r
    }

    private func icon(_ rec: VideoRecord, pairTint: Bool = false) -> CatalogRowStateIcon? {
        CatalogRowStateIcon.icon(for: rec, pairTint: pairTint)
    }

    func test_plainRowHasNoGlyph() {
        XCTAssertNil(icon(record()))
        XCTAssertNil(icon(record(stream: .videoOnly)), "a pair glyph needs the Pairs-only tint")
    }

    func test_ladderPriority_highestWins() {
        XCTAssertEqual(icon(record(purged: true, setAside: true, superseded: true, needsReformat: true, workspace: true), pairTint: true), .purged)
        XCTAssertEqual(icon(record(setAside: true, superseded: true, needsReformat: true, workspace: true), pairTint: true), .setAside)
        XCTAssertEqual(icon(record(superseded: true, needsReformat: true, workspace: true), pairTint: true), .superseded)
        XCTAssertEqual(icon(record(needsReformat: true, workspace: true), pairTint: true), .unanalyzable)
        XCTAssertEqual(icon(record(workspace: true), pairTint: true), .workspace)
    }

    func test_pairGlyph_followsTheStreamType() {
        XCTAssertEqual(icon(record(stream: .videoOnly), pairTint: true), .pairedVideo)
        XCTAssertEqual(icon(record(stream: .audioOnly), pairTint: true), .pairedAudio)
        XCTAssertEqual(icon(record(stream: .videoAndAudio), pairTint: true), .pairedAudio,
                       "anything that is not video-only takes the waveform — as the column always did")
    }

    func test_symbolsAndColours() {
        let expected: [(CatalogRowStateIcon, String, Color)] = [
            (.purged, "trash.slash", .orange), (.setAside, "archivebox", .purple),
            (.superseded, "arrow.triangle.swap", .brown), (.unanalyzable, "exclamationmark.triangle.fill", .red),
            (.workspace, "hammer.fill", .mint), (.pairedVideo, "film", .blue), (.pairedAudio, "waveform", .green),
        ]
        for (icon, symbol, color) in expected {
            XCTAssertEqual(icon.systemImage, symbol)
            XCTAssertEqual(icon.color, color)
        }
    }
}
