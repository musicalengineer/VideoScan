// EmbeddedCreationDateTests.swift
// LOGIC dimension for the embedded creation date + origin feature
// (2026-08-16): the tag-string parser matrix, the sanity filter, origin
// (make/model/encoder) extraction and description, the confidence tiers,
// the tags → capture entry point, and the schema contract (Codable round-
// trip, legacy decode, DTO delta-minimal encoding, ProbeResult apply/lift,
// snapshotClone parity is covered by ModelSchemaTests' Mirror sweep).
//
// Style: Swift Testing. For Rick: `#expect` ≈ EXPECT_*, `try #require`
// ≈ ASSERT_*.

import Foundation
import Testing
@testable import VideoScan

// MARK: - Helpers

private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    var dc = DateComponents()
    dc.year = y; dc.month = mo; dc.day = d; dc.hour = h; dc.minute = mi; dc.second = s
    return cal.date(from: dc)!
}

// MARK: - Parser matrix

@Suite("Embedded date — parser matrix")
struct EmbeddedDateParserTests {

    @Test("ISO-8601 variants: Z, fractional seconds, offsets with and without colon, space separator, date-only, EXIF colons",
          arguments: [
            ("2025-06-15T22:47:45Z",              utc(2025, 6, 15, 22, 47, 45)),
            ("2025-06-15T22:47:45.000000Z",       utc(2025, 6, 15, 22, 47, 45)),
            ("2025-06-15T22:47:45.5Z",            utc(2025, 6, 15, 22, 47, 45).addingTimeInterval(0.5)),
            ("2025-06-15T18:47:45-0400",          utc(2025, 6, 15, 22, 47, 45)),   // QuickTime creationdate
            ("2025-06-15T18:47:45-04:00",         utc(2025, 6, 15, 22, 47, 45)),
            ("2025-06-16T07:47:45+0900",          utc(2025, 6, 15, 22, 47, 45)),
            ("2025-06-15 22:47:45",               utc(2025, 6, 15, 22, 47, 45)),   // no zone ⇒ UTC
            ("2025:06:15 22:47:45",               utc(2025, 6, 15, 22, 47, 45)),   // EXIF
            ("2025-06-15",                        utc(2025, 6, 15)),
            ("  2025-06-15T22:47:45Z \n",         utc(2025, 6, 15, 22, 47, 45)),   // trimmed
            ("2025-06-15T22:47:45.000000Z;2025-06-15T22:47:45Z", utc(2025, 6, 15, 22, 47, 45)), // ffmpeg dup join
            ("2025-06-15T22:47Z",                 utc(2025, 6, 15, 22, 47, 0)),    // no seconds
          ] as [(String, Date)])
    func parsesVariants(input: String, expected: Date) {
        let got = EmbeddedDateParser.parse(input)
        #expect(got != nil, "should parse: \(input)")
        if let got { #expect(abs(got.timeIntervalSince(expected)) < 0.001, "\(input) → \(got) ≠ \(expected)") }
    }

    @Test("garbage and impossible calendar dates → nil",
          arguments: ["", "not a date", "1995", "06/15/2025", "2025-13-01T00:00:00Z", "2025-02-30",
                      "2025-06-15T25:00:00Z", "2025-06-15T22:47:45Q", "2025-06-15X22:47:45Z", "20250615"])
    func rejectsGarbage(input: String) {
        #expect(EmbeddedDateParser.parse(input) == nil, "should reject: \(input)")
    }
}

// MARK: - Sanity filter

@Suite("Embedded date — sanity filter")
struct EmbeddedDateSanityTests {

    let now = utc(2026, 8, 16, 12, 0, 0)

    @Test("junk defaults are rejected: QuickTime epoch 1904, Unix epoch 1970, camera default 2000-01-01T00:00:00, anything before 1980",
          arguments: ["1904-01-01T00:00:00Z", "1970-01-01T00:00:00Z", "2000-01-01T00:00:00Z",
                      "1970-01-01T05:00:00Z",       // 1970-01-01 midnight in a US zone
                      "1904-01-01T08:00:00Z",       // 1904 in a Pacific zone
                      "2000-01-01T05:00:00Z",       // 2000-01-01 anywhere is a default
                      "1979-12-31T23:59:59Z", "1965-04-01T10:00:00Z"])
    func rejectsDefaults(input: String) throws {
        let d = try #require(EmbeddedDateParser.parse(input))
        #expect(EmbeddedDateSanity.accept(d, now: now) == nil, "should reject \(input)")
    }

    @Test("the future is rejected beyond one day of slack; a real 1980+ date passes")
    func futureAndReal() {
        #expect(EmbeddedDateSanity.accept(now.addingTimeInterval(2 * 86_400), now: now) == nil)
        #expect(EmbeddedDateSanity.accept(now.addingTimeInterval(3_600), now: now) != nil, "an hour ahead is clock skew, not junk")
        #expect(EmbeddedDateSanity.accept(utc(1980, 1, 1), now: now) != nil)
        #expect(EmbeddedDateSanity.accept(utc(2000, 1, 2), now: now) != nil, "only 2000-01-01 is the default")
        #expect(EmbeddedDateSanity.accept(utc(2025, 6, 15, 22, 47, 45), now: now) != nil)
    }
}

// MARK: - Entry point (tags → capture)

@Suite("Embedded date — tags → capture")
struct EmbeddedCreationDateExtractTests {

    let now = utc(2026, 8, 16)

    @Test("format creation_time wins; source names the tag")
    func formatWins() {
        let cap = EmbeddedCreationDate.extract(
            formatTags: ["creation_time": "2025-06-15T22:47:45.000000Z",
                         "com.apple.quicktime.creationdate": "2025-06-15T18:47:45-0400"],
            streamTags: [["creation_time": "2025-06-15T22:47:45.000000Z"]], now: now)
        #expect(cap?.date == utc(2025, 6, 15, 22, 47, 45))
        #expect(cap?.source == "format:creation_time")
    }

    @Test("a junk format stamp does not hide a good QuickTime or stream stamp")
    func fallsThroughJunk() {
        let a = EmbeddedCreationDate.extract(
            formatTags: ["creation_time": "1904-01-01T00:00:00Z",
                         "com.apple.quicktime.creationdate": "2025-06-15T18:47:45-0400"],
            streamTags: [], now: now)
        #expect(a?.source == "quicktime:com.apple.quicktime.creationdate")
        #expect(a?.date == utc(2025, 6, 15, 22, 47, 45))
        let b = EmbeddedCreationDate.extract(
            formatTags: ["creation_time": "1970-01-01T00:00:00Z"],
            streamTags: [["handler_name": "VideoHandler"], ["creation_time": "2019-03-02T10:00:00Z"]], now: now)
        #expect(b?.source == "stream:creation_time")
        #expect(b?.date == utc(2019, 3, 2, 10))
    }

    @Test("Matroska upper-case keys and no tags at all")
    func caseAndAbsence() {
        #expect(EmbeddedCreationDate.extract(formatTags: ["CREATION_TIME": "2015-05-05T05:05:05Z"], streamTags: [], now: now)?.date == utc(2015, 5, 5, 5, 5, 5))
        #expect(EmbeddedCreationDate.extract(formatTags: ["ENCODER": "Lavf60"], streamTags: [["DURATION": "00:00:01"]], now: now) == nil)
        #expect(EmbeddedCreationDate.extract(formatTags: [:], streamTags: [], now: now) == nil)
    }
}

// MARK: - Origin tags

@Suite("Embedded origin — make / model / encoder matrix")
struct EmbeddedOriginTagsTests {

    @Test("iPhone: com.apple.quicktime.make/model; the OS version in .software is not an encoder")
    func iphone() {
        let o = EmbeddedOriginTags.extract(
            formatTags: ["com.apple.quicktime.make": "Apple", "com.apple.quicktime.model": "iPhone 15 Pro",
                         "com.apple.quicktime.software": "17.2"],
            streamTags: [["handler_name": "Core Media Video"]])
        #expect(o.make == "Apple"); #expect(o.model == "iPhone 15 Pro"); #expect(o.encoder == nil)
        #expect(EmbeddedOriginTags.description(o) == "Apple iPhone 15 Pro")
        #expect(o.namesDevice)
    }

    @Test("Canon-style: make + model where the model already carries the make; the encoder is secondary")
    func canon() {
        let o = EmbeddedOriginTags.extract(
            formatTags: ["make": "Canon", "model": "Canon EOS R6m2", "encoder": "Lavf63.1.101"],
            streamTags: [["encoder": "Lavc63.1.101 libx264"]])
        #expect(o.make == "Canon"); #expect(o.model == "Canon EOS R6m2"); #expect(o.encoder == "Lavf63.1.101")
        #expect(EmbeddedOriginTags.description(o) == "Canon EOS R6m2", "make not repeated")
        #expect(RecordDateResolver.embeddedConfidence(originMake: o.make, originModel: o.model, originEncoder: o.encoder) == 0.95)
    }

    @Test("transcoder only: HandBrake with build stamp, ffmpeg Lavf, MKV upper-case ENCODER, encoding_tool")
    func encoderOnly() {
        let hb = EmbeddedOriginTags.extract(formatTags: ["encoder": "HandBrake 1.7.3 2023121300"], streamTags: [])
        #expect(hb.make == nil); #expect(hb.model == nil); #expect(hb.encoder == "HandBrake 1.7.3 2023121300")
        #expect(EmbeddedOriginTags.description(hb) == "HandBrake 1.7.3")
        #expect(EmbeddedOriginTags.encoderFamily(hb.encoder!) == "HandBrake")
        #expect(RecordDateResolver.embeddedConfidence(originMake: nil, originModel: nil, originEncoder: hb.encoder) == 0.80)

        let ff = EmbeddedOriginTags.extract(formatTags: ["ENCODER": "Lavf63.1.101"], streamTags: [["ENCODER": "Lavc63.1.101 ffv1"]])
        #expect(ff.encoder == "Lavf63.1.101")
        #expect(EmbeddedOriginTags.encoderFamily(ff.encoder!) == "ffmpeg")

        let tool = EmbeddedOriginTags.extract(formatTags: ["encoding_tool": "Final Cut Pro 10.7"], streamTags: [])
        #expect(tool.encoder == "Final Cut Pro 10.7")
        #expect(EmbeddedOriginTags.encoderFamily(tool.encoder!) == "Final Cut Pro")
    }

    @Test("stream-only device signals: GoPro handler_name names the maker; stream make/model fill gaps; nothing → empty")
    func streamSignals() {
        let gp = EmbeddedOriginTags.extract(formatTags: [:], streamTags: [["handler_name": "\tGoPro AVC"], ["handler_name": "\tGoPro AAC"]])
        #expect(gp.make == "GoPro"); #expect(gp.model == nil)
        #expect(EmbeddedOriginTags.description(gp) == "GoPro")
        let st = EmbeddedOriginTags.extract(formatTags: [:], streamTags: [["make": "Sony", "model": "FDR-AX53"]])
        #expect(EmbeddedOriginTags.description(st) == "Sony FDR-AX53")
        let none = EmbeddedOriginTags.extract(formatTags: ["major_brand": "qt  "], streamTags: [["handler_name": "VideoHandler"]])
        #expect(none.isEmpty); #expect(EmbeddedOriginTags.description(none) == nil)
        #expect(RecordDateResolver.embeddedConfidence(originMake: nil, originModel: nil, originEncoder: nil) == 0.85)
        // NUL-padded / punctuation-only values are noise.
        let noise = EmbeddedOriginTags.extract(formatTags: ["make": "\u{0}\u{0}", "model": "---"], streamTags: [])
        #expect(noise.isEmpty)
    }

    @Test("VideoRecord conveniences: originDescription + the inspector's paren label")
    @MainActor
    func recordConveniences() {
        let r = VideoRecord()
        #expect(r.originDescription == nil)
        #expect(r.embeddedDateOriginLabel == "container tag")
        r.originEncoder = "HandBrake 1.7.3 2023121300"
        #expect(r.originDescription == "HandBrake 1.7.3")
        #expect(r.embeddedDateOriginLabel == "HandBrake")
        r.originMake = "Canon"; r.originModel = "Canon EOS R6m2"
        #expect(r.originDescription == "Canon EOS R6m2")
        #expect(r.embeddedDateOriginLabel == "Canon EOS R6m2")
    }
}

// MARK: - Schema contract

@Suite("Embedded date — schema (Codable / DTO / ProbeResult)")
struct EmbeddedDateSchemaTests {

    private static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    private static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }

    private static let legacyJSON = """
    {
      "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
      "filename": "RickGuitar2025.mov", "ext": "mov", "streamTypeRaw": "Video+Audio",
      "size": "500 MB", "sizeBytes": 524288000, "duration": "00:00:30", "durationSeconds": 30.0,
      "dateCreated": "2026-08-01 10:00", "dateModified": "2026-08-01 10:00",
      "container": "QuickTime / MOV", "videoCodec": "hevc", "resolution": "3840x2160",
      "frameRate": "29.97", "videoBitrate": "", "totalBitrate": "", "colorSpace": "",
      "bitDepth": "", "scanType": "", "audioCodec": "aac", "audioChannels": "2",
      "audioSampleRate": "48000 Hz", "timecode": "", "tapeName": "", "isPlayable": "Yes",
      "partialMD5": "", "fullPath": "/Volumes/MediaExpansion/RickGuitar2025.mov",
      "directory": "/Volumes/MediaExpansion", "notes": ""
    }
    """

    @Test("legacy catalog.json (no embedded keys) decodes with nil fields and re-encodes WITHOUT the keys")
    @MainActor
    func legacyDecodesNil() throws {
        let rec = try Self.decoder().decode(VideoRecord.self, from: Data(Self.legacyJSON.utf8))
        #expect(rec.embeddedCreationDate == nil)
        #expect(rec.embeddedCreationSource == nil)
        #expect(rec.originMake == nil); #expect(rec.originModel == nil); #expect(rec.originEncoder == nil)
        let out = String(decoding: try Self.encoder().encode(VideoRecordDTO(rec)), as: UTF8.self)
        #expect(!out.contains("embeddedCreationDate"))
        #expect(!out.contains("originMake"))
        #expect(!out.contains("originEncoder"))
    }

    @Test("populated fields round-trip through the DTO encoder and back; snapshotClone carries them")
    @MainActor
    func roundTrip() throws {
        let rec = try Self.decoder().decode(VideoRecord.self, from: Data(Self.legacyJSON.utf8))
        rec.embeddedCreationDate = utc(2025, 6, 15, 22, 47, 45)
        rec.embeddedCreationSource = "format:creation_time"
        rec.originMake = "Apple"; rec.originModel = "iPhone 15 Pro"; rec.originEncoder = nil
        let data = try Self.encoder().encode(VideoRecordDTO(rec))
        let back = try Self.decoder().decode(VideoRecord.self, from: data)
        #expect(back.embeddedCreationDate == utc(2025, 6, 15, 22, 47, 45))
        #expect(back.embeddedCreationSource == "format:creation_time")
        #expect(back.originMake == "Apple"); #expect(back.originModel == "iPhone 15 Pro"); #expect(back.originEncoder == nil)
        let clone = rec.snapshotClone()
        #expect(clone.embeddedCreationDate == rec.embeddedCreationDate)
        #expect(clone.embeddedCreationSource == rec.embeddedCreationSource)
        #expect(clone.originMake == "Apple"); #expect(clone.originModel == "iPhone 15 Pro")
    }

    @Test("ProbeResult carries the fields both ways (apply + scanDerivedFrom) and the cache-hit path keeps them")
    @MainActor
    func probeResultBothWays() {
        var p = ProbeResult()
        p.embeddedCreationDate = utc(2019, 3, 2, 10)
        p.embeddedCreationSource = "stream:creation_time"
        p.originEncoder = "HandBrake 1.7.3 2023121300"
        let rec = VideoRecord()
        rec.apply(p)
        #expect(rec.embeddedCreationDate == utc(2019, 3, 2, 10))
        #expect(rec.originEncoder == "HandBrake 1.7.3 2023121300")
        let lifted = ProbeResult(scanDerivedFrom: rec)
        #expect(lifted.embeddedCreationDate == p.embeddedCreationDate)
        #expect(lifted.embeddedCreationSource == p.embeddedCreationSource)
        #expect(lifted.originEncoder == p.originEncoder)
        // Full outcome round trip (the scan-merge adoption path).
        var o = ProbeOutcome(); o.probe = p
        let r2 = VideoRecord(); r2.apply(o)
        #expect(ProbeOutcome(scanDerivedFrom: r2).probe.embeddedCreationDate == p.embeddedCreationDate)
    }
}

// MARK: - Probe cache (SQLite, isolated temp path)

@Suite("Probe cache — embedded date columns")
struct MetadataCacheEmbeddedDateTests {

    private func tempCachePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_mc_embedded-\(UUID().uuidString).sqlite").path
    }

    /// THE regression the columns prevent: a cache hit returns before
    /// ffprobe runs, so without them a rescan of an unchanged file would
    /// hand back nil and erase what the scan / backfill captured.
    @Test func embeddedDateRoundTripsThroughTheCache() {
        let cache = MetadataCache(path: tempCachePath())
        var o = ProbeOutcome()
        o.fullPath = "/Volumes/V/RickGuitar2025.mov"; o.filename = "RickGuitar2025.mov"; o.sizeBytes = 4_096
        o.probe.streamTypeRaw = StreamType.videoAndAudio.rawValue
        o.probe.embeddedCreationDate = utc(2025, 6, 15, 22, 47, 45)
        o.probe.embeddedCreationSource = "format:creation_time"
        o.probe.originMake = "Apple"; o.probe.originModel = "iPhone 15 Pro"
        let mod = Date(timeIntervalSince1970: 1_700_000_000)
        cache.store(outcome: o, fileSize: o.sizeBytes, modDate: mod)
        let back = cache.lookup(path: o.fullPath, fileSize: o.sizeBytes, modDate: mod)
        #expect(back?.probe.embeddedCreationDate == utc(2025, 6, 15, 22, 47, 45))
        #expect(back?.probe.embeddedCreationSource == "format:creation_time")
        #expect(back?.probe.originMake == "Apple"); #expect(back?.probe.originModel == "iPhone 15 Pro")
        #expect(back?.probe.originEncoder == nil, "NULL column → nil, not empty string")
        // allRecordsWithPrefix (offline-volume backfill) decodes them too.
        let recs = cache.allRecordsWithPrefix("/Volumes/V")
        #expect(recs.first?.embeddedCreationDate == utc(2025, 6, 15, 22, 47, 45))
        #expect(recs.first?.originModel == "iPhone 15 Pro")
    }

    @Test("write-through update lands on an existing row; reopening migrates in place")
    func writeThroughAndMigration() {
        let path = tempCachePath()
        let cache = MetadataCache(path: path)
        var o = ProbeOutcome(); o.fullPath = "/Volumes/V/x.mov"; o.sizeBytes = 10
        let mod = Date(timeIntervalSince1970: 1)
        cache.store(outcome: o, fileSize: 10, modDate: mod)
        #expect(cache.lookup(path: o.fullPath, fileSize: 10, modDate: mod)?.probe.embeddedCreationDate == nil)
        cache.updateEmbeddedDate(path: o.fullPath, date: utc(2001, 9, 9), source: "stream:creation_time",
                                 make: nil, model: nil, encoder: "HandBrake 1.5")
        let reopened = MetadataCache(path: path)   // "column already present" branch is a no-op
        let back = reopened.lookup(path: o.fullPath, fileSize: 10, modDate: mod)
        #expect(back?.probe.embeddedCreationDate == utc(2001, 9, 9))
        #expect(back?.probe.originEncoder == "HandBrake 1.5")
        #expect(back?.probe.originMake == nil)
    }
}
