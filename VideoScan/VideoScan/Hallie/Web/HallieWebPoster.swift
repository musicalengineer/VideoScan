// HallieWebPoster.swift
// A still frame for each Browse row (Saturday 2026-08-22: "big thumbnails /
// poster frames" — an album, not a list). One JPEG per record, taken a few
// seconds in (past the colour bars and the date stamp), 360 px tall,
// cached next to the proxies; made by ffmpeg so DV / MXF / MTS / ProRes
// all work, not only what AVFoundation decodes. Never touches the original.

import Foundation
import VideoScanCore

struct HallieWebPosterPlan: Equatable, Sendable {
    static let height = 360
    /// Seconds in: past leader/colour bars on a tape, still "the start".
    static let offsetSeconds = 3.0

    let sourcePath: String
    let outputPath: String
    let offsetSeconds: Double

    var arguments: [String] {
        [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
            "-ss", String(format: "%.1f", offsetSeconds),
            "-i", sourcePath,
            "-frames:v", "1",
            "-vf", "scale=-2:'min(\(Self.height),ih)'",
            "-q:v", "4",
            "-f", "image2", outputPath,
        ]
    }
}

actor HallieWebPosterCache {
    private let directory: URL
    private let runner: @Sendable (HallieWebPosterPlan) async throws -> Void
    private var inFlight: Set<UUID> = []
    private var failed: Set<UUID> = []
    private var active = 0
    private let maxConcurrent = 2
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(directory: URL,
         runner: @escaping @Sendable (HallieWebPosterPlan) async throws -> Void = HallieWebPosterCache.ffmpeg) {
        self.directory = directory
        self.runner = runner
    }

    func posterURL(for recordID: UUID) -> URL {
        directory.appendingPathComponent("\(recordID.uuidString).jpg", isDirectory: false)
    }

    /// The poster if it exists; otherwise starts making it and returns nil
    /// (the page shows a placeholder and asks again later).
    func poster(for recordID: UUID, sourcePath: String, durationSeconds: Double) -> URL? {
        let url = posterURL(for: recordID)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard !inFlight.contains(recordID), !failed.contains(recordID) else { return nil }
        inFlight.insert(recordID)
        Task { await self.make(recordID: recordID, sourcePath: sourcePath, durationSeconds: durationSeconds) }
        return nil
    }

    func isFailed(_ recordID: UUID) -> Bool { failed.contains(recordID) }

    private func make(recordID: UUID, sourcePath: String, durationSeconds: Double) async {
        while active >= maxConcurrent { await withCheckedContinuation { waiters.append($0) } }
        active += 1
        defer {
            active -= 1
            inFlight.remove(recordID)
            let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() }
        }
        let final = posterURL(for: recordID)
        let partial = directory.appendingPathComponent(".\(recordID.uuidString).partial.jpg")
        // A clip shorter than the offset gets its first frame instead.
        let offset = durationSeconds > HallieWebPosterPlan.offsetSeconds + 1
            ? HallieWebPosterPlan.offsetSeconds : 0
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: partial)
            try await runner(HallieWebPosterPlan(sourcePath: sourcePath, outputPath: partial.path, offsetSeconds: offset))
            guard let size = try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber,
                  size.int64Value > 0 else { throw NSError(domain: "HallieWebPoster", code: 1) }
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: partial, to: final)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            failed.insert(recordID)
        }
    }

    static let ffmpeg: @Sendable (HallieWebPosterPlan) async throws -> Void = { plan in
        let ffmpegPath = ToolLocator.ffmpegPath
        guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
            throw NSError(domain: "HallieWebPoster", code: 2)
        }
        // Through ProcessRunner (2026-11-21; this was a hand-rolled
        // `Process()`): same executable and argv, both outputs still
        // discarded (limit 0 — nothing is collected). Gained: the pipes are
        // drained, a cancelled task stops ffmpeg, and a test can answer the
        // command with a ScriptedExecutor.
        let result = await ProcessRunner.runProcess(executable: ffmpegPath, arguments: plan.arguments,
                                                    stdoutLimitBytes: 0, stderrLimitBytes: 0)
        guard result.launched else {
            throw NSError(domain: "HallieWebPoster", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "ffmpeg could not be started: \(result.stderr)"])
        }
        guard result.exitCode == 0 else {
            throw NSError(domain: "HallieWebPoster", code: Int(result.exitCode))
        }
    }
}
