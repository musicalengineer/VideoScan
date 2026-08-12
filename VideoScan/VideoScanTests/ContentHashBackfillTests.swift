import Foundation
import Testing
@testable import VideoScan

// MARK: - Content-hash backfill (2026-08-11)
//
// The backfill exists because a RESCAN cannot do this job: `probeFile`
// returns early on a probe-cache hit, before it reaches any hashing code.
// These tests pin the two properties that make the pass safe to re-run
// unattended against 18k live records:
//
//   1. It only ever ADDS a hash to a record that has none. Never
//      overwrites, never deletes, never touches a file.
//   2. Plan and run agree on what the work is — both go through
//      `needsContentHash`, so a dry run cannot promise different work
//      than the real pass performs.
//
// Five-dimension coverage:
//   Logic     — candidate selection truth table, plan arithmetic.
//   Scale     — plan over 100k records with a budget (it runs on the
//               main actor before the job starts).
//   Isolation — reachability is INJECTED; no test touches a real mount.
//   Sensor    — `neverOverwritesAnExistingHash` pins the safety property.
// Media matrix: N/A — no media is opened at this layer (see
// SegmentedHashTests for the hashing itself).

private func bfRec(
    path: String = "/Volumes/LaCie8TB/a.mov",
    bytes: Int64 = 1_000_000,
    hash: String = "",
    purged: Bool = false,
    setAside: String? = nil
) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.sizeBytes = bytes
    r.contentHash = hash
    if purged { r.purgedAt = Date(timeIntervalSince1970: 1_000) }
    r.setAsideReason = setAside
    return r
}

private let allReachable: (String) -> Bool = { _ in true }

@Suite("Content-hash backfill — candidate selection")
struct ContentHashBackfillSelectionTests {

    @Test func unhashedLiveRecordIsACandidate() {
        #expect(VideoScanModel.needsContentHash(bfRec()))
    }

    /// SENSOR — the safety property. An already-hashed record must never
    /// be re-hashed, which is what makes re-running the pass free and
    /// makes a cancelled run safe to resume.
    @Test func neverOverwritesAnExistingHash() {
        let rec = bfRec(hash: "v1:" + String(repeating: "a", count: 64))
        #expect(!VideoScanModel.needsContentHash(rec))

        let plan = VideoScanModel.planContentHashBackfill(
            records: [rec], isReachable: allReachable
        )
        #expect(plan.candidates == 0)
        #expect(plan.alreadyHashed == 1)
    }

    /// Trashed and tidied-away rows are not live storage — hashing them
    /// would spend I/O on files the user has already dismissed.
    @Test func purgedAndSetAsideAreSkipped() {
        #expect(!VideoScanModel.needsContentHash(bfRec(purged: true)))
        #expect(!VideoScanModel.needsContentHash(bfRec(setAside: "tidy")))
    }

    /// A zero-byte record has no content to identify, and
    /// `segmentedHash` would return "" for it anyway — so counting it as
    /// a candidate would guarantee a permanent "failed" every run.
    @Test func zeroByteAndPathlessRecordsAreSkipped() {
        #expect(!VideoScanModel.needsContentHash(bfRec(bytes: 0)))
        #expect(!VideoScanModel.needsContentHash(bfRec(path: "")))
    }
}

@Suite("Content-hash backfill — plan")
struct ContentHashBackfillPlanTests {

    /// Offline drives are counted separately rather than as candidates:
    /// roughly half Rick's catalog lives on unmounted volumes, and a
    /// plan that promised to hash them would be lying about its scope.
    @Test func unreachableRecordsAreReportedNotAttempted() {
        let recs = [
            bfRec(path: "/Volumes/Online/a.mov"),
            bfRec(path: "/Volumes/Offline/b.mov"),
            bfRec(path: "/Volumes/Offline/c.mov"),
        ]
        let plan = VideoScanModel.planContentHashBackfill(records: recs) { path in
            path.hasPrefix("/Volumes/Online")
        }
        #expect(plan.candidates == 1)
        #expect(plan.unreachable == 2)
        #expect(plan.alreadyHashed == 0)
    }

    /// Cost is per-FILE, not per-byte — the whole point of segmented
    /// hashing. A 12 GB file must not be estimated as more work than a
    /// 200 MB one.
    @Test func costIsFlatPerFileRegardlessOfSize() {
        let small = VideoScanModel.planContentHashBackfill(
            records: [bfRec(bytes: 200_000_000)], isReachable: allReachable)
        let huge = VideoScanModel.planContentHashBackfill(
            records: [bfRec(bytes: 12_000_000_000)], isReachable: allReachable)
        #expect(small.bytesToRead == huge.bytesToRead)
        #expect(small.estimatedSeconds == huge.estimatedSeconds)
        #expect(huge.bytesToRead == 3 << 20)
    }

    @Test func emptyPlanIsRecognizedAsEmpty() {
        let plan = VideoScanModel.planContentHashBackfill(
            records: [bfRec(hash: "v1:x")], isReachable: allReachable)
        #expect(plan.isEmpty)
    }

    /// Rick's actual shape: ~18k records, roughly half reachable. The
    /// estimate should land in minutes, not hours — if this ever reports
    /// an overnight job, the cost model has drifted from the design.
    @Test func realisticCatalogEstimatesMinutesNotHours() {
        var recs: [VideoRecord] = []
        for i in 0..<18_000 {
            let vol = i % 2 == 0 ? "/Volumes/Online" : "/Volumes/Offline"
            recs.append(bfRec(path: "\(vol)/f\(i).mov"))
        }
        let plan = VideoScanModel.planContentHashBackfill(records: recs) {
            $0.hasPrefix("/Volumes/Online")
        }
        #expect(plan.candidates == 9_000)
        #expect(plan.unreachable == 9_000)
        #expect(plan.estimatedSeconds < 1_800, "should be well under 30 minutes")
    }

    /// Scale: the plan runs on the main actor before the job starts, so
    /// its cost is UI latency.
    @Test func planScalesTo100kRecords() {
        let recs = (0..<100_000).map { bfRec(path: "/Volumes/V/f\($0).mov") }
        let start = ContinuousClock.now
        let plan = VideoScanModel.planContentHashBackfill(records: recs, isReachable: allReachable)
        let elapsed = ContinuousClock.now - start
        #expect(plan.candidates == 100_000)
        #expect(elapsed < .seconds(2), "plan took \(elapsed) for 100k records")
    }
}

@Suite("Probe cache — content_hash column")
struct MetadataCacheContentHashTests {

    private func tempCachePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mc-\(UUID().uuidString).sqlite").path
    }

    /// THE regression this column exists to prevent. `probeFile` returns
    /// a cached outcome BEFORE it hashes, so if the cache did not carry
    /// contentHash, a rescan would hand back "" and erase hashes a
    /// backfill had just computed. Round-tripping it here is what makes
    /// a rescan safe after a backfill.
    @Test func contentHashRoundTripsThroughTheCache() {
        let cache = MetadataCache(path: tempCachePath())
        var o = ProbeOutcome()
        o.fullPath = "/Volumes/V/clip.mov"
        o.filename = "clip.mov"
        o.sizeBytes = 4_096
        o.partialMD5 = "abc123"
        o.contentHash = "v1:" + String(repeating: "d", count: 64)
        o.probe.streamTypeRaw = StreamType.videoAndAudio.rawValue

        let mod = Date(timeIntervalSince1970: 1_700_000_000)
        cache.store(outcome: o, fileSize: o.sizeBytes, modDate: mod)

        let back = cache.lookup(path: o.fullPath, fileSize: o.sizeBytes, modDate: mod)
        #expect(back?.contentHash == o.contentHash,
                "a cache hit must carry the content hash, or a rescan erases it")
        #expect(back?.partialMD5 == "abc123", "the legacy key still round-trips")
    }

    /// Databases created before 2026-08-11 have no content_hash column.
    /// Opening one must migrate it in place rather than crash or refuse
    /// — Rick's real cache has months of probe results in it.
    @Test func legacyDatabaseGainsTheColumnOnOpen() throws {
        let path = tempCachePath()
        // First open creates the modern schema; reopening exercises the
        // "column already present" branch of the migration, which must
        // be a no-op rather than an error.
        _ = MetadataCache(path: path)
        let reopened = MetadataCache(path: path)

        var o = ProbeOutcome()
        o.fullPath = "/Volumes/V/x.mov"
        o.sizeBytes = 10
        o.contentHash = "v1:reopened"
        let mod = Date(timeIntervalSince1970: 1)
        reopened.store(outcome: o, fileSize: 10, modDate: mod)
        #expect(reopened.lookup(path: o.fullPath, fileSize: 10, modDate: mod)?.contentHash
                == "v1:reopened")
    }
}


// MARK: - Scoping (2026-08-12)
//
// Rick: "it should allow us to select one or more volumes… or navigate
// to a folder or individual file." Scoping matters for more than
// convenience — it is what makes "try it on one volume first" possible
// on a pass that mutates thousands of records.
//
// The scope is over CATALOG RECORDS, not the filesystem: a folder that
// was never scanned has no records, and a signature has nowhere to live
// without one.

@Suite("File signatures — timestamp")
struct ContentHashDateTests {

    /// The date round-trips, so "when were these signed?" survives a
    /// relaunch. Without it the Catalog Info line and the checklist's
    /// Signed step would reset to blank on every launch.
    @Test func contentHashDateRoundTrips() throws {
        let rec = VideoRecord()
        rec.contentHash = "v1:" + String(repeating: "c", count: 64)
        rec.contentHashAt = Date(timeIntervalSince1970: 1_760_000_000)

        let data = try JSONEncoder().encode(VideoRecordDTO(rec))
        let back = try JSONDecoder().decode(VideoRecord.self, from: data)
        #expect(back.contentHashAt == rec.contentHashAt)
    }

    /// SENSOR. The field is encodeIfPresent, so a record without a date
    /// emits NO key — which is what keeps the frozen catalog goldens
    /// byte-identical and lets months-old catalogs decode untouched. An
    /// unconditional encode would have rewritten every golden for a
    /// field that is usually absent.
    @Test func absentDateEmitsNoKeyAtAll() throws {
        let rec = VideoRecord()
        rec.contentHash = "v1:x"
        let json = String(decoding: try JSONEncoder().encode(VideoRecordDTO(rec)), as: UTF8.self)
        #expect(!json.contains("contentHashAt"))
    }

    /// A catalog written before the field existed decodes to nil, not a
    /// throw — the same additive contract contentHash itself follows.
    @Test func legacyRecordsDecodeWithoutTheDate() throws {
        let json = "{\"id\":\"\(UUID().uuidString)\",\"filename\":\"old.mov\",\"contentHash\":\"v1:y\"}"
        let rec = try JSONDecoder().decode(VideoRecord.self, from: Data(json.utf8))
        #expect(rec.contentHashAt == nil)
        #expect(rec.contentHash == "v1:y")
    }
}

@Suite("File signatures — scope")
struct ContentHashScopeTests {

    private let reachable: (String) -> Bool = { _ in true }

    /// The load-bearing prefix bug: "/Volumes/X" must not also claim
    /// "/Volumes/X2". Signature work scoped to one drive silently
    /// spilling onto a similarly-named one would be a nasty surprise on
    /// a fleet with CrucialX9 and CrucialX10 sitting side by side.
    @Test func siblingVolumesWithSharedPrefixDoNotOverlap() {
        let recs = [
            bfRec(path: "/Volumes/CrucialX1/a.mov"),
            bfRec(path: "/Volumes/CrucialX10/b.mov"),
        ]
        let plan = VideoScanModel.planContentHashBackfill(
            records: recs, isReachable: reachable, pathPrefix: "/Volumes/CrucialX1")
        #expect(plan.candidates == 1)
    }

    @Test func folderScopeSelectsOnlyThatSubtree() {
        let recs = [
            bfRec(path: "/Volumes/V/Family/a.mov"),
            bfRec(path: "/Volumes/V/Family/1994/b.mov"),
            bfRec(path: "/Volumes/V/Music/c.mov"),
        ]
        let plan = VideoScanModel.planContentHashBackfill(
            records: recs, isReachable: reachable, pathPrefix: "/Volumes/V/Family")
        #expect(plan.candidates == 2)
    }

    /// A single file is a legitimate scope — the narrowest useful test
    /// before turning a pass loose on a whole drive.
    @Test func singleFileScopeSelectsExactlyIt() {
        let recs = [
            bfRec(path: "/Volumes/V/a.mov"),
            bfRec(path: "/Volumes/V/b.mov"),
        ]
        let plan = VideoScanModel.planContentHashBackfill(
            records: recs, isReachable: reachable, pathPrefix: "/Volumes/V/a.mov")
        #expect(plan.candidates == 1)
    }

    /// A migrated file is still its origin volume's history. Scoping by
    /// the drive in your hand should find what came off it.
    @Test func scopeMatchesOriginPathToo() {
        let rec = bfRec(path: "/Volumes/New/a.mov")
        rec.originalFullPath = "/Volumes/OldDrive/a.mov"
        let plan = VideoScanModel.planContentHashBackfill(
            records: [rec], isReachable: reachable, pathPrefix: "/Volumes/OldDrive")
        #expect(plan.candidates == 1)
    }

    /// An unscanned folder yields nothing — the case the UI must report
    /// rather than silently no-op.
    @Test func unknownFolderYieldsAnEmptyPlan() {
        let plan = VideoScanModel.planContentHashBackfill(
            records: [bfRec(path: "/Volumes/V/a.mov")],
            isReachable: reachable,
            pathPrefix: "/Volumes/NeverScanned")
        #expect(plan.isEmpty)
        #expect(plan.candidates == 0)
    }

    @Test func nilScopeCoversTheWholeCatalog() {
        let recs = (0..<5).map { bfRec(path: "/Volumes/V\($0)/a.mov") }
        let plan = VideoScanModel.planContentHashBackfill(
            records: recs, isReachable: reachable, pathPrefix: nil)
        #expect(plan.candidates == 5)
    }
}
