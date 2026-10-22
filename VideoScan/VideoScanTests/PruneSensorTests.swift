// PruneSensorTests.swift
// SENSOR for the one prune plan (docs/design/pruneplan_simple_2026-10-21.md),
// read at the source, at production scale (the whole app tree):
//   * ONE DOOR, TRASH ONLY (I3): no prune file moves, renames or removes a
//     file itself; the only removal is `deleteConfirmedJunk(… mode: mode …)`
//     with `let mode: JunkDeletionMode = .toTrash` — no mode parameter
//     anywhere in the apply path, no `.permanent`;
//   * I1, by construction: a `PruneProof` is made in exactly ONE place, the
//     candidate's full read against an archive reading of this batch, and no
//     stored stamp (`describesFileNow`) appears in the apply path;
//   * I9: no prune view walks `records`;
//   * the retired machinery stays retired (bar, keeper, name-alikes, hash to
//     confirm, survivors, note carry).

import Foundation
import Testing

@Suite("Prune — one door, Trash only, both reads (source sensor)")
struct PruneSensorTests {

    static let applyFiles = ["VideoScanModel+PruneApply.swift", "VideoScanModel+PruneVerification.swift",
                             "VideoScanModel+PrunePlan.swift", "PruneApplyJob.swift"]
    static let viewFiles = ["PruneChecklistView.swift", "ArchivedWhatNextSheet.swift", "ExcessCopiesPane.swift",
                            "PruneApplyDetailView.swift"]

    @Test("no prune file removes, moves or renames a file itself, or asks for a permanent delete")
    func noFileOperationOfItsOwn() throws {
        let forbidden = ["trashItem(", "removeItem(", "unlink(", "rmdir(", "rename(", "renamex_np(", "moveItem(",
                         ".permanent", "replaceItemAt(", "removeThroughTestSeam"]
        for file in Self.applyFiles + Self.viewFiles {
            let code = try SourceTree.appCode(named: file)
            for token in forbidden {
                #expect(!code.contains(token), "\(file) contains \(token) — every removal goes through deleteConfirmedJunk")
            }
        }
    }

    @Test("I3: the one removal call is deleteConfirmedJunk in Trash mode, and nothing in the apply path takes a mode")
    func theOneDoorIsTheTrash() throws {
        let apply = try SourceTree.appCode(named: "VideoScanModel+PruneApply.swift")
        #expect(apply.components(separatedBy: "deleteConfirmedJunk(").count - 1 == 1)
        #expect(apply.contains("let mode: JunkDeletionMode = .toTrash"))
        #expect(apply.contains("let result = await deleteConfirmedJunk([rec], mode: mode, reason: .prune, guard: fileGuard)"))
        for file in Self.applyFiles + Self.viewFiles {
            let code = try SourceTree.appCode(named: file)
                .replacingOccurrences(of: "let mode: JunkDeletionMode = .toTrash", with: "")
            #expect(!code.contains("mode: JunkDeletionMode") && !code.contains("mode: VideoScanModel.JunkDeletionMode"),
                    "\(file) takes a deletion mode — the Trash is the only destination")
            if file != "VideoScanModel+PruneApply.swift" {
                #expect(!code.contains("deleteConfirmedJunk("), "\(file) calls the Trash routine directly")
            }
        }
    }

    @Test("I1: a PruneProof is made in exactly one place, from a full read; no stored stamp stands in for a read")
    func theProofComesOnlyFromBothFullReads() throws {
        var makers: [String] = []
        for entry in SourceTree.appSources where entry.relative.hasSuffix(".swift") {
            let text = try String(contentsOf: entry.url, encoding: .utf8)
            if text.contains("PruneProof(copyID:") { makers.append((entry.relative as NSString).lastPathComponent) }
        }
        #expect(makers == ["VideoScanModel+PruneVerification.swift"], "\(makers)")
        let verify = try SourceTree.appCode(named: "VideoScanModel+PruneVerification.swift")
        #expect(verify.components(separatedBy: "PruneProof(copyID:").count - 1 == 1)
        #expect(verify.contains("switch pruneFullRead(item.path, hooks: hooks)"), "the candidate is read in full")
        #expect(verify.contains("switch pruneFullRead(path, hooks: hooks)"), "the archive file is read in full")
        for file in Self.applyFiles {
            let code = try SourceTree.appCode(named: file)
            #expect(!code.contains("describesFileNow"), "\(file): a stored stamp must never replace a read")
            #expect(!code.contains("verifyAgainstStoredKeeper"), "\(file): the stored-keeper shortcut is not this path")
        }
        let apply = try SourceTree.appCode(named: "VideoScanModel+PruneApply.swift")
        #expect(apply.contains("if let done = batch.archiveReadings[item.archiveID]"), "archive readings are per batch")
        #expect(apply.contains("if let refusal = bulkDeleteRefusal(rec, volume: archiveVolume) {"))
    }

    @Test("I9: no prune view walks the catalog's records")
    func noViewWalksRecords() throws {
        for file in Self.viewFiles {
            let code = try SourceTree.appCode(named: file)
            #expect(!code.contains(".records"), "\(file) reads model.records — O(records) in a view")
        }
    }

    @Test("the retired machinery stays retired")
    func theOldMachineryIsGone() throws {
        let retired = ["ImportanceBar", "ArchiveCopySnapshot", "ArchiveCopyFamilies", "keeperVolume", "hashToConfirm",
                       "PruneSurvivor", "applyHumanMetadataInheritance", "ExcessCopiesPlan", "ExcessKeepStore",
                       "PruneBarSettingsSection", "barOverride"]
        for file in Self.applyFiles + Self.viewFiles + ["VideoScanModel+MediaLedger.swift"] {
            let code = try SourceTree.appCode(named: file)
            for token in retired {
                #expect(!code.contains(token), "\(file) still mentions \(token)")
            }
        }
    }
}
