import Testing
import Foundation
@testable import VideoScan

// Regression: POI deletion must NEVER `rm -rf` user data per project
// policy (MANAGER.md). Deletes route through POIStorage.trashPOIFolder
// which moves the folder into ~/dev/VideoScan/.trash/POI-<name>-<UTC>/.
// The user can recover by moving the folder back into storeDir.
//
// Triggering scenario: 2026-05-15 — Rick's broken bundle import on the
// M5 left him with 3 dud POIs and no in-app way to clean them out
// without hand-editing Application Support.
//
// These tests use POIStorage's storeOverride/trashOverride parameters
// to redirect both ends into a per-test sandbox so we never touch the
// real Application Support / .trash directories on the dev machine.
struct POIDeletionTests {

    // MARK: - Sandbox helpers

    /// A pair of throw-away temp dirs standing in for storeDir and trashDir.
    /// Both are unique per test invocation. The sandbox is recursively
    /// deleted on `cleanup()`.
    private struct Sandbox {
        let store: URL
        let trash: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: store)
            try? FileManager.default.removeItem(at: trash)
        }

        /// Create a fake POI folder with profile.json + one photo stub.
        @discardableResult
        func makePOI(_ name: String) throws -> URL {
            let folder = store.appendingPathComponent(POIStorage.sanitize(name),
                                                      isDirectory: true)
            try FileManager.default.createDirectory(at: folder,
                                                    withIntermediateDirectories: true)
            let profile = POIProfile(name: name,
                                     referencePath: folder.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(profile)
                .write(to: folder.appendingPathComponent("profile.json"))
            // Stub photo so the folder isn't suspiciously empty.
            try Data([0xFF, 0xD8, 0xFF, 0xE0])  // JPEG magic
                .write(to: folder.appendingPathComponent("photo_0.jpg"))
            return folder
        }
    }

    private func makeSandbox() throws -> Sandbox {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("poi-deletion-\(UUID().uuidString)",
                                    isDirectory: true)
        let store = base.appendingPathComponent("store", isDirectory: true)
        let trash = base.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        // Note: trash dir is created lazily by trashPOIFolder. Don't
        // pre-create it here — that path mirrors production behavior.
        return Sandbox(store: store, trash: trash)
    }

    // MARK: - Tests

    @Test func deletePOI_movesToTrash() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }

        let src = try sandbox.makePOI("Donna")
        #expect(FileManager.default.fileExists(atPath: src.path),
                "Pre-condition: fake POI should exist")

        let dest = POIStorage.trashPOIFolder(
            named: "Donna",
            storeOverride: sandbox.store,
            trashOverride: sandbox.trash
        )

        // 1. Source is gone.
        #expect(!FileManager.default.fileExists(atPath: src.path),
                "Original POI folder should no longer exist under storeDir")

        // 2. Trash now holds a timestamped folder for this POI.
        #expect(dest != nil, "trashPOIFolder should return the destination URL")
        if let dest {
            #expect(FileManager.default.fileExists(atPath: dest.path),
                    "Trashed POI folder should exist at the returned URL")
            #expect(dest.path.contains(sandbox.trash.path),
                    "Trashed folder should live under the trashOverride root")
            #expect(dest.lastPathComponent.hasPrefix("POI-donna-"),
                    "Trashed folder name should follow POI-<sanitized>-<stamp> format")
            // Verify contents survived the move.
            let profile = dest.appendingPathComponent("profile.json")
            #expect(FileManager.default.fileExists(atPath: profile.path),
                    "profile.json should ride along to .trash/")
        }
    }

    @Test func deletePOI_doesNotTouchOtherPOIs() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }

        let donna = try sandbox.makePOI("Donna")
        let beth = try sandbox.makePOI("Beth")

        _ = POIStorage.trashPOIFolder(
            named: "Donna",
            storeOverride: sandbox.store,
            trashOverride: sandbox.trash
        )

        #expect(!FileManager.default.fileExists(atPath: donna.path),
                "Donna should be gone from storeDir")
        #expect(FileManager.default.fileExists(atPath: beth.path),
                "Beth should be untouched")
        // Beth's profile.json should still decode.
        let bethProfile = beth.appendingPathComponent("profile.json")
        let data = try Data(contentsOf: bethProfile)
        let decoded = try JSONDecoder().decode(POIProfile.self, from: data)
        #expect(decoded.name == "Beth",
                "Beth's profile.json should be intact and decodable")
    }

    @Test func deletePOI_idempotentOnMissing() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }

        // Don't create the POI — trashPOIFolder should return nil without
        // throwing or creating a trash entry.
        let result = POIStorage.trashPOIFolder(
            named: "Ghost",
            storeOverride: sandbox.store,
            trashOverride: sandbox.trash
        )

        #expect(result == nil,
                "Deleting a non-existent POI should return nil")
        // Trash directory should NOT have been created — there was nothing
        // to move into it.
        let trashContents = (try? FileManager.default.contentsOfDirectory(
            at: sandbox.trash, includingPropertiesForKeys: nil
        )) ?? []
        #expect(trashContents.isEmpty,
                "No phantom POI folder should appear under .trash/")
    }

    @Test func deletePOI_sanitizesNameForTrashFolder() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }

        // Spaces and mixed case — trash entry should land at lowercased
        // / underscore-joined form, matching the on-disk POI folder.
        _ = try sandbox.makePOI("Aunt Beth")
        let dest = POIStorage.trashPOIFolder(
            named: "Aunt Beth",
            storeOverride: sandbox.store,
            trashOverride: sandbox.trash
        )

        #expect(dest != nil)
        if let dest {
            #expect(dest.lastPathComponent.hasPrefix("POI-aunt_beth-"),
                    "Trash folder name should use POIStorage.sanitize() form")
        }
    }
}
