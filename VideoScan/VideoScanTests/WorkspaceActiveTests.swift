import Testing
import Foundation
@testable import VideoScan

// MARK: - Workspace-active (triage) tests
//
// Pass A of the Triage workflow (Manager dispatch 2026-06-14):
//   - VideoRecord.workspaceActive: a per-record Bool, default false.
//   - Round-trips through Codable (additive, legacy catalogs must decode).
//   (The Show ▸ In Workspace filter that read the flag was removed
//    2026-11-17; the test that mirrored its predicate went with it.)
//
// Pass A does NOT add UI mechanism to set the flag; Pass B (Import) does.
// These tests cover the data shape only.

struct WorkspaceActiveTests {

    // MARK: - Test helpers

    private func makeRecord(name: String, workspaceActive: Bool = false) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/TestVol/\(name)"
        r.directory = "/Volumes/TestVol"
        r.partialMD5 = String(name.hash, radix: 16)
        r.sizeBytes = 1_000_000
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.workspaceActive = workspaceActive
        return r
    }

    // MARK: - 1. Codable round-trip + legacy decode

    // regression: Pass A spec — workspaceActive must round-trip cleanly when
    // set, AND a catalog.json that predates the field must decode with
    // workspaceActive == false (additive Codable contract).
    @Test func workspaceActive_codableRoundTrip() throws {
        // --- A. Fresh encode/decode with the flag set ---
        let original = makeRecord(name: "topaz_in_progress.mov", workspaceActive: true)
        let encoder = JSONEncoder()
        let data = try encoder.encode(VideoRecordDTO(original))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(VideoRecord.self, from: data)
        #expect(decoded.workspaceActive == true,
                "workspaceActive=true must survive a JSON round-trip")
        #expect(decoded.filename == original.filename)

        // --- B. Legacy decode — hand-rolled JSON without the key ---
        // Hand-rolled rather than encoding a workspaceActive=false record
        // (the encoder is delta-minimal and omits false), to guarantee the
        // key is genuinely absent on the wire.
        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "filename": "legacy_clip.mov",
          "fullPath": "/Volumes/Legacy/legacy_clip.mov",
          "streamTypeRaw": "Video+Audio",
          "sizeBytes": 1234567,
          "durationSeconds": 12.5
        }
        """
        let legacyData = Data(legacyJSON.utf8)
        let legacyRecord = try decoder.decode(VideoRecord.self, from: legacyData)
        #expect(legacyRecord.workspaceActive == false,
                "Legacy catalog without workspaceActive key must decode to false")
    }

    // MARK: - 2. Default + clone propagation

    // regression: Pass A spec — newly constructed VideoRecord must have
    // workspaceActive == false (matches Bool default), and snapshotClone()
    // must propagate the flag (additive-field clone-parity contract).
    @Test func workspaceActive_defaultAndClone() {
        let fresh = VideoRecord()
        #expect(fresh.workspaceActive == false,
                "Freshly constructed VideoRecord must have workspaceActive == false")

        let active = makeRecord(name: "in_workspace.mov", workspaceActive: true)
        let clone = active.snapshotClone()
        #expect(clone.workspaceActive == true,
                "snapshotClone() must propagate workspaceActive — adding a stored field to VideoRecord requires updating all four Codable touchpoints AND the clone")
    }
}
