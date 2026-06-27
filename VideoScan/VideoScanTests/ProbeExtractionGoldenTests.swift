// ProbeExtractionGoldenTests.swift
//
// GOLDEN BEHAVIOR PIN for the upcoming `Sendable ProbeResult` restructure
// (refactor/videorecord-sendable). Steps 1-3 will move WHERE the VideoRecord
// is constructed: the off-actor probe path will build a Sendable value struct
// (ProbeResult) and the VideoRecord will be materialized later on the main
// actor. This test freezes the CURRENT output of the metadata-extraction
// stage — `ScanEngine.extractMetadata(probe:into:)` — field by field, so that
// any of those steps can be proven behavior-preserving: the same ffprobe JSON
// must still produce a VideoRecord with byte-identical field values, and no
// field may start or stop being populated.
//
// regression: ProbeResult seam (step 0) — pin probe-extraction output before
// the VideoRecord-construction point moves across the actor boundary.
//
// Deterministic by construction: the input is a hand-authored ffprobe JSON
// fixture decoded into `FFProbeOutput` (exactly how ScanEngine.runFFProbe
// feeds the live path — see FFProbeTests.decodesStreamFields for the same
// decode seam). No ffmpeg/ffprobe subprocess runs, so the golden values are
// stable on every machine and CI.
//
// Style: Swift Testing (`@Test` / `#expect`) to match the dominant suite.
// For Rick (C++ test reader): `#expect(x == y)` ≈ GoogleTest `EXPECT_EQ` — a
// soft check that records a failure but keeps going, so ALL drifted fields are
// reported in one run, not just the first. The Mirror sweep at the end is the
// completeness guard: it is the same reflection technique ModelSchemaTests
// uses for snapshotClone() parity, repurposed here to assert that extraction
// touches EXACTLY the expected set of fields and leaves every other field at
// its fresh-construction default.

import Testing
import Foundation
@testable import VideoScan

@Suite("ScanEngine.extractMetadata — golden field pinning")
struct ProbeExtractionGoldenTests {

    // MARK: - Fixture

    /// A realistic ffprobe JSON object for an Avid-style MXF clip carrying a
    /// full video stream, a full audio stream, and the format-level tags the
    /// recovery pipeline depends on (timecode, tape/reel name, MaterialPackage
    /// UMID). Chosen to drive EVERY branch of extractMetadata that populates a
    /// field: format name, duration, total bitrate, the three format tags, the
    /// first-video-stream block, the first-audio-stream block, and the
    /// video+audio stream-type classification.
    private static let mxfProbeJSON = """
    {
      "streams": [
        {
          "codec_type": "video",
          "codec_name": "mpeg2video",
          "width": 1920,
          "height": 1080,
          "r_frame_rate": "30000/1001",
          "avg_frame_rate": "30000/1001",
          "bit_rate": "50000000",
          "color_space": "bt709",
          "bits_per_raw_sample": "8",
          "field_order": "tt",
          "tags": {}
        },
        {
          "codec_type": "audio",
          "codec_name": "pcm_s24le",
          "channels": 2,
          "sample_rate": "48000",
          "tags": {}
        }
      ],
      "format": {
        "format_name": "mxf",
        "format_long_name": "MXF (Material eXchange Format)",
        "duration": "120.500000",
        "bit_rate": "50384000",
        "tags": {
          "timecode": "01:00:00:00",
          "tape_name": "REEL_042",
          "material_package_umid": "0x060A2B340101010501010D4313000000"
        }
      }
    }
    """

    private static func decodeFixture() throws -> FFProbeOutput {
        try JSONDecoder().decode(FFProbeOutput.self, from: Data(mxfProbeJSON.utf8))
    }

    // MARK: - Golden values
    //
    // The EXACT field values extractMetadata must produce from the fixture
    // above. Keyed by the VideoRecord stored-property label so the Mirror
    // completeness sweep can cross-check them. Values are the post-formatting
    // results (Formatting.duration / Formatting.fraction / "kbps" / "Hz"),
    // i.e. exactly what reaches the catalog and the persisted JSON.
    private static let golden: [String: String] = [
        "container":           "MXF (Material eXchange Format)",
        "durationSeconds":     "120.5",          // Double(120.5) String(describing:)
        "duration":            "00:02:00",       // Formatting.duration(120.5)
        "totalBitrate":        "50384 kbps",      // 50384000 / 1000
        "timecode":            "01:00:00:00",
        "tapeName":            "REEL_042",
        "materialPackageUMID": "0x060A2B340101010501010D4313000000",
        "videoCodec":          "mpeg2video",
        "resolution":          "1920x1080",
        "frameRate":           "29.97",          // Formatting.fraction("30000/1001")
        "videoBitrate":        "50000 kbps",      // 50000000 / 1000
        "colorSpace":          "bt709",
        "bitDepth":            "8",
        "scanType":            "tt",
        "audioCodec":          "pcm_s24le",
        "audioChannels":       "2",
        "audioSampleRate":     "48000 Hz",
        "streamTypeRaw":       "Video+Audio",
        "isPlayable":          "Yes",
    ]

    // MARK: - 1. Explicit field-by-field pin
    //
    // Names each populated field so a drift in any one prints that field's
    // identity. Mirrors the readability style of ModelSchemaTests' round-trip.

    @Test func extractMetadataPinsEveryPopulatedField() throws {
        let probe = try Self.decodeFixture()
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)

        // format-level
        #expect(rec.container == "MXF (Material eXchange Format)")
        #expect(rec.durationSeconds == 120.5)
        #expect(rec.duration == "00:02:00")
        #expect(rec.totalBitrate == "50384 kbps")
        #expect(rec.timecode == "01:00:00:00")
        #expect(rec.tapeName == "REEL_042")
        #expect(rec.materialPackageUMID == "0x060A2B340101010501010D4313000000")

        // first video stream
        #expect(rec.videoCodec == "mpeg2video")
        #expect(rec.resolution == "1920x1080")
        #expect(rec.frameRate == "29.97")
        #expect(rec.videoBitrate == "50000 kbps")
        #expect(rec.colorSpace == "bt709")
        #expect(rec.bitDepth == "8")
        #expect(rec.scanType == "tt")

        // first audio stream
        #expect(rec.audioCodec == "pcm_s24le")
        #expect(rec.audioChannels == "2")
        #expect(rec.audioSampleRate == "48000 Hz")

        // classification
        #expect(rec.streamTypeRaw == StreamType.videoAndAudio.rawValue)
        #expect(rec.isPlayable == "Yes")
    }

    // MARK: - 2. Mirror completeness sweep
    //
    // The strong guard the seam restructure needs: reflect over EVERY stored
    // property of the extracted record and assert
    //   (a) each field listed in `golden` holds its pinned value, AND
    //   (b) every OTHER field is byte-identical to a fresh VideoRecord() —
    //       i.e. extractMetadata populated EXACTLY the golden set and nothing
    //       else.
    // This fails loudly if Steps 1-3 cause a field to stop being populated
    // (it reverts to its default → (a) fails) OR start being populated (it
    // diverges from the fresh baseline → (b) fails). `id` is excluded because
    // it is a fresh random UUID on each construction.

    @Test func extractMetadataTouchesExactlyTheGoldenFieldSet() throws {
        let probe = try Self.decodeFixture()
        let extracted = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: extracted)

        let baseline = VideoRecord()   // untouched defaults for the comparison

        let excluded: Set<String> = ["id"]   // random per-instance UUID

        var baselineChildren: [String: String] = [:]
        for child in Mirror(reflecting: baseline).children {
            if let label = child.label {
                baselineChildren[label] = String(describing: child.value)
            }
        }

        var seenGoldenKeys: Set<String> = []
        var reflected = 0

        for child in Mirror(reflecting: extracted).children {
            guard let label = child.label, !excluded.contains(label) else { continue }
            reflected += 1
            let actual = String(describing: child.value)

            if let want = Self.golden[label] {
                seenGoldenKeys.insert(label)
                #expect(actual == want,
                        "extractMetadata drifted on populated field '\(label)': got=\(actual) want=\(want)")
            } else {
                let base = baselineChildren[label] ?? "<missing baseline>"
                #expect(actual == base,
                        "extractMetadata unexpectedly populated field '\(label)': got=\(actual) — fresh default is \(base). If this is intended, add it to `golden`.")
            }
        }

        // Every pinned field must have actually been visited (guards against a
        // golden key that no longer maps to a real stored property after a
        // rename — which would otherwise silently weaken the pin).
        let missing = Set(Self.golden.keys).subtracting(seenGoldenKeys)
        #expect(missing.isEmpty,
                "golden keys not found as stored properties on VideoRecord: \(missing.sorted())")

        // Guard against a broken Mirror enumeration passing vacuously (same
        // sanity check ModelSchemaTests.snapshotClone parity uses).
        #expect(reflected >= 60,
                "Expected to reflect ~60+ stored properties; only saw \(reflected) — Mirror enumeration may be broken")
    }
}
