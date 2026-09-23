// ArchiveTimelineRailScrollSensorTests.swift
// Rick 2026-09-23: clicking a decade in the Archive timeline rail did nothing
// (only "Undated" jumped). Cause: the rail's ForEach(timeline.decades) gives
// each rail row the decade's Int id, so ScrollViewReader.scrollTo(1990)
// resolved to the rail's own visible row. Stream anchors now live in their
// own String id space. This source sensor keeps it that way — a UI click
// can't be unit-tested, but the id discipline can.

import Foundation
import Testing
@testable import VideoScan

@Suite("Archive timeline — rail scroll targets never collide with rail rows")
struct ArchiveTimelineRailScrollSensorTests {

    private func source() throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let file = here.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/ArchiveView+Timeline.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    @Test("every stream anchor and the rail's scrollTo go through anchorID (String), never a bare decade Int")
    func anchorsUseTheirOwnIDSpace() throws {
        let s = try source()
        #expect(s.contains("proxy.scrollTo(Self.anchorID(anchor)"), "the rail scrolls to anchorID(...)")
        #expect(!s.contains(".id(decade.id)"), "a bare decade Int id collides with the rail's ForEach rows")
        #expect(!s.contains(".id(Self.undatedAnchor)"), "the undated anchor goes through anchorID too")
        #expect(s.components(separatedBy: ".id(Self.anchorID(").count - 1 >= 3,
                "gap band, decade marker and undated marker all use anchorID")
    }
}
