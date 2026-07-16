// TrimProvenanceTests.swift
// Catalog-integration dimension for Trim Master (chunk 3):
//
//   - SCHEMA: trimInSeconds/trimOutSeconds are ADDITIVE optionals —
//     legacy catalog JSON (no trim keys) decodes to nil and re-encodes
//     with ZERO new bytes (the encodeIfPresent discipline; same byte-
//     oracle idea as CatalogStoreAsyncSaveTests' legacy golden, which
//     also re-verifies this at the full-record scale since its golden
//     predates these fields).
//   - ROUND TRIP: populated trim fields survive DTO encode → class
//     decode → snapshotClone.
//   - INTEGRATION: a full real trim job stamps derivedFrom + the range
//     on the NEW record, journey notes on BOTH records, and leaves the
//     original record's disposition untouched.
//   - ISOLATION: a full trim job writes nothing to UserDefaults (the
//     documented settings-pollution class) and only ever touches its
//     temp fixture directory.

import Testing
import Foundation
@testable import VideoScan

@Suite(.serialized) @MainActor
struct TrimProvenanceTests {

    /// Deterministic encoder — same rationale as CatalogStoreAsyncSaveTests.
    private static func goldenEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// A minimal legacy-shaped record: captured from the pre-trim-fields
    /// schema (no trimInSeconds/trimOutSeconds keys anywhere).
    private static let legacyJSON = #"""
        {"id":"11111111-2222-3333-4444-555555555555","filename":"tape7.mkv",
         "ext":"mkv","streamTypeRaw":"Video+Audio","sizeBytes":107374182400,
         "durationSeconds":7205.5,"videoCodec":"ffv1","fullPath":"/Volumes/T/tape7.mkv",
         "directory":"/Volumes/T","derivedFrom":"99999999-9999-9999-9999-999999999999"}
        """#

    // MARK: - Schema: additive-only, legacy round trip

    @Test func legacyJSONDecodesWithNilTrimFields() throws {
        let record = try JSONDecoder().decode(VideoRecord.self,
                                              from: Data(Self.legacyJSON.utf8))
        #expect(record.trimInSeconds == nil)
        #expect(record.trimOutSeconds == nil)
        // Sanity: the rest of the record decoded normally.
        #expect(record.filename == "tape7.mkv")
        #expect(record.derivedFrom != nil)
    }

    @Test func legacyRecordReencodesWithoutTrimKeys() throws {
        let record = try JSONDecoder().decode(VideoRecord.self,
                                              from: Data(Self.legacyJSON.utf8))
        let encoded = String(decoding: try Self.goldenEncoder()
            .encode(VideoRecordDTO(record)), as: UTF8.self)
        #expect(!encoded.contains("trimInSeconds"),
                "trim keys leaked into a legacy record's JSON — additive-only contract broken")
        #expect(!encoded.contains("trimOutSeconds"))

        // Byte-stability fixed point: decode(encode(x)) re-encodes to the
        // SAME bytes — proves the new decode lines are lossless no-ops
        // for legacy data.
        let second = try JSONDecoder().decode(VideoRecord.self, from: Data(encoded.utf8))
        let reencoded = String(decoding: try Self.goldenEncoder()
            .encode(VideoRecordDTO(second)), as: UTF8.self)
        #expect(reencoded == encoded,
                "legacy record no longer round-trips byte-identical through the trim-fields schema")
    }

    // MARK: - Schema: populated round trip + clone parity

    @Test func populatedTrimFieldsRoundTripThroughDTOAndClone() throws {
        let record = try JSONDecoder().decode(VideoRecord.self,
                                              from: Data(Self.legacyJSON.utf8))
        record.trimInSeconds = 2.5
        record.trimOutSeconds = 95.25

        // DTO encode → class decode.
        let encoded = try Self.goldenEncoder().encode(VideoRecordDTO(record))
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"trimInSeconds\":2.5"))
        let decoded = try JSONDecoder().decode(VideoRecord.self, from: encoded)
        #expect(decoded.trimInSeconds == 2.5)
        #expect(decoded.trimOutSeconds == 95.25)

        // snapshotClone carries the fields (the off-main save path).
        let clone = record.snapshotClone()
        #expect(clone.trimInSeconds == 2.5)
        #expect(clone.trimOutSeconds == 95.25)
    }

    // MARK: - Integration: full real job stamps provenance

    @Test("a real trim job catalogs the output with derivedFrom + range, journey notes on both, source disposition untouched",
          .timeLimit(.minutes(2)))
    func fullJobStampsProvenance() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("trim_prov")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_trim_prov.mkv",
            duration: 6.0, size: "320x240", rate: "25",
            videoCodec: "ffv1", extraVideoArgs: ["-g", "1"],
            audioCodec: "pcm_s16le")

        let model = VideoScanModel()
        let source = makeTrimSourceRecord(path: src, durationSeconds: 6.0, videoCodec: "ffv1")
        source.mediaDisposition = .important   // pre-existing user decision
        source.starRating = 3
        model.records = [source]

        let job = TrimJob(record: source,
                          range: TrimRange(inSeconds: 1.0, outSeconds: 4.0),
                          model: model)
        job.start()
        await job.task?.value
        guard case .finished = job.state else {
            Issue.record("trim did not finish: \(job.state)")
            return
        }

        // New record: provenance fully stamped.
        #expect(model.records.count == 2)
        let derived = try #require(model.records.first { $0.id != source.id })
        #expect(derived.derivedFrom == source.id)
        #expect(derived.trimInSeconds == 1.0)
        #expect(derived.trimOutSeconds == 4.0)
        #expect(derived.notes.contains("Trimmed from test_trim_prov.mkv"))
        #expect(derived.notes.contains("no re-encode"))
        #expect(derived.videoCodec == "ffv1", "probe of the published file sees the same codec")

        // Source record: journey note added, EVERYTHING else untouched —
        // Rick decides separately what happens to the raw capture.
        #expect(source.notes.contains("Created trimmed master"))
        #expect(source.mediaDisposition == .important, "source disposition must not change")
        #expect(source.starRating == 3)
        #expect(source.trimInSeconds == nil, "range lives on the DERIVED record only")
        #expect(source.purgedAt == nil)
        #expect(source.lifecycleStage == .cataloged)
    }

    // MARK: - Isolation: no UserDefaults writes, temp-dir only

    @Test("a full trim job writes nothing to UserDefaults", .timeLimit(.minutes(2)))
    func trimJobWritesNoDefaults() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("trim_isolation")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_trim_iso.mkv",
            duration: 4.0, size: "320x240", rate: "25",
            videoCodec: "ffv1", extraVideoArgs: ["-g", "1"],
            audioCodec: "pcm_s16le")

        let keysBefore = Set(UserDefaults.standard.dictionaryRepresentation().keys)

        let model = VideoScanModel()
        let source = makeTrimSourceRecord(path: src, durationSeconds: 4.0, videoCodec: "ffv1")
        model.records = [source]
        let job = TrimJob(record: source,
                          range: TrimRange(inSeconds: 0.5, outSeconds: 3.0),
                          model: model)
        job.start()
        await job.task?.value
        guard case .finished = job.state else {
            Issue.record("trim did not finish: \(job.state)")
            return
        }

        let keysAfter = Set(UserDefaults.standard.dictionaryRepresentation().keys)
        let added = keysAfter.subtracting(keysBefore)
        #expect(added.isEmpty,
                "trim job polluted UserDefaults with: \(added.sorted())")
    }
}
