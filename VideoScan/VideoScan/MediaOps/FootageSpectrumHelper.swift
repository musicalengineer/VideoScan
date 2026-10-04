// FootageSpectrumHelper.swift
// How "Compare Footage…" finds and runs its helper, and where its files go
// (Footage Spectrum trial, 2026-10-03).
//
//   FootageSpectrumHelper  — the Python + script + ffmpeg the job needs,
//                            found the way the app finds its OTHER Python
//                            helpers (ToolLocator: an env-var override, then
//                            the repo venv / scripts candidates; cf.
//                            CaptionOrchestrator+Dossier.swift for Whisper and
//                            FindPersonJob.swift for the recipe engine), and
//                            launched through ProcessRunner (the one subprocess
//                            runner; SIGTERM→SIGKILL on cancel) with the same
//                            environment fix the Whisper runner applies
//                            (PATH with Homebrew, PYTHONUNBUFFERED).
//   FootageSpectrumStore   — ~/Library/Caches/VideoScan/spectrum/{runs,cache};
//                            injectable root so tests never touch the real one.
//
// Media is only ever READ by the helper. The ONLY deletion in the feature is
// `FootageSpectrumStore.pruneOldRuns`: run folders under <root>/runs older
// than 14 days, canonical path checked to be inside <root>/runs first. The
// shared extraction cache is never pruned here (a gap, noted in the report).

import Foundation
import os

private let spectrumLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "fileOps")

// MARK: - Locating the helper

/// The three paths one run needs. Value type so a test can hand the job a
/// fake without any file existing.
struct FootageSpectrumTools: Sendable, Equatable {
    var python: String
    var script: String
    var ffmpeg: String
    var ffprobe: String
}

enum FootageSpectrumHelper {

    static let scriptEnvVar = "VS_FOOTAGE_SPECTRUM_SCRIPT_PATH"

    static let scriptCandidates = [
        NSHomeDirectory() + "/dev/VideoScan/scripts/footage_spectrum.py",
        FileManager.default.currentDirectoryPath + "/scripts/footage_spectrum.py",
    ]

    /// Path to scripts/footage_spectrum.py, "" when not findable — the same
    /// env-override-then-candidates shape as ToolLocator.whisperScriptPath.
    static var scriptPath: String {
        ToolLocator.resolveExistingFile(envVar: scriptEnvVar, candidates: scriptCandidates)
    }

    /// Everything the run needs, or the first thing that is missing
    /// ("python" / "script" / "ffmpeg" / "ffprobe" — see
    /// FootageSpectrumWords.missingDependency). numpy is the helper's own
    /// check: it answers with an ERROR line naming it.
    static func locate(python: String = ToolLocator.pythonPath,
                       script: String = scriptPath,
                       ffmpeg: String = ToolLocator.ffmpegPath,
                       ffprobe: String = ToolLocator.ffprobePath,
                       fileManager: FileManager = .default) -> Result<FootageSpectrumTools, FootageSpectrumRefusal> {
        func executable(_ path: String) -> Bool {
            !path.isEmpty && fileManager.isExecutableFile(atPath: path)
        }
        guard executable(python) else { return .failure(.init(reason: FootageSpectrumWords.missingDependency("python"))) }
        guard !script.isEmpty, fileManager.fileExists(atPath: script) else {
            return .failure(.init(reason: FootageSpectrumWords.missingDependency("script")))
        }
        guard executable(ffmpeg) else { return .failure(.init(reason: FootageSpectrumWords.missingDependency("ffmpeg"))) }
        guard executable(ffprobe) else { return .failure(.init(reason: FootageSpectrumWords.missingDependency("ffprobe"))) }
        return .success(FootageSpectrumTools(python: python, script: script, ffmpeg: ffmpeg, ffprobe: ffprobe))
    }

    // MARK: Launching

    /// One helper launch, fully described — what a stub launcher receives.
    struct Invocation: Sendable, Equatable {
        var tools: FootageSpectrumTools
        var setsFile: URL
        var outputPage: URL
        var cacheDir: URL

        var arguments: [String] {
            ["-u", tools.script,
             "--sets", setsFile.path,
             "--out", outputPage.path,
             "--cache-dir", cacheDir.path,
             "--progress",
             "--ffmpeg", tools.ffmpeg,
             "--ffprobe", tools.ffprobe]
        }

        /// The child's environment: PATH with Homebrew in front (the helper
        /// is told ffmpeg's path, but keep the Whisper runner's fix anyway)
        /// and unbuffered stdout, so progress lines arrive as they happen.
        var environment: [String: String] {
            var env = ProcessInfo.processInfo.environment
            env["PYTHONUNBUFFERED"] = "1"
            env["PATH"] = augmentedPathWithHomebrew(inheriting: env["PATH"])
            return env
        }
    }

    struct Exit: Sendable, Equatable {
        var code: Int32
        /// The last few stderr lines, for the failure reason.
        var stderrTail: String
    }

    /// The seam the job launches through. The production launcher is
    /// `ProcessRunner`; tests inject a closure that plays back lines.
    /// Cancellation reaches the launcher as Task cancellation — the real one
    /// terminates the child (SIGTERM, then SIGKILL after the grace period).
    typealias Launcher = @Sendable (_ invocation: Invocation,
                                    _ onStdoutLine: @escaping @Sendable (String) -> Void) async -> Exit

    static let processRunnerLauncher: Launcher = { invocation, onLine in
        let result = await ProcessRunner.runProcess(
            executable: invocation.tools.python,
            arguments: invocation.arguments,
            environment: invocation.environment,
            stdoutLine: onLine,
            stderrLine: nil,
            stdoutLimitBytes: 64 * 1024,
            stderrLimitBytes: 64 * 1024)
        let tail = result.stderr.split(separator: "\n").suffix(3).joined(separator: " · ")
        return Exit(code: result.exitCode, stderrTail: tail)
    }
}

// MARK: - Where the files go

/// `<root>/runs/<uuid>/{sets.json,page.html}` per run and `<root>/cache/`
/// for the helper's per-file extraction cache. The root is injectable (tests
/// use a temp folder and a tripwire around it).
struct FootageSpectrumStore: Sendable, Equatable {

    static let defaultRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Caches/VideoScan/spectrum", isDirectory: true)

    /// Runs older than this are removed at the start of the next run.
    static let runKeepDays = 14

    var root: URL

    init(root: URL = FootageSpectrumStore.defaultRoot) {
        self.root = root
    }

    var runsDir: URL { root.appendingPathComponent("runs", isDirectory: true) }
    var cacheDir: URL { root.appendingPathComponent("cache", isDirectory: true) }

    func runDir(_ id: UUID) -> URL { runsDir.appendingPathComponent(id.uuidString, isDirectory: true) }
    func setsFile(_ id: UUID) -> URL { runDir(id).appendingPathComponent("sets.json") }
    func pageFile(_ id: UUID) -> URL { runDir(id).appendingPathComponent("page.html") }

    /// Make the run's folder and the cache folder.
    func prepare(run id: UUID, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: runDir(id), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Which run folders are old enough to go (pure over what the caller
    /// lists): a run is dated by its folder's modification time.
    static func runsToPrune(_ runs: [(url: URL, modified: Date)], now: Date,
                            keepDays: Int = runKeepDays) -> [URL] {
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        return runs.filter { $0.modified < cutoff }.map(\.url)
    }

    /// Remove run folders older than `runKeepDays` — the feature's ONE
    /// deletion. Every candidate is re-checked to be a direct child of
    /// `<root>/runs` by canonical path before it goes; anything else is left
    /// alone and logged. Returns how many were removed.
    @discardableResult
    func pruneOldRuns(now: Date = Date(), fileManager: FileManager = .default) -> Int {
        let runsPath = runsDir.standardizedFileURL.resolvingSymlinksInPath().path
        guard let entries = try? fileManager.contentsOfDirectory(
            at: runsDir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var dated: [(url: URL, modified: Date)] = []
        for url in entries {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard values?.isDirectory == true, let modified = values?.contentModificationDate else { continue }
            dated.append((url, modified))
        }
        var removed = 0
        for url in Self.runsToPrune(dated, now: now) {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical.deletingLastPathComponent().path == runsPath,
                  UUID(uuidString: canonical.lastPathComponent) != nil else {
                spectrumLog.error("spectrum prune refused: \(url.path, privacy: .public) is not a run folder under \(runsPath, privacy: .public)")
                continue
            }
            do {
                try fileManager.removeItem(at: canonical)
                removed += 1
            } catch {
                spectrumLog.error("spectrum prune failed: \(canonical.path, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            }
        }
        if removed > 0 {
            spectrumLog.info("spectrum prune: removed \(removed) run folder(s) older than \(Self.runKeepDays) days")
        }
        return removed
    }
}
