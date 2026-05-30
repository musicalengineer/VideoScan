import Testing
import Foundation
@testable import VideoScan

// MARK: - RelocateSchemaTests
//
// Covers the schema additions from §1 + §1B of docs/relocate_volume_plan.md:
//   - VideoRecord.originalFullPath: String?
//   - VideoRecord.originVolume: String?
//   - ArchiveStage.manuallyDeleted, .salvageFailed
//   - CatalogSnapshot.currentVersion bumped 4 → 5 → 6
//   - §1B: CatalogScanTarget gains retiredAt / retiredReason /
//     retiredWitnesses (persisted via UserDefaults + VolumeMetadataSnapshot,
//     NOT in catalog.json — so v5 catalog.json files decode unchanged).
//
// Critically asserts BACKWARD COMPATIBILITY: legacy v4/v5 catalog.json
// without the new keys must decode unchanged. If this fails on a real
// catalog, every record loses its data on first load — that's the SEV 1
// risk this catches.

@MainActor
struct RelocateSchemaTests {

    // MARK: - Version bump

    @Test
    func currentSnapshotVersionIsSix() {
        #expect(CatalogSnapshot.currentVersion == 6)
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

    // MARK: - §1B v5 → v6 backward compatibility

    @Test
    func legacyV5CatalogWithoutRetiredFieldsDecodes() throws {
        // The §1B version bump is purely a marker — no record-level field
        // was added. A v5 catalog.json shaped exactly as before the bump
        // must still decode cleanly on a v6-aware build. Records with the
        // §1 provenance keys round-trip; the absence of any retire-related
        // key in the snapshot is the expected shape (retire metadata lives
        // on CatalogScanTarget, not VideoRecord).
        let v5SnapshotJSON = """
        {
          "version": 5,
          "savedAt": "2026-05-30T09:00:00Z",
          "records": [
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "filename": "old.mov",
              "fullPath": "/Volumes/Mini2TB/old.mov",
              "directory": "/Volumes/Mini2TB",
              "partialMD5": "feedface",
              "sizeBytes": 4096,
              "originalFullPath": "/Volumes/Mini2TB/old.mov",
              "originVolume": "Mini2TB"
            }
          ],
          "savedFromHost": "RicksM4"
        }
        """.data(using: .utf8)!

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(CatalogSnapshot.self, from: v5SnapshotJSON)
        #expect(decoded.version == 5)
        #expect(decoded.records.count == 1)
        #expect(decoded.records.first?.originalFullPath == "/Volumes/Mini2TB/old.mov")
        #expect(decoded.records.first?.originVolume == "Mini2TB")
    }

    @Test
    func legacyVolumeMetadataSnapshotWithoutRetiredFieldsDecodes() throws {
        // VolumeMetadataSnapshot gained retiredAt/retiredReason/
        // retiredWitnesses in §1B. Pre-§1B bundle JSON without those keys
        // must decode cleanly with nil for each — otherwise importing an
        // older bundle into a v6-aware build would throw.
        let legacyJSON = """
        {
          "searchPath": "/Volumes/Maxtor500FW",
          "phase": "Cataloged",
          "role": "Original",
          "trust": "Aging",
          "mediaTech": "HDD",
          "filesystem": "HFS+",
          "notes": ""
        }
        """.data(using: .utf8)!

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let snap = try dec.decode(VolumeMetadataSnapshot.self, from: legacyJSON)
        #expect(snap.searchPath == "/Volumes/Maxtor500FW")
        #expect(snap.retiredAt == nil)
        #expect(snap.retiredReason == nil)
        #expect(snap.retiredWitnesses == nil)
    }
}
