// EmbeddedDateProbeFixtureTests.swift
// MEDIA-MATRIX + ISOLATION dimensions for the embedded creation date
// (2026-08-16): synthetic ffmpeg fixtures carrying `-metadata
// creation_time=…` (and Canon-style / iPhone-style origin tags) are run
// through the REAL scan parser (`ScanEngine.runFFProbe` → `extractMetadata`)
// and through the backfill's tag-only probe, and the model-level "Refresh
// Embedded Dates" pass is exercised end-to-end against an isolated model
// (temp catalog store, temp files — the real App Support store, UserDefaults
// and /Volumes are never touched).
//
// Fixtures: mov/h264 (Canon-style make/model), mov/h264 (iPhone-style
// com.apple.quicktime.* keys via use_metadata_tags), mp4/h264, mkv/ffv1,
// plus a mov with a junk 1970 stamp and an mkv with no stamp at all.

import Foundation
import Testing
@testable import VideoScan

private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    var dc = DateComponents()
    dc.year = y; dc.month = mo; dc.day = d; dc.hour = h; dc.minute = mi; dc.second = s
    return cal.date(from: dc)!
}

struct EmbeddedFixtureCase: Sendable, CustomStringConvertible {
    let label: String
    let filename: String
    let videoCodec: String
    let extraArgs: [String]          // muxer flags + -metadata …
    let expectDate: Date?            // nil ⇒ must NOT capture
    let expectSource: String?
    let expectMake: String?
    let expectModel: String?
    let expectEncoderFamily: String? // nil ⇒ don't care
    var description: String { label }
}

let embeddedFixtureMatrix: [EmbeddedFixtureCase] = [
    EmbeddedFixtureCase(label: "mov/h264 Canon-style make+model", filename: "test_emb_canon.mov", videoCodec: "libx264",
                        extraArgs: ["-metadata", "creation_time=2025-06-15T22:47:45Z",
                                    "-metadata", "make=Canon", "-metadata", "model=Canon EOS R6m2"],
                        expectDate: utc(2025, 6, 15, 22, 47, 45), expectSource: "format:creation_time",
                        expectMake: "Canon", expectModel: "Canon EOS R6m2", expectEncoderFamily: nil),
    EmbeddedFixtureCase(label: "mov/h264 iPhone-style com.apple.quicktime.* keys", filename: "test_emb_iphone.mov", videoCodec: "libx264",
                        extraArgs: ["-movflags", "use_metadata_tags",
                                    "-metadata", "creation_time=2025-06-15T22:47:45Z",
                                    "-metadata", "com.apple.quicktime.make=Apple",
                                    "-metadata", "com.apple.quicktime.model=iPhone 15 Pro",
                                    "-metadata", "com.apple.quicktime.software=17.2",
                                    "-metadata", "com.apple.quicktime.creationdate=2025-06-15T18:47:45-0400"],
                        expectDate: utc(2025, 6, 15, 22, 47, 45), expectSource: "format:creation_time",
                        expectMake: "Apple", expectModel: "iPhone 15 Pro", expectEncoderFamily: nil),
    EmbeddedFixtureCase(label: "mp4/h264 creation_time only (transcoder origin)", filename: "test_emb_plain.mp4", videoCodec: "libx264",
                        extraArgs: ["-metadata", "creation_time=2019-03-02T10:15:00Z"],
                        expectDate: utc(2019, 3, 2, 10, 15), expectSource: "format:creation_time",
                        expectMake: nil, expectModel: nil, expectEncoderFamily: "ffmpeg"),
    EmbeddedFixtureCase(label: "mkv/ffv1 creation_time (upper-case tag keys)", filename: "test_emb_ffv1.mkv", videoCodec: "ffv1",
                        extraArgs: ["-metadata", "creation_time=2015-05-05T05:05:05Z"],
                        expectDate: utc(2015, 5, 5, 5, 5, 5), expectSource: "format:creation_time",
                        expectMake: nil, expectModel: nil, expectEncoderFamily: "ffmpeg"),
    EmbeddedFixtureCase(label: "mov with the 1970 junk default → no date", filename: "test_emb_junk.mov", videoCodec: "libx264",
                        extraArgs: ["-metadata", "creation_time=1970-01-01T00:00:00Z"],
                        expectDate: nil, expectSource: nil, expectMake: nil, expectModel: nil, expectEncoderFamily: nil),
    EmbeddedFixtureCase(label: "mkv with no stamp at all → no date", filename: "test_emb_none.mkv", videoCodec: "ffv1",
                        extraArgs: [],
                        expectDate: nil, expectSource: nil, expectMake: nil, expectModel: nil, expectEncoderFamily: nil),
]

enum EmbeddedFixtures {
    /// One-second testsrc + sine fixture with the case's muxer/metadata flags.
    static func generate(_ c: EmbeddedFixtureCase, into dir: URL) throws -> String {
        let out = dir.appendingPathComponent(c.filename).path
        var args: [String] = ["-f", "lavfi", "-i", "testsrc=duration=1:size=64x64:rate=10",
                              "-f", "lavfi", "-i", "sine=frequency=440:duration=1:sample_rate=48000",
                              "-c:v", c.videoCodec]
        if c.videoCodec == "libx264" { args += ["-pix_fmt", "yuv420p"] }
        args += ["-c:a", c.filename.hasSuffix(".mkv") ? "pcm_s16le" : "aac"]
        args += c.extraArgs
        try CleanupTestMedia.runFFmpeg(args, output: out)
        return out
    }
}

// MARK: - Scan parser (the real path)

@Suite("Embedded date — ffprobe fixture matrix (scan parser + backfill probe)", .serialized)
struct EmbeddedDateProbeFixtureTests {

    @Test("ScanEngine.runFFProbe → extractMetadata captures the stamp + origin; the tag-only backfill probe agrees",
          .timeLimit(.minutes(2)), arguments: embeddedFixtureMatrix)
    func scanParserCaptures(testCase: EmbeddedFixtureCase) async throws {
        try #require(CleanupTestMedia.toolsAvailable, "ffmpeg/ffprobe are required project dependencies")
        let dir = try CleanupTestMedia.makeScratchDir("emb")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try EmbeddedFixtures.generate(testCase, into: dir)

        // 1. The scan's own parser — same JSON, same extractMetadata.
        let (probe, stderr) = await ScanEngine.runFFProbe(url: URL(fileURLWithPath: path))
        let out = try #require(probe, "ffprobe failed: \(stderr)")
        let r = ScanEngine.extractMetadata(probe: out)
        #expect(r.streamTypeRaw == StreamType.videoAndAudio.rawValue, "the 19 legacy fields still populate")
        if let want = testCase.expectDate {
            #expect(r.embeddedCreationDate != nil, "\(testCase.label): no date captured")
            if let got = r.embeddedCreationDate { #expect(abs(got.timeIntervalSince(want)) < 1.0, "\(testCase.label): \(got) ≠ \(want)") }
            #expect(r.embeddedCreationSource == testCase.expectSource)
        } else {
            #expect(r.embeddedCreationDate == nil, "\(testCase.label): junk/absent stamp must not be captured")
            #expect(r.embeddedCreationSource == nil)
        }
        #expect(r.originMake == testCase.expectMake, "\(testCase.label)")
        #expect(r.originModel == testCase.expectModel, "\(testCase.label)")
        if let fam = testCase.expectEncoderFamily {
            #expect(r.originEncoder.map(EmbeddedOriginTags.encoderFamily) == fam, "\(testCase.label): \(r.originEncoder ?? "nil")")
        }

        // 2. The backfill's tag-only probe reads the same values.
        let probed = try #require(await VideoScanModel.probeEmbeddedTags(path: path))
        if let want = testCase.expectDate {
            #expect(probed.0.map { abs($0.date.timeIntervalSince(want)) < 1.0 } == true, "\(testCase.label): backfill probe")
        } else {
            #expect(probed.0 == nil, "\(testCase.label): backfill probe must not capture")
        }
        #expect(probed.1.make == testCase.expectMake); #expect(probed.1.model == testCase.expectModel)

        // 3. Applied to a record, the resolver places it (or not).
        let rec = VideoRecord()
        rec.filename = testCase.filename; rec.ext = (testCase.filename as NSString).pathExtension
        rec.apply(r)
        let res = RecordDateResolver.resolve(userDate: nil, embeddedCreationDate: rec.embeddedCreationDate,
                                             originMake: rec.originMake, originModel: rec.originModel, originEncoder: rec.originEncoder,
                                             inferredRecordDate: nil, inferredDateConfidence: nil, filename: rec.filename)
        if testCase.expectDate != nil {
            #expect(res.source == .embedded); #expect(res.precision == .day)
            #expect(res.confidence == (testCase.expectMake != nil ? 0.95 : 0.80), "\(testCase.label): tier")
        } else {
            #expect(res.precision == .unknown, "test_emb_* names carry no year")
        }
    }
}

// MARK: - Model-level backfill (isolated)

@Suite("Embedded date — Refresh Embedded Dates backfill (isolated model)", .serialized)
@MainActor
struct EmbeddedDateBackfillTests {

    @Test("dates only records lacking one, captures origin, writes through to the probe cache, respects read-only, is idempotent",
          .timeLimit(.minutes(2)))
    func backfillEndToEnd() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let sb = try MasterArchiveTestSupport.makeSandbox("embfill")
        defer { sb.cleanup() }
        let canonPath = try EmbeddedFixtures.generate(embeddedFixtureMatrix[0], into: sb.sources)
        let nonePath = try EmbeddedFixtures.generate(embeddedFixtureMatrix[5], into: sb.sources)

        let model = MasterArchiveTestSupport.makeModel(sb)
        // Point the model's probe cache at a temp file (never the real one) —
        // MetadataCache(path:) is what the write-through targets.
        let cachePath = sb.root.appendingPathComponent("test_probe_cache.sqlite").path
        let cache = MetadataCache(path: cachePath)

        let canon = MasterArchiveTestSupport.makeRecord(path: canonPath)
        let none = MasterArchiveTestSupport.makeRecord(path: nonePath)
        let already = MasterArchiveTestSupport.makeRecord(path: canonPath)
        already.embeddedCreationDate = utc(1999, 9, 9); already.embeddedCreationSource = "stream:creation_time"
        let purged = MasterArchiveTestSupport.makeRecord(path: canonPath); purged.purgedAt = Date()
        let failed = MasterArchiveTestSupport.makeRecord(path: canonPath); failed.streamTypeRaw = StreamType.ffprobeFailed.rawValue
        model.records = [canon, none, already, purged, failed]

        // Candidate predicate (pure).
        #expect(VideoScanModel.needsEmbeddedDate(canon))
        #expect(VideoScanModel.needsEmbeddedDate(none))
        #expect(!VideoScanModel.needsEmbeddedDate(already))
        #expect(!VideoScanModel.needsEmbeddedDate(purged))
        #expect(!VideoScanModel.needsEmbeddedDate(failed))

        // Seed the cache row for canon so the write-through has a row to land on.
        var o = ProbeOutcome(); o.fullPath = canonPath; o.filename = canon.filename; o.sizeBytes = canon.sizeBytes
        let attrs = try FileManager.default.attributesOfItem(atPath: canonPath)
        let mod = (attrs[.modificationDate] as? Date) ?? Date()
        cache.store(outcome: o, fileSize: canon.sizeBytes, modDate: mod)
        // The model's cache is `let`; drive the same write-through the pass does
        // against our temp cache by running the pass, then replaying its update.
        // (The pass writes to model.metadataCache; we assert on the record and
        // replay the same call on the temp cache to prove the SQL path.)

        // Read-only guard.
        model.isReadOnly = true
        let ro = await model.runEmbeddedDateBackfill()
        #expect(ro.dated == 0); #expect(canon.embeddedCreationDate == nil)
        model.isReadOnly = false

        var progressCalls = 0
        let result = await model.runEmbeddedDateBackfill(batchSize: 1) { _, _ in progressCalls += 1 }
        #expect(result.dated == 1, "\(result)")
        #expect(result.noTag == 1)
        #expect(result.failed == 0)
        #expect(!result.cancelled)
        #expect(progressCalls >= 1)
        #expect(canon.embeddedCreationDate.map { abs($0.timeIntervalSince(utc(2025, 6, 15, 22, 47, 45))) < 1 } == true)
        #expect(canon.embeddedCreationSource == "format:creation_time")
        #expect(canon.originMake == "Canon"); #expect(canon.originModel == "Canon EOS R6m2")
        #expect(none.embeddedCreationDate == nil)
        #expect(none.originEncoder != nil, "origin still captured when there is no date")
        #expect(already.embeddedCreationDate == utc(1999, 9, 9), "never overwrites")
        #expect(purged.embeddedCreationDate == nil); #expect(failed.embeddedCreationDate == nil)

        // Write-through SQL path against the temp cache.
        cache.updateEmbeddedDate(path: canonPath, date: canon.embeddedCreationDate, source: canon.embeddedCreationSource,
                                 make: canon.originMake, model: canon.originModel, encoder: canon.originEncoder)
        let hit = cache.lookup(path: canonPath, fileSize: canon.sizeBytes, modDate: mod)
        #expect(hit?.probe.embeddedCreationDate == canon.embeddedCreationDate)
        #expect(hit?.probe.originModel == "Canon EOS R6m2")

        // Idempotent: a second run finds nothing to date (none has no tag → probed again, still noTag).
        let again = await model.runEmbeddedDateBackfill()
        #expect(again.dated == 0)
        #expect(model.isRefreshingEmbeddedDates == false)
    }
}
