import Foundation
import Testing
@testable import VideoScan

// MARK: - Storage tab per-volume dashboard arithmetic (Rick 2026-08-19)
//
// Five-dimension coverage (CLAUDE.md checklist):
//   Logic     — component-wise root matching, top-folder extraction,
//               every series (kind/streams/decade/year/review/copies/
//               stars/archive/folders), the Other fold, chronological
//               ordering, semantic colors, deleted-everywhere exclusion.
//   Scale     — 100k synthetic records under an explicit < 0.5 s budget.
//   Isolation — pure functions over constructed inputs; no UserDefaults,
//               no filesystem, no shared caches.
//   Sensor    — `projectionMatchesRootScope` pins that the projection
//               never claims a sibling volume's records (X9 vs X9-Matt).
// Media matrix: N/A — catalog metadata only, no file is opened.

private let GB: Int64 = 1_073_741_824

private func year(_ y: Int) -> Date {
    var c = DateComponents(); c.year = y; c.month = 6; c.day = 15; c.hour = 12
    c.timeZone = TimeZone(secondsFromGMT: 0)
    return Calendar(identifier: .gregorian).date(from: c)!
}

private func row(_ path: String, _ bytes: Int64,
                 deleted: Bool = false,
                 ext: String? = nil,
                 stream: StreamType = .videoAndAudio,
                 date: Date? = nil,
                 disposition: MediaDisposition = .unreviewed,
                 copies: Int = 0,
                 stars: Int = 0,
                 promoted: Bool = false,
                 verified: Bool = false) -> VolumeDashboardInput {
    VolumeDashboardInput(fullPath: path, sizeBytes: bytes, isManuallyDeleted: deleted,
                         ext: ext ?? (path as NSString).pathExtension.uppercased(),
                         streamType: stream, bestDate: date, disposition: disposition,
                         copiesElsewhere: copies, starRating: stars,
                         isPromotedCopy: promoted, fixityVerified: verified)
}

private func rec(_ path: String, _ bytes: Int64, purged: Bool = false) -> VideoRecord {
    let r = VideoRecord()
    r.filename = (path as NSString).lastPathComponent
    r.directory = (path as NSString).deletingLastPathComponent
    r.fullPath = path
    r.sizeBytes = bytes
    if purged { r.purgedAt = Date(timeIntervalSince1970: 1_000_000) }
    return r
}

@Suite("Volume dashboard — root scoping")
struct VolumeDashboardScopeTests {

    @Test func isUnderIsComponentWise() {
        let root = "/Volumes/X9"
        #expect(VolumeDashboardCalculator.isUnder("/Volumes/X9/a.mov", root: root))
        #expect(VolumeDashboardCalculator.isUnder("/Volumes/X9", root: root))
        #expect(!VolumeDashboardCalculator.isUnder("/Volumes/X9-Matt/a.mov", root: root))
        #expect(!VolumeDashboardCalculator.isUnder("/Volumes/X", root: root))
        #expect(VolumeDashboardCalculator.isUnder("/anything", root: "/"))
        #expect(VolumeDashboardCalculator.normalizedRoot("/Volumes/X9/") == "/Volumes/X9")
        #expect(VolumeDashboardCalculator.normalizedRoot("/") == "/")
    }

    @Test func topFolderIsFirstComponentBelowRoot() {
        let root = "/Volumes/FamilyArchive"
        #expect(VolumeDashboardCalculator.topFolder(of: "/Volumes/FamilyArchive/1990s/1994/a.mov", root: root) == "1990s")
        #expect(VolumeDashboardCalculator.topFolder(of: "/Volumes/FamilyArchive/a.mov", root: root)
                == VolumeDashboardCalculator.rootFolderName)
        #expect(VolumeDashboardCalculator.topFolder(of: "/x/a.mov", root: "/") == "x")
    }

    /// Sensor: the projection claims ONLY this target's records — a
    /// sibling volume with the same prefix, purged rows, and foreign
    /// paths stay out.
    @MainActor
    @Test func projectionMatchesRootScope() {
        let records = [
            rec("/Volumes/X9/a.mov", 1 * GB),
            rec("/Volumes/X9/sub/b.mov", 2 * GB),
            rec("/Volumes/X9-Matt/c.mov", 4 * GB),          // sibling volume
            rec("/Volumes/X9/purged.mov", 8 * GB, purged: true),
            rec("/Users/rick/Movies/d.mov", 16 * GB),
        ]
        let inputs = VolumeDashboardCalculator.project(records, under: "/Volumes/X9/")
        #expect(inputs.map(\.fullPath).sorted() == ["/Volumes/X9/a.mov", "/Volumes/X9/sub/b.mov"])
        let stats = VolumeDashboardCalculator.compute(inputs: inputs, root: "/Volumes/X9")
        #expect(stats.totalFiles == 2)
        #expect(stats.totalBytes == 3 * GB)
        #expect(stats.folders.slices.map(\.name) == ["sub", VolumeDashboardCalculator.rootFolderName])
    }
}

@Suite("Volume dashboard — series")
struct VolumeDashboardSeriesTests {

    private let root = "/Volumes/Drive"

    @Test func deletedEverywhereIsExcludedButCounted() {
        let s = VolumeDashboardCalculator.compute(inputs: [
            row("/Volumes/Drive/a.mov", 1 * GB),
            row("/Volumes/Drive/gone.mov", 5 * GB, deleted: true),
        ], root: root)
        #expect(s.totalFiles == 1)
        #expect(s.totalBytes == 1 * GB)
        #expect(s.deletedFiles == 1)
    }

    @Test func kindAndStreamsUseSharedLabels() {
        let s = VolumeDashboardCalculator.compute(inputs: [
            row("/Volumes/Drive/a.MOV", 3 * GB),
            row("/Volumes/Drive/b.mxf", 4 * GB, stream: .videoOnly),
            row("/Volumes/Drive/c.mxf", 1 * GB, stream: .audioOnly),
            row("/Volumes/Drive/noext", 1 * GB, ext: ""),
        ], root: root)
        #expect(s.kind.slices.map(\.name) == ["mxf", "mov", MediaDistributionCalculator.noExtensionName])
        #expect(s.streams.slices.first?.name == "Video + audio")
        #expect(Set(s.streams.slices.map(\.name)) == ["Video + audio", "Video only", "Audio only"])
        // Alphabetical color slots: "mov" < "mxf" < "no extension".
        #expect(s.kind.slices.first { $0.name == "mov" }?.colorSlot == 0)
        #expect(s.kind.slices.first { $0.name == "mxf" }?.colorSlot == 1)
    }

    @Test func decadesAndYearsAreChronologicalWithUndatedLast() {
        let s = VolumeDashboardCalculator.compute(inputs: [
            row("/Volumes/Drive/a.mov", 1 * GB, date: year(2004)),
            row("/Volumes/Drive/b.mov", 1 * GB, date: year(1987)),
            row("/Volumes/Drive/c.mov", 1 * GB),
            row("/Volumes/Drive/d.mov", 1 * GB, date: year(1994)),
        ], root: root)
        #expect(s.decade.slices.map(\.name) == ["1980s", "1990s", "2000s", MediaDistributionCalculator.undatedName])
        #expect(s.year.slices.map(\.name) == ["1987", "1994", "2004", MediaDistributionCalculator.undatedName])
        #expect(s.decade.slices.last?.fixedColor == .gray)
        #expect(s.decade.slices.first?.colorSlot == 0)
    }

    @Test func reviewCopiesStarsCarrySemanticColorsInFixedOrder() {
        let s = VolumeDashboardCalculator.compute(inputs: [
            row("/Volumes/Drive/a.mov", 1 * GB, disposition: .confirmedJunk, copies: 2, stars: 3),
            row("/Volumes/Drive/b.mov", 1 * GB, disposition: .important, copies: 0, stars: 0),
            row("/Volumes/Drive/c.mov", 1 * GB, disposition: .unreviewed, copies: 1, stars: 1),
            row("/Volumes/Drive/d.mov", 1 * GB, disposition: .unreviewed, copies: 7, stars: 0),
        ], root: root)
        #expect(s.review.slices.map(\.name) == ["Undecided", "Keep", "Junk"])
        #expect(s.review.slices.map(\.fixedColor) == [.secondary, .blue, .red])
        #expect(s.copies.slices.map(\.name) == ["Only copy is here", "1 copy elsewhere", "2+ copies elsewhere"])
        #expect(s.copies.slices.map(\.files) == [1, 1, 2])
        #expect(s.copies.slices.map(\.fixedColor) == [.red, .orange, .green])
        #expect(s.stars.slices.map(\.name) == ["Unrated", "★", "★★★"])
    }

    @Test func archiveSeriesOnlyCountsPromotedCopies() {
        let s = VolumeDashboardCalculator.compute(inputs: [
            row("/Volumes/Drive/a.mov", 1 * GB, promoted: true, verified: true),
            row("/Volumes/Drive/b.mov", 1 * GB, promoted: true, verified: false),
            row("/Volumes/Drive/c.mov", 1 * GB, promoted: false, verified: false),
        ], root: root)
        #expect(s.archive.slices.map(\.name) == ["Verified", "Not yet verified"])
        #expect(s.archive.totalFiles == 2)
    }

    @Test func foldersFoldPastEightIntoOther() {
        var inputs: [VolumeDashboardInput] = []
        for i in 0..<12 {
            inputs.append(row("/Volumes/Drive/folder\(i)/a.mov", Int64(12 - i) * GB))
        }
        let s = VolumeDashboardCalculator.compute(inputs: inputs, root: root)
        #expect(s.folders.slices.count == VolumeDashboardCalculator.maxFolders)
        #expect(s.folders.slices.last?.isOther == true)
        #expect(s.folders.slices.first?.name == "folder0")
        #expect(s.folders.totalFiles == 12)
        #expect(s.folders.slices.reduce(0) { $0 + $1.files } == 12)
    }

    @Test func percentFollowsMeasure() {
        let s = VolumeDashboardCalculator.compute(inputs: [
            row("/Volumes/Drive/a.mov", 3 * GB, stream: .videoOnly),
            row("/Volumes/Drive/b.mov", 1 * GB),
            row("/Volumes/Drive/c.mov", 1 * GB),
            row("/Volumes/Drive/d.mov", 1 * GB),
        ], root: root)
        let vo = s.streams.slices.first { $0.name == "Video only" }!
        #expect(s.streams.percent(of: vo, by: .size) == 50)
        #expect(s.streams.percent(of: vo, by: .files) == 25)
    }
}

@Suite("Volume dashboard — scale")
struct VolumeDashboardScaleTests {

    /// 100k rows, every series, under the same 0.5 s budget as the
    /// "Where media lives" calculator.
    @Test func hundredThousandRowsUnderBudget() {
        var inputs: [VolumeDashboardInput] = []
        inputs.reserveCapacity(100_000)
        let exts = ["mov", "mxf", "mp4", "avi", "mkv", "dv", "m4v", "wmv", "mpg", "mts"]
        for i in 0..<100_000 {
            inputs.append(row("/Volumes/Big/folder\(i % 40)/sub\(i % 7)/clip\(i).\(exts[i % exts.count])",
                              Int64(1 + i % 7) * 100_000_000,
                              deleted: i % 97 == 0,
                              stream: i % 5 == 0 ? .videoOnly : .videoAndAudio,
                              date: i % 13 == 0 ? nil : year(1960 + i % 60),
                              disposition: MediaDisposition.allCases[i % 5],
                              copies: i % 3, stars: i % 4,
                              promoted: i % 2 == 0, verified: i % 4 == 0))
        }
        let start = ContinuousClock.now
        let s = VolumeDashboardCalculator.compute(inputs: inputs, root: "/Volumes/Big")
        let elapsed = ContinuousClock.now - start
        #expect(s.totalFiles + s.deletedFiles == 100_000)
        #expect(s.folders.slices.count == VolumeDashboardCalculator.maxFolders)
        #expect(elapsed < .milliseconds(500),
                "volume dashboard took \(elapsed) for 100k records — over the 0.5 s budget")
    }
}
