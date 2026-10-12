import Foundation
import VideoScanCore

/// THE one call that hands a catalog media file to the Finder Trash
/// (GH #143, docs/design/one_removal_marker_and_trash_engine.md §3).
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

    nonisolated static let testHostTrash = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("VideoScan-tests/trash-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    /// No-clobber move into `testHostTrash` ("a 2.mov" on a name clash).
    nonisolated static func moveToTestHostTrash(_ url: URL) throws -> URL {
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
