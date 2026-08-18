import Foundation
import SwiftUI
import Testing
@testable import VideoScan

// MARK: - "Where media lives" donut arithmetic (Rick 2026-08-18)
//
// Five-dimension coverage (CLAUDE.md checklist):
//   Logic     — grouping by volume incl. the home-folder fold, the two
//               exclusions (Manually Deleted, retired targets), the
//               >8-category fold into Other, color-slot determinism, and
//               the kind / streams / decade key extractors.
//   Scale     — 100k synthetic records under an explicit < 0.5 s budget.
//   Isolation — pure functions over constructed inputs; no UserDefaults,
//               no filesystem, no shared caches.
//   Sensor    — `colorDomainAndRangeAgree` pins the legend/sector
//               contract at production shape.
// Media matrix: N/A — pure catalog metadata, no file is ever opened.

private let GB: Int64 = 1_073_741_824

private func row(_ path: String, _ bytes: Int64, deleted: Bool = false,
                 ext: String? = nil,
                 stream: StreamType = .videoAndAudio,
                 date: Date? = nil) -> MediaDistributionInput {
    // Production stores `ext` UPPERCASED; default to that from the path
    // so the lowercasing in the kind extractor is exercised.
    MediaDistributionInput(fullPath: path, sizeBytes: bytes, isManuallyDeleted: deleted,
                           ext: ext ?? (path as NSString).pathExtension.uppercased(),
                           streamType: stream, bestDate: date)
}

/// A date in the given year (mid-year, local calendar) — keeps the
/// decade test clear of any timezone edge.
private func year(_ y: Int) -> Date {
    var c = DateComponents(); c.year = y; c.month = 6; c.day = 15; c.hour = 12
    return Calendar(identifier: .gregorian).date(from: c)!
}

private func rec(_ path: String, _ bytes: Int64,
                 stage: ArchiveStage = .none,
                 purged: Bool = false,
                 setAside: String? = nil) -> VideoRecord {
    let r = VideoRecord()
    r.filename = (path as NSString).lastPathComponent
    r.directory = (path as NSString).deletingLastPathComponent
    r.fullPath = path
    r.sizeBytes = bytes
    r.archiveStage = stage
    if purged { r.purgedAt = Date(timeIntervalSince1970: 1_000_000) }
    r.setAsideReason = setAside
    return r
}

@Suite("Media distribution — grouping")
struct MediaDistributionGroupingTests {

    /// (a) One slice per /Volumes/<name>; everything under /Users folds
    /// into "Mac (home)". Sorted by size descending.
    @Test func groupsByVolumeAndFoldsHome() {
        let inputs = [
            row("/Volumes/FamilyArchive/1990/a.mov", 3 * GB),
            row("/Volumes/FamilyArchive/1991/b.mov", 2 * GB),
            row("/Volumes/X9/scratch/c.mov", 1 * GB),
            row("/Users/rickb/Movies/d.mov", 4 * GB),
            row("/Users/rickb/Desktop/e.mov", 1 * GB),
            row("/Users/donna/Movies/f.mov", 1 * GB),   // another home — same slice
        ]
        let d = MediaDistributionCalculator.compute(inputs: inputs)

        #expect(d.slices.map(\.name) == ["Mac (home)", "FamilyArchive", "X9"])
        #expect(d.slices[0].bytes == 6 * GB && d.slices[0].files == 3)
        #expect(d.slices[1].bytes == 5 * GB && d.slices[1].files == 2)
        #expect(d.slices[2].bytes == 1 * GB && d.slices[2].files == 1)
        #expect(d.totalBytes == 12 * GB)
        #expect(d.totalFiles == 6)
        #expect(d.retiredBytes == 0 && d.retiredFiles == 0)
        // Home is always reachable; the others are unknown with no targets.
        #expect(d.slices[0].isReachable == true)
        #expect(d.slices[1].isReachable == nil)
    }

    @Test func volumeLabelHelper() {
        #expect(MediaDistributionCalculator.volumeLabel(forPath: "/Volumes/LaCie/x.mov") == "LaCie")
        #expect(MediaDistributionCalculator.volumeLabel(forPath: "/Users/rickb/Movies/x.mov") == "Mac (home)")
        #expect(MediaDistributionCalculator.volumeLabel(forPath: "/Users/anyone/x.mov") == "Mac (home)")
    }

    /// (b) Manually Deleted records count NOWHERE (not even retired);
    /// records under a retired target leave the chart but are tallied
    /// so the sheet can be honest about them.
    @Test func excludesManuallyDeletedAndRetired() {
        let inputs = [
            row("/Volumes/FamilyArchive/a.mov", 3 * GB),
            row("/Volumes/FamilyArchive/gone.mov", 9 * GB, deleted: true),
            row("/Volumes/RicksBackups/old1.mov", 2 * GB),
            row("/Volumes/RicksBackups/old2.mov", 2 * GB),
            row("/Volumes/RicksBackups/gone.mov", 5 * GB, deleted: true),
        ]
        let d = MediaDistributionCalculator.compute(
            inputs: inputs,
            retiredPrefixes: ["/Volumes/RicksBackups"])

        #expect(d.slices.map(\.name) == ["FamilyArchive"])
        #expect(d.totalBytes == 3 * GB)
        #expect(d.totalFiles == 1)
        #expect(d.retiredBytes == 4 * GB)
        #expect(d.retiredFiles == 2)
    }

    /// An empty retired prefix must not swallow the whole catalog.
    @Test func emptyRetiredPrefixIsIgnored() {
        let d = MediaDistributionCalculator.compute(
            inputs: [row("/Volumes/A/a.mov", GB)],
            retiredPrefixes: [""])
        #expect(d.totalFiles == 1 && d.retiredFiles == 0)
    }

    /// The projection applies `pfActiveRecords` and carries the
    /// Manually Deleted flag — the main-actor half of the exclusion.
    @Test func projectionDropsPurgedSetAsideAndFlagsDeleted() {
        let recs = [
            rec("/Volumes/A/keep.mov", GB),
            rec("/Volumes/A/purged.mov", GB, purged: true),
            rec("/Volumes/A/aside.mov", GB, setAside: "cruft"),
            rec("/Volumes/A/deleted.mov", GB, stage: .manuallyDeleted),
        ]
        let p = MediaDistributionCalculator.project(recs)
        #expect(p.count == 2)
        #expect(p.map(\.fullPath).sorted() == ["/Volumes/A/deleted.mov", "/Volumes/A/keep.mov"])
        #expect(p.first { $0.fullPath.hasSuffix("deleted.mov") }?.isManuallyDeleted == true)
        #expect(p.first { $0.fullPath.hasSuffix("keep.mov") }?.isManuallyDeleted == false)

        let d = MediaDistributionCalculator.compute(inputs: p)
        #expect(d.totalFiles == 1)
    }

    /// Reachability captions come from the caller's cached target state:
    /// reachable → true, known-but-offline → false, no target → nil.
    @Test func reachabilityFlagsFromCallerSets() {
        let inputs = [
            row("/Volumes/On/a.mov", GB),
            row("/Volumes/Off/b.mov", GB),
            row("/Volumes/Mystery/c.mov", GB),
        ]
        let d = MediaDistributionCalculator.compute(
            inputs: inputs,
            reachableVolumes: ["On"],
            knownVolumes: ["On", "Off"])
        let by = Dictionary(uniqueKeysWithValues: d.slices.map { ($0.name, $0.isReachable) })
        #expect(by["On"] == .some(true))
        #expect(by["Off"] == .some(false))
        #expect(by["Mystery"] == .some(nil))
    }
}

@Suite("Media distribution — kind / streams / decade")
struct MediaDistributionDimensionTests {

    /// Kind = extension lowercased; empty → "no extension". Retired and
    /// Manually Deleted exclusions apply identically in every dimension.
    @Test func kindGroupsByLowercasedExtension() {
        let inputs = [
            row("/Volumes/A/a.MOV", 3 * GB),
            row("/Volumes/A/b.mov", 2 * GB),
            row("/Volumes/A/c.MXF", 4 * GB),
            row("/Volumes/A/d.mp4", 1 * GB),
            row("/Volumes/A/essence", 6 * GB, ext: ""),
            row("/Volumes/A/gone.mov", 9 * GB, deleted: true),
            row("/Volumes/Retired/e.avi", 9 * GB),
        ]
        let d = MediaDistributionCalculator.compute(
            inputs: inputs, dimension: .kind, retiredPrefixes: ["/Volumes/Retired"])
        #expect(d.dimension == .kind)
        #expect(d.slices.map(\.name) == ["no extension", "mov", "mxf", "mp4"])
        #expect(d.slices[1].bytes == 5 * GB && d.slices[1].files == 2)
        #expect(d.totalBytes == 16 * GB)
        #expect(d.retiredFiles == 1)
        // Reachability is a drive property — nil for every kind row.
        #expect(d.slices.allSatisfy { $0.isReachable == nil })
        #expect(MediaDistributionCalculator.kindLabel(forExtension: "  MTS ") == "mts")
    }

    /// Streams = the four ffprobe shapes (+ unreadable). This is the MXF
    /// A/V-halves picture: separated video-only and audio-only essence.
    @Test func streamsGroupsByShape() {
        let inputs = [
            row("/Volumes/A/full.mov", 4 * GB, stream: .videoAndAudio),
            row("/Volumes/A/v1.mxf", 3 * GB, stream: .videoOnly),
            row("/Volumes/A/v2.mxf", 3 * GB, stream: .videoOnly),
            row("/Volumes/A/a1.mxf", 1 * GB, stream: .audioOnly),
            row("/Volumes/A/blank.dat", 1 * GB, stream: .noStreams),
            row("/Volumes/A/broken.bin", 1 * GB, stream: .ffprobeFailed),
        ]
        let d = MediaDistributionCalculator.compute(inputs: inputs, dimension: .streams)
        let by = Dictionary(uniqueKeysWithValues: d.slices.map { ($0.name, $0) })
        #expect(by["Video only"]?.bytes == 6 * GB && by["Video only"]?.files == 2)
        #expect(by["Video + audio"]?.bytes == 4 * GB)
        #expect(by["Audio only"]?.files == 1)
        #expect(by["No streams"]?.files == 1)
        #expect(by["Unreadable"]?.files == 1)
        #expect(d.slices.first?.name == "Video only")   // size-desc order holds
        // Five shapes max → never folds.
        #expect(!d.slices.contains { $0.isOther })
    }

    /// Decade = "1990s" from the best date; nil → "Undated". More than
    /// eight decades fold into Other keeping the largest 7.
    @Test func decadeGroupsAndUndated() {
        let inputs = [
            row("/Volumes/A/a.mov", 3 * GB, date: year(1994)),
            row("/Volumes/A/b.mov", 2 * GB, date: year(1999)),
            row("/Volumes/A/c.mov", 1 * GB, date: year(2000)),
            row("/Volumes/A/d.mov", 5 * GB, date: year(1947)),
            row("/Volumes/A/e.mov", 4 * GB),                 // undated
            row("/Volumes/A/f.mov", 4 * GB, date: nil),
        ]
        let d = MediaDistributionCalculator.compute(inputs: inputs, dimension: .decade)
        let by = Dictionary(uniqueKeysWithValues: d.slices.map { ($0.name, $0) })
        #expect(by["1990s"]?.bytes == 5 * GB && by["1990s"]?.files == 2)
        #expect(by["2000s"]?.bytes == 1 * GB)
        #expect(by["1940s"]?.bytes == 5 * GB)
        #expect(by["Undated"]?.bytes == 8 * GB && by["Undated"]?.files == 2)
        #expect(d.slices.first?.name == "Undated")
        #expect(MediaDistributionCalculator.decadeLabel(for: nil) == "Undated")
        #expect(MediaDistributionCalculator.decadeLabel(for: year(1940)) == "1940s")
        #expect(MediaDistributionCalculator.decadeLabel(for: year(2029)) == "2020s")
    }

    @Test func decadeFoldsBeyondEight() {
        // 1940s … 2020s = 9 decades, plus Undated = 10 categories.
        var inputs: [MediaDistributionInput] = []
        for (i, y) in stride(from: 1940, through: 2020, by: 10).enumerated() {
            inputs.append(row("/Volumes/A/\(y).mov", Int64(i + 2) * GB, date: year(y)))
        }
        inputs.append(row("/Volumes/A/undated.mov", 1 * GB))   // the smallest
        let d = MediaDistributionCalculator.compute(inputs: inputs, dimension: .decade)
        #expect(d.slices.count == 8)
        let other = d.slices.last!
        #expect(other.isOther && other.foldedVolumeCount == 3)
        // Smallest three: Undated (1 GB), 1940s (2 GB), 1950s (3 GB).
        #expect(other.bytes == 6 * GB)
        #expect(!d.slices.contains { $0.name == "Undated" })
        #expect(d.slices.first?.name == "2020s")
        // Slots still alphabetical among the survivors.
        let named = d.slices.filter { !$0.isOther }
        let sortedNames = named.map(\.name).sorted()
        for s in named {
            #expect(s.colorSlot == sortedNames.firstIndex(of: s.name))
        }
    }

    /// The projection carries every dimension's field.
    @Test func projectionCarriesKindStreamsAndBestDate() {
        let r = rec("/Volumes/A/x.MXF", GB)
        r.ext = "MXF"
        r.streamTypeRaw = StreamType.videoOnly.rawValue
        r.dateCreatedRaw = year(1985)
        r.embeddedCreationDate = year(1975)
        let p1 = MediaDistributionCalculator.project([r]).first!
        #expect(p1.ext == "MXF")
        #expect(p1.streamType == .videoOnly)
        #expect(p1.bestDate == year(1975))          // embedded beats filesystem
        r.inferredRecordDate = year(1962)
        let p2 = MediaDistributionCalculator.project([r]).first!
        #expect(p2.bestDate == year(1962))          // consensus inference wins
        #expect(MediaDistributionCalculator.key(for: p2, dimension: .kind) == "mxf")
        #expect(MediaDistributionCalculator.key(for: p2, dimension: .streams) == "Video only")
        #expect(MediaDistributionCalculator.key(for: p2, dimension: .decade) == "1960s")
        #expect(MediaDistributionCalculator.key(for: p2, dimension: .volume) == "A")
    }
}

@Suite("Media distribution — fold and colors")
struct MediaDistributionFoldTests {

    /// (c) Ten volumes → the largest 7 keep their names, the smallest 3
    /// fold into "Other" (system gray, last in the list, no slot).
    @Test func foldsSmallestIntoOtherKeepingLargestSeven() {
        var inputs: [MediaDistributionInput] = []
        for i in 1...10 {
            inputs.append(row("/Volumes/Vol\(String(format: "%02d", i))/f.mov", Int64(i) * GB))
        }
        let d = MediaDistributionCalculator.compute(inputs: inputs)

        #expect(d.slices.count == 8)
        let named = d.slices.filter { !$0.isOther }.map(\.name)
        #expect(named == ["Vol10", "Vol09", "Vol08", "Vol07", "Vol06", "Vol05", "Vol04"])
        let other = d.slices.last!
        #expect(other.isOther)
        #expect(other.name == "Other")
        #expect(other.bytes == (1 + 2 + 3) * GB)
        #expect(other.files == 3)
        #expect(other.foldedVolumeCount == 3)
        #expect(other.colorSlot == nil)
        #expect(d.totalBytes == 55 * GB)   // Other still counts toward the total
        #expect(d.colorDomain.last == "Other")
        #expect(MediaDistributionCalculator.color(for: other, scheme: .light) == .gray)
    }

    /// Exactly 8 volumes → no fold (Other only appears when we EXCEED
    /// the palette).
    @Test func exactlyEightVolumesDoNotFold() {
        let inputs = (1...8).map { row("/Volumes/V\($0)/f.mov", Int64($0) * GB) }
        let d = MediaDistributionCalculator.compute(inputs: inputs)
        #expect(d.slices.count == 8)
        #expect(!d.slices.contains { $0.isOther })
        #expect(Set(d.slices.compactMap(\.colorSlot)) == Set(0..<8))
    }

    /// (d) Color slot follows ALPHABETICAL name, not size rank. Swap the
    /// sizes around and every volume keeps its slot.
    @Test func colorSlotIsDeterministicBySortedName() {
        let before = MediaDistributionCalculator.compute(inputs: [
            row("/Volumes/Zeta/a.mov", 10 * GB),
            row("/Volumes/Alpha/b.mov", 1 * GB),
            row("/Users/rickb/c.mov", 5 * GB),
        ])
        let after = MediaDistributionCalculator.compute(inputs: [
            row("/Volumes/Zeta/a.mov", 1 * GB),
            row("/Volumes/Alpha/b.mov", 10 * GB),
            row("/Users/rickb/c.mov", 50 * GB),
        ])
        func slots(_ d: MediaDistribution) -> [String: Int?] {
            Dictionary(uniqueKeysWithValues: d.slices.map { ($0.name, $0.colorSlot) })
        }
        // Alphabetical: "Alpha" < "Mac (home)" < "Zeta"
        #expect(slots(before) == ["Alpha": 0, "Mac (home)": 1, "Zeta": 2])
        #expect(slots(after) == slots(before))
        // …while the size ORDER did change.
        #expect(before.slices.first?.name == "Zeta")
        #expect(after.slices.first?.name == "Mac (home)")
        // Same slot → same color in either scheme.
        for scheme in [ColorScheme.light, .dark] {
            let b = before.slices.first { $0.name == "Zeta" }!
            let a = after.slices.first { $0.name == "Zeta" }!
            #expect(MediaDistributionCalculator.color(for: a, scheme: scheme)
                    == MediaDistributionCalculator.color(for: b, scheme: scheme))
        }
    }

    /// SENSOR. The scale domain and range the chart consumes must line
    /// up one-to-one with the legend swatches, or the sectors and the
    /// legend disagree — the exact failure the fixed-slot design exists
    /// to rule out.
    @Test func colorDomainAndRangeAgree() {
        let inputs = (1...12).map { row("/Volumes/Drive\(String(format: "%02d", $0))/f.mov", Int64($0) * GB) }
        let d = MediaDistributionCalculator.compute(inputs: inputs)
        let domain = d.colorDomain
        let range = MediaDistributionCalculator.colorRange(for: d, scheme: .light)
        #expect(domain.count == range.count)
        #expect(domain.count == d.slices.count)
        for (name, color) in zip(domain, range) {
            let slice = d.slices.first { $0.name == name }!
            #expect(MediaDistributionCalculator.color(for: slice, scheme: .light) == color)
        }
        // Domain is slot-ordered (alphabetical) with Other last.
        #expect(domain.dropLast().sorted() == Array(domain.dropLast()))
        #expect(domain.last == "Other")
    }

    @Test func percentAndEmptyInputs() {
        let empty = MediaDistributionCalculator.compute(inputs: [])
        #expect(empty.slices.isEmpty && empty.totalBytes == 0)

        let d = MediaDistributionCalculator.compute(inputs: [
            row("/Volumes/A/a.mov", 3 * GB),
            row("/Volumes/B/b.mov", 1 * GB),
            row("/Volumes/B/c.mov", 0),
        ])
        let a = d.slices.first { $0.name == "A" }!
        let b = d.slices.first { $0.name == "B" }!
        #expect(d.percent(of: a, by: .size) == 75)
        #expect(d.percent(of: b, by: .size) == 25)
        #expect(abs(d.percent(of: a, by: .files) - 100.0 / 3.0) < 0.001)
        #expect(MediaDistributionFormat.percentString(0.4) == "<1%")
        #expect(MediaDistributionFormat.percentString(52.4) == "52%")
    }
}

@Suite("Media distribution — scale")
struct MediaDistributionScaleTests {

    /// (e) Scale dimension: 100k projected records across a dozen
    /// volumes (so the fold path runs too) under a stated < 0.5 s
    /// budget. Catches an accidental O(n × volumes) or O(n²).
    @Test func scales_100kRecordsUnderHalfSecond() {
        var inputs: [MediaDistributionInput] = []
        inputs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let vol = i % 12
            let path = vol == 0
                ? "/Users/rickb/Movies/clip\(i).mov"
                : "/Volumes/Drive\(vol)/Family/1990s/clip\(i).mov"
            inputs.append(row(path, Int64(1 + i % 7) * 100_000_000, deleted: i % 97 == 0))
        }
        let retired = ["/Volumes/Drive11", "/Volumes/Drive10"]

        let start = ContinuousClock.now
        let d = MediaDistributionCalculator.compute(inputs: inputs, retiredPrefixes: retired)
        let elapsed = ContinuousClock.now - start

        #expect(d.slices.count == 8)                        // 10 live volumes → 7 + Other
        #expect(d.totalFiles + d.retiredFiles + (100_000 / 97 + 1) == 100_000)
        #expect(elapsed < .milliseconds(500),
                "media distribution took \(elapsed) for 100k records — over the 0.5 s budget")
    }
}
