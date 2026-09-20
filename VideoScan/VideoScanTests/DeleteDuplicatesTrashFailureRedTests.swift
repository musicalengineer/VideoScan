// DeleteDuplicatesTrashFailureRedTests.swift
// QA RED tests (review of d998cb7e + b0ae1ad0, 2026-09-20). Pins
// SignatureVerification.swift `deleteQuarantined` `.trash` catch and
// DeleteDuplicatesJob.swift `settle(.retained)` + `clearQuarantine`:
// when the move to the Trash FAILS (network/external volume without a
// usable .Trashes, permission), nothing destructive has happened, so the
// file must go back to its public path — "any doubt → restored". Today it
// is RETAINED in the hidden `.videoscan-quarantine-*` folder, the row is
// marked failed, the plan forgets the folder (clearQuarantine) and is
// filed under done/ — a family file parked in a dot-folder the catalog
// does not know about.

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_duptrashfail_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ url: URL, _ bytes: [UInt8]) { FileManager.default.createFile(atPath: url.path, contents: Data(bytes)) }

private func plainSHA256(_ url: URL) -> String {
    SHA256.hash(data: (try? Data(contentsOf: url)) ?? Data()).map { String(format: "%02x", $0) }.joined()
}

private func quarantineFolders(in dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasPrefix(SignatureVerification.quarantineDirectoryPrefix) }
}

private struct TrashRefused: Error {}

@Suite("QA RED — a failed move to the Trash puts the file back")
struct DeleteDuplicatesTrashFailureRedTests {

    /// Gate level: `deleteQuarantined(_, disposal: .trash)` with a Trash
    /// step that throws must restore the file, not retain it.
    @Test func trashFailureAtTheGateRestoresTheFile() throws {
        let dir = tempDir("gate"); defer { try? FileManager.default.removeItem(at: dir) }
        let size = FileHasher.segmentSize + 123
        let bytes = (0..<size).map { UInt8($0 % 29) }
        let keeper = dir.appendingPathComponent("keeper.mov"); write(keeper, bytes)
        let copy = dir.appendingPathComponent("copy.mov"); write(copy, bytes)
        let fixity = try #require(ContentFixity.captured(path: keeper.path, digest: plainSHA256(keeper), byteCount: Int64(size)))
        var hooks = SignatureVerification.Hooks.live
        hooks.trashItem = { _ in throw TrashRefused() }

        guard case .held(let hold) = SignatureVerification.holdForSingleRead(
                keeperPath: keeper.path, keeperFixity: fixity, duplicatePath: copy.path, hooks: hooks),
              case .verified(let ticket) = SignatureVerification.verifyHeld(hold, hooks: hooks) else {
            Issue.record("expected a verified ticket"); return
        }
        let result = SignatureVerification.deleteQuarantined(ticket, disposal: .trash, hooks: hooks)

        if case .retainedQuarantine(let path, _) = result {
            Issue.record("retained in the hidden quarantine folder \(path) — nothing destructive happened, the file must be put back")
        }
        #expect(FileManager.default.fileExists(atPath: copy.path), "back at its public path")
        #expect((try? Data(contentsOf: copy)) == Data(bytes))
        #expect(quarantineFolders(in: dir).isEmpty, "no hidden folder left behind")
    }

    /// Job level: the Trash rung (archive + keeper → 2 remain) with a
    /// Trash step that throws. The file must be back at its path and the
    /// plan must either name the folder or the file must be home — never
    /// "forgotten in a dot-folder and filed as done".
    @Test @MainActor func trashFailureInTheJobPutsTheFileBackAndNeverForgetsIt() async throws {
        let dir = tempDir("job"); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("plans", isDirectory: true)
        let size = FileHasher.segmentSize * 2
        let bytes = (0..<size).map { UInt8($0 % 31) }
        let keeperURL = dir.appendingPathComponent("keeper.mov"); write(keeperURL, bytes)
        let copyURL = dir.appendingPathComponent("copy1.mov"); write(copyURL, bytes)
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        let group = UUID()
        func rec(_ url: URL, _ d: DuplicateDisposition) -> VideoRecord {
            let r = VideoRecord()
            r.fullPath = url.path; r.filename = url.lastPathComponent; r.directory = dir.path
            r.sizeBytes = Int64(size); r.partialMD5 = "same"; r.durationSeconds = 61
            r.duplicateGroupID = group; r.duplicateDisposition = d; r.duplicateConfidence = .high
            return r
        }
        let keeper = rec(keeperURL, .keep)
        keeper.contentFixity = ContentFixity.captured(path: keeperURL.path, digest: plainSHA256(keeperURL), byteCount: Int64(size))
        let copy = rec(copyURL, .extraCopy)
        model.records = [keeper, copy]
        addVerifiedArchiveFamily(to: model, keeper: keeper, withSibling: false)   // archive + keeper → the Trash rung

        var hooks = SignatureVerification.Hooks.live
        hooks.trashItem = { _ in throw TrashRefused() }
        let job = DeleteDuplicatesJob(model: model, volumePath: dir.path, hooks: hooks, planRoot: root)
        job.start(); await job.task?.value

        let plan = try #require(job.plan)
        #expect(FileManager.default.fileExists(atPath: copyURL.path), "put back at its public path — \(plan.entries[0].status): \(plan.entries[0].note)")
        #expect(quarantineFolders(in: dir).isEmpty, "no hidden quarantine folder left behind")
        #expect(FileManager.default.fileExists(atPath: copyURL.path) || plan.entries[0].quarantineDirectory != nil,
                "a file not at home must still be named by the plan")
        #expect(!FileManager.default.fileExists(atPath: DeleteDuplicatesPlanStore.doneURL(for: plan.id, root: root).path)
                || FileManager.default.fileExists(atPath: copyURL.path),
                "never filed as done with the file parked in a dot-folder")
        #expect(job.result.deleted == 0)
    }
}
