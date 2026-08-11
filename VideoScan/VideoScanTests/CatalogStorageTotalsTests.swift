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

    /// Rick's requested shape: "5.6 TB", "150 GB" — one decimal until
    /// three significant figures, then none.
    @Test func displaySizeMatchesRequestedShape() {
        #expect(CatalogStorageTotals.displaySize(0) == "0 GB")
        #expect(CatalogStorageTotals.displaySize(150 * GB) == "150 GB")
        #expect(CatalogStorageTotals.displaySize(Int64(5.6 * Double(GB) * 1024)) == "5.6 TB")
        #expect(CatalogStorageTotals.displaySize(7 * GB) == "7.0 GB")
    }

    /// Base-1024, matching the Media Size column directly above the
    /// footer. A total in different units than the column it sits under
    /// reads as a bug.
    @Test func displayUsesSameBaseAsMediaSizeColumn() {
        #expect(CatalogStorageTotals.displaySize(1_073_741_824) == "1.0 GB")
        #expect(CatalogStorageTotals.displaySize(1_099_511_627_776) == "1.0 TB")
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

    /// The footer positions itself from a MEASURED Media Size frame, so
    /// the contract to pin is the reduce rule that delivers it: every
    /// visible row publishes, and the first real frame must win. A
    /// `reduce` that let later rows overwrite would make the anchor
    /// depend on row count; one that never accepted a value would leave
    /// the footer stuck on its fallback forever.
    @Test func mediaSizeFramePreferenceKeepsFirstRealFrame() {
        let real = CGRect(x: 447, y: 0, width: 106, height: 28)
        let other = CGRect(x: 999, y: 28, width: 106, height: 28)

        var v = MediaSizeColumnFrameKey.defaultValue
        #expect(v == .zero)

        v = .zero
        MediaSizeColumnFrameKey.reduce(value: &v) { real }
        #expect(v == real, "first real frame must be adopted")

        MediaSizeColumnFrameKey.reduce(value: &v) { other }
        #expect(v == real, "later rows must not move the anchor")
    }

    /// Zero frames are what an off-screen or not-yet-laid-out row
    /// reports. They must never displace a real measurement, or the
    /// footer would snap back to its fallback mid-scroll.
    @Test func zeroFramesNeverDisplaceAMeasurement() {
        var v = CGRect(x: 447, y: 0, width: 106, height: 28)
        MediaSizeColumnFrameKey.reduce(value: &v) { .zero }
        #expect(v.minX == 447)
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
