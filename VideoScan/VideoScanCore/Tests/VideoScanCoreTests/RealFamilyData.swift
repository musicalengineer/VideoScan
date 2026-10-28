import Foundation
import XCTest

/// Rick's real GEDCOMs on the Master Archive, for the few tests that prove
/// something against production-sized family data. Opt-in only:
///
///     VIDEOSCAN_REAL_DATA=1 swift test --package-path … --filter Gedcom
///
/// Run it by hand from Terminal. 2026-10-28: a launchd nightly that merely
/// stat'ed /Volumes/FamilyArchive made macOS raise "would like to access
/// files on a removable volume" and the test waited for a click at 5 a.m.
/// (sandboxd "request approval" 05:03:58, a 900 s Core stall). Merely
/// mounting the archive never opts a suite in; nothing here touches
/// /Volumes until the switch is set. tests/test_no_real_volume_reads_in_tests.py
/// keeps real-volume URLs in this file only.
enum RealFamilyData {
    static let optIn = "VIDEOSCAN_REAL_DATA"
    static let bigTree =
        "/Volumes/FamilyArchive/Breen_Family_Archive/40_Family_Tree/GEDCOM/familysearch-tree-20generations.ged"
    static let donnaPull =
        "/Volumes/FamilyArchive/Breen_Family_Archive/40_Family_Tree/GEDCOM/pulls/familysearch-donna-20generations.ged"

    /// The file's URL, or an XCTSkip. The opt-in is checked before any stat.
    static func require(_ path: String) throws -> URL {
        guard ProcessInfo.processInfo.environment[optIn] == "1" else {
            throw XCTSkip("real family data: set \(optIn)=1 and run from Terminal")
        }
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("archive not mounted: \(path)") }
        return URL(fileURLWithPath: path)
    }
}
