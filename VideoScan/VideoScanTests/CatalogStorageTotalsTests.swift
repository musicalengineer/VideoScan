import CoreGraphics
import Foundation
import Testing
@testable import VideoScan

// MARK: - TOTAL MEDIA footer arithmetic (Rick 2026-08-09)
//
// The footer answers a PURCHASE question: "how big a drive do I need?"
// That makes the direction of every error matter, not just its size —
// under-counting duplicates inflates `unique` and buys too much disk;
// over-collapsing duplicates deflates it and loses family footage. Both
// directions are pinned below.
//
// Five-dimension coverage (CLAUDE.md checklist):
//   Logic     — bucket precedence truth table, both duplicate signals,
//               the collapse guards, and the display formatter.
//   Scale     — 100k synthetic records with an explicit time budget: the
//               calculation runs on the main thread inside the catalog's
//               existing recompute trigger, so its cost is a UI cost.
//   Isolation — pure functions over constructed records. No UserDefaults,
//               no real filesystem paths, no shared caches.
//   Sensor    — `waterfallIsExact` and `realisticCatalogSensor` pin the
//               invariant and a production-shaped result at scale.
// Media matrix: N/A — pure catalog metadata, no file is ever opened.

/// Production stores `ext` UPPERCASED (probe engine uses
/// `url.pathExtension.uppercased()`), so mirror that here — it is the
/// exact case-sensitivity trap the non-video bucket has to survive.
private func stRec(
    _ filename: String,
    stream: StreamType = .videoAndAudio,
    bytes: Int64 = 1_000_000_000,
    dir: String = "/Volumes/LaCie8TB/Family",
    md5: String = "",
    disposition: MediaDisposition = .unreviewed,
    dupDisposition: DuplicateDisposition = .none,
    purged: Bool = false,
    setAside: String? = nil
) -> VideoRecord {
    let r = VideoRecord()
    r.filename = filename
    r.ext = (filename as NSString).pathExtension.uppercased()
    r.streamTypeRaw = stream.rawValue
    r.directory = dir
    r.fullPath = dir + "/" + filename
    r.sizeBytes = bytes
    r.partialMD5 = md5
    r.mediaDisposition = disposition
    r.duplicateDisposition = dupDisposition
    if purged { r.purgedAt = Date(timeIntervalSince1970: 1_000_000) }
    r.setAsideReason = setAside
    return r
}

private let GB: Int64 = 1_073_741_824

// MARK: - The invariant

@Suite("Storage totals — waterfall invariant")
struct CatalogStorageWaterfallTests {

    /// THE load-bearing contract: every excluded byte lands in exactly
    /// one bucket. If this fails, some category is either double-charged
    /// (shrinking `unique` — Rick under-buys and loses footage) or not
    /// charged at all (inflating it). A number that can't show its work
    /// is not a number you plan a purchase against.
    @Test func waterfallIsExact() {
        let recs = [
            stRec("wedding.mov", bytes: 4 * GB),
            stRec("photo.CR3", stream: .videoOnly, bytes: 1 * GB),   // one-frame-mjpeg trap
            stRec("song.mp3", stream: .audioOnly, bytes: 2 * GB, dir: "/Volumes/X/iTunes/Music"),
            stRec("blurry.mov", bytes: 3 * GB, disposition: .confirmedJunk),
            stRec("copy.mov", bytes: 5 * GB, dupDisposition: .extraCopy),
            stRec("nostreams.dat", stream: .noStreams, bytes: 6 * GB),
        ]
        let t = CatalogStorageTotalsCalculator.compute(records: recs)

        #expect(t.waterfallBalances)
        #expect(t.grossBytes == 21 * GB)
        #expect(t.uniqueBytes == 4 * GB)          // only the wedding
        #expect(t.nonVideoBytes == 7 * GB)        // CR3 + no-streams
        #expect(t.musicBytes == 2 * GB)
        #expect(t.junkBytes == 3 * GB)
        #expect(t.duplicateBytes == 5 * GB)
    }

    /// Precedence, not addition. A duplicated junk photo is ONE
    /// exclusion, charged to the first matching bucket — never three.
    @Test func overlappingCategoriesChargedOnce() {
        let recs = [
            stRec("keep.mov", bytes: 10 * GB),
            stRec("junkdupe.JPG", stream: .videoOnly, bytes: 2 * GB,
                  disposition: .confirmedJunk, dupDisposition: .extraCopy),
        ]
        let t = CatalogStorageTotalsCalculator.compute(records: recs)

        #expect(t.waterfallBalances)
        #expect(t.nonVideoBytes == 2 * GB)   // non-video wins the precedence
        #expect(t.junkBytes == 0)
        #expect(t.duplicateBytes == 0)
        #expect(t.uniqueBytes == 10 * GB)
    }

    /// The ONLINE figure exists to explain the gap Rick hit: the table
    /// filters to Connected, so the visible rows sum to less than the
    /// catalog total. ONLINE is what those rows actually add up to.
    @Test func onlineBytesCountOnlyReachableVolumes() {
        let recs = [
            stRec("a.mov", bytes: 3 * GB, dir: "/Volumes/LaCie8TB/Family"),
            stRec("b.mov", bytes: 2 * GB, dir: "/Volumes/MyBook3T/Old"),
        ]
        let t = CatalogStorageTotalsCalculator.compute(
            records: recs, onlineVolumes: ["LaCie8TB"]
        )
        #expect(t.grossBytes == 5 * GB)
        #expect(t.onlineBytes == 3 * GB)
        #expect(t.onlineFileCount == 1)
        // Online is a SLICE of gross, never larger — a footer showing
        // more online than catalogued would be nonsense.
        #expect(t.onlineBytes <= t.grossBytes)
    }

    /// Unknown reachability must report everything as online, not
    /// nothing. Defaulting to zero would flash "ONLINE 0 GB" on a
    /// perfectly healthy catalog during startup.
    @Test func unknownReachabilityReportsEverythingOnline() {
        let recs = [stRec("a.mov", bytes: 4 * GB)]
        let t = CatalogStorageTotalsCalculator.compute(records: recs, onlineVolumes: nil)
        #expect(t.onlineBytes == t.grossBytes)
    }

    /// Offline volumes still count toward the catalog total — Rick's
    /// explicit call, and the reason the two figures differ at all.
    @Test func offlineVolumesStillCountInCatalogTotal() {
        let recs = [stRec("gone.mov", bytes: 9 * GB, dir: "/Volumes/Unplugged/x")]
        let t = CatalogStorageTotalsCalculator.compute(records: recs, onlineVolumes: [])
        #expect(t.grossBytes == 9 * GB)
        #expect(t.onlineBytes == 0)
        #expect(t.waterfallBalances, "the online split must not disturb the waterfall")
    }

    @Test func emptyCatalogIsAllZeroAndBalanced() {
        let t = CatalogStorageTotalsCalculator.compute(records: [])
        #expect(t.grossBytes == 0)
        #expect(t.uniqueBytes == 0)
        #expect(t.fileCount == 0)
        #expect(t.waterfallBalances)
        #expect(t.duplicateCoverage == 1.0)   // no files ⇒ no doubt
    }
}

// MARK: - Duplicate collapse

@Suite("Storage totals — duplicate collapse")
struct CatalogStorageDuplicateTests {

    /// The insurance-drive case that motivated the second signal.
    /// Catalog-wide dup analysis is parked (GH #104), so without exact-
    /// byte twinning the copies on MyBook/RicksBackups would ALL count
    /// as unique and roughly triple the drive Rick thinks he needs.
    @Test func exactByteTwinsCollapseAcrossVolumes() {
        let recs = [
            stRec("xmas1994.mov", bytes: 8 * GB, dir: "/Volumes/LaCie8TB/Family", md5: "abc123"),
            stRec("xmas1994.mov", bytes: 8 * GB, dir: "/Volumes/MyBook3T/Backup", md5: "abc123"),
            stRec("xmas1994.mov", bytes: 8 * GB, dir: "/Volumes/RicksBackups/Old", md5: "abc123"),
        ]
        let t = CatalogStorageTotalsCalculator.compute(records: recs)

        #expect(t.grossBytes == 24 * GB)
        #expect(t.uniqueBytes == 8 * GB)      // counted exactly once
        #expect(t.duplicateBytes == 16 * GB)
        #expect(t.uniqueFileCount == 1)
        #expect(t.volumeCount == 3)
    }

    /// Same hash, DIFFERENT length ⇒ not twins. Partial MD5 only reads
    /// the head of the file, so a truncated copy and a complete one can
    /// share a hash — collapsing them would silently drop the only
    /// intact copy's bytes from the plan.
    @Test func sameHashDifferentSizeAreNotTwins() {
        let recs = [
            stRec("clip.mov", bytes: 8 * GB, dir: "/Volumes/A", md5: "same"),
            stRec("clip.mov", bytes: 3 * GB, dir: "/Volumes/B", md5: "same"),
        ]
        let t = CatalogStorageTotalsCalculator.compute(records: recs)
        #expect(t.duplicateBytes == 0)
        #expect(t.uniqueBytes == 11 * GB)
    }

    /// The catastrophic-collapse guard. Un-hashed records share the
    /// empty string; if that were a valid group key, the entire
    /// un-hashed catalog would fold into ONE file and `unique` would
    /// collapse to a few gigabytes.
    @Test func emptyHashNeverTwins() {
        let recs = (0..<50).map {
            stRec("v\($0).mov", bytes: 1 * GB, dir: "/Volumes/A", md5: "")
        }
        let t = CatalogStorageTotalsCalculator.compute(records: recs)
        #expect(t.duplicateBytes == 0)
        #expect(t.uniqueBytes == 50 * GB)
        #expect(t.unanalyzedFiles == 50)      // and it admits the doubt
    }

    /// Zero-byte files all hash alike and are all the same length —
    /// the other half of the same trap.
    @Test func zeroSizeNeverTwins() {
        let recs = (0..<10).map {
            stRec("empty\($0).mov", bytes: 0, dir: "/Volumes/A", md5: "d41d8cd9")
        }
        let t = CatalogStorageTotalsCalculator.compute(records: recs)
        #expect(t.duplicateBytes == 0)
        #expect(t.uniqueFileCount == 10)
    }

    /// An unresolved "Review" verdict must NOT be subtracted. Erring
    /// toward a bigger drive is recoverable; erring toward a smaller one
    /// means discovering the shortfall mid-copy.
    @Test func reviewDispositionCountsAsUnique() {
        let recs = [
            stRec("maybe.mov", bytes: 4 * GB, dupDisposition: .review),
            stRec("definitely.mov", bytes: 4 * GB, dupDisposition: .extraCopy),
        ]
        let t = CatalogStorageTotalsCalculator.compute(records: recs)
        #expect(t.uniqueBytes == 4 * GB)
        #expect(t.duplicateBytes == 4 * GB)
    }

    /// Both signals firing on the same record must charge it once.
    @Test func unionedSignalsDoNotDoubleCharge() {
        let recs = [
            stRec("orig.mov", bytes: 5 * GB, dir: "/Volumes/A", md5: "h1"),
            stRec("orig.mov", bytes: 5 * GB, dir: "/Volumes/B", md5: "h1",
                  dupDisposition: .extraCopy),
        ]
        let t = CatalogStorageTotalsCalculator.compute(records: recs)
        #expect(t.waterfallBalances)
        #expect(t.duplicateBytes == 5 * GB)
        #expect(t.duplicateFiles == 1)
    }
}

// MARK: - Exclusion buckets

@Suite("Storage totals — exclusion buckets")
struct CatalogStorageBucketTests {

    /// ffprobe reports a JPEG as a one-frame mjpeg VIDEO stream, so
    /// stream shape alone would count Rick's photo library as footage.
    /// The extension check is what stops that.
    @Test func stillsProbingAsVideoAreExcluded() {
        for ext in ["JPG", "jpeg", "HEIC", "cr3", "NEF", "png"] {
            let t = CatalogStorageTotalsCalculator.compute(
                records: [stRec("shot.\(ext)", stream: .videoOnly, bytes: 1 * GB)]
            )
            #expect(t.nonVideoBytes == 1 * GB, "\(ext) should not count as A/V")
            #expect(t.uniqueBytes == 0, "\(ext) should not count as A/V")
        }
    }

    /// Unknown extensions stay counted. Extensionless and oddly-named
    /// Avid essence IS the recovery mission — excluding by default would
    /// quietly write off the footage the whole app exists to rescue.
    @Test func unknownAndMissingExtensionsStillCount() {
        let recs = [
            stRec("A0010203", stream: .videoOnly, bytes: 2 * GB),      // no extension
            stRec("clip.xyzzy", stream: .videoOnly, bytes: 3 * GB),    // unknown
        ]
        let t = CatalogStorageTotalsCalculator.compute(records: recs)
        #expect(t.uniqueBytes == 5 * GB)
        #expect(t.nonVideoBytes == 0)
    }

    /// Damaged Avid MXF that ffprobe can't parse is the patient, not the
    /// noise. It must stay in the unique number.
    @Test func ffprobeFailedCountsAsUnique() {
        let t = CatalogStorageTotalsCalculator.compute(
            records: [stRec("damaged.mxf", stream: .ffprobeFailed, bytes: 7 * GB)]
        )
        #expect(t.uniqueBytes == 7 * GB)
    }

    /// Music is subtracted (Rick's call) — but MusicTriage's precision
    /// vetoes must still hold, or an orphaned Avid audio half gets
    /// written off as an iTunes track.
    @Test func musicExcludedButAudioMxfHalfSurvives() {
        let recs = [
            stRec("track.mp3", stream: .audioOnly, bytes: 1 * GB,
                  dir: "/Volumes/X/iTunes/Music"),
            stRec("A0010203.mxf", stream: .audioOnly, bytes: 2 * GB),   // Avid audio half
        ]
        let t = CatalogStorageTotalsCalculator.compute(records: recs)
        #expect(t.musicBytes == 1 * GB)
        #expect(t.uniqueBytes == 2 * GB, "an audio MXF is a pair half, never music")
    }

    /// Audio sitting next to a same-stem video is family material, not
    /// library music — MusicTriage's veto 3, exercised end to end.
    @Test func videoAdjacentAudioSurvives() {
        let recs = [
            stRec("Wedding1994.mov", bytes: 5 * GB),
            stRec("Wedding1994.wav", stream: .audioOnly, bytes: 1 * GB),
        ]
        let t = CatalogStorageTotalsCalculator.compute(records: recs)
        #expect(t.musicBytes == 0)
        #expect(t.uniqueBytes == 6 * GB)
    }

    @Test func suspectedAndConfirmedJunkBothSubtracted() {
        let recs = [
            stRec("a.mov", bytes: 1 * GB, disposition: .suspectedJunk),
            stRec("b.mov", bytes: 2 * GB, disposition: .confirmedJunk),
            stRec("c.mov", bytes: 4 * GB, disposition: .important),
        ]
        let t = CatalogStorageTotalsCalculator.compute(records: recs)
        #expect(t.junkBytes == 3 * GB)
        #expect(t.uniqueBytes == 4 * GB)
    }

    /// A file already in the Trash is not storage to plan for.
    @Test func purgedAndSetAsideRecordsAreInvisible() {
        let recs = [
            stRec("live.mov", bytes: 4 * GB),
            stRec("trashed.mov", bytes: 9 * GB, purged: true),
            stRec("hidden.mov", bytes: 9 * GB, setAside: "tidy"),
        ]
        let t = CatalogStorageTotalsCalculator.compute(records: recs)
        #expect(t.grossBytes == 4 * GB)
        #expect(t.fileCount == 1)
    }

    /// Corrupt metadata must not credit bytes back and break the
    /// invariant.
    @Test func negativeSizeIsClampedNotCredited() {
        let bad = stRec("corrupt.mov", bytes: 4 * GB)
        bad.sizeBytes = -5_000
        let t = CatalogStorageTotalsCalculator.compute(records: [bad])
        #expect(t.grossBytes == 0)
        #expect(t.waterfallBalances)
    }
}

// MARK: - Honesty / display

@Suite("Storage totals — honesty and display")
struct CatalogStorageDisplayTests {

    /// `unique` is an upper bound whenever records carry no dup
    /// evidence, and the caption must say so. Presenting a bound as a
    /// measurement is the specific dishonesty this guards.
    @Test func thinCoverageDowngradesTheCaption() {
        let unhashed = (0..<10).map { stRec("v\($0).mov", bytes: 1 * GB) }
        let t = CatalogStorageTotalsCalculator.compute(records: unhashed)
        #expect(t.duplicateCoverage == 0.0)
        #expect(t.uniqueCaption.contains("at most"))
        #expect(t.breakdownTooltip.contains("upper bound"))
    }

    @Test func fullCoverageGivesThePlainCaption() {
        let hashed = (0..<10).map {
            stRec("v\($0).mov", bytes: 1 * GB, md5: "h\($0)")
        }
        let t = CatalogStorageTotalsCalculator.compute(records: hashed)
        #expect(t.duplicateCoverage == 1.0)
        #expect(!t.uniqueCaption.contains("at most"))
        #expect(t.uniqueCaption.contains("duplicates"))
    }

    /// Rick's requested shape: "5.6 TB", "150 GB" — one decimal for TB,
    /// none for GB at or above 10. DECIMAL units since 2026-08-18
    /// (Finder / `df -H` base) — the old base-1024 footer read "4.9 TB"
    /// for a drive Finder calls 5.41 TB.
    @Test func displaySizeMatchesRequestedShape() {
        #expect(CatalogStorageTotals.displaySize(0) == "0 B")
        #expect(CatalogStorageTotals.displaySize(150 * MediaBytes.GB) == "150 GB")
        #expect(CatalogStorageTotals.displaySize(5_600 * MediaBytes.GB) == "5.6 TB")
        #expect(CatalogStorageTotals.displaySize(7 * MediaBytes.GB) == "7.0 GB")
        #expect(CatalogStorageTotals.displaySize(5_410 * MediaBytes.GB) == "5.4 TB")
    }

    /// Same helper as the Media Size column directly above the footer,
    /// so the total still visibly adds up to the column it sits under —
    /// and both now agree with Finder.
    @Test func displayUsesSameBaseAsMediaSizeColumn() {
        #expect(CatalogStorageTotals.displaySize(1_000_000_000) == "1.0 GB")
        #expect(CatalogStorageTotals.displaySize(1_000_000_000_000) == "1.0 TB")
        #expect(CatalogStorageTotals.displaySize(1_073_741_824) == MediaBytes.display(1_073_741_824))
        #expect(CatalogStorageTotals.displaySize(-5) == "0 B")   // corrupt metadata clamps, never "-5 B"
    }
}

// MARK: - Manually deleted (Rick 2026-08-18)

/// Migrate's safely-redundant bucket marks a source record
/// `.manuallyDeleted` without touching the file. The catalog view hides
/// those rows; the footer used to COUNT them, so TOTAL MEDIA sat ~1.1 TB
/// above the catalog's own figure. Pinned here: they leave every headline
/// number and land in their own honesty field + caption.
@Suite("Storage totals — manually deleted records")
struct CatalogStorageManuallyDeletedTests {

    private func mdRec(_ name: String, bytes: Int64, dir: String = "/Volumes/SanDiskWorkspace/Old") -> VideoRecord {
        let r = stRec(name, bytes: bytes, dir: dir, md5: "md-\(name)")
        r.archiveStage = .manuallyDeleted
        return r
    }

    @Test func manuallyDeletedLeavesGrossUniqueAndOnline() {
        let live = stRec("a.mov", bytes: 4 * GB, md5: "a")
        let dead = mdRec("gone.mov", bytes: 3 * GB)
        let t = CatalogStorageTotalsCalculator.compute(records: [live, dead],
                                                       onlineVolumes: ["LaCie8TB", "SanDiskWorkspace"])
        #expect(t.grossBytes == 4 * GB)
        #expect(t.uniqueBytes == 4 * GB)
        #expect(t.onlineBytes == 4 * GB)
        #expect(t.fileCount == 1)
        #expect(t.uniqueFileCount == 1)
        #expect(t.manuallyDeletedBytes == 3 * GB)
        #expect(t.manuallyDeletedFiles == 1)
        #expect(t.waterfallBalances)
    }

    /// A manually-deleted record must not participate in the duplicate
    /// collapse either — its twin on a live drive is the KEEPER, not an
    /// extra copy of a ghost.
    @Test func manuallyDeletedNeverElectsAKeeper() {
        let live = stRec("a.mov", bytes: 2 * GB, dir: "/Volumes/LaCie8TB/Family", md5: "same")
        let dead = mdRec("a.mov", bytes: 2 * GB, dir: "/Volumes/A_sorts_first/Family")
        let t = CatalogStorageTotalsCalculator.compute(records: [live, dead])
        #expect(t.uniqueBytes == 2 * GB)
        #expect(t.duplicateBytes == 0)
    }

    @Test func manuallyDeletedVolumeDoesNotCountAsAVolume() {
        let live = stRec("a.mov", bytes: 1 * GB)
        let dead = mdRec("b.mov", bytes: 1 * GB, dir: "/Volumes/OnlyGhosts/x")
        let t = CatalogStorageTotalsCalculator.compute(records: [live, dead])
        #expect(t.volumeCount == 1)
    }

    @Test func allManuallyDeletedIsAnEmptyFooterWithACaption() {
        let t = CatalogStorageTotalsCalculator.compute(records: [mdRec("x.mov", bytes: 5 * GB)])
        #expect(t.grossBytes == 0)
        #expect(t.fileCount == 0)
        #expect(t.manuallyDeletedBytes == 5 * GB)
        #expect(t.manuallyDeletedCaption != nil)
    }

    // MARK: Caption

    @Test func captionAbsentWhenNothingIsMarkedDeleted() {
        let t = CatalogStorageTotalsCalculator.compute(records: [stRec("a.mov")])
        #expect(t.manuallyDeletedCaption == nil)
        #expect(!t.breakdownTooltip.contains("Manually Deleted"))
    }

    /// Before the off-main probe reports, the caption must HEDGE — the
    /// footer has not looked at the disk yet.
    @Test func captionHedgesUntilTheProbeReports() {
        var t = CatalogStorageTotalsCalculator.compute(records: [stRec("a.mov"), mdRec("g.mov", bytes: 1_300 * MediaBytes.GB)])
        #expect(t.manuallyDeletedOnDiskBytes == nil)
        #expect(t.manuallyDeletedCaption == "+ 1.3 TB marked deleted (may still be on disk)")
        #expect(t.breakdownTooltip.contains("on-disk check pending"))

        t.manuallyDeletedOnDiskBytes = 1_260 * MediaBytes.GB
        t.manuallyDeletedOnDiskFiles = 1
        #expect(t.manuallyDeletedCaption == "+ 1.3 TB marked deleted, still on disk")
        #expect(t.breakdownTooltip.contains("still on disk"))
    }

    /// Probe looked and found every marked file truly gone → no caption.
    /// Nothing to disclose; the footer should not grow a line for zero.
    @Test func captionAbsentWhenProbeFindsNothingOnDisk() {
        var t = CatalogStorageTotalsCalculator.compute(records: [stRec("a.mov"), mdRec("g.mov", bytes: 1 * GB)])
        t.manuallyDeletedOnDiskBytes = 0
        #expect(t.manuallyDeletedCaption == nil)
        #expect(VolumeTableTotalsFooter.height(for: t) == VolumeTableTotalsFooter.height)
        t.manuallyDeletedOnDiskBytes = 1 * GB
        #expect(VolumeTableTotalsFooter.height(for: t) > VolumeTableTotalsFooter.height)
    }

    // MARK: Probe halves

    @Test func probesCoverOnlyActiveManuallyDeletedOnOnlineVolumes() {
        let live = stRec("a.mov")
        let onlineDead = mdRec("b.mov", bytes: 1 * GB, dir: "/Volumes/SanDiskWorkspace/x")
        let offlineDead = mdRec("c.mov", bytes: 1 * GB, dir: "/Volumes/MyBook/x")
        let purgedDead = mdRec("d.mov", bytes: 1 * GB)
        purgedDead.purgedAt = Date()
        let zeroDead = mdRec("e.mov", bytes: 0)
        let probes = CatalogStorageTotalsCalculator.manuallyDeletedProbes(
            records: [live, onlineDead, offlineDead, purgedDead, zeroDead],
            onlineVolumes: ["SanDiskWorkspace", "LaCie8TB"])
        #expect(probes.map(\.fullPath) == ["/Volumes/SanDiskWorkspace/x/b.mov"])
        // Unknown reachability keeps every checkable candidate.
        let all = CatalogStorageTotalsCalculator.manuallyDeletedProbes(
            records: [live, onlineDead, offlineDead, purgedDead, zeroDead])
        #expect(all.count == 2)
    }

    /// The I/O half with an injected `exists` — no real filesystem.
    @Test func onDiskSumsOnlyWhatExists() {
        let probes = [
            CatalogStorageTotalsCalculator.ManuallyDeletedProbe(fullPath: "/v/keep.mov", sizeBytes: 3 * GB),
            CatalogStorageTotalsCalculator.ManuallyDeletedProbe(fullPath: "/v/gone.mov", sizeBytes: 5 * GB),
        ]
        let r = CatalogStorageTotalsCalculator.manuallyDeletedOnDisk(probes) { $0.hasSuffix("keep.mov") }
        #expect(r.bytes == 3 * GB)
        #expect(r.files == 1)
        let none = CatalogStorageTotalsCalculator.manuallyDeletedOnDisk([]) { _ in true }
        #expect(none.bytes == 0 && none.files == 0)
    }
}

// MARK: - Scale + sensor

@Suite("Storage totals — scale and sensor")
struct CatalogStorageScaleTests {

    /// Builds a production-shaped catalog: mostly music (the iTunes
    /// sweep), a solid block of video, photos mixed in, some junk, and
    /// heavy cross-volume duplication on the insurance drives.
    private func syntheticCatalog(count: Int) -> [VideoRecord] {
        var out: [VideoRecord] = []
        out.reserveCapacity(count)
        let volumes = ["/Volumes/LaCie8TB", "/Volumes/MyBook3T", "/Volumes/RicksBackups"]
        for i in 0..<count {
            let vol = volumes[i % 3]
            switch i % 10 {
            case 0...5:   // music library — the dominant population
                out.append(stRec("track\(i).mp3", stream: .audioOnly,
                                 bytes: 8_000_000, dir: "\(vol)/iTunes/Music",
                                 md5: "m\(i)"))
            case 6, 7:    // family video, duplicated across all 3 volumes
                out.append(stRec("home\(i / 10).mov", bytes: 2 * GB,
                                 dir: "\(vol)/Family", md5: "v\(i / 10)"))
            case 8:       // photos
                out.append(stRec("img\(i).CR3", stream: .videoOnly,
                                 bytes: 30_000_000, dir: "\(vol)/Photos", md5: "p\(i)"))
            default:      // junk
                out.append(stRec("junk\(i).mov", bytes: 500_000_000,
                                 dir: "\(vol)/Misc", md5: "j\(i)",
                                 disposition: .suspectedJunk))
            }
        }
        return out
    }

    /// Scale dimension. This runs on the main thread inside the
    /// catalog's recompute trigger, so its cost is felt as UI latency
    /// every time the record count changes. 100k records is ~4× Rick's
    /// live catalog; the budget is deliberately loose enough not to
    /// flake on a busy machine but tight enough to catch an accidental
    /// O(n²) (which would take minutes here, not milliseconds).
    @Test func scales_100kRecordsWithinBudget() {
        let recs = syntheticCatalog(count: 100_000)
        let start = ContinuousClock.now
        let t = CatalogStorageTotalsCalculator.compute(records: recs)
        let elapsed = ContinuousClock.now - start

        #expect(t.fileCount == 100_000)
        #expect(t.waterfallBalances)
        #expect(elapsed < .seconds(3),
                "storage totals took \(elapsed) for 100k records — suspect O(n²)")
    }

    /// SENSOR. Pins the shape of the answer on a production-scale mixed
    /// catalog so a future change to any classifier shows up here as a
    /// moved number rather than as a wrong figure in Rick's footer.
    @Test func realisticCatalogSensor() {
        let t = CatalogStorageTotalsCalculator.compute(records: syntheticCatalog(count: 30_000))

        #expect(t.waterfallBalances)
        #expect(t.fileCount == 30_000)
        #expect(t.volumeCount == 3)

        // Unique must be a small fraction of gross on a catalog this
        // duplicated — that compression IS the feature.
        #expect(t.uniqueBytes < t.grossBytes / 2)
        // Every exclusion category must actually fire; a silently empty
        // bucket means a classifier stopped matching.
        #expect(t.musicBytes > 0)
        #expect(t.junkBytes > 0)
        #expect(t.nonVideoBytes > 0)
        #expect(t.duplicateBytes > 0)
        // Family video survives: 3 copies each of 3,000 distinct clips
        // at 2 GB ⇒ 3,000 unique clips counted once.
        #expect(t.uniqueBytes == 3_000 * 2 * GB)
        #expect(t.uniqueFileCount == 3_000)
    }

    /// Isolation dimension: the calculation must be a pure function of
    /// its input. Same records in, same numbers out, twice running.
    @Test func repeatedRunsAreIdentical() {
        let recs = syntheticCatalog(count: 5_000)
        let a = CatalogStorageTotalsCalculator.compute(records: recs)
        let b = CatalogStorageTotalsCalculator.compute(records: recs)
        #expect(a == b)
    }
}

// MARK: - Footer / column coupling

@Suite("TOTAL MEDIA footer geometry")
struct VolumeTableTotalsFooterTests {

    /// The footer positions itself from MEASURED column frames, so the
    /// contract to pin is the reduce rule that delivers them: every
    /// visible row publishes, and the FIRST real frame per column must
    /// win. A rule that let later rows overwrite would make each anchor
    /// depend on row count; one that never accepted a value would leave
    /// all three figures stuck on their fallbacks.
    @Test func columnFramesKeepFirstRealFramePerColumn() {
        let media = CGRect(x: 915, y: 0, width: 106, height: 28)
        let scanned = CGRect(x: 1123, y: 0, width: 100, height: 28)
        let laterRow = CGRect(x: 915, y: 28, width: 106, height: 28)

        var v = VolumeColumnFramesKey.defaultValue
        #expect(v.isEmpty)

        VolumeColumnFramesKey.reduce(value: &v) {
            [VolumeColumnID.mediaSize: media, VolumeColumnID.scanned: scanned]
        }
        #expect(v[VolumeColumnID.mediaSize] == media)
        #expect(v[VolumeColumnID.scanned] == scanned)

        // A second row reports the same columns — must not move anchors.
        VolumeColumnFramesKey.reduce(value: &v) { [VolumeColumnID.mediaSize: laterRow] }
        #expect(v[VolumeColumnID.mediaSize] == media, "later rows must not move the anchor")
    }

    /// Zero frames are what an off-screen or not-yet-laid-out row
    /// reports. They must never displace a real measurement, or a figure
    /// would snap back to its fallback mid-scroll.
    @Test func zeroFramesNeverDisplaceAMeasurement() {
        let real = CGRect(x: 915, y: 0, width: 106, height: 28)
        var v = [VolumeColumnID.mediaSize: real]
        VolumeColumnFramesKey.reduce(value: &v) { [VolumeColumnID.mediaSize: .zero] }
        #expect(v[VolumeColumnID.mediaSize] == real)
    }

    /// All three columns the footer anchors to must have distinct ids —
    /// a duplicated id would silently stack two figures on one column.
    @Test func columnIDsAreDistinct() {
        let ids = [VolumeColumnID.mediaSize, VolumeColumnID.scanned, VolumeColumnID.phase]
        #expect(Set(ids).count == 3)
    }

    /// The fallback covers the first frame before any measurement
    /// arrives. It encodes the Media Size origin measured from Rick's
    /// 2026-08-09 screenshot, so even the unmeasured frame lands in
    /// roughly the right place rather than at x=0.
    @Test func fallbackMatchesMeasuredScreenshotOrigin() {
        #expect(VolumeTableMetrics.fallbackMediaSizeX == 447)
        #expect(VolumeTableMetrics.fallbackMediaSizeWidth > 0)
    }
}
