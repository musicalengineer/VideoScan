// VolumeCompare.swift
// Compare two cataloged volumes and identify media files that exist on one
// but not the other. Primary use case: rescue unique files from aging drives
// before they fail, without blindly copying everything (including duplicates).

import Foundation
import SwiftUI
import Combine

// MARK: - Comparison Result

struct VolumeCompareResult {
    let sourcePath: String
    let destPath: String
    let missingFiles: [VideoRecord]       // on source, NOT on destination
    let alreadySafe: [VideoRecord]        // on source AND destination
    let sourceOnly: Int                   // count for quick display
    let alreadySafeCount: Int
    let totalSourceBytes: Int64
    let missingBytes: Int64

    var missingHumanSize: String { humanSize(missingBytes) }
    var totalHumanSize: String { humanSize(totalSourceBytes) }
}

// MARK: - Comparison Engine

enum VolumeComparer {

    /// Compare source volume against destination volume using catalog records.
    /// A file is "already safe" if destination has a record with matching
    /// (partialMD5 + sizeBytes) OR (filename + sizeBytes) when MD5 is unavailable.
    static func compare(
        sourceRecords: [VideoRecord],
        destRecords: [VideoRecord],
        sourcePath: String,
        destPath: String
    ) -> VolumeCompareResult {
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

        for rec in sourceRecords {
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
            missingFiles: missing,
            alreadySafe: safe,
            sourceOnly: missing.count,
            alreadySafeCount: safe.count,
            totalSourceBytes: totalBytes,
            missingBytes: missingBytes
        )
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

    /// Copy missing files from source volume to a destination folder.
    /// Preserves relative directory structure under the volume root.
    func start(files: [VideoRecord], sourcePath: String, destPath: String) {
        guard !isRunning else { return }
        isRunning = true
        isDone = false
        progress = 0
        filesCopied = 0
        filesFailed = 0
        bytesWritten = 0
        errors = []

        let total = files.count
        task = Task { [weak self] in
            let fm = FileManager.default

            // Create destination root if needed
            let rescueDir = (destPath as NSString).appendingPathComponent("Rescued")
            try? fm.createDirectory(atPath: rescueDir, withIntermediateDirectories: true)

            for (idx, rec) in files.enumerated() {
                if Task.isCancelled { break }

                let srcFile = rec.fullPath
                // Relative path from volume root
                let relative: String
                if srcFile.hasPrefix(sourcePath) {
                    let start = srcFile.index(srcFile.startIndex, offsetBy: sourcePath.count)
                    relative = String(srcFile[start...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                } else {
                    relative = rec.filename
                }

                let destFile = (rescueDir as NSString).appendingPathComponent(relative)
                let destDir = (destFile as NSString).deletingLastPathComponent

                await MainActor.run { [weak self] in
                    self?.currentFile = rec.filename
                    self?.progress = Double(idx) / Double(total)
                }

                // Create intermediate directories
                do {
                    try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
                } catch {
                    await MainActor.run { [weak self] in
                        self?.filesFailed += 1
                        self?.errors.append("mkdir failed: \(relative) — \(error.localizedDescription)")
                    }
                    continue
                }

                // Skip if already exists at destination
                if fm.fileExists(atPath: destFile) {
                    await MainActor.run { [weak self] in
                        self?.filesCopied += 1
                        self?.bytesWritten += rec.sizeBytes
                    }
                    continue
                }

                // Copy
                do {
                    try fm.copyItem(atPath: srcFile, toPath: destFile)
                    await MainActor.run { [weak self] in
                        self?.filesCopied += 1
                        self?.bytesWritten += rec.sizeBytes
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.filesFailed += 1
                        self?.errors.append("\(relative) — \(error.localizedDescription)")
                    }
                }
            }

            await MainActor.run { [weak self] in
                self?.progress = 1.0
                self?.isRunning = false
                self?.isDone = true
                self?.currentFile = ""
            }
        }
    }

    func cancel() {
        task?.cancel()
        isRunning = false
    }
}

// MARK: - Compare Sheet View

struct VolumeCompareSheet: View {
    @ObservedObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    @State private var sourceIdx: Int = 0
    @State private var destIdx: Int = 1
    @State private var result: VolumeCompareResult?
    @State private var isComparing = false
    @StateObject private var rescue = VolumeRescueOperation()
    @State private var showCopyConfirm = false

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
                Text("Volume Compare & Rescue")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if volumes.count < 2 {
                Text("Need at least 2 scan targets to compare. Add volumes or use 'All Volumes Ever Scanned' to restore from catalog.")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                // Volume pickers
                HStack(spacing: 20) {
                    VStack(alignment: .leading) {
                        Text("Source (old drive)").font(.caption).foregroundColor(.secondary)
                        Picker("Source", selection: $sourceIdx) {
                            ForEach(0..<volumes.count, id: \.self) { i in
                                Text(volumes[i].label).tag(i)
                            }
                        }
                        .labelsHidden()
                    }

                    Image(systemName: "arrow.right")
                        .font(.title2).foregroundColor(.secondary)

                    VStack(alignment: .leading) {
                        Text("Destination (new drive)").font(.caption).foregroundColor(.secondary)
                        Picker("Destination", selection: $destIdx) {
                            ForEach(0..<volumes.count, id: \.self) { i in
                                Text(volumes[i].label).tag(i)
                            }
                        }
                        .labelsHidden()
                    }

                    Button("Compare") {
                        runCompare()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sourceIdx == destIdx || isComparing)
                }

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
        .frame(minWidth: 700, minHeight: 500)
        .alert("Copy Missing Files?", isPresented: $showCopyConfirm) {
            Button("Copy", role: .destructive) {
                if let r = result {
                    rescue.start(files: r.missingFiles, sourcePath: r.sourcePath, destPath: r.destPath)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let r = result {
                Text("This will copy \(r.sourceOnly) file(s) (\(r.missingHumanSize)) from \(URL(fileURLWithPath: r.sourcePath).lastPathComponent) to \(URL(fileURLWithPath: r.destPath).lastPathComponent)/Rescued/\n\nDirectory structure is preserved. Existing files are skipped.")
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
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("All source media files are already on the destination!")
                        .font(.callout)
                }
                .padding()
            } else {
                Text("Missing files (\(r.sourceOnly)):")
                    .font(.callout.bold())

                List(r.missingFiles.prefix(500)) { rec in
                    HStack {
                        Image(systemName: streamIcon(rec.streamType))
                            .foregroundColor(streamColor(rec.streamType))
                            .frame(width: 16)
                        Text(rec.filename).font(.callout).lineLimit(1)
                        Spacer()
                        Text(humanSize(rec.sizeBytes))
                            .font(.callout).foregroundColor(.secondary)
                    }
                }
                .frame(maxHeight: 250)

                if r.missingFiles.count > 500 {
                    Text("…and \(r.missingFiles.count - 500) more")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            Spacer()

            // Action bar
            if !r.missingFiles.isEmpty {
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
                        Button("Cancel") { rescue.cancel() }
                            .buttonStyle(.bordered)
                    } else if rescue.isDone {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("Done — \(rescue.filesCopied) copied, \(rescue.filesFailed) failed")
                                .font(.callout)
                        }
                    } else {
                        let srcOnline = model.scanTargets.first(where: { $0.searchPath == r.sourcePath })?.isReachable ?? false
                        Button("Copy \(r.sourceOnly) Missing Files to Destination") {
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

    private func runCompare() {
        guard sourceIdx != destIdx else { return }
        isComparing = true

        let srcPath = volumes[sourceIdx].path
        let dstPath = volumes[destIdx].path

        let srcRecords = model.records.filter { $0.fullPath.hasPrefix(srcPath) }
        let dstRecords = model.records.filter { $0.fullPath.hasPrefix(dstPath) }

        result = VolumeComparer.compare(
            sourceRecords: srcRecords,
            destRecords: dstRecords,
            sourcePath: srcPath,
            destPath: dstPath
        )
        isComparing = false
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
