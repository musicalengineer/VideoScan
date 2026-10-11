// VolumeContextMenuRulesTests.swift
// Truth tables for the volume context menu's decisions, lifted out of the
// @ViewBuilder on 2026-10-10 (CatalogView.volumeContextCatalogSection). The
// rows are the conditions the view body used to spell inline; a quirk is
// pinned where one exists so it is at least a known one.

import XCTest
@testable import VideoScan
import VideoScanCore

final class VolumeContextMenuRulesTests: XCTestCase {

    private func record(_ path: String, _ stream: StreamType = .videoAndAudio, volumeName: String = "LaCie") -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.streamTypeRaw = stream.rawValue
        r.scanContext.volumeName = volumeName
        return r
    }

    func test_captionableVideoCount_countsVideoStreamsUnderThePath() {
        let records = [
            record("/Volumes/A/a.mov", .videoAndAudio),
            record("/Volumes/A/b.mxf", .videoOnly),
            record("/Volumes/A/c.wav", .audioOnly),
            record("/Volumes/A/d.bin", .ffprobeFailed),
            record("/Volumes/B/e.mov", .videoAndAudio),
        ]
        XCTAssertEqual(VolumeContextMenuRules.captionableVideoCount(records: records, under: "/Volumes/A"), 2)
        XCTAssertEqual(VolumeContextMenuRules.captionableVideoCount(records: records, under: "/Volumes/B"), 1)
        XCTAssertEqual(VolumeContextMenuRules.captionableVideoCount(records: records, under: "/Volumes/C"), 0)
        XCTAssertEqual(VolumeContextMenuRules.captionableVideoCount(records: [], under: "/Volumes/A"), 0)
    }

    func test_captionableVideoCount_matchesWholePathComponentsOnly() {
        // Was pinned-not-endorsed by the 2026-10-10 refactor as a plain
        // prefix match; fixed 2026-10-11 (bug-fix lane): "/Volumes/A"
        // must not take "/Volumes/AB/…", and an empty path takes nothing.
        let records = [record("/Volumes/AB/x.mov", .videoOnly), record("/Volumes/A/y.mov", .videoOnly)]
        XCTAssertEqual(VolumeContextMenuRules.captionableVideoCount(records: records, under: "/Volumes/A"), 1)
        XCTAssertEqual(VolumeContextMenuRules.captionableVideoCount(records: records, under: "/Volumes/A/"), 1, "trailing slash is the same root")
        XCTAssertEqual(VolumeContextMenuRules.captionableVideoCount(records: records, under: "/Volumes/AB"), 1)
        XCTAssertEqual(VolumeContextMenuRules.captionableVideoCount(records: records, under: ""), 0, "an empty path is not a match-everything scope")
    }

    func test_offersMigrationReport_forRetiredOrOfflineOnly() {
        XCTAssertFalse(VolumeContextMenuRules.offersMigrationReport(isRetired: false, isReachable: true), "online, in service: noise")
        XCTAssertTrue(VolumeContextMenuRules.offersMigrationReport(isRetired: true, isReachable: true), "parked")
        XCTAssertTrue(VolumeContextMenuRules.offersMigrationReport(isRetired: false, isReachable: false), "gone")
        XCTAssertTrue(VolumeContextMenuRules.offersMigrationReport(isRetired: true, isReachable: false))
    }

    func test_offersVolumeNameBackfill_severalVolumesOrOneWithUnnamedRecords() {
        let named = [record("/Volumes/A/a.mov"), record("/Volumes/A/b.mov")]
        let mixed = named + [record("/Volumes/A/c.mov", volumeName: "")]
        XCTAssertTrue(VolumeContextMenuRules.offersVolumeNameBackfill(targetCount: 2, records: named), "two volumes: always")
        XCTAssertTrue(VolumeContextMenuRules.offersVolumeNameBackfill(targetCount: 3, records: []))
        XCTAssertFalse(VolumeContextMenuRules.offersVolumeNameBackfill(targetCount: 1, records: named))
        XCTAssertTrue(VolumeContextMenuRules.offersVolumeNameBackfill(targetCount: 1, records: mixed))
        XCTAssertFalse(VolumeContextMenuRules.offersVolumeNameBackfill(targetCount: 1, records: []))
        XCTAssertFalse(VolumeContextMenuRules.offersVolumeNameBackfill(targetCount: 0, records: mixed), "no selection, no item")
    }

    func test_offersReset_whenAnyTargetHasFinished() {
        XCTAssertTrue(VolumeContextMenuRules.offersReset(statuses: [.idle, .complete]))
        XCTAssertTrue(VolumeContextMenuRules.offersReset(statuses: [.stopped]))
        XCTAssertTrue(VolumeContextMenuRules.offersReset(statuses: [.error, .scanning]))
        XCTAssertFalse(VolumeContextMenuRules.offersReset(statuses: [.idle, .resumable, .scanning, .paused, .discovering, .waitingForVolume]))
        XCTAssertFalse(VolumeContextMenuRules.offersReset(statuses: []))
    }
}
