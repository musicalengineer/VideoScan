// CorpusSweepDriver.swift — lane `sweep` of the real-data corpus harness.
// (How this file reaches a build, the seal and the privacy rule:
// CorpusDriverSupport.swift.)
//
// The check lane's engines (probe · Check Media quick · Verify Audio · the
// pair link — CorpusCheckDriver.walk, one code path) over files READ IN PLACE
// on the read-only mount of the wider collection under ~/corpus/live, with a
// catalog built for the run from the catalog backup (scripts/corpus_run.py,
// SweepLane). Nothing is copied, nothing is written beside the files; the seal
// (CorpusSeal.swift) admits a `sourceRoot` for this lane only, inside live.

import Foundation
import XCTest

final class CorpusSweepDriver: XCTestCase {

    func testSweepLane() async throws {
        try await CorpusCheckDriver.walk(lane: "sweep")
    }
}
