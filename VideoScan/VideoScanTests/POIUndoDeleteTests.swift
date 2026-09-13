import Testing
import Foundation
@testable import VideoScan

// Issue follow-up to c39f630 (POI soft-delete to .trash/): Rick wants a
// one-tap undo affordance for the most recent delete. The model state
// + restore primitive are the testable surface — the SwiftUI banner is
// confirmed visually per spec.
//
// These tests exercise POIStorage.restorePOIFolder(from:uuid:storeOverride:)
// directly with a per-test sandbox (no Application Support touches), mirroring
// POIDeletionTests's pattern. Where the test name implies model-level
// behavior, the test is staged so trashPOIFolder + restorePOIFolder run
// against the same sandbox pair — this is the codepath PersonFinderModel
// drives in production (it just passes nil overrides to use real paths).
//
// 2026-09-12: folders are keyed by uuid; restore lands at `storeDir/<UUID>/`.
struct POIUndoDeleteTests {

    // MARK: - Sandbox helpers (mirror POIDeletionTests)

    private struct Sandbox {
        let store: URL
        let trash: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: store)
            try? FileManager.default.removeItem(at: trash)
        }

        @discardableResult
        func makePOI(_ name: String) throws -> POIProfile {
            let profile = POIProfile(name: name, referencePath: "")
            let folder = folder(of: profile)
            try FileManager.default.createDirectory(at: folder,
                                                    withIntermediateDirectories: true)
            var stored = profile
            stored.referencePath = folder.path
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(stored)
                .write(to: folder.appendingPathComponent("profile.json"))
            try Data([0xFF, 0xD8, 0xFF, 0xE0])  // JPEG magic — looks like a real photo
                .write(to: folder.appendingPathComponent("photo_0.jpg"))
            return stored
        }

        func folder(of profile: POIProfile) -> URL {
            store.appendingPathComponent(POIStorage.folderName(for: profile.uuid), isDirectory: true)
        }

        func trash(_ profile: POIProfile) -> URL? {
            POIStorage.trashPOIFolder(uuid: profile.uuid, displayName: profile.displayName,
                                      storeOverride: store, trashOverride: trash)
        }
    }

    private func makeSandbox() throws -> Sandbox {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("poi-undo-\(UUID().uuidString)",
                                    isDirectory: true)
        let store = base.appendingPathComponent("store", isDirectory: true)
        let trash = base.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        return Sandbox(store: store, trash: trash)
    }

    // MARK: - Tests

    @Test func undo_restoresMostRecentDelete() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }

        let donna = try sandbox.makePOI("Donna")
        let src = sandbox.folder(of: donna)
        let trashed = sandbox.trash(donna)
        #expect(trashed != nil, "Pre-condition: delete should succeed")
        #expect(!FileManager.default.fileExists(atPath: src.path),
                "Pre-condition: source should be gone after delete")

        guard let trashURL = trashed else { return }
        let result = POIStorage.restorePOIFolder(
            from: trashURL,
            uuid: donna.uuid,
            storeOverride: sandbox.store
        )

        // Restored to the original uuid location.
        if case let .restored(dest) = result {
            #expect(dest.path == src.path,
                    "Restored folder should land at the original uuid path")
            #expect(FileManager.default.fileExists(atPath: dest.path),
                    "Restored folder should exist on disk")
            // profile.json + the stub photo should ride along.
            #expect(FileManager.default.fileExists(
                atPath: dest.appendingPathComponent("profile.json").path
            ), "profile.json should survive the round-trip")
            #expect(FileManager.default.fileExists(
                atPath: dest.appendingPathComponent("photo_0.jpg").path
            ), "Reference photo should survive the round-trip")
        } else {
            Issue.record("Expected .restored, got \(result)")
        }

        // Trash entry should be gone — the folder MOVED, not copied.
        #expect(!FileManager.default.fileExists(atPath: trashURL.path),
                "Trash entry should be empty after successful restore")
    }

    @Test @MainActor
    func undo_isNoOpWhenNothingDeleted() async throws {
        // PersonFinderModel.undoLastDelete is the user-facing API; with
        // no pending delete it should return false and not crash. We
        // don't drive the model's production paths here (it would touch
        // Application Support) — just verify the guard path.
        let model = PersonFinderModel()
        #expect(model.lastDeletedPOI == nil,
                "Pre-condition: no pending undo")

        let ok = await model.undoLastDelete()
        #expect(ok == false, "Undo with no pending delete should return false")
        #expect(model.lastDeletedPOI == nil,
                "State should remain clear after no-op undo")
        #expect(model.lastUndoError == nil,
                "No error should be set for a clean no-op")
    }

    @Test func undo_secondDelete_supersedesPrevious() throws {
        // Spec: only one undo target at a time. After deleting A then B,
        // undo restores B. A's trash entry still exists on disk (manually
        // recoverable), but is no longer one-tap restorable.
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }

        let alpha = try sandbox.makePOI("Alpha")
        let beta = try sandbox.makePOI("Beta")

        let trashedA = sandbox.trash(alpha)
        let trashedB = sandbox.trash(beta)
        #expect(trashedA != nil)
        #expect(trashedB != nil)

        // Simulate the model: only B's snapshot is retained. Undo B.
        guard let bURL = trashedB else { return }
        let result = POIStorage.restorePOIFolder(
            from: bURL,
            uuid: beta.uuid,
            storeOverride: sandbox.store
        )

        if case .restored = result { /* ok */ } else {
            Issue.record("Expected .restored, got \(result)")
        }

        // Beta is back; Alpha is NOT (one-tap undo is gone for A).
        #expect(FileManager.default.fileExists(atPath: sandbox.folder(of: beta).path),
                "Beta should be restored")
        #expect(!FileManager.default.fileExists(atPath: sandbox.folder(of: alpha).path),
                "Alpha should remain trashed — superseded undo target")
        // Alpha's trash entry still exists on disk for manual recovery.
        if let aURL = trashedA {
            #expect(FileManager.default.fileExists(atPath: aURL.path),
                    "Alpha's trash entry should remain on disk for manual recovery")
        }
    }

    @Test func undo_refusesToOverwriteExistingPOI() throws {
        // Spec: if the uuid folder reappears while the banner is up (a
        // bundle import, a manual restore), undo must NOT clobber it.
        // Return .destinationExists, leave both folders alone.
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }

        let alpha = try sandbox.makePOI("Alpha")
        let trashed = sandbox.trash(alpha)
        #expect(trashed != nil)

        // Manually re-create the uuid folder with NEW content.
        let recreated = sandbox.folder(of: alpha)
        try FileManager.default.createDirectory(at: recreated,
                                                withIntermediateDirectories: true)
        let sentinel = recreated.appendingPathComponent("marker.txt")
        try "new content".write(to: sentinel, atomically: true, encoding: .utf8)

        guard let trashURL = trashed else { return }
        let result = POIStorage.restorePOIFolder(
            from: trashURL,
            uuid: alpha.uuid,
            storeOverride: sandbox.store
        )

        #expect(result == .destinationExists,
                "Undo must refuse when destination already exists")

        // Both folders untouched.
        #expect(FileManager.default.fileExists(atPath: trashURL.path),
                "Trash entry retained on conflict")
        #expect(FileManager.default.fileExists(atPath: sentinel.path),
                "Re-created folder's content must NOT be clobbered")
        let sentinelContent = try String(contentsOf: sentinel, encoding: .utf8)
        #expect(sentinelContent == "new content",
                "Re-created folder's content must be byte-identical after refused undo")
    }

    @Test func undo_restoresToTheUUIDFolderWhateverTheName() throws {
        // Mirror deletePOI_sanitizesNameForTrashFolder: "Aunt Beth" →
        // "aunt_beth" in the trash label; the restore is keyed by uuid.
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }

        let beth = try sandbox.makePOI("Aunt Beth")
        let trashed = sandbox.trash(beth)
        #expect(trashed != nil)
        if let dest = trashed {
            #expect(dest.lastPathComponent.hasPrefix("POI-aunt_beth-"),
                    "Pre-condition: trash folder uses sanitized name")
        }

        guard let trashURL = trashed else { return }
        let result = POIStorage.restorePOIFolder(
            from: trashURL,
            uuid: beth.uuid,
            storeOverride: sandbox.store
        )

        if case let .restored(dest) = result {
            #expect(dest.lastPathComponent == beth.id,
                    "Restored folder must be the uuid folder")
            #expect(FileManager.default.fileExists(atPath: dest.path),
                    "Restored folder should exist")
            #expect(FileManager.default.fileExists(
                atPath: dest.appendingPathComponent("profile.json").path
            ), "profile.json must ride along on a restore")
        } else {
            Issue.record("Expected .restored, got \(result)")
        }
    }

    // Sanity: source-missing branch. If the user manually emptied
    // .trash/ between delete and undo, restorePOIFolder reports it
    // distinctly so the model can drop the banner without surfacing
    // an error.
    @Test func undo_reportsSourceMissingWhenTrashEntryGone() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }

        let bogusURL = sandbox.trash.appendingPathComponent("POI-ghost-19700101-000000")
        let result = POIStorage.restorePOIFolder(
            from: bogusURL,
            uuid: UUID(),
            storeOverride: sandbox.store
        )
        #expect(result == .sourceMissing,
                "Missing trash entry should produce .sourceMissing, not .ioError")
    }
}
