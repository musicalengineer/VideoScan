// IdentifyFamilyModel.swift
// Drives scripts/cluster_faces.py and exposes its progress + clusters to SwiftUI.
//
// Workflow: pick folder → spawn cluster_faces.py via venv Python → stream stdout
// for live progress → on success, parse cluster_summary.csv and load each
// cluster's grid.jpg as a thumbnail → present clusters for the user to name.

import Foundation
import AppKit
import Combine

@MainActor
final class IdentifyFamilyModel: ObservableObject {

    // MARK: - State machine

    enum Phase: Equatable {
        case idle
        case scanning      // collecting faces from videos
        case clustering    // HDBSCAN running (brief, no per-step progress)
        case reviewing     // clusters loaded, user is naming them
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var selectedFolder: URL?
    @Published var runName: String = ""
    @Published private(set) var runDir: URL?

    // Live progress while scanning
    @Published private(set) var totalVideos: Int = 0
    @Published private(set) var processedVideos: Int = 0
    @Published private(set) var totalFaces: Int = 0
    @Published private(set) var currentFile: String = ""
    @Published private(set) var consoleLines: [String] = []
    @Published private(set) var scanStartedAt: Date?
    @Published private(set) var elapsedSecs: TimeInterval = 0
    private var elapsedTimer: Timer?

    // Review phase
    @Published var clusters: [FaceCluster] = []
    /// One-line summary from the last loadClusters() attempt — surfaced in the
    /// review view when the cluster list comes up empty so silent parse
    /// failures stop being silent.
    @Published private(set) var lastLoadDiagnostic: String = ""

    // MARK: - Subprocess plumbing

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = ""

    // MARK: - Paths (anchored to ~/dev/VideoScan)

    /// Use python3.12 explicitly: the venv's `python` symlink points at 3.14
    /// after a Homebrew upgrade, but every torch/facenet/hdbscan package is
    /// installed under the 3.12 site-packages. The script's shebang is
    /// `#!/usr/bin/env python3.12` for the same reason.
    private var pythonPath: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("dev/VideoScan/venv/bin/python3.12")
    }
    private var scriptPath: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("dev/VideoScan/scripts/cluster_faces.py")
    }
    private var outputRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("dev/VideoScan/output/cluster_faces")
    }

    // MARK: - Public actions

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Pick a folder of videos to scan for faces"
        if panel.runModal() == .OK, let url = panel.url {
            selectedFolder = url
            if runName.isEmpty {
                runName = url.lastPathComponent
                    .replacingOccurrences(of: " ", with: "_")
            }
        }
    }

    func startScan() {
        guard let folder = selectedFolder else { return }
        let trimmedName = runName.trimmingCharacters(in: .whitespaces)
        let effectiveName = trimmedName.isEmpty
            ? folder.lastPathComponent.replacingOccurrences(of: " ", with: "_")
            : trimmedName
        runName = effectiveName
        runDir = outputRoot.appendingPathComponent(effectiveName)

        consoleLines.removeAll()
        clusters.removeAll()
        processedVideos = 0
        totalVideos = 0
        totalFaces = 0
        currentFile = ""
        scanStartedAt = Date()
        elapsedSecs = 0
        startElapsedTimer()
        phase = .scanning

        launch(folder: folder, runName: effectiveName)
    }

    func cancel() {
        process?.terminate()
        process = nil
        stopElapsedTimer()
        phase = .idle
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        let started = scanStartedAt ?? Date()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsedSecs = Date().timeIntervalSince(started) }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    /// Average faces extracted per second. Returns nil when too early to estimate.
    var facesPerSecond: Double? {
        guard elapsedSecs > 1, totalFaces > 0 else { return nil }
        return Double(totalFaces) / elapsedSecs
    }

    /// ETA for scanning phase, based on per-video rate. Nil until at least one
    /// video has been processed and total is known.
    var scanETA: TimeInterval? {
        guard processedVideos > 0,
              totalVideos > processedVideos,
              elapsedSecs > 1 else { return nil }
        let remaining = totalVideos - processedVideos
        let perVideo = elapsedSecs / Double(processedVideos)
        return Double(remaining) * perVideo
    }

    func resetToIdle() {
        phase = .idle
    }

    /// Names of every run dir under output/cluster_faces that has a
    /// cluster_summary.csv (i.e. completed clustering at least once).
    func listExistingRuns() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: outputRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return entries.compactMap { url -> String? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue,
                  fm.fileExists(atPath: url.appendingPathComponent("cluster_summary.csv").path)
            else { return nil }
            return url.lastPathComponent
        }.sorted()
    }

    /// Load an already-clustered run into the review view without re-scanning.
    /// Useful when a previous run completed (or partially completed) and we
    /// want to inspect the clusters without re-running collection.
    func loadExistingRun(named name: String) {
        let dir = outputRoot.appendingPathComponent(name)
        runName = name
        runDir = dir
        loadClusters()
    }

    // MARK: - Process launch + streaming

    private func launch(folder: URL, runName: String) {
        guard FileManager.default.fileExists(atPath: scriptPath.path) else {
            phase = .failed("Script missing: \(scriptPath.path)")
            return
        }
        guard FileManager.default.fileExists(atPath: pythonPath.path) else {
            phase = .failed("Python venv missing: \(pythonPath.path)")
            return
        }

        let proc = Process()
        proc.executableURL = pythonPath
        proc.arguments = [
            "-u",                 // unbuffered stdout/stderr — without this, Python
            scriptPath.path,      // line-buffers when piped to a non-TTY subprocess
            folder.path,          // and Swift sees nothing for ~8KB at a time, which
            "--run-name", runName // makes the UI freeze at "Videos 0/0".
        ]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.absorbStdout(text) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendConsole(text) }
        }

        proc.terminationHandler = { [weak self] p in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in self?.handleTermination(status: p.terminationStatus) }
        }

        process = proc
        stdoutPipe = outPipe
        stderrPipe = errPipe

        do {
            try proc.run()
        } catch {
            phase = .failed("Failed to launch: \(error.localizedDescription)")
        }
    }

    private func absorbStdout(_ text: String) {
        stdoutBuffer += text
        while let range = stdoutBuffer.range(of: "\n") {
            let line = String(stdoutBuffer[..<range.lowerBound])
            stdoutBuffer.removeSubrange(..<range.upperBound)
            handleStdoutLine(line)
        }
    }

    private func handleStdoutLine(_ line: String) {
        appendConsole(line + "\n")

        // [scan] N videos under <root>
        if line.hasPrefix("[scan] "),
           let count = firstIntInWords(line) {
            totalVideos = count
        }

        // [i/N] <filename>: K faces (total T)
        // Parse leading [i/N]
        if line.hasPrefix("["),
           let close = line.firstIndex(of: "]") {
            let inside = line[line.index(after: line.startIndex)..<close]
            let parts = inside.split(separator: "/")
            if parts.count == 2, let i = Int(parts[0]), let n = Int(parts[1]) {
                processedVideos = i
                totalVideos = n
                let rest = line[line.index(after: close)...]
                    .trimmingCharacters(in: .whitespaces)
                if let colon = rest.firstIndex(of: ":") {
                    currentFile = String(rest[..<colon])
                }
                if let totalRange = line.range(of: "(total ") {
                    let after = line[totalRange.upperBound...]
                    if let closeP = after.firstIndex(of: ")") {
                        if let n = Int(after[..<closeP]) { totalFaces = n }
                    }
                }
            }
        }

        // [scan-done] N faces from M videos
        if line.hasPrefix("[scan-done]") {
            phase = .clustering
        }

        // [done] cluster_summary.csv at <path>
        if line.hasPrefix("[done]") {
            // Final results ready, but wait for process termination to load.
        }
    }

    private func appendConsole(_ chunk: String) {
        // Keep last 500 lines to bound memory.
        let lines = chunk.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines where !line.isEmpty {
            consoleLines.append(String(line))
        }
        if consoleLines.count > 500 {
            consoleLines.removeFirst(consoleLines.count - 500)
        }
    }

    private func handleTermination(status: Int32) {
        process = nil
        stopElapsedTimer()
        if status == 0 {
            loadClusters()
        } else if case .scanning = phase {
            phase = .failed("Process exited with status \(status)")
        } else if case .clustering = phase {
            phase = .failed("Process exited with status \(status)")
        }
        // If user cancelled (.idle), leave alone.
    }

    // MARK: - Result loading

    private func loadClusters() {
        guard let runDir else {
            phase = .failed("No run directory")
            return
        }
        let summaryURL = runDir.appendingPathComponent("cluster_summary.csv")
        guard let text = try? String(contentsOf: summaryURL, encoding: .utf8) else {
            phase = .failed("Could not read \(summaryURL.lastPathComponent)")
            return
        }

        // CSV columns: cluster_id, rank, face_count, video_count,
        // videos_sample (quoted, may contain commas), thumb_dir.
        // The script names cluster directories by rank (cluster_001, ...),
        // not cluster_id, so we use the thumb_dir column directly.
        var parsed: [FaceCluster] = []
        var rejectedRows = 0
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for (i, raw) in lines.enumerated() where i > 0 {
            let cols = parseCSVRow(String(raw))
            guard cols.count >= 6,
                  let id = Int(cols[0]),
                  let faceCount = Int(cols[2]),
                  let videoCount = Int(cols[3]) else {
                rejectedRows += 1
                continue
            }
            let thumbDir = cols[5]
            let dir = runDir.appendingPathComponent(thumbDir)
            let grid = dir.appendingPathComponent("grid.jpg")
            parsed.append(FaceCluster(
                id: id,
                faceCount: faceCount,
                videoCount: videoCount,
                gridImageURL: FileManager.default.fileExists(atPath: grid.path) ? grid : nil,
                directoryURL: dir,
                name: ""
            ))
        }
        // Sort: real clusters by face count desc, noise (id == -1) last.
        clusters = parsed.sorted { lhs, rhs in
            if lhs.id == -1 { return false }
            if rhs.id == -1 { return true }
            return lhs.faceCount > rhs.faceCount
        }
        let dataRows = max(lines.count - 1, 0)
        let real = parsed.filter { $0.id != -1 }.count
        let noise = parsed.first(where: { $0.id == -1 })?.faceCount ?? 0
        lastLoadDiagnostic = "CSV \(text.count)B, \(dataRows) data row(s), parsed \(parsed.count) (rejected \(rejectedRows)). Real clusters: \(real). Noise faces: \(noise)."
        phase = .reviewing
    }

    /// Minimal CSV row parser that respects quoted fields (which may contain
    /// commas). Doesn't handle escaped quotes since the script doesn't emit any.
    private func parseCSVRow(_ row: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for ch in row {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Naming

    func setName(_ name: String, for clusterID: Int) {
        if let idx = clusters.firstIndex(where: { $0.id == clusterID }) {
            clusters[idx].name = name
        }
    }

    func saveNames() {
        guard let runDir else { return }
        let mapping = clusters.reduce(into: [String: String]()) { dict, c in
            let key = c.id == -1 ? "noise" : String(format: "cluster_%03d", c.id)
            dict[key] = c.name
        }
        let url = runDir.appendingPathComponent("cluster_names.json")
        if let data = try? JSONSerialization.data(
            withJSONObject: mapping, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    // MARK: - Helpers

    private func firstIntInWords(_ s: String) -> Int? {
        for word in s.split(separator: " ") {
            if let n = Int(word) { return n }
        }
        return nil
    }
}

// MARK: - Cluster value type

struct FaceCluster: Identifiable, Equatable {
    let id: Int
    let faceCount: Int
    let videoCount: Int
    let gridImageURL: URL?
    let directoryURL: URL
    var name: String
}
