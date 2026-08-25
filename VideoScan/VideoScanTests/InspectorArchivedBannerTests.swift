import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// "Archived on [Date] to [Volume] in nice bold green" (Rick 2026-08-25):
// the inspector line that says this content is safe — on the promote
// source, on a byte-identical original elsewhere, and on the copy itself.
struct InspectorArchivedBannerTests {

    private func copy(verified: Bool, volume: String = "FamilyArchive") -> VideoRecord {
        let c = VideoRecord()
        c.fullPath = "/Volumes/\(volume)/Breen_Family_Archive/30_Video/1980-1989/1984/1984-11-xx_Thanksgiving_1984.mkv"
        c.derivationKind = ArchivePromotion.derivationKind
        if verified {
            c.archiveFixity = ArchiveFixity(algorithm: "sha256", digest: String(repeating: "a", count: 64),
                                            verifiedAt: Date(timeIntervalSince1970: 1_787_000_000), sizeBytes: 10)
        }
        return c
    }

    @Test func promoteSourceGetsBoldGreenDateAndVolume() {
        let src = VideoRecord(); src.fullPath = "/Volumes/Projects/staging/x.mkv"
        let c = copy(verified: true); c.derivedFrom = src.id
        let banner = InspectorPanel.archivedBanner(record: src, masterCopy: c, promotionSource: nil)
        #expect(banner?.verified == true)
        #expect(banner?.text.hasPrefix("Archived on ") == true)
        #expect(banner?.text.hasSuffix(" to FamilyArchive") == true, Comment(rawValue: banner?.text ?? "nil"))
    }

    @Test func identicalOriginalElsewhereSaysSo() {
        let original = VideoRecord(); original.fullPath = "/Volumes/MediaExpansion/x.mkv"
        let c = copy(verified: true); c.derivedFrom = UUID()   // promoted from a different path
        let banner = InspectorPanel.archivedBanner(record: original, masterCopy: c, promotionSource: nil)
        #expect(banner?.verified == true)
        #expect(banner?.text.contains("(identical copy)") == true)
    }

    @Test func unverifiedCopyIsOrangeAndHonest() {
        let src = VideoRecord()
        let c = copy(verified: false); c.derivedFrom = src.id
        let banner = InspectorPanel.archivedBanner(record: src, masterCopy: c, promotionSource: nil)
        #expect(banner?.verified == false)
        #expect(banner?.text.contains("not yet verified") == true)
    }

    @Test func theCopyItselfShowsItsOwnFixity() {
        let src = VideoRecord()
        let c = copy(verified: true); c.derivedFrom = src.id
        let banner = InspectorPanel.archivedBanner(record: c, masterCopy: nil, promotionSource: src)
        #expect(banner?.verified == true && banner?.text.hasPrefix("Archived on ") == true)
        #expect(InspectorPanel.archivedBanner(record: src, masterCopy: nil, promotionSource: nil) == nil)
    }
}
