// VolumeCompare.swift
// Compare two cataloged volumes and identify media files that exist on one
// but not the other. Primary use case: rescue unique files from aging drives
// before they fail, without blindly copying everything (including duplicates).

import Foundation
import SwiftUI
import Combine
import os

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
    case verified = "Verified (rsync --checksum)"

    var description: String {
        switch self {
        case .fast: return "Uses system copy — fastest, no post-copy checksum"
        case .verified: return "Uses rsync with checksums — slower but guarantees integrity"
        }
    }
}

// MARK: - Copy Engine

@MainActor
final class VolumeRescueOperation: ObservableObject {
    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var currentFile: String = ""
    @Published var filesCopied: Int = 0
    @Published var filesFailed: Int = 0
    @Published var bytesWritten: Int64 = 0
    @Published var errors: [String] = []
    @Published var isDone = false

    private var task: Task<Void, Never>?

    /// Currently-running rsync (or future subprocess) so `cancel()` can
    /// `terminate()` it mid-file. Without this, cancel was "soft" — it
    /// marked the Task cancelled but `proc.waitUntilExit()` blocked until
    /// the in-flight multi-GB rsync finished, which felt like a hung app.
    /// Rick force-quit the app 2026-06-07 trying to cancel a copy.
    /// `nonisolated(unsafe)` because we set it on the rsync helper actor
    /// boundary and read it on MainActor cancel — single producer / single
    /// reader, manual sync via task-cancellation semantics.
    nonisolated(unsafe) private var currentProcess: Process?

    /// Default subfolder name on the destination. Used as the placeholder
    /// in the Compare UI's "Folder name" TextField. The folder is created
    /// under destPath, then the source's relative directory structure
    /// preserved underneath.
    static let defaultRescueFolderName = "Rescued"

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
        errors = []
        currentProcess = nil
        // Remember destination so post-completion UX can trigger a
        // rescan of the volume that just received the files.
        lastDestPath = destPath

        // Snapshot up front: VideoRecord is a class and capturing it across
        // an actor boundary trips strict-concurrency. Sendable snapshots
        // carry every field these copy paths read.
        let snapshots = files.snapshots()
        let total = snapshots.count
        // Sanitize the folder name — empty or whitespace falls back to
        // the default so we never produce a path with a missing component.
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeFolder = trimmed.isEmpty ? Self.defaultRescueFolderName : trimmed
        let started = Date()
        let totalBytesPlanned = snapshots.reduce(Int64(0)) { $0 + $1.sizeBytes }
        rescueLog.notice("Rescue start: \(total, privacy: .public) files, \(humanSize(totalBytesPlanned), privacy: .public) → \(destPath, privacy: .public)/\(safeFolder, privacy: .public) (mode=\(mode.rawValue, privacy: .public))")
        task = Task { [weak self] in
            let fm = FileManager.default

            // Create destination root if needed
            let rescueDir = (destPath as NSString).appendingPathComponent(safeFolder)
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
                rescueLog.notice("Rescue done: copied=\(self.filesCopied, privacy: .public) failed=\(self.filesFailed, privacy: .public) bytes=\(humanSize(self.bytesWritten), privacy: .public) elapsed=\(Int(elapsed), privacy: .public)s")
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
        currentFile = ""
    }

    /// Destination path the most-recent rescue wrote to. Used by the
    /// post-rescue UX so we can offer (or auto-trigger) a rescan of
    /// that destination volume to catalog the freshly-copied files.
    /// nil before the first rescue.
    @Published private(set) var lastDestPath: String?

    /// Stop a running copy as fast as possible. Calls Task.cancel() (which
    /// stops the loop between files) AND `terminate()` on the current
    /// rsync subprocess (which kills the in-flight transfer mid-file).
    /// Without the latter, cancel was effectively "stop after this file"
    /// which meant several minutes of "did it cancel?" UI for large MXFs.
    func cancel() {
        let hadProc = currentProcess != nil
        task?.cancel()
        if let proc = currentProcess, proc.isRunning {
            proc.terminate()
        }
        currentProcess = nil
        rescueLog.notice("Rescue cancel requested (hadProc=\(hadProc, privacy: .public))")
        // isRunning is flipped by the task's completion block once it
        // observes the cancellation. Leaving it true here keeps any
        // re-issued start() guard intact until cleanup lands.
    }

    // MARK: - Fast Copy (FileManager)

    private nonisolated func fastCopy(files: [VideoRecordSnapshot], sourcePath: String, rescueDir: String, total: Int) async {
        let fm = FileManager.default

        for (idx, rec) in files.enumerated() {
            if Task.isCancelled { break }

            let srcFile = rec.fullPath
            let filename = rec.filename
            let sizeBytes = rec.sizeBytes
            let relative = Self.relativePath(srcFile, under: sourcePath, fallback: filename)
            let destFile = (rescueDir as NSString).appendingPathComponent(relative)
            let destDir = (destFile as NSString).deletingLastPathComponent
            let progressFraction = Double(idx) / Double(total)

            await MainActor.run { [weak self] in
                self?.currentFile = filename
                self?.progress = progressFraction
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

            if fm.fileExists(atPath: destFile) {
                await MainActor.run { [weak self] in
                    self?.filesCopied += 1
                    self?.bytesWritten += sizeBytes
                }
                continue
            }

            do {
                try fm.copyItem(atPath: srcFile, toPath: destFile)
                await MainActor.run { [weak self] in
                    self?.filesCopied += 1
                    self?.bytesWritten += sizeBytes
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.filesFailed += 1
                    self?.errors.append("\(relative) — \(error.localizedDescription)")
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
            let sizeBytes = rec.sizeBytes
            let relative = Self.relativePath(srcFile, under: sourcePath, fallback: filename)
            let destFile = (rescueDir as NSString).appendingPathComponent(relative)
            let destDir = (destFile as NSString).deletingLastPathComponent
            let progressFraction = Double(idx) / Double(total)

            await MainActor.run { [weak self] in
                self?.currentFile = filename
                self?.progress = progressFraction
            }

            // Create destination directory
            let mkdirProc = Process()
            mkdirProc.executableURL = URL(fileURLWithPath: "/bin/mkdir")
            mkdirProc.arguments = ["-p", destDir]
            do {
                try mkdirProc.run()
                mkdirProc.waitUntilExit()
            } catch {
                await MainActor.run { [weak self] in
                    self?.filesFailed += 1
                    self?.errors.append("mkdir failed: \(relative) — \(error.localizedDescription)")
                }
                continue
            }

            // rsync with checksum verification
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
            proc.arguments = [
                "--checksum",       // verify with checksum, not just size/mtime
                "--partial",        // keep partial transfers for resume
                "--times",          // preserve modification times
                srcFile,
                destFile
            ]

            let errPipe = Pipe()
            proc.standardError = errPipe

            // Hand the running process to the actor so cancel() can kill
            // it mid-transfer (rsync responds to SIGTERM by aborting the
            // current chunk, which is what the user expects when they
            // click Cancel on a multi-GB file).
            await MainActor.run { [weak self] in
                self?.currentProcess = proc
            }
            do {
                try proc.run()
                proc.waitUntilExit()
                await MainActor.run { [weak self] in
                    if self?.currentProcess === proc {
                        self?.currentProcess = nil
                    }
                }

                if proc.terminationStatus == 0 {
                    await MainActor.run { [weak self] in
                        self?.filesCopied += 1
                        self?.bytesWritten += sizeBytes
                    }
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(proc.terminationStatus)"
                    await MainActor.run { [weak self] in
                        self?.filesFailed += 1
                        self?.errors.append("\(relative) — rsync: \(errMsg)")
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    if self?.currentProcess === proc {
                        self?.currentProcess = nil
                    }
                    self?.filesFailed += 1
                    self?.errors.append("\(relative) — \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Helpers

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
                        .help("Stop the copy now. In-flight files will be aborted (rsync gets SIGTERM); partial copies are kept under the destination folder for resume.")
                } else if rescue.isDone {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text("Done — \(rescue.filesCopied) copied, \(rescue.filesFailed) failed")
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
        Image(systemName: "checkmark.circle.fill")
            .foregroundColor(.green)
            .imageScale(.large)
        VStack(alignment: .leading, spacing: 2) {
            Text("Copy finished")
                .font(.callout.bold())
            Text("\(rescue.filesCopied) copied · \(rescue.filesFailed) failed · \(humanSize(rescue.bytesWritten))")
                .font(.caption)
                .foregroundColor(.secondary)
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
            .help("Scan the destination volume so the freshly-copied files get cataloged. Status appears in the Scan Volumes table.")
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
