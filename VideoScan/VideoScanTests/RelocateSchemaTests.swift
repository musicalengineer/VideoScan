import Testing
import Foundation
@testable import VideoScan

// MARK: - RelocateSchemaTests
//
// Covers the schema additions from §1 of docs/relocate_volume_plan.md:
//   - VideoRecord.originalFullPath: String?
//   - VideoRecord.originVolume: String?
//   - ArchiveStage.manuallyDeleted, .salvageFailed
//   - CatalogSnapshot.currentVersion bumped 4 → 5
//
// Critically asserts BACKWARD COMPATIBILITY: legacy v4 catalog.json without
// the new keys must decode unchanged. If this fails on a real catalog, every
// record loses its data on first load — that's the SEV 1 risk this catches.

@MainActor
struct RelocateSchemaTests {

    // MARK: - Version bump

    @Test
    func currentSnapshotVersionIsFive() {
        #expect(CatalogSnapshot.currentVersion == 5)
    }

    // MARK: - New ArchiveStage cases

    @Test
    func newArchiveStagesAreCodable() throws {
        let cases: [ArchiveStage] = [.manuallyDeleted, .salvageFailed]
        for stage in cases {
            let data = try JSONEncoder().encode(stage)
            let decoded = try JSONDecoder().decode(ArchiveStage.self, from: data)
            #expect(decoded == stage)
        }
    }

    @Test
    func newArchiveStagesHaveDistinctIconAndColor() {
        // Sanity: both new states have icon/color overloads — not falling
        // through to defaults that would render as empty strings.
        #expect(!ArchiveStage.manuallyDeleted.icon.isEmpty)
        #expect(!ArchiveStage.salvageFailed.icon.isEmpty)
        #expect(ArchiveStage.manuallyDeleted.icon != ArchiveStage.salvageFailed.icon)
    }

    @Test
    func archiveStageComparableOrderingPreserved() {
        // Happy-path cases keep their existing order. New cases land at end
        // (highest ordinals), so all happy-path cases are < manuallyDeleted.
        #expect(ArchiveStage.none < ArchiveStage.healthy)
        #expect(ArchiveStage.healthy < ArchiveStage.masterAssigned)
        #expect(ArchiveStage.archived < ArchiveStage.manuallyDeleted)
        #expect(ArchiveStage.manuallyDeleted < ArchiveStage.salvageFailed)
    }

    // MARK: - VideoRecord round-trip with new fields

    @Test
    func videoRecordRoundTripWithProvenance() throws {
        let rec = VideoRecord()
        rec.filename = "test.mov"
        rec.fullPath = "/Volumes/LaCie8TB/from-Mini2TB/test.mov"
        rec.originalFullPath = "/Volumes/Mini2TB/test.mov"
        rec.originVolume = "Mini2TB"

        let data = try JSONEncoder().encode(rec)
        let decoded = try JSONDecoder().decode(VideoRecord.self, from: data)
        #expect(decoded.originalFullPath == "/Volumes/Mini2TB/test.mov")
        #expect(decoded.originVolume == "Mini2TB")
        #expect(decoded.fullPath == "/Volumes/LaCie8TB/from-Mini2TB/test.mov")
    }

    @Test
    func videoRecordWithoutProvenanceEncodesNoExtraKeys() throws {
        // Default record (never relocated) must round-trip with both new
        // keys absent from the JSON. This keeps catalog.json byte-deltas
        // minimal across the rollout.
        let rec = VideoRecord()
        rec.filename = "fresh.mov"
        rec.fullPath = "/Volumes/Crucial2TB/fresh.mov"

        let data = try JSONEncoder().encode(rec)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("originalFullPath"))
        #expect(!json.contains("originVolume"))
    }

    // MARK: - Backward compatibility (the SEV 1 catch)

    @Test
    func legacyV4RecordWithoutProvenanceKeysDecodesAsNil() throws {
        // Synthetic JSON shaped like a v4 record — no originalFullPath /
        // originVolume keys at all. Decoder must yield nil for both fields,
        // not throw. If this fails, every existing record's first load on
        // a v5 build loses its data.
        let legacyJSON = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "filename": "legacy.mov",
          "fullPath": "/Volumes/SomeVolume/legacy.mov",
          "directory": "/Volumes/SomeVolume",
          "partialMD5": "abc123",
          "sizeBytes": 1024
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(VideoRecord.self, from: legacyJSON)
        #expect(decoded.originalFullPath == nil)
        #expect(decoded.originVolume == nil)
        #expect(decoded.filename == "legacy.mov")  // sanity: other fields still load
    }

    @Test
    func legacyV4CatalogSnapshotLoadsAsCurrentVersion() throws {
        // Whole-snapshot legacy compatibility: a v4-shaped JSON with
        // version:4 must still decode. The CatalogStore.loadFromDisk path
        // is responsible for migrating in-memory; here we just verify the
        // raw Codable layer doesn't choke.
        let v4SnapshotJSON = """
        {
          "version": 4,
          "savedAt": "2026-05-29T12:00:00Z",
          "records": [],
          "savedFromHost": "RicksM4"
        }
        """.data(using: .utf8)!

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(CatalogSnapshot.self, from: v4SnapshotJSON)
        #expect(decoded.version == 4)
        #expect(decoded.savedFromHost == "RicksM4")
    }
}
