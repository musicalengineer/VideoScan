// ExcessCopiesSensorTests.swift
// SENSOR for "Delete excess copies" (Tier 1): the lane adds NO file
// operation of its own. Every removal goes through the shared door —
// `pruneOneCopy` → the ONE Trash routine, `deleteConfirmedJunk` — and the
// lane's mode is `.toTrash`, never `.permanent`. A future edit that adds a
// trashItem / removeItem / unlink / rename to the lane, calls the Trash
// routine directly, or passes `.permanent`, trips here at the source.

import Foundation
import Testing

@Suite("Excess copies — one door, Trash only (source sensor)")
struct ExcessCopiesSensorTests {

    static var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan", isDirectory: true)
    }

    static var coreRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScanCore/Sources/VideoScanCore", isDirectory: true)
    }

    static var modelFile: URL { appRoot.appendingPathComponent("MediaOps/VideoScanModel+ExcessCopies.swift") }
    static var jobFile: URL { appRoot.appendingPathComponent("MediaOps/ExcessCopiesJob.swift") }

    /// Every source file of the lane.
    static var laneFiles: [URL] {
        [modelFile, jobFile, appRoot.appendingPathComponent("Catalog/ExcessCopiesPane.swift"),
         coreRoot.appendingPathComponent("ExcessCopiesPlan.swift")]
    }

    static func source(_ url: URL) throws -> String {
        // Comment lines are documentation, not calls.
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .joined(separator: "\n")
    }

    static let forbidden = ["trashItem(", "removeItem(", "unlink(", "rmdir(", "rename(", "renamex_np(", "moveItem(",
                            "deleteConfirmedJunk(", ".permanent", "replaceItemAt("]

    @Test("no file in the lane removes, moves or renames a file itself, or asks for a permanent delete")
    func noFileOperationOfItsOwn() throws {
        for url in Self.laneFiles {
            let text = try Self.source(url)
            for token in Self.forbidden {
                #expect(!text.contains(token), "\(url.lastPathComponent) contains \(token) — every removal goes through pruneOneCopy")
            }
        }
    }

    @Test("the lane's one removal call is pruneOneCopy, Trash mode, with the lane guard")
    func theOneDoorIsPruneOneCopyToTrash() throws {
        let model = try Self.source(Self.modelFile)
        let calls = model.components(separatedBy: "pruneOneCopy(").count - 1
        #expect(calls == 1, "exactly one call site — \(calls)")
        #expect(model.contains("pruneOneCopy(item, batch: batch, mode: .toTrash, hooks: hooks, laneGuard: excessLaneGuard(env: env))"))
        let job = try Self.source(Self.jobFile)
        #expect(!job.contains("pruneOneCopy("), "the job goes through excessOneCopy, the same door as applyExcess")
        #expect(job.contains("model.excessOneCopy("))
        #expect(job.contains("model.prepareExcess(shown: shown"), "the job re-asks the one plan at its turn")
    }

    @Test("the lane always reads the copy in full: every item is a duplicate to the pipeline")
    func everyCopyIsReadInFull() throws {
        let model = try Self.source(Self.modelFile)
        #expect(model.contains("kind: .duplicate"))
        #expect(!model.contains("kind: .original"), "an original may be trusted on its promotion stamp — never here")
        #expect(model.contains("pruneItem.forceArchiveRead = survivors.isEmpty"), "C05 amendment 2")
    }
}
