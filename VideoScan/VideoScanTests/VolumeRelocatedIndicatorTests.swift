import Testing
import Foundation
@testable import VideoScan

// MARK: - VolumeRelocatedIndicatorTests
//
// Covers the "Relocated to <path>" computation used by the Volumes-window
// editor pane (`VideoScanModel.relocatedDestinationSummary`).
//
// Pure builder — no MainActor, no filesystem. Pattern parallels
// ProvenanceTests.

@Suite
struct VolumeRelocatedIndicatorTests {

    // MARK: - Fixtures

    private func makeRecord(fullPath: String,
                            originalFullPath: String? = nil,
                            originVolume: String? = nil) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (fullPath as NSString).lastPathComponent
        r.fullPath = fullPath
        r.directory = (fullPath as NSString).deletingLastPathComponent
        r.originalFullPath = originalFullPath
        r.originVolume = originVolume
        return r
    }

    // MARK: - relocatedDestinationSummary

    @Test
    func relocatedTo_returnsNoneWhenNoRecordsMoved() {
        // Two records, both still resident on ExternalRAID. Neither has
        // ever moved — should return nil so the banner stays hidden.
        let records = [
            makeRecord(fullPath: "/Volumes/ExternalRAID/clip1.mxf"),
            makeRecord(fullPath: "/Volumes/ExternalRAID/sub/clip2.mxf")
        ]
        let summary = VideoScanModel.relocatedDestinationSummary(
            sourceVolumeRootPath: "/Volumes/ExternalRAID",
            sourceVolumeName: "ExternalRAID",
            allRecords: records
        )
        #expect(summary == nil)
    }

    @Test
    func relocatedTo_returnsCommonPrefixWhenAllRecordsOnSingleDest() {
        // 3 records originated on ExternalRAID, all relocated under
        // /Volumes/LaCieWorkspace/CheesegraterArchive/ExternalRAID/...
        // The longest common prefix should be that whole directory,
        // ending with a '/' boundary.
        let records = [
            makeRecord(
                fullPath: "/Volumes/LaCieWorkspace/CheesegraterArchive/ExternalRAID/a.mxf",
                originalFullPath: "/Volumes/ExternalRAID/a.mxf",
                originVolume: "ExternalRAID"),
            makeRecord(
                fullPath: "/Volumes/LaCieWorkspace/CheesegraterArchive/ExternalRAID/b.mxf",
                originalFullPath: "/Volumes/ExternalRAID/b.mxf",
                originVolume: "ExternalRAID"),
            makeRecord(
                fullPath: "/Volumes/LaCieWorkspace/CheesegraterArchive/ExternalRAID/c.mxf",
                originalFullPath: "/Volumes/ExternalRAID/c.mxf",
                originVolume: "ExternalRAID")
        ]
        let summary = VideoScanModel.relocatedDestinationSummary(
            sourceVolumeRootPath: "/Volumes/ExternalRAID",
            sourceVolumeName: "ExternalRAID",
            allRecords: records
        )
        let unwrapped = try? #require(summary)
        guard let s = unwrapped else { return }
        #expect(s.dominantDestinationPath
                == "/Volumes/LaCieWorkspace/CheesegraterArchive/ExternalRAID/")
        #expect(s.dominantDestinationVolume == "LaCieWorkspace")
        #expect(s.dominantDestinationCount == 3)
        #expect(s.movedRecordCount == 3)
        #expect(s.totalOriginRecords == 3)
        #expect(s.hasOtherDestinations == false)
        #expect(s.otherDestinationVolumeCount == 0)
    }

    @Test
    func relocatedTo_handlesMultipleDestinations() {
        // 4 records originated on ExternalRAID:
        //   - 3 went to /Volumes/LaCieWorkspace/CheesegraterArchive/ExternalRAID/
        //   - 1 went to /Volumes/MyBook3Terabytes/Salvage/
        // LaCieWorkspace is the dominant destination (3 > 1); MyBook is
        // surfaced via the "and 1 more on other volumes" subtitle bits.
        let records = [
            makeRecord(
                fullPath: "/Volumes/LaCieWorkspace/CheesegraterArchive/ExternalRAID/a.mxf",
                originalFullPath: "/Volumes/ExternalRAID/a.mxf",
                originVolume: "ExternalRAID"),
            makeRecord(
                fullPath: "/Volumes/LaCieWorkspace/CheesegraterArchive/ExternalRAID/b.mxf",
                originalFullPath: "/Volumes/ExternalRAID/b.mxf",
                originVolume: "ExternalRAID"),
            makeRecord(
                fullPath: "/Volumes/LaCieWorkspace/CheesegraterArchive/ExternalRAID/c.mxf",
                originalFullPath: "/Volumes/ExternalRAID/c.mxf",
                originVolume: "ExternalRAID"),
            makeRecord(
                fullPath: "/Volumes/MyBook3Terabytes/Salvage/d.mxf",
                originalFullPath: "/Volumes/ExternalRAID/sub/d.mxf",
                originVolume: "ExternalRAID")
        ]
        let summary = VideoScanModel.relocatedDestinationSummary(
            sourceVolumeRootPath: "/Volumes/ExternalRAID",
            sourceVolumeName: "ExternalRAID",
            allRecords: records
        )
        guard let s = summary else {
            Issue.record("expected a summary, got nil")
            return
        }
        #expect(s.dominantDestinationVolume == "LaCieWorkspace")
        #expect(s.dominantDestinationCount == 3)
        #expect(s.dominantDestinationPath
                == "/Volumes/LaCieWorkspace/CheesegraterArchive/ExternalRAID/")
        #expect(s.movedRecordCount == 4)
        #expect(s.hasOtherDestinations == true)
        #expect(s.otherDestinationVolumeCount == 1)
    }

    @Test
    func relocatedTo_handlesPartialMove_someStillOnSource() {
        // 4 records originated on Mini2TB. 2 still resident, 2 moved to
        // LaCieWorkspace. Banner SHOULD appear, with 2 of 4 moved.
        let records = [
            makeRecord(
                fullPath: "/Volumes/Mini2TB/clip1.mxf",
                originalFullPath: nil,
                originVolume: nil),
            makeRecord(
                fullPath: "/Volumes/Mini2TB/clip2.mxf",
                originalFullPath: nil,
                originVolume: nil),
            makeRecord(
                fullPath: "/Volumes/LaCieWorkspace/Migrated/Mini2TB/clip3.mxf",
                originalFullPath: "/Volumes/Mini2TB/clip3.mxf",
                originVolume: "Mini2TB"),
            makeRecord(
                fullPath: "/Volumes/LaCieWorkspace/Migrated/Mini2TB/clip4.mxf",
                originalFullPath: "/Volumes/Mini2TB/clip4.mxf",
                originVolume: "Mini2TB")
        ]
        let summary = VideoScanModel.relocatedDestinationSummary(
            sourceVolumeRootPath: "/Volumes/Mini2TB",
            sourceVolumeName: "Mini2TB",
            allRecords: records
        )
        guard let s = summary else {
            Issue.record("expected a summary, got nil")
            return
        }
        #expect(s.movedRecordCount == 2)
        // totalOriginRecords counts: 2 moved + 0 still resident (the two
        // still resident ones have originVolume=nil and no
        // originalFullPath, so they don't satisfy the "originated here"
        // predicate). That matches the spec edge case: records with nil
        // originVolume are excluded from the partition.
        #expect(s.totalOriginRecords == 2)
        #expect(s.dominantDestinationVolume == "LaCieWorkspace")
        #expect(s.dominantDestinationPath
                == "/Volumes/LaCieWorkspace/Migrated/Mini2TB/")
        #expect(s.hasOtherDestinations == false)
    }

    @Test
    func relocatedTo_excludesRecordsWithNilOriginVolume() {
        // 3 records, none have originVolume set and none have an
        // originalFullPath under ExternalRAID. They live on a third
        // volume entirely. Expected: nil — never relocated FROM
        // ExternalRAID.
        let records = [
            makeRecord(fullPath: "/Volumes/LaCieWorkspace/random/a.mxf"),
            makeRecord(fullPath: "/Volumes/LaCieWorkspace/random/b.mxf"),
            makeRecord(fullPath: "/Volumes/LaCieWorkspace/random/c.mxf")
        ]
        let summary = VideoScanModel.relocatedDestinationSummary(
            sourceVolumeRootPath: "/Volumes/ExternalRAID",
            sourceVolumeName: "ExternalRAID",
            allRecords: records
        )
        #expect(summary == nil)
    }

    @Test
    func relocatedTo_longestCommonPathPrefix_acrossMixedSubpaths() {
        // 3 records originated on ExternalRAID, all on LaCieWorkspace but
        // under DIFFERENT subfolders. The common prefix should fall back
        // to /Volumes/LaCieWorkspace/CheesegraterArchive/ — the deepest
        // shared directory.
        let records = [
            makeRecord(
                fullPath: "/Volumes/LaCieWorkspace/CheesegraterArchive/Video/clip1.mxf",
                originalFullPath: "/Volumes/ExternalRAID/Video/clip1.mxf",
                originVolume: "ExternalRAID"),
            makeRecord(
                fullPath: "/Volumes/LaCieWorkspace/CheesegraterArchive/Audio/clip2.mxf",
                originalFullPath: "/Volumes/ExternalRAID/Audio/clip2.mxf",
                originVolume: "ExternalRAID"),
            makeRecord(
                fullPath: "/Volumes/LaCieWorkspace/CheesegraterArchive/Extras/clip3.mxf",
                originalFullPath: "/Volumes/ExternalRAID/Extras/clip3.mxf",
                originVolume: "ExternalRAID")
        ]
        let summary = VideoScanModel.relocatedDestinationSummary(
            sourceVolumeRootPath: "/Volumes/ExternalRAID",
            sourceVolumeName: "ExternalRAID",
            allRecords: records
        )
        guard let s = summary else {
            Issue.record("expected a summary, got nil")
            return
        }
        // Critically NOT "/Volumes/LaCieWorkspace/CheesegraterArchive/V"
        // — the prefix scan trims back to the last '/' so we never
        // truncate mid-component.
        #expect(s.dominantDestinationPath
                == "/Volumes/LaCieWorkspace/CheesegraterArchive/")
        #expect(s.dominantDestinationCount == 3)
        #expect(s.hasOtherDestinations == false)
    }

    // MARK: - longestCommonPathPrefix (helper, exposed for testing)

    @Test
    func longestCommonPathPrefix_singlePath_returnsParentWithSlash() {
        let result = VideoScanModel.longestCommonPathPrefix(
            ["/Volumes/Foo/Bar/clip.mxf"]
        )
        #expect(result == "/Volumes/Foo/Bar/")
    }

    @Test
    func longestCommonPathPrefix_emptyInput_returnsEmpty() {
        #expect(VideoScanModel.longestCommonPathPrefix([]) == "")
    }

    @Test
    func longestCommonPathPrefix_trimsBackToLastSlash() {
        // The raw char-by-char prefix would be "/Volumes/Foo/clip" — the
        // helper must trim back to "/Volumes/Foo/" so the indicator
        // doesn't render a truncated filename.
        let result = VideoScanModel.longestCommonPathPrefix([
            "/Volumes/Foo/clip1.mxf",
            "/Volumes/Foo/clip2.mxf"
        ])
        #expect(result == "/Volumes/Foo/")
    }
}
