// VolumeCompare.swift
// Compare two cataloged volumes and identify media files that exist on one
// but not the other. Primary use case: rescue unique files from aging drives
// before they fail, without blindly copying everything (including duplicates).

import Darwin
import Foundation
import SwiftUI
import Combine
import os
import VideoScanCore

private let rescueLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "rescue")

// MARK: - Comparison Result

struct VolumeCompareResult {
    let sourcePath: String
    let destPath: String
    let destLabel: String                 // human-readable; may be a volume name or "(any other cataloged volume)"
    let isAuditMode: Bool                 // true when dest is "any other volume" — copy not available
    let missingFiles: [VideoRecord]       // on source, NOT on destination
    let alreadySafe: [VideoRecord]        // on source AND destination
    let sourceOnly: Int                   // count for quick display
    let alreadySafeCount: Int
    let totalSourceBytes: Int64
    let missingBytes: Int64

    var missingHumanSize: String { humanSize(missingBytes) }
}

// MARK: - Comparison Engine

enum VolumeComparer {

    /// Compare source volume against destination volume using catalog records.
    /// A file is "already safe" if destination has a record with matching
    /// (partialMD5 + sizeBytes) OR (filename + sizeBytes) when MD5 is unavailable.
    ///
    /// Pass `isAuditMode: true` when `destRecords` is the union of *many* volumes
    /// (i.e., "does this file exist anywhere else in the catalog?") so the result
    /// can flag that copy isn't available (no single target path).
    ///
    /// Source-side dedup contract: the catalog has, for historical scan-import
    /// reasons, multiple records per fullPath. The COMPARE OUTPUT must treat
    /// those rows as a single physical file — otherwise users see inflated
    /// "missing GB" totals and overestimate what would be lost if the source
    /// volume failed. Specifically:
    ///   - `missingFiles` is path-deduped (one VideoRecord per fullPath)
    ///   - `missingBytes` / `totalSourceBytes` are summed over path-deduped rows
    ///   - `alreadySafe` is also path-deduped so the rescue UI doesn't show
    ///     two rows for the same file
    /// Verified 2026-06-07: without this, Rick's MyBook3Terabytes compare was
    /// reporting 1352 records / 712 GB when the true at-risk surface was
    /// 676 paths / ~356 GB — exactly 2× inflated.
    static func compare(
        sourceRecords: [VideoRecord],
        destRecords: [VideoRecord],
        sourcePath: String,
        destPath: String,
        destLabel: String? = nil,
        isAuditMode: Bool = false
    ) -> VolumeCompareResult {
        // Dedup source by fullPath up-front — collapse historical
        // catalog-duplicate rows down to one record per physical file.
        // Keep the FIRST occurrence so the result preserves the catalog
        // order users see in the table.
        var seenPaths = Set<String>()
        seenPaths.reserveCapacity(sourceRecords.count)
        let dedupedSource = sourceRecords.filter { rec in
            seenPaths.insert(rec.fullPath).inserted
        }

        // Build destination lookup indices
        var destByHash: Set<String> = []       // "md5|size"
        var destByNameSize: Set<String> = []   // "filename|size"

        for rec in destRecords {
            if !rec.partialMD5.isEmpty && rec.sizeBytes > 0 {
                destByHash.insert("\(rec.partialMD5)|\(rec.sizeBytes)")
            }
            destByNameSize.insert("\(rec.filename.lowercased())|\(rec.sizeBytes)")
        }

        var missing: [VideoRecord] = []
        var safe: [VideoRecord] = []
        var missingBytes: Int64 = 0
        var totalBytes: Int64 = 0

        for rec in dedupedSource {
            totalBytes += rec.sizeBytes

            // Check by hash first (strongest match)
            if !rec.partialMD5.isEmpty && rec.sizeBytes > 0 {
                let hashKey = "\(rec.partialMD5)|\(rec.sizeBytes)"
                if destByHash.contains(hashKey) {
                    safe.append(rec)
                    continue
                }
            }

            // Fallback: filename + size
            let nameKey = "\(rec.filename.lowercased())|\(rec.sizeBytes)"
            if destByNameSize.contains(nameKey) {
                safe.append(rec)
                continue
            }

            // Not found on destination
            missing.append(rec)
            missingBytes += rec.sizeBytes
        }

        return VolumeCompareResult(
            sourcePath: sourcePath,
            destPath: destPath,
            destLabel: destLabel ?? URL(fileURLWithPath: destPath).lastPathComponent,
            isAuditMode: isAuditMode,
            missingFiles: missing,
            alreadySafe: safe,
            sourceOnly: missing.count,
            alreadySafeCount: safe.count,
            totalSourceBytes: totalBytes,
            missingBytes: missingBytes
        )
    }
}

// MARK: - Copy Mode

enum RescueCopyMode: String, CaseIterable {
    case fast = "Fast (no verification)"
    /// The case keeps its name (call sites); the LABEL no longer says
    /// "Verified" (GH #506): what VideoScan itself checks after rsync is
    /// that the destination is a regular file of the source's size — a
    /// size check, not a content hash.
    case verified = "rsync --checksum (size checked)"

    var description: String {
        switch self {
        case .fast: return "Uses system copy — fastest, no post-copy checksum. Nothing already at the destination is ever replaced."
        case .verified: return "Uses rsync --checksum — slower. A file counts as copied only after its size at the destination is checked against the source (a size check, not a hash). Nothing already at the destination is ever replaced."
        }
    }

    /// For the START line in the log.
    var logName: String {
        switch self {
        case .fast: return "fast copy"
        case .verified: return "rsync --checksum"
        }
    }
}

// MARK: - Copy Engine

@MainActor
final class VolumeRescueOperation: ObservableObject {
    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var currentFile: String = ""
    /// Files that are now SAFE at the destination: newly copied +
    /// already-present + repaired. Progress and the toolbar chip read this.
    @Published var filesCopied: Int = 0
    @Published var filesFailed: Int = 0
    /// Bytes this run actually WROTE, measured from write(2) in
    /// RescueFileCopier. Files that were already present contribute
    /// nothing here — they're counted in `bytesAlreadyPresent`. Before
    /// 2026-09-13 this accrued the catalog's source size for every file,
    /// including skipped ones, so it was a claim rather than a
    /// measurement.
    @Published var bytesWritten: Int64 = 0
    /// Subset of `filesCopied` that a previous rescue had already put
    /// there, whole (same size as the source). Shown so a resumed rescue
    /// reads honestly instead of looking like it re-copied everything.
    @Published var filesAlreadyPresent: Int = 0
    @Published var bytesAlreadyPresent: Int64 = 0
    /// Subset of `filesFailed`: source files NOT copied because a different
    /// file (another size, a folder, a link) is already at their name under
    /// the destination. A rescue never replaces what is there (rule 2).
    @Published private(set) var filesNameTaken: Int = 0
    /// One line per file that is NOT a copy (failed, or in flight at Stop),
    /// each saying why and what is at the destination. Bounded: one line of
    /// at most ~700 characters per such file.
    @Published var errors: [String] = []
    @Published var isDone = false
    /// GH #506 item 4: a Stop is a named outcome, not "done, 1 failed".
    /// True when Stop ended the run with files still to copy.
    @Published private(set) var wasStopped = false
    /// The file whose transfer Stop killed (0 or 1): not copied, not failed.
    @Published private(set) var filesInterrupted: Int = 0
    /// Files the run never started because Stop came first.
    @Published private(set) var filesNotAttempted: Int = 0
    /// How many files this run was asked to copy. Always
    /// `filesCopied + filesFailed + filesInterrupted + filesNotAttempted`
    /// once the run is done.
    @Published private(set) var filesPlanned: Int = 0
    private var stopRequested = false

    private var task: Task<Void, Never>?

    /// True while an rsync child is running. Until 2026-11-21 this was the
    /// `Process` itself, kept so `cancel()` could `terminate()` it mid-file
    /// (without that, cancel was "soft": `waitUntilExit()` blocked until the
    /// in-flight multi-GB rsync finished, and Rick force-quit the app
    /// 2026-06-07 trying to cancel a copy). rsync now runs through
    /// ProcessRunner, whose cancellation handler sends that same SIGTERM the
    /// moment `task.cancel()` lands (and SIGKILL if rsync lingers past the
    /// grace period) — so only the fact is kept, for the cancel log line.
    private var rsyncInFlight = false

    /// Default subfolder name on the destination. Used as the placeholder
    /// in the Compare UI's "Folder name" TextField. The folder is created
    /// under destPath, then the source's relative directory structure
    /// preserved underneath.
    nonisolated static let defaultRescueFolderName = "Rescued"

    /// Pure sanitizer for the user-entered rescue folder name. Trims
    /// whitespace, falls back to the default when empty. Exposed as
    /// static + `nonisolated` so tests (which run off the main actor)
    /// can pin the edge cases (empty / whitespace / already-trimmed)
    /// without standing up a VolumeRescueOperation. Used by
    /// `start(folderName:)` before constructing rescueDir.
    /// One honest line for the completion banner. Pure + nonisolated so a
    /// test can pin the wording without standing up the operation, and so
    /// the SwiftUI body stays a single `Text` (this view has tripped the
    /// type-checker's timeout before).
    ///
    /// "Safe" is the total that now exists at the destination; the bytes
    /// figure is what this run actually WROTE, so a resumed rescue reads
    /// "40 safe · 0 failed · 0 bytes · 40 already there" instead of
    /// claiming it copied 400 GB it never touched.
    ///
    /// GH #506: the first figure is "at the destination (size checked)" —
    /// not "safe" and not "verified": what was checked is that each file
    /// is a regular file of the source's size (and it is not "copied",
    /// because a resumed run counts files that were already there). After
    /// a Stop the file in flight and the files never attempted are named.
    nonisolated static func doneSummary(safe: Int,
                                        failed: Int,
                                        bytesWritten: Int64,
                                        alreadyPresent: Int,
                                        nameTaken: Int = 0,
                                        interrupted: Int = 0,
                                        notAttempted: Int = 0) -> String {
        // "Failed" says how many were refused because the name is taken:
        // those files are not lost (they are still on the source) and
        // nothing at the destination was replaced.
        let failedWords = nameTaken > 0
            ? "\(failed) failed (\(nameTaken) not replaced: a different file was already there)" : "\(failed) failed"
        var parts = ["\(safe) at the destination (size checked)", failedWords, humanSize(bytesWritten) + " written"]
        if alreadyPresent > 0 { parts.append("\(alreadyPresent) already there") }
        if interrupted > 0 { parts.append("\(interrupted) interrupted by Stop") }
        if notAttempted > 0 { parts.append("\(notAttempted) not attempted") }
        return parts.joined(separator: " · ")
    }

    /// The banner's title: a stopped or partly failed copy is never
    /// headed "Copy finished" over a green tick.
    nonisolated static func doneTitle(stopped: Bool, failed: Int) -> String {
        if stopped { return "Copy stopped" }
        return failed > 0 ? "Copy finished — \(failed) file\(failed == 1 ? "" : "s") failed" : "Copy finished"
    }

    /// The banner's second line when some file is not a copy: the first
    /// such line, and where the rest are. nil when every file was copied.
    nonisolated static func doneDetail(errors: [String]) -> String? {
        guard let first = errors.first else { return nil }
        return errors.count == 1 ? first : "\(first) — and \(errors.count - 1) more; every line is in videoscan.log (rescue FAILED)."
    }

    /// The one OUTCOME line for the app log.
    nonisolated static func outcomeLine(stopped: Bool, planned: Int, summary: String, destination: String, elapsedSeconds: Int) -> String {
        "rescue OUTCOME: \(stopped ? "stopped" : "done") — \(planned) planned: \(summary) — destination \(destination), \(elapsedSeconds) s"
    }

    nonisolated static func sanitizeRescueFolderName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultRescueFolderName : trimmed
    }

    /// Copy missing files from source volume to a destination folder.
    /// Preserves relative directory structure under the volume root.
    ///
    /// `folderName` is the subfolder created under `destPath`. Default
    /// preserves the historical "Rescued" name for back-compat; the UI
    /// now lets Rick pick.
    func start(files: [VideoRecord],
               sourcePath: String,
               destPath: String,
               mode: RescueCopyMode = .verified,
               folderName: String = VolumeRescueOperation.defaultRescueFolderName) {
        guard !isRunning else { return }
        isRunning = true
        isDone = false
        progress = 0
        filesCopied = 0
        filesFailed = 0
        bytesWritten = 0
        filesAlreadyPresent = 0
        bytesAlreadyPresent = 0
        filesNameTaken = 0
        errors = []
        rsyncInFlight = false
        wasStopped = false
        stopRequested = false
        filesInterrupted = 0
        filesNotAttempted = 0
        filesPlanned = files.count
        // Remember destination so post-completion UX can trigger a
        // rescan of the volume that just received the files.
        lastDestPath = destPath

        // Snapshot up front: VideoRecord is a class and capturing it across
        // an actor boundary trips strict-concurrency. Sendable snapshots
        // carry every field these copy paths read.
        let snapshots = files.snapshots()
        let total = snapshots.count
        // Sanitize the folder name via the public helper so tests
        // exercise the same code path that the runtime does.
        let safeFolder = Self.sanitizeRescueFolderName(folderName)
        let started = Date()
        let totalBytesPlanned = snapshots.reduce(Int64(0)) { $0 + $1.sizeBytes }
        rescueLog.notice("Rescue start: \(total, privacy: .public) files, \(humanSize(totalBytesPlanned), privacy: .public) → \(destPath, privacy: .public)/\(safeFolder, privacy: .public) (mode=\(mode.rawValue, privacy: .public))")
        let rescueDir = (destPath as NSString).appendingPathComponent(safeFolder)
        // START and OUTCOME through the one log sink (GH #506 item 5). The
        // rescue is NOT an MFO job yet (no Pause, no stall watchdog — a
        // bigger design, noted in the issue); this is its audit trail.
        appLog.write("rescue START: \(total) file(s), \(humanSize(totalBytesPlanned)), \(sourcePath) → \(rescueDir) (\(mode.logName)); "
            + "a file counts only when it is at the destination with the source's size (a size check, not a hash); nothing at the source is changed")
        task = Task { [weak self] in
            let fm = FileManager.default

            // Create destination root if needed
            try? fm.createDirectory(atPath: rescueDir, withIntermediateDirectories: true)

            if mode == .verified {
                // rsync mode: batch copy with checksum verification
                await self?.rsyncCopy(files: snapshots, sourcePath: sourcePath, rescueDir: rescueDir, total: total)
            } else {
                // Fast mode: FileManager copy, no verification
                await self?.fastCopy(files: snapshots, sourcePath: sourcePath, rescueDir: rescueDir, total: total)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(started)
                // Counts add up: planned = at the destination + failed +
                // interrupted + not attempted. Only a Stop leaves files
                // unattempted (the loops break on nothing else).
                self.filesNotAttempted = max(0, total - self.filesCopied - self.filesFailed - self.filesInterrupted)
                self.wasStopped = self.stopRequested && (self.filesInterrupted + self.filesNotAttempted) > 0
                rescueLog.notice("Rescue done: safe=\(self.filesCopied, privacy: .public) failed=\(self.filesFailed, privacy: .public) written=\(humanSize(self.bytesWritten), privacy: .public) alreadyPresent=\(self.filesAlreadyPresent, privacy: .public) (\(humanSize(self.bytesAlreadyPresent), privacy: .public)) nameTaken=\(self.filesNameTaken, privacy: .public) elapsed=\(Int(elapsed), privacy: .public)s")
                appLog.write(Self.outcomeLine(
                    stopped: self.wasStopped, planned: total,
                    summary: Self.doneSummary(safe: self.filesCopied, failed: self.filesFailed, bytesWritten: self.bytesWritten,
                                              alreadyPresent: self.filesAlreadyPresent, nameTaken: self.filesNameTaken,
                                              interrupted: self.filesInterrupted, notAttempted: self.filesNotAttempted),
                    destination: rescueDir, elapsedSeconds: Int(elapsed)))
                self.progress = 1.0
                self.isRunning = false
                self.isDone = true
                self.currentFile = ""
            }
        }
    }

    /// Acknowledge that the user has SEEN the completion banner so it
    /// can collapse out of the UI. Doesn't touch the running-task state
    /// (there isn't one — we're already `isDone`). Resets the published
    /// counters so a subsequent start() shows fresh numbers.
    func acknowledgeCompletion() {
        guard isDone else { return }
        isDone = false
        progress = 0
        filesCopied = 0
        filesFailed = 0
        bytesWritten = 0
        filesAlreadyPresent = 0
        bytesAlreadyPresent = 0
        filesNameTaken = 0
        filesInterrupted = 0
        filesNotAttempted = 0
        filesPlanned = 0
        wasStopped = false
        errors = []
        currentFile = ""
    }

    /// Destination path the most-recent rescue wrote to. Used by the
    /// post-rescue UX so we can offer (or auto-trigger) a rescan of
    /// that destination volume to catalog the freshly-copied files.
    /// nil before the first rescue.
    @Published private(set) var lastDestPath: String?

    /// Stop a running copy as fast as possible. Task.cancel() stops the
    /// loop between files AND — through ProcessRunner's cancellation
    /// handler — sends SIGTERM to the current rsync subprocess (which kills
    /// the in-flight transfer mid-file). Without the latter, cancel was
    /// effectively "stop after this file" which meant several minutes of
    /// "did it cancel?" UI for large MXFs.
    func cancel() {
        let hadProc = rsyncInFlight
        if isRunning { stopRequested = true }
        task?.cancel()
        rsyncInFlight = false
        rescueLog.notice("Rescue cancel requested (hadProc=\(hadProc, privacy: .public))")
        // isRunning is flipped by the task's completion block once it
        // observes the cancellation. Leaving it true here keeps any
        // re-issued start() guard intact until cleanup lands.
    }

    // MARK: - Fast Copy (FileManager)

    /// Fast mode: descriptor copy through a `.partial`, no checksum.
    ///
    /// Every file goes through `RescueFileCopier`, which publishes a file
    /// only by renaming a complete `.partial` onto the final name. The
    /// previous implementation called `FileManager.copyItem` straight to
    /// the final name and treated ANY pre-existing destination as "already
    /// copied" — so an interrupted rescue left truncated files at final
    /// names and the next run reported them as good (found by the
    /// check-then-act ratchet, 2026-09-13). Counters here now record what
    /// the copier measured, not what the catalog claimed the size was.
    private nonisolated func fastCopy(files: [VideoRecordSnapshot], sourcePath: String, rescueDir: String, total: Int) async {
        let fm = FileManager.default

        for (idx, rec) in files.enumerated() {
            if Task.isCancelled { break }

            let srcFile = rec.fullPath
            let filename = rec.filename
            let relative = Self.relativePath(srcFile, under: sourcePath, fallback: filename)
            let destFile = (rescueDir as NSString).appendingPathComponent(relative)
            let destDir = (destFile as NSString).deletingLastPathComponent
            let progressFraction = Double(idx) / Double(total)

            await MainActor.run { [weak self] in
                self?.currentFile = filename
                self?.progress = progressFraction
            }

            // Refuse before mutating (rule 2): a name that is taken by a
            // different file is never touched. (A same-size file goes on
            // to the copier, which leaves it alone, counts it as already
            // there and sweeps only its OWN stale `.partial`.)
            if case .taken(let line) = Self.nameCheck(relative: relative, rescueDir: rescueDir, sourceFile: srcFile, destFile: destFile) {
                await recordFailed(line, nameTaken: true)
                continue
            }

            do {
                try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            } catch {
                await MainActor.run { [weak self] in
                    self?.filesFailed += 1
                    self?.errors.append("mkdir failed: \(relative) — \(error.localizedDescription)")
                }
                continue
            }

            do {
                let outcome = try RescueFileCopier.copy(source: srcFile,
                                                        destination: destFile,
                                                        shouldCancel: { Task.isCancelled })
                switch outcome {
                case .copied(let written):
                    await MainActor.run { [weak self] in
                        self?.filesCopied += 1
                        self?.bytesWritten += written
                    }
                case .alreadyPresent(let bytes):
                    // Resumed rescue: this file was already there, whole.
                    // It counts as safe, but this run did not write it.
                    await MainActor.run { [weak self] in
                        self?.filesCopied += 1
                        self?.filesAlreadyPresent += 1
                        self?.bytesAlreadyPresent += bytes
                    }
                }
            } catch RescueFileCopier.Failure.cancelled {
                // In flight at Stop: named, not failed (as the rsync path).
                await recordInterrupted("\(relative) — stopped during the copy; nothing was published at the final name.")
                break
            } catch {
                // The copier refused because the name is (or became) taken:
                // say it in the same words as the check above, from a
                // fresh look at what is there now.
                if Self.isNameTaken(error),
                   case .taken(let line) = Self.nameCheck(relative: relative, rescueDir: rescueDir, sourceFile: srcFile, destFile: destFile) {
                    await recordFailed(line, nameTaken: true)
                } else {
                    await recordFailed("\(relative) — \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Verified Copy (rsync)

    private nonisolated func rsyncCopy(files: [VideoRecordSnapshot], sourcePath: String, rescueDir: String, total: Int) async {
        // rsync individual files to preserve per-file progress reporting
        // and handle errors per-file rather than aborting the whole batch
        for (idx, rec) in files.enumerated() {
            if Task.isCancelled { break }

            let srcFile = rec.fullPath
            let filename = rec.filename
            let relative = Self.relativePath(srcFile, under: sourcePath, fallback: filename)
            let destFile = (rescueDir as NSString).appendingPathComponent(relative)
            let destDir = (destFile as NSString).deletingLastPathComponent
            let progressFraction = Double(idx) / Double(total)

            await MainActor.run { [weak self] in
                self?.currentFile = filename
                self?.progress = progressFraction
            }

            // NEVER REPLACE (rule 2, 2026-11-21). THE BUG: nothing asked
            // what was already at the destination name, and a successful
            // rsync replaced it — the previous bytes unlinked, not trashed.
            // Two volumes with the same relative path (two camera cards
            // with DCIM/100CANON/MVI_0001.MOV) rescued into one folder is
            // all it took. Decided here, before mkdir and before rsync:
            // a free name is transferred; a regular file of the source's
            // size is counted as already there and left alone (content is
            // NOT compared — a size check); anything else at the name
            // fails this file and is not touched.
            switch Self.nameCheck(relative: relative, rescueDir: rescueDir, sourceFile: srcFile, destFile: destFile) {
            case .free:
                break
            case .alreadyThere(let bytes):
                await MainActor.run { [weak self] in
                    self?.filesCopied += 1
                    self?.filesAlreadyPresent += 1
                    self?.bytesAlreadyPresent += bytes
                }
                continue
            case .taken(let line):
                await recordFailed(line, nameTaken: true)
                continue
            }

            // Create destination directory.
            //
            // Through ProcessRunner (2026-11-21; it was a hand-rolled
            // `Process()`): same executable and argv, the app's environment
            // and working directory. As before, only a FAILURE TO LAUNCH is
            // reported here — mkdir's exit status is not read (rsync then
            // fails on the missing directory and says so). mkdir's output,
            // which used to go to the app's own stdout/stderr, is discarded.
            let mkdir = await ProcessRunner.runProcess(executable: "/bin/mkdir", arguments: ["-p", destDir],
                                                       stdoutLimitBytes: 0, stderrLimitBytes: 0)
            if !mkdir.launched {
                // The runner does not launch a child for a cancelled task:
                // that is the user's Stop, not a failed file. Asked of the
                // RESULT, not of the task: a Stop that lands after a genuine
                // launch failure must not erase that failure (Codex r1 P2).
                if mkdir.cancelledBeforeLaunch { break }
                await MainActor.run { [weak self] in
                    self?.filesFailed += 1
                    self?.errors.append("mkdir failed: \(relative) — \(mkdir.stderr)")
                }
                continue
            }

            // rsync with --checksum.
            //
            // `--partial-dir=.videoscan-partial` (GH #506, 2026-11-21; it was
            // a bare `--partial`). THE BUG: `--partial` keeps an interrupted
            // transfer AT THE FINAL NAME, so a failed or stopped copy left a
            // truncated file named like a good one, and a catalog scan of
            // the destination recorded it as a file. With `--partial-dir`
            // rsync parks the partial in `<destination folder>/
            // .videoscan-partial/<name>`, resumes from it on the next run
            // and removes the folder when it is done; nothing truncated is
            // ever at a final name because of this run. (Measured on the
            // installed /usr/bin/rsync — openrsync, protocol 29 — with a
            // real interrupted transfer: VolumeRescueRsyncNegativeMatrixTests.)
            //
            // Through ProcessRunner (2026-11-21; it was a hand-rolled
            // `Process()` + `waitUntilExit()`): the app's environment and
            // working directory. What the runner does differently, none of
            // it weaker:
            //   • stderr is drained while rsync runs (it was read only after
            //     exit, so more than the 64 KB pipe buffer blocked rsync
            //     forever); the collected copy is capped at that same 64 KB;
            //   • stdout (nothing, without -v) is discarded instead of
            //     inherited;
            //   • Stop: task cancellation sends the SIGTERM `cancel()` used
            //     to send by hand, then SIGKILL after the 5 s grace if rsync
            //     has not exited (before: SIGTERM only).
            // There is still NO deadline: a multi-GB file on a slow disk
            // legitimately takes as long as it takes.
            await MainActor.run { [weak self] in
                self?.rsyncInFlight = true
            }
            let result = await ProcessRunner.runProcess(
                executable: "/usr/bin/rsync",
                arguments: [
                    "--checksum",       // compare by checksum, not just size/mtime
                    "--ignore-existing", // second belt: a file that appears at the name after the check is not replaced
                    "--partial-dir=\(Self.partialDirName)",   // an interrupted transfer never sits at the final name
                    "--times",          // preserve modification times
                    srcFile,
                    destFile
                ],
                stdoutLimitBytes: 0,
                stderrLimitBytes: 64 * 1024)
            await MainActor.run { [weak self] in
                self?.rsyncInFlight = false
            }

            if !result.launched {
                // The runner refused to launch because the task was already
                // cancelled = the user's Stop landed before this file
                // started: it was not attempted. Asked of the RESULT, not of
                // the task — a Stop arriving after a genuine launch failure
                // leaves that failure counted and named (Codex r1 P2).
                if result.cancelledBeforeLaunch { break }
                await recordFailed("\(relative) — \(result.stderr)")
                continue
            }

            // EVIDENCE, NOT AN EXIT STATUS (GH #506 item 1, P0). THE BUG:
            // exit 0 was believed — a destination that was missing (the
            // installed rsync SKIPS a source it will not copy, e.g. a
            // directory, exits 0 and creates nothing) or short was counted
            // "safe". A file now counts as copied only when a FRESH lstat of
            // both shows a regular file at the destination whose size equals
            // the source's. That is a size check, NOT content verification
            // (rsync's own whole-file checksum is the tool's claim; a hash
            // of the destination is the follow-up) — and it is said as
            // "size checked", never "verified".
            let source = Self.entry(at: srcFile)
            let final = Self.entry(at: destFile)
            let parked = Self.entry(at: Self.partialPath(forDestination: destFile)).regularSize
            if result.exitCode == 0 {
                if let size = source.regularSize, final == .regular(size) {
                    await MainActor.run { [weak self] in
                        self?.filesCopied += 1
                        self?.bytesWritten += size
                    }
                    // The copy is whole: this file's OWN parked partial from
                    // an earlier interrupted run has served its purpose.
                    // (With --ignore-existing the installed rsync leaves it
                    // behind.) The only file a rescue ever unlinks — its
                    // own, under `.videoscan-partial`, never a final name.
                    unlink(Self.partialPath(forDestination: destFile))
                } else {
                    await recordFailed(Self.notCopiedLine(relative: relative, source: source, final: final, stderr: result.stderr))
                }
            } else {
                let reason = Self.rsyncReason(exitCode: result.exitCode, stderr: result.stderr)
                let left = Self.leftAtDestination(final: final, partialBytes: parked, sourceSize: source.regularSize)
                if Task.isCancelled {
                    // The user's Stop killed this transfer: it is not a
                    // failed copy (GH #506 item 4), and it is named.
                    await recordInterrupted("\(relative) — stopped during the transfer (\(reason)). At the destination: \(left)")
                } else {
                    await recordFailed("\(relative) — \(reason). At the destination: \(left)")
                }
            }
            // An emptied partial folder is removed (rmdir refuses a
            // non-empty one: a parked partial is never deleted here).
            rmdir(Self.partialDirectory(forDestination: destFile))
        }
    }

    // MARK: - What happened to one file (GH #506)

    /// One file that is NOT a copy: counted, listed, and written to the app
    /// log (the first `failureLogLimit` lines; the OUTCOME line carries the
    /// count of all of them).
    private nonisolated func recordFailed(_ line: String, nameTaken: Bool = false) async {
        rescueLog.error("Rescue copy failed: \(line, privacy: .public)")
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.filesFailed += 1
            if nameTaken { self.filesNameTaken += 1 }
            self.errors.append(line)
            if self.filesFailed <= Self.failureLogLimit { appLog.write("rescue FAILED: \(line)") }
        }
    }

    /// The file in flight when Stop landed: not copied, not failed.
    private nonisolated func recordInterrupted(_ line: String) async {
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.filesInterrupted += 1
            self.errors.append(line)
            appLog.write("rescue STOPPED: \(line)")
        }
    }

    nonisolated static let failureLogLimit = 50
    /// Where rsync parks an interrupted transfer, inside the destination
    /// file's own folder.
    nonisolated static let partialDirName = ".videoscan-partial"

    nonisolated static func partialDirectory(forDestination destFile: String) -> String {
        ((destFile as NSString).deletingLastPathComponent as NSString).appendingPathComponent(partialDirName)
    }

    nonisolated static func partialPath(forDestination destFile: String) -> String {
        (partialDirectory(forDestination: destFile) as NSString).appendingPathComponent((destFile as NSString).lastPathComponent)
    }

    /// What the rescue does with one destination name, decided from a fresh
    /// lstat of the source and of the name BEFORE anything is written.
    enum NameCheck: Equatable, Sendable {
        /// Nothing is there: transfer.
        case free
        /// A regular file of the source's size: counted as already at the
        /// destination, left alone. Content is not compared.
        case alreadyThere(Int64)
        /// Anything else is there. The line for the user; nothing is touched.
        case taken(String)
    }

    nonisolated static func nameCheck(relative: String, rescueDir: String, sourceFile: String, destFile: String) -> NameCheck {
        nameCheck(relative: relative, folder: (rescueDir as NSString).lastPathComponent,
                  source: entry(at: sourceFile), final: entry(at: destFile))
    }

    /// Pure. `folder` is the rescue folder's name, so the line reads as a
    /// path under the destination ("Rescued/DCIM/100CANON/MVI_0001.MOV").
    nonisolated static func nameCheck(relative: String, folder: String, source: DiskEntry, final: DiskEntry) -> NameCheck {
        let there: String
        switch (final, source.regularSize) {
        case (.absent, _):
            return .free
        case (.regular(let bytes), .some(let size)) where bytes == size:
            return .alreadyThere(bytes)
        case (.regular(let bytes), _):
            there = "\(bytes) bytes there"
        case (.notRegular, _):
            there = "not a regular file there — a folder or a link"
        }
        let placed = (folder as NSString).appendingPathComponent(relative)
        let onSource = source.regularSize.map { "\($0) bytes on the source" } ?? "the source could not be measured"
        let kept = source.regularSize == nil ? "nothing was touched." : "nothing was touched, and the file is still on the source."
        return .taken("\(relative) — a different file is already at \(placed) (\(there), \(onSource)) — not replaced; \(kept)")
    }

    /// The fast copier's refusals that mean "the name is taken".
    nonisolated static func isNameTaken(_ error: Error) -> Bool {
        switch error as? RescueFileCopier.Failure {
        case .differentFileAtDestination, .destinationNotRegularFile, .destinationAppearedDuringCopy: return true
        default: return false
        }
    }

    /// What one fresh lstat says is at a path. (For Rick: ≈ a tagged union
    /// over stat()'s answer — absent / S_ISREG with st_size / anything else.)
    enum DiskEntry: Equatable, Sendable {
        case absent
        case regular(Int64)
        /// A directory, a symlink, a device — or a path that cannot be
        /// stat'ed for a reason other than "not there".
        case notRegular

        var regularSize: Int64? {
            if case .regular(let size) = self { return size }
            return nil
        }
    }

    /// lstat, never following a symlink: a link at the destination is not a
    /// copy of the file.
    nonisolated static func entry(at path: String) -> DiskEntry {
        var sb = stat()
        guard lstat(path, &sb) == 0 else { return errno == ENOENT ? .absent : .notRegular }
        return (sb.st_mode & S_IFMT) == S_IFREG ? .regular(Int64(sb.st_size)) : .notRegular
    }

    /// A tool's stderr as one bounded phrase: its non-blank lines joined
    /// with " · ", at most 300 characters.
    nonisolated static func flat(_ stderr: String) -> String {
        let joined = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return joined.count > 300 ? String(joined.prefix(300)) + "…" : joined
    }

    /// Why rsync did not copy: always its exit code (the runner reports a
    /// signal death as the signal number), then its own words — or that it
    /// printed none (GH #506 item 3: a SIGKILL used to read "rsync: " and
    /// nothing after it).
    nonisolated static func rsyncReason(exitCode: Int32, stderr: String) -> String {
        let words = flat(stderr)
        return words.isEmpty ? "rsync exit \(exitCode) (it printed no message)" : "rsync exit \(exitCode): \(words)"
    }

    /// What is at the destination after a transfer that failed or was
    /// stopped. Nothing there is moved or removed: a file found at the
    /// final name is reported, never touched and never counted.
    nonisolated static func leftAtDestination(final: DiskEntry, partialBytes: Int64?, sourceSize: Int64?) -> String {
        let parked: String? = partialBytes.map { bytes in
            let of = sourceSize.map { " of \($0)" } ?? ""
            return "\(bytes)\(of) bytes kept in \(partialDirName) for the next run"
        }
        switch final {
        case .absent:
            return parked.map { "nothing at the final name; \($0)." } ?? "nothing was left."
        case .notRegular:
            return "the final name is not a regular file; it was left untouched" + (parked.map { "; \($0)." } ?? ".")
        case .regular(let bytes):
            let source = sourceSize.map { "the source is \($0) bytes" } ?? "the source could not be measured"
            return "a file of \(bytes) bytes is at the final name (\(source)) — it is not counted as a copy and was left untouched"
                + (parked.map { "; \($0)." } ?? ".")
        }
    }

    /// The line for a file rsync said it copied (exit 0) that the fresh
    /// stat does not find as a regular file of the source's size.
    nonisolated static func notCopiedLine(relative: String, source: DiskEntry, final: DiskEntry, stderr: String) -> String {
        let what: String
        switch (final, source.regularSize) {
        case (.absent, .some):
            what = "nothing is at the destination"
        case (.absent, .none):
            what = "nothing is at the destination, and the source is not a regular file rsync would copy"
        case (.notRegular, _):
            what = "the destination is not a regular file; it was left untouched"
        case (.regular(let bytes), .some(let size)):
            what = "a file of \(bytes) bytes is at the final name, the source is \(size) bytes — a different file, or not a complete copy "
                + "(rsync is told never to replace a file that is there); it was left untouched"
        case (.regular(let bytes), .none):
            what = "a file of \(bytes) bytes is at the final name but the source could not be measured to compare; it was left untouched"
        }
        let said = flat(stderr)
        return "\(relative) — rsync exited 0 but the copy is not there: \(what)" + (said.isEmpty ? "." : " (rsync said: \(said)).")
    }

    // MARK: - Helpers

    /// Size of a file as measured through an open descriptor (fstat on the
    /// thing we actually opened, not a question about a name). nil when it
    /// can't be opened or isn't a regular file.
    nonisolated static func measuredSize(ofFileAt path: String) -> Int64? {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var sb = stat()
        guard fstat(fd, &sb) == 0, (sb.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int64(sb.st_size)
    }

    private nonisolated static func relativePath(_ fullPath: String, under basePath: String, fallback: String) -> String {
        if fullPath.hasPrefix(basePath) {
            let start = fullPath.index(fullPath.startIndex, offsetBy: basePath.count)
            return String(fullPath[start...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return fallback
    }
}

// MARK: - Compare Sheet View

struct VolumeCompareSheet: View {
    @ObservedObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    // Multi-select model: volume paths tagged as source and/or destination.
    // A volume cannot be both (UI enforces); a path never in either set is ignored.
    @State private var selectedSources: Set<String> = []
    @State private var selectedDests: Set<String> = []
    @State private var result: VolumeCompareResult?
    @State private var isComparing = false
    /// Rescue operation lifted to the parent (ContentView) so the copy
    /// task survives when the user dismisses the sheet via "Continue in
    /// Background". @StateObject here would die with the sheet view and
    /// take the running Task with it. @ObservedObject lets the parent
    /// keep ownership; dismissing the sheet just hides the UI.
    @ObservedObject var rescue: VolumeRescueOperation
    @State private var copyMode: RescueCopyMode = .verified
    @State private var showCopyConfirm = false
    @State private var detailFile: VideoRecord?
    /// User-editable destination subfolder name. Defaults to "Rescued"
    /// for back-compat with the pre-2026-06-07 hardcoded behavior.
    @State private var rescueFolderName: String = VolumeRescueOperation.defaultRescueFolderName

    private var volumes: [(label: String, path: String)] {
        var vols: [(String, String)] = []
        for target in model.scanTargets {
            let name = URL(fileURLWithPath: target.searchPath).lastPathComponent
            let status = target.isReachable ? "" : " (offline)"
            vols.append(("\(name)\(status)", target.searchPath))
        }
        return vols
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2).foregroundColor(.accentColor)
                Text("Compare Volumes")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            // Persistent rescue status banner.
            //
            // Shown whenever a copy is in flight regardless of whether
            // the user has run a fresh comparison this sheet open. Solves
            // the case Rick hit 2026-06-07: clicked "Continue in
            // Background", re-opened Compare, and saw the volume picker
            // again rather than his running copy. The progress UI inside
            // resultView wasn't reachable because `result` is sheet-local
            // @State that resets when the sheet is dismissed and reopened.
            // The shared rescue (ObservedObject from ContentView) is the
            // source of truth — surface it at the top so it's always
            // visible.
            if rescue.isRunning || rescue.isDone {
                runningRescueBanner
            }

            if volumes.count < 2 {
                Text("Need at least 2 scan targets to compare. Add volumes or use 'All Volumes Ever Scanned' to restore from catalog.")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                volumeSelector

                Divider()

                // Results
                if isComparing {
                    ProgressView("Comparing…")
                } else if let r = result {
                    resultView(r)
                } else {
                    Text("Select source and destination volumes, then click Compare.")
                        .foregroundColor(.secondary)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .padding()
        .frame(
            minWidth: 900, idealWidth: 1200, maxWidth: .infinity,
            minHeight: 650, idealHeight: 850, maxHeight: .infinity
        )
        .sheet(item: $detailFile) { rec in
            missingFileDetail(rec)
        }
        .alert("Copy Missing Files?", isPresented: $showCopyConfirm) {
            // Folder name input lives inside the alert so Rick can change
            // it from the default "Rescued" before kicking off a multi-hour
            // copy. Empty / whitespace falls back to the default in
            // VolumeRescueOperation.start so we never produce a bad path.
            TextField("Folder name", text: $rescueFolderName)
            Button("Copy", role: .destructive) {
                if let r = result {
                    rescue.start(
                        files: r.missingFiles,
                        sourcePath: r.sourcePath,
                        destPath: r.destPath,
                        mode: copyMode,
                        folderName: rescueFolderName
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let r = result {
                let folderDisplay = rescueFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? VolumeRescueOperation.defaultRescueFolderName : rescueFolderName
                Text("This will copy \(r.sourceOnly) file(s) (\(r.missingHumanSize)) from \(URL(fileURLWithPath: r.sourcePath).lastPathComponent) to \(URL(fileURLWithPath: r.destPath).lastPathComponent)/\(folderDisplay)/\n\nDirectory structure is preserved. Existing files are skipped.")
            }
        }
    }

    @ViewBuilder
    private func resultView(_ r: VolumeCompareResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Summary cards
            HStack(spacing: 20) {
                statCard(title: "Already Safe", count: r.alreadySafeCount, icon: "checkmark.shield.fill", color: .green)
                statCard(title: "Missing — Needs Rescue", count: r.sourceOnly, icon: "exclamationmark.triangle.fill", color: .orange)
                statCard(title: "Data to Copy", value: r.missingHumanSize, icon: "doc.on.doc.fill", color: .blue)
            }

            Divider()

            // File list (scrollable)
            if r.missingFiles.isEmpty {
                // Big-green-everything-is-safe panel — mirrors the
                // Migrate sheet's celebratory empty state so a Compare
                // run after a successful rescue feels like a real "ok
                // you're done" moment instead of a quiet one-line.
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 56))
                        .foregroundColor(.green)
                    Text("All Files Safe")
                        .font(.title2.bold())
                        .foregroundColor(.green)
                    Text("Every file on \(URL(fileURLWithPath: r.sourcePath).lastPathComponent) has a verified copy on \(r.destLabel).")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Source volume could fail and you'd lose nothing.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.green.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.green.opacity(0.35), lineWidth: 1)
                )
            } else {
                Text("Files with no copy on \(r.destLabel) (\(r.sourceOnly)):")
                    .font(.callout.bold())

                List(r.missingFiles.prefix(500)) { rec in
                    Button {
                        detailFile = rec
                    } label: {
                        HStack {
                            Image(systemName: streamIcon(rec.streamType))
                                .foregroundColor(streamColor(rec.streamType))
                                .frame(width: 16)
                            Text(rec.filename).font(.callout).lineLimit(1)
                            Spacer()
                            Text(humanSize(rec.sizeBytes))
                                .font(.callout).foregroundColor(.secondary)
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Click for details")
                }
                .frame(maxHeight: 250)

                if r.missingFiles.count > 500 {
                    Text("…and \(r.missingFiles.count - 500) more")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            Spacer()

            rescueActionBar(r)
        }
    }

    @ViewBuilder
    private func rescueActionBar(_ r: VolumeCompareResult) -> some View {
        if !r.missingFiles.isEmpty && r.isAuditMode {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text("Audit complete. To rescue these files, turn off Audit mode and pick a destination.")
                    .font(.caption).foregroundColor(.secondary)
            }
        } else if !r.missingFiles.isEmpty {
            HStack {
                if rescue.isRunning {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: rescue.progress)
                        HStack {
                            Text("\(rescue.filesCopied)/\(r.sourceOnly) files")
                                .font(.caption)
                            Spacer()
                            Text(rescue.currentFile).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                    // "Continue in Background" — dismisses the sheet so
                    // Rick can use the rest of the app while the copy
                    // (which can take hours for a TB-class transfer) keeps
                    // running. Reopening Compare shows the live progress
                    // again. The task survives because @StateObject rescue
                    // is owned by the sheet view, which stays in memory
                    // even when the sheet is hidden.
                    Button("Continue in Background") { dismiss() }
                        .buttonStyle(.bordered)
                        .help("Hide this dialog and keep copying. Reopen Compare to check progress or cancel.")
                    Button("Cancel") { rescue.cancel() }
                        .buttonStyle(.bordered)
                        .help("Stop the copy now. The file in flight is aborted (rsync gets SIGTERM); what it had written is kept in a .videoscan-partial folder beside the destination — never under the file's final name — and the next run resumes from it.")
                } else if rescue.isDone {
                    HStack {
                        Image(systemName: rescue.wasStopped || rescue.filesFailed > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundColor(rescue.wasStopped || rescue.filesFailed > 0 ? .orange : .green)
                        Text(VolumeRescueOperation.doneTitle(stopped: rescue.wasStopped, failed: rescue.filesFailed))
                            .font(.callout)
                    }
                } else {
                    let srcOnline = model.scanTargets.first(where: { $0.searchPath == r.sourcePath })?.isReachable ?? false

                    Picker("Copy Mode:", selection: $copyMode) {
                        ForEach(RescueCopyMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                    .help(copyMode.description)

                    Button("Copy \(r.sourceOnly) Missing Files") {
                        showCopyConfirm = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!srcOnline)
                    if !srcOnline {
                        Text("Source volume is offline — connect it to copy.")
                            .font(.caption).foregroundColor(.orange)
                    }
                }
            }
        }
    }

    // MARK: - Missing file detail

    @ViewBuilder
    private func missingFileDetail(_ rec: VideoRecord) -> some View {
        let srcLabel = result.map { URL(fileURLWithPath: $0.sourcePath).lastPathComponent } ?? "source"
        let dstLabel = result?.destLabel ?? "destination"
        let otherVolumes = volumesContaining(rec)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: streamIcon(rec.streamType))
                    .foregroundColor(streamColor(rec.streamType))
                Text(rec.filename).font(.headline).lineLimit(2)
                Spacer()
                Button("Close") { detailFile = nil }
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                detailRow(label: "Size", value: humanSize(rec.sizeBytes))
                detailRow(label: "Full path", value: rec.fullPath, mono: true)
                if !rec.partialMD5.isEmpty {
                    detailRow(label: "Partial MD5", value: rec.partialMD5, mono: true)
                }

                HStack(alignment: .top) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    VStack(alignment: .leading) {
                        Text("Exists on: \(srcLabel)").font(.callout)
                        Text(rec.fullPath).font(.caption).foregroundColor(.secondary).lineLimit(2)
                    }
                }

                HStack(alignment: .top) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.orange)
                    Text("Not found on: \(dstLabel)").font(.callout)
                }

                if otherVolumes.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                        Text("No other cataloged volume has a matching copy — this file exists only on \(srcLabel).")
                            .font(.callout)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "shield.lefthalf.filled").foregroundColor(.blue)
                            Text("Matching copy also found on:").font(.callout)
                        }
                        ForEach(otherVolumes, id: \.self) { vol in
                            Text("• \(vol)").font(.caption).foregroundColor(.secondary)
                                .padding(.leading, 22)
                        }
                    }
                }
            }

            Spacer()

            HStack {
                Button {
                    let url = URL(fileURLWithPath: rec.fullPath)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .disabled(!FileManager.default.fileExists(atPath: rec.fullPath))

                Spacer()
            }
        }
        .padding()
        .frame(minWidth: 520, idealWidth: 680, minHeight: 360, idealHeight: 440)
    }

    private func detailRow(label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(mono ? .system(.caption, design: .monospaced) : .callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Scan the full catalog for records matching rec's hash/size or name/size and
    /// return the distinct scan-target volume names that contain such a match,
    /// excluding the record's own volume.
    private func volumesContaining(_ rec: VideoRecord) -> [String] {
        let ownVolume = model.scanTargets
            .map { $0.searchPath }
            .first { rec.fullPath.hasPrefix($0) }

        let hashKey = (!rec.partialMD5.isEmpty && rec.sizeBytes > 0)
            ? "\(rec.partialMD5)|\(rec.sizeBytes)" : nil
        let nameKey = "\(rec.filename.lowercased())|\(rec.sizeBytes)"

        var found: Set<String> = []
        // Global-inert: purged records are not considered when searching for
        // alternate-volume copies. A "removed from catalog" record shouldn't
        // light up as a backup of a live record.
        for other in pfActiveRecords(model.records) {
            if other.fullPath == rec.fullPath { continue }
            let otherHash = (!other.partialMD5.isEmpty && other.sizeBytes > 0)
                ? "\(other.partialMD5)|\(other.sizeBytes)" : nil
            let otherName = "\(other.filename.lowercased())|\(other.sizeBytes)"
            let hashMatch = (hashKey != nil && otherHash == hashKey)
            let nameMatch = (otherName == nameKey)
            guard hashMatch || nameMatch else { continue }

            // Which volume?
            if let vol = model.scanTargets.map({ $0.searchPath }).first(where: { other.fullPath.hasPrefix($0) }) {
                if vol == ownVolume { continue }
                found.insert(URL(fileURLWithPath: vol).lastPathComponent)
            }
        }
        return found.sorted()
    }

    private func statCard(title: String, count: Int? = nil, value: String? = nil, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title2).foregroundColor(color)
            if let c = count {
                Text("\(c)").font(.title3.bold())
            } else if let v = value {
                Text(v).font(.title3.bold())
            }
            Text(title).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func streamIcon(_ st: StreamType) -> String {
        switch st {
        case .videoAndAudio: return "film"
        case .videoOnly: return "video"
        case .audioOnly: return "waveform"
        case .noStreams, .ffprobeFailed: return "exclamationmark.triangle"
        }
    }

    private func streamColor(_ st: StreamType) -> Color {
        switch st {
        case .videoAndAudio: return .blue
        case .videoOnly: return .purple
        case .audioOnly: return .green
        case .noStreams, .ffprobeFailed: return .red
        }
    }

    // MARK: - Multi-select volume picker

    /// One row per known volume with a "Source" and "Destination" toggle.
    /// A volume can be either, but not both — toggling one clears the other.
    @ViewBuilder
    private var volumeSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick which volumes to check and where backups should live.")
                .font(.callout).foregroundColor(.secondary)

            // Header
            HStack {
                Text("Volume").bold().frame(maxWidth: .infinity, alignment: .leading)
                Text("Role / Policy").bold().frame(width: 200, alignment: .leading)
                    .help("Declared role + computed destination policy. Forbidden = RAID-0 / unreliable; discouraged = aging / offline.")
                Text("Source").bold().frame(width: 70, alignment: .center)
                    .help("Check for files that need backing up")
                Text("Dest").bold().frame(width: 70, alignment: .center)
                    .help("Where backups should exist (leave all unchecked for audit mode)")
            }
            .font(.caption).foregroundColor(.secondary)

            Divider()

            // Rows
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(volumes, id: \.path) { v in
                        HStack {
                            Text(v.label)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 6) {
                                if let target = model.scanTargets.first(where: { $0.searchPath == v.path }) {
                                    ObservedVolumeBadge(target: target)
                                    PolicyBadge(policy: target.destinationPolicy)
                                } else {
                                    Text("—").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(width: 200, alignment: .leading)
                            Toggle("", isOn: sourceBinding(for: v.path))
                                .labelsHidden()
                                .frame(width: 70, alignment: .center)
                            Toggle("", isOn: destBinding(for: v.path))
                                .labelsHidden()
                                .frame(width: 70, alignment: .center)
                                .disabled(destDisabled(for: v.path))
                                .help(destDisabledReason(for: v.path) ?? "")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: 200)

            // Mode hint + compare button
            HStack {
                if selectedDests.isEmpty && !selectedSources.isEmpty {
                    Label("Audit mode — checking against every volume outside your source set. Copy disabled.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundColor(.secondary)
                } else if selectedSources.isEmpty {
                    Text("Pick at least one source volume to compare.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Label("\(selectedSources.count) source × \(selectedDests.count) dest — copy enabled when exactly one destination is selected.",
                          systemImage: "checkmark.circle")
                        .font(.caption).foregroundColor(.secondary)
                }

                Spacer()

                Button("Compare") { runCompare() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isComparing || selectedSources.isEmpty)
            }
        }
    }

    private func sourceBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { selectedSources.contains(path) },
            set: { newVal in
                if newVal {
                    selectedSources.insert(path)
                    selectedDests.remove(path)  // mutual exclusion
                } else {
                    selectedSources.remove(path)
                }
            }
        )
    }

    /// Forbidden policies (RAID-0, unreliable drives) block destination selection
    /// to prevent a Compare-and-rescue from being told to copy *to* a fragile or
    /// untrusted drive. The user can lift the block by re-classifying the volume
    /// in the Volumes window.
    private func destDisabled(for path: String) -> Bool {
        guard let target = model.scanTargets.first(where: { $0.searchPath == path }) else {
            return false
        }
        return target.destinationPolicy == .forbidden
    }

    private func destDisabledReason(for path: String) -> String? {
        guard let target = model.scanTargets.first(where: { $0.searchPath == path }) else {
            return nil
        }
        switch target.destinationPolicy {
        case .forbidden:
            if target.mediaTech.isFragile { return "Forbidden: \(target.mediaTech.rawValue) is a fragile destination (no redundancy)." }
            if target.trust == .unreliable { return "Forbidden: this volume is marked Unreliable." }
            return "Forbidden destination — change role/trust in Volumes window to enable."
        case .discouraged:
            return "Discouraged — verify role and reliability in Volumes window before relying on this destination."
        case .acceptable, .preferred:
            return nil
        }
    }

    private func destBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { selectedDests.contains(path) },
            set: { newVal in
                if newVal {
                    selectedDests.insert(path)
                    selectedSources.remove(path)  // mutual exclusion
                } else {
                    selectedDests.remove(path)
                }
            }
        )
    }

    // MARK: - Rescue status banner
    //
    // Persistent at the top of the sheet so an in-flight (or just-
    // finished) copy is visible regardless of the sheet's local
    // result/select state. Restores progress visibility for the case
    // where Rick clicks 'Continue in Background', does other work, and
    // reopens Compare to monitor or cancel.

    @ViewBuilder
    private var runningRescueBanner: some View {
        HStack(spacing: 12) {
            if rescue.isRunning {
                Image(systemName: "doc.on.doc.fill")
                    .foregroundColor(.blue)
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Copying…")
                            .font(.callout.bold())
                        Spacer()
                        Text("\(rescue.filesCopied) files · \(humanSize(rescue.bytesWritten))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    ProgressView(value: rescue.progress)
                    if !rescue.currentFile.isEmpty {
                        Text(rescue.currentFile)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Button("Cancel") { rescue.cancel() }
                    .buttonStyle(.bordered)
                    .help("Stop the copy. Rsync gets SIGTERM and aborts the current file within seconds.")
            } else if rescue.isDone {
                doneBannerBody
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(rescue.isRunning ? Color.blue.opacity(0.08) : Color.green.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(rescue.isRunning ? Color.blue.opacity(0.35) : Color.green.opacity(0.35),
                        lineWidth: 0.5)
        )
    }

    /// Done-state branch of the rescue banner — extracted because the
    /// inline conditional was tripping SwiftUI's type-check timeout
    /// when combined with the running-state branch.
    @ViewBuilder
    private var doneBannerBody: some View {
        let attention = rescue.wasStopped || rescue.filesFailed > 0
        Image(systemName: attention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .foregroundColor(attention ? .orange : .green)
            .imageScale(.large)
        VStack(alignment: .leading, spacing: 2) {
            Text(VolumeRescueOperation.doneTitle(stopped: rescue.wasStopped, failed: rescue.filesFailed))
                .font(.callout.bold())
            Text(VolumeRescueOperation.doneSummary(safe: rescue.filesCopied,
                                                   failed: rescue.filesFailed,
                                                   bytesWritten: rescue.bytesWritten,
                                                   alreadyPresent: rescue.filesAlreadyPresent,
                                                   nameTaken: rescue.filesNameTaken,
                                                   interrupted: rescue.filesInterrupted,
                                                   notAttempted: rescue.filesNotAttempted))
                .font(.caption)
                .foregroundColor(.secondary)
            // The user is told WHICH file and why, not only a count.
            if let detail = VolumeRescueOperation.doneDetail(errors: rescue.errors) {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        Spacer()
        // Catalog gap: the rescue wrote files to disk but the catalog
        // doesn't know about them until the destination volume is
        // scanned. One-click trigger for that scan so Rick doesn't
        // have to remember it. Uses the standard startTarget() entry
        // point so the volume status flips to "Scanning" in the table.
        if let destTarget = rescanDestTarget {
            Button("Re-scan destination") {
                rescueLog.notice("Post-rescue rescan triggered for \(destTarget.searchPath, privacy: .public)")
                model.startTarget(destTarget)
            }
            .buttonStyle(.borderedProminent)
            .help("Scan the destination volume so the freshly-copied files get cataloged. Status appears in Volume Scanner.")
        }
        Button("Dismiss") {
            rescue.acknowledgeCompletion()
        }
        .buttonStyle(.bordered)
    }

    /// Lookup helper — the destination volume target if it's currently
    /// in the model's scan-target list. nil if the destination isn't a
    /// known scan target (rare; user could have removed it between
    /// start and finish).
    private var rescanDestTarget: CatalogScanTarget? {
        guard let destPath = rescue.lastDestPath else { return nil }
        return model.scanTargets.first { $0.searchPath == destPath }
    }

    // MARK: - Compare

    private func runCompare() {
        guard !selectedSources.isEmpty else { return }
        isComparing = true
        defer { isComparing = false }

        // Global-inert: purged records are excluded from the Compare pool.
        // A removed record shouldn't be checked for backups, nor counted as
        // a backup of something else. Filter once at the entry point so the
        // src/dst pairing below never sees them.
        let activeRecords = pfActiveRecords(model.records)

        // Source records: union of everything under any selected source path.
        let srcRecords = activeRecords.filter { rec in
            selectedSources.contains { src in rec.fullPath.hasPrefix(src) }
        }

        // Destination records: either explicit selection, or "everything outside source set" for audit.
        let dstRecords: [VideoRecord]
        let destLabel: String
        if selectedDests.isEmpty {
            dstRecords = activeRecords.filter { rec in
                !selectedSources.contains { src in rec.fullPath.hasPrefix(src) }
            }
            destLabel = "any volume outside the source set"
        } else {
            dstRecords = activeRecords.filter { rec in
                selectedDests.contains { dst in rec.fullPath.hasPrefix(dst) }
            }
            let sortedDests = selectedDests.sorted()
            destLabel = sortedDests.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
        }

        // Copy is only meaningful when exactly one source and exactly one dest are picked:
        //  - Need single source for the relative-path logic in VolumeRescueOperation
        //  - Need single dest for a concrete target directory
        // Everything else is "audit" (report-only).
        let canCopy = selectedSources.count == 1 && selectedDests.count == 1
        let srcPath: String
        if canCopy, let s = selectedSources.first {
            srcPath = s
        } else {
            srcPath = selectedSources.sorted().map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
        }
        let dstPath = canCopy ? (selectedDests.first ?? "") : ""

        result = VolumeComparer.compare(
            sourceRecords: srcRecords,
            destRecords: dstRecords,
            sourcePath: srcPath,
            destPath: dstPath,
            destLabel: destLabel,
            isAuditMode: !canCopy
        )
    }
}

// MARK: - Helpers

private func humanSize(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let units = ["KB", "MB", "GB", "TB"]
    var val = Double(bytes)
    for unit in units {
        val /= 1024
        if val < 1024 || unit == "TB" {
            return String(format: "%.1f %@", val, unit)
        }
    }
    return "\(bytes) B"
}
