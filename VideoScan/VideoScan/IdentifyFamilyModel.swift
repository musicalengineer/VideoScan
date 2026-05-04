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
        // CRITICAL: split on ANY newline, not just "\n". Python's csv writer
        // emits CRLF; Swift treats "\r\n" as a single extended grapheme
        // cluster, so split(separator: "\n") finds zero matches and returns
        // the whole file as one substring (parsed=0, silent failure).
        let lines = text.split(
            omittingEmptySubsequences: true,
            whereSeparator: { $0.isNewline }
        )
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

    // MARK: - Promote to POI (Step 2 of family-id plan)

    /// One planned action for a single named cluster — drives the
    /// confirmation sheet so the user can review before any filesystem
    /// mutation. Generated by `planPromotion()`, executed by `executePromotion()`.
    enum PromotionAction: Identifiable {
        case create(clusterID: Int, name: String, faceCount: Int)
        case merge(clusterID: Int, name: String, faceCount: Int, existingCount: Int)
        case skip(clusterID: Int, reason: String)

        var id: Int {
            switch self {
            case .create(let cid, _, _), .merge(let cid, _, _, _), .skip(let cid, _): return cid
            }
        }
    }

    /// Inspect named clusters and decide what would happen if the user
    /// confirmed promotion — without touching any files. The returned list
    /// drives the confirmation sheet.
    func planPromotion() -> [PromotionAction] {
        let existing = Set(POIProfile.listAll().map { POIStorage.sanitize($0.name) })
        var plan: [PromotionAction] = []
        for c in clusters where c.id != -1 {
            let trimmed = c.name.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                plan.append(.skip(clusterID: c.id, reason: "no name"))
                continue
            }
            let key = POIStorage.sanitize(trimmed)
            if existing.contains(key) {
                let existingFaces = (try? FileManager.default.contentsOfDirectory(
                    at: POIStorage.folder(for: trimmed),
                    includingPropertiesForKeys: nil
                ))?.filter { isImageFile($0) }.count ?? 0
                plan.append(.merge(
                    clusterID: c.id, name: trimmed,
                    faceCount: c.faceCount,
                    existingCount: existingFaces
                ))
            } else {
                plan.append(.create(
                    clusterID: c.id, name: trimmed, faceCount: c.faceCount
                ))
            }
        }
        return plan
    }

    /// Execute an approved plan: copy face crops into POI folders,
    /// create profile.json for new POIs, persist a breadcrumb in
    /// cluster_names.json so later steps (active learning) can trace
    /// which faces came from which cluster.
    /// Returns a summary string for the toast/log.
    func executePromotion(_ plan: [PromotionAction]) -> String {
        let runNameForBreadcrumb = runName
        var created = 0, merged = 0, copiedFaces = 0
        var breadcrumb: [String: [String: String]] = [:]
        let isoFormatter = ISO8601DateFormatter()
        let timestamp = isoFormatter.string(from: Date())

        for action in plan {
            switch action {
            case .skip:
                continue
            case .create(let cid, let name, _), .merge(let cid, let name, _, _):
                guard let cluster = clusters.first(where: { $0.id == cid }) else { continue }
                let copied = copyClusterFacesToPOI(cluster: cluster, poiName: name)
                copiedFaces += copied

                if case .create = action {
                    var profile = POIProfile(
                        name: name,
                        referencePath: POIStorage.folder(for: name).path
                    )
                    if let coverFile = pickCoverFilename(in: POIStorage.folder(for: name)) {
                        profile.coverImageFilename = coverFile
                    }
                    try? profile.save()
                    created += 1
                } else {
                    merged += 1
                }

                let key = String(format: "cluster_%03d", cid)
                breadcrumb[key] = [
                    "name": name,
                    "promoted_to_poi": name,
                    "promoted_at": timestamp,
                    "promoted_from_run": runNameForBreadcrumb
                ]
            }
        }

        // Persist the breadcrumb alongside cluster_names.json so it's
        // discoverable next to the original clustering output.
        if !breadcrumb.isEmpty, let runDir {
            let url = runDir.appendingPathComponent("cluster_promotions.json")
            if let data = try? JSONSerialization.data(
                withJSONObject: breadcrumb, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url)
            }
        }

        return "Promoted: \(created) new POI, \(merged) merged, \(copiedFaces) faces copied."
    }

    /// Copy every image file in a cluster directory into the named POI's
    /// reference folder. Filenames are prefixed with the run + cluster id
    /// so re-promoting the same cluster overwrites cleanly (idempotent).
    /// Returns the number of files copied.
    private func copyClusterFacesToPOI(cluster: FaceCluster, poiName: String) -> Int {
        let dest = POIStorage.folder(for: poiName)
        try? FileManager.default.createDirectory(
            at: dest, withIntermediateDirectories: true)
        let runTag = POIStorage.sanitize(runName)
        let cidTag = String(format: "%03d", cluster.id)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cluster.directoryURL, includingPropertiesForKeys: nil
        ) else { return 0 }
        var copied = 0
        for src in entries where isImageFile(src) {
            let suffix = src.lastPathComponent
            let destURL = dest.appendingPathComponent(
                "cluster_\(runTag)_\(cidTag)_\(suffix)"
            )
            try? FileManager.default.removeItem(at: destURL)  // idempotent
            do {
                try FileManager.default.copyItem(at: src, to: destURL)
                copied += 1
            } catch {
                // Single-file failure shouldn't abort the whole batch.
                continue
            }
        }
        return copied
    }

    /// Pick a cover image from the POI folder — largest file by bytes is a
    /// decent proxy for sharpest/biggest face crop in absence of richer
    /// metadata. Caller already ensured the folder exists.
    private func pickCoverFilename(in folder: URL) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return nil }
        let images = entries.filter { isImageFile($0) }
        let withSize = images.compactMap { url -> (URL, Int)? in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return (url, size)
        }
        return withSize.max(by: { $0.1 < $1.1 })?.0.lastPathComponent
    }

    private func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "heic", "heif"].contains(ext)
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
