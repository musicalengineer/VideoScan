import Testing
import Foundation
@testable import VideoScan

// MARK: - RelocateScopeTests
//
// Covers the pure helpers from §2 of docs/relocate_volume_plan.md:
//   - VideoScanModel.recordsScoped(to:in:)
//   - VideoScanModel.rewrittenPath(forSourcePath:sourceRoot:destRoot:)
//   - VideoScanModel.suggestDestinationName(forSourceVolumeName:now:)
//
// These are the helpers the engine relies on to decide WHAT to copy
// and WHERE to put it. Bugs here would silently relocate the wrong
// records or stamp them with wrong paths — both catastrophic. Tests
// are hermetic (no disk).

@MainActor
struct RelocateScopeTests {

    // MARK: - Helper

    private func rec(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        return r
    }

    // MARK: - recordsScoped

    @Test
    func scopeMatchesOnlyRecordsUnderRoot() {
        let all = [
            rec("/Volumes/Mini2TB/family/2020.mov"),
            rec("/Volumes/Mini2TB/family/2021.mov"),
            rec("/Volumes/Crucial2TB/other.mov")
        ]
        let scoped = VideoScanModel.recordsScoped(to: "/Volumes/Mini2TB", in: all)
        #expect(scoped.count == 2)
        #expect(scoped.allSatisfy { $0.fullPath.hasPrefix("/Volumes/Mini2TB/") })
    }

    @Test
    func scopeAddsTrailingSlashToAvoidPrefixCollision() {
        // /Volumes/Mini2TB-backup must NOT match /Volumes/Mini2TB.
        let all = [
            rec("/Volumes/Mini2TB/file.mov"),
            rec("/Volumes/Mini2TB-backup/file.mov")
        ]
        let scoped = VideoScanModel.recordsScoped(to: "/Volumes/Mini2TB", in: all)
        #expect(scoped.count == 1)
        #expect(scoped.first?.fullPath == "/Volumes/Mini2TB/file.mov")
    }

    @Test
    func scopeAcceptsRootWithOrWithoutTrailingSlash() {
        let all = [rec("/Volumes/Mini2TB/family.mov")]
        let withSlash = VideoScanModel.recordsScoped(to: "/Volumes/Mini2TB/", in: all)
        let without = VideoScanModel.recordsScoped(to: "/Volumes/Mini2TB", in: all)
        #expect(withSlash.count == 1)
        #expect(without.count == 1)
    }

    @Test
    func emptyCatalogReturnsEmptyScope() {
        let scoped = VideoScanModel.recordsScoped(to: "/Volumes/Mini2TB", in: [])
        #expect(scoped.isEmpty)
    }

    // MARK: - rewrittenPath

    @Test
    func rewrittenPreservesSubdirectoryStructure() {
        let out = VideoScanModel.rewrittenPath(
            forSourcePath: "/Volumes/Mini2TB/family/2020/birthday.mov",
            sourceRoot: "/Volumes/Mini2TB",
            destRoot: "/Volumes/LaCie8TB/from-Mini2TB"
        )
        #expect(out == "/Volumes/LaCie8TB/from-Mini2TB/family/2020/birthday.mov")
    }

    @Test
    func rewrittenWithFileAtRootGivesFlatPath() {
        let out = VideoScanModel.rewrittenPath(
            forSourcePath: "/Volumes/Mini2TB/at-root.mov",
            sourceRoot: "/Volumes/Mini2TB",
            destRoot: "/Volumes/LaCie8TB/archive"
        )
        #expect(out == "/Volumes/LaCie8TB/archive/at-root.mov")
    }

    @Test
    func rewrittenNormalizesTrailingSlashOnBothRoots() {
        let out = VideoScanModel.rewrittenPath(
            forSourcePath: "/Volumes/Mini2TB/x/y.mov",
            sourceRoot: "/Volumes/Mini2TB/",
            destRoot: "/Volumes/LaCie8TB/archive/"
        )
        #expect(out == "/Volumes/LaCie8TB/archive/x/y.mov")
    }

    @Test
    func rewrittenFallsBackToLeafWhenSourceMismatched() {
        // Defensive case — recordsScoped should prevent this, but if a
        // mismatched path slips through, dropping it under destRoot as a
        // flat filename is the least-bad outcome.
        let out = VideoScanModel.rewrittenPath(
            forSourcePath: "/Volumes/Other/file.mov",
            sourceRoot: "/Volumes/Mini2TB",
            destRoot: "/Volumes/LaCie8TB/archive"
        )
        #expect(out == "/Volumes/LaCie8TB/archive/file.mov")
    }

    // MARK: - suggestDestinationName

    @Test
    func suggestedNameFormatIsFromVolumeDate() {
        let fixedDate = Date(timeIntervalSince1970: 1748563200)  // 2025-05-30 in some TZ
        let name = VideoScanModel.suggestDestinationName(
            forSourceVolumeName: "Mini2TB",
            now: fixedDate
        )
        #expect(name.hasPrefix("from-Mini2TB-"))
        #expect(name.count == "from-Mini2TB-".count + 8)  // YYYYMMDD
    }

    @Test
    func suggestedNameSanitizesUnsafeCharacters() {
        let name = VideoScanModel.suggestDestinationName(
            forSourceVolumeName: "My Old Drive / 2010",
            now: Date()
        )
        // Slashes and spaces must not survive (would break the
        // dest-folder URL).
        #expect(!name.contains(" "))
        #expect(!name.contains("/"))
    }

    // MARK: - RelocateError

    @Test
    func relocateErrorEquatable() {
        #expect(RelocateError.sourceUnreachable("a") == RelocateError.sourceUnreachable("a"))
        #expect(RelocateError.sourceUnreachable("a") != RelocateError.sourceUnreachable("b"))
        #expect(RelocateError.insufficientSpace(needed: 1, free: 0)
                != RelocateError.insufficientSpace(needed: 2, free: 0))
        #expect(RelocateError.noRecordsInScope == RelocateError.noRecordsInScope)
    }
}
