import Foundation
import VideoScanCore

/// THE one call that hands a catalog media file to the Finder Trash
/// (GH #143, docs/archive/design/one_removal_marker_and_trash_engine.md §3).
///
/// Every Trash door reaches it: the engine's disk turn
/// (`JunkDiskTurn`, behind Delete Junk, ⌘⌫, Prune / Excess copies and
/// Workbench Discard), Delete Duplicates' quarantine step
/// (`DeleteDuplicatesDiskWorker.moveToTrash` → the verifier's
/// `Hooks.trashItem`), the verifier's own default, and a Transcode /
/// Reformat "replace" of an app-made output (`DerivativeOutputPublish`).
/// The gates, proofs and catalog stamp stay with their callers; this is
/// only the move. OneEngineSensorTests fails if `trashItem(` appears in any
/// other file that can reach catalog media.
///
/// Trash only: there is no permanent removal here, and nothing ever
/// empties the Trash. Under a test host the file goes to a per-process
/// scratch folder instead, so no test fixture ever lands in Rick's real
/// Trash, whatever seams a test forgets to pass (the plan store's
/// discipline, `DeleteDuplicatesPlanStore.defaultRoot`).
///
/// (For Rick: a caseless `enum` with static members ≈ a C++ namespace —
/// it cannot be instantiated.)
enum MediaTrash {

    /// Move `url` to its volume's Trash; returns where it landed (the URL
    /// macOS returned — the removal marker and the receipt keep it). A
    /// volume with no usable Trash (some SMB / exFAT mounts) throws; the
    /// file is then where it was, and the caller holds or fails it — never a
    /// fallback to another kind of removal.
    nonisolated static func move(_ url: URL) throws -> URL {
        if TestEnvironment.isTestHost { return try moveToTestHostTrash(url) }
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?) ?? url
    }

    /// Under a test host, a source that is not test scratch (TestHostScratch.isScratch, symlinks resolved before
    /// `..`) is refused: the test trash lives in the test temp root, which the runner deletes after the run, so a
    /// real input moved into it would be erased (Codex 2026-11-23 #352 P1-3, r2 #2). Residual (Codex r2 #5): the
    /// check and the move are two system calls; a tree rewritten between them could still redirect the move. This
    /// stops test BUGS, not an adversary racing the test — the deletion that matters is the runner's rmtree.
    struct TestHostRefusal: Error, CustomStringConvertible {
        let path: String
        var description: String { "test host: refusing to trash \(path) — not test scratch (the test trash is deleted with the run)" }
    }

    /// Under the test temp root; the runner frees it (TestHostScratch).
    nonisolated static let testHostTrash = TestHostScratch.perProcess("VideoScan-tests/trash")

    /// Serializes the name pick and the move below. Test host only: the
    /// "exists? → move" pair is two steps, and parallel tests or jobs
    /// trashing same-named files raced between them — one move failed
    /// ("already exists") or landed on another's name
    /// (MediaTrashTestHostRaceTests, 2026-11-20). The real Trash
    /// (`trashItem`) picks its own unique name atomically.
    /// (≈ a C++ static std::mutex around a check-then-act.)
    private static let testHostTrashLock = NSLock()

    /// No-clobber move into `testHostTrash` ("a 2.mov" on a name clash).
    nonisolated static func moveToTestHostTrash(_ url: URL) throws -> URL {
        try testHostTrashLock.withLock { try moveToTestHostTrashLocked(url) }
    }

    private nonisolated static func moveToTestHostTrashLocked(_ url: URL) throws -> URL {
        guard TestHostScratch.isScratch(url) else { throw TestHostRefusal(path: url.path) }
        let fm = FileManager.default
        try fm.createDirectory(at: testHostTrash, withIntermediateDirectories: true)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var destination = testHostTrash.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: destination.path) {
            destination = testHostTrash.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        try fm.moveItem(at: url, to: destination)
        return destination
    }
}
