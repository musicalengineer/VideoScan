// CatalogChangeDetectorTests.swift
// LOGIC for the change detector (cutover B2): a fingerprint is a pure
// function of the persisted state — the same state → the same value, a
// change in any field class → a new one; the changed list is exactly the
// records that differ from the baseline (or have none); the parallel pass
// agrees with the serial one. Scale: CatalogCommitScaleTests.
//
// Suite (filter by SUITE): CatalogChangeDetectorTests

import Foundation
import Testing
@testable import VideoScanCore

@Suite("CatalogChangeDetector — the dirty bit is a fingerprint of the persisted state")
struct CatalogChangeDetectorTests {

    private static func rich() -> VideoRecord {
        let other = UUID()
        return RichRecord.make(id: UUID(), path: "/Volumes/F/rich.mov", digest: String(repeating: "a", count: 64),
                               sizeBytes: 4_096, pairWith: other, otherRow: other)
    }

    @Test func theSameStateHasTheSameFingerprint() {
        let r = Self.rich()
        #expect(CatalogChangeDetector.fingerprint(VideoRecordDTO(r)) == CatalogChangeDetector.fingerprint(VideoRecordDTO(r)))
    }

    @Test("a change in any field class moves the fingerprint", arguments: [
        "star", "tag", "date", "marker", "path", "caption", "pair", "probe",
    ])
    func anyChangeMovesIt(_ what: String) {
        let r = Self.rich()
        let before = CatalogChangeDetector.fingerprint(VideoRecordDTO(r))
        switch what {
        case "star": r.starRating = 1
        case "tag": r.tags.append("New")
        case "date": r.userDate = "1999"
        case "marker": r.removalRevision += 1
        case "path": r.fullPath += ".moved"
        case "caption": r.sceneCaptions[0] = SceneCaption(timestamp: 1.5, text: "a lake at dusk")
        case "pair": r.pairConfidence = .low
        default: r.resolution = "640x480"
        }
        #expect(CatalogChangeDetector.fingerprint(VideoRecordDTO(r)) != before)
    }

    @Test func theChangedListIsTheRecordsThatDiffer() {
        let records = (0..<4).map { _ in Self.rich() }
        let prints = CatalogChangeDetector.fingerprints(of: records.map(VideoRecordDTO.init))
        var baseline = Dictionary(uniqueKeysWithValues: zip(records.map(\.id), prints))
        baseline[records[3].id] = nil                 // never stored
        records[1].starRating = 1                      // edited
        let now = CatalogChangeDetector.fingerprints(of: records.map(VideoRecordDTO.init))
        #expect(CatalogChangeDetector.changed(records.map(\.id), fingerprints: now, baseline: baseline) == [1, 3])
    }

    @Test func parallelAndSerialAgree() {
        let records = (0..<300).map { _ in Self.rich() }
        let dtos = records.map(VideoRecordDTO.init)
        #expect(CatalogChangeDetector.fingerprints(of: dtos) == dtos.map { CatalogChangeDetector.fingerprint($0) })
    }
}
