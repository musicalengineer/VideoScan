// HallieWebProxy.swift
// Playback on the iPad for the tapes Safari can't decode (Saturday
// 2026-08-22: "Donna uses her iPad to ask Hallie about Cape Cod videos from
// the 90s and it can play back"). The Cape tapes are DV / MXF / MTS /
// ProRes; Safari plays H.264 in MP4. So: an on-demand ACCESS COPY —
// 720p H.264 (VideoToolbox, hardware) + AAC, faststart — made once per
// record and cached; the original is never touched (PRESERVE), the proxy
// is disposable and lives outside the archive.
//
// Rules:
// - at most 2 encodes in flight, and 1 per spinning-disk volume (the HDD
//   rule: one reader at a time);
// - partial file → atomic rename, so a crash never leaves a half proxy
//   that looks ready;
// - the ffmpeg runner is injected so the state machine is unit-tested
//   without ffmpeg; one real-ffmpeg smoke test covers the media matrix.

import Foundation
import VideoScanCore

/// The argument plan. Pure, so the exact ffmpeg line is testable.
struct HallieWebProxyPlan: Equatable, Sendable {
    static let defaultHeight = 720
    static let heightKey = "archivist.webProxyHeight"
    static let directoryKey = "archivist.webProxyDirectory"

    let sourcePath: String
    let outputPath: String
    let height: Int

    var arguments: [String] {
        [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
            "-i", sourcePath,
            // Keep aspect; never upscale past the source height.
            "-vf", "scale=-2:'min(\(height),ih)',format=yuv420p",
            "-c:v", "h264_videotoolbox", "-q:v", "65", "-profile:v", "main",
            "-c:a", "aac", "-b:a", "128k", "-ac", "2",
            "-movflags", "+faststart",
            "-f", "mp4", outputPath,
        ]
    }

    /// Where proxies live: the user's choice, else Application Support.
    static func directory(_ defaults: UserDefaults = .standard) -> URL {
        if let custom = defaults.string(forKey: directoryKey), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("VideoScan/web-proxies", isDirectory: true)
    }

    static func height(_ defaults: UserDefaults = .standard) -> Int {
        let value = defaults.integer(forKey: heightKey)
        return (360...2160).contains(value) ? value : defaultHeight
    }
}

/// What the page needs to know about one record's proxy.
enum HallieWebProxyStatus: Equatable, Sendable {
    case ready(URL)
    case preparing(startedAt: Date)
    case failed(String)
    case notStarted
}

/// Runs one encode. Injected; production spawns ffmpeg.
typealias HallieWebProxyRunner = @Sendable (HallieWebProxyPlan) async throws -> Void

actor HallieWebProxyCache {
    private let directory: URL
    private let height: Int
    private let runner: HallieWebProxyRunner
    private let maxConcurrent: Int
    private var inFlight: [UUID: Date] = [:]
    private var failures: [UUID: String] = [:]
    private var perVolume: [String: Int] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(directory: URL, height: Int = HallieWebProxyPlan.defaultHeight,
         maxConcurrent: Int = 2,
         runner: @escaping HallieWebProxyRunner = HallieWebProxyCache.ffmpeg) {
        self.directory = directory
        self.height = height
        self.maxConcurrent = max(1, maxConcurrent)
        self.runner = runner
    }

    func proxyURL(for recordID: UUID) -> URL {
        directory.appendingPathComponent("\(recordID.uuidString).mp4", isDirectory: false)
    }

    private func partialURL(for recordID: UUID) -> URL {
        directory.appendingPathComponent(".\(recordID.uuidString).partial.mp4", isDirectory: false)
    }

    func status(for recordID: UUID) -> HallieWebProxyStatus {
        let url = proxyURL(for: recordID)
        if FileManager.default.fileExists(atPath: url.path) { return .ready(url) }
        if let started = inFlight[recordID] { return .preparing(startedAt: started) }
        if let failure = failures[recordID] { return .failed(failure) }
        return .notStarted
    }

    /// Start an encode if none exists; returns the current status at once.
    /// `volumeIsSpinningDisk` lets the caller apply the HDD one-at-a-time
    /// rule without this actor knowing the catalog.
    func ensure(recordID: UUID, sourcePath: String, volumeRoot: String,
                volumeIsSpinningDisk: Bool) -> HallieWebProxyStatus {
        let current = status(for: recordID)
        switch current {
        case .ready, .preparing: return current
        case .failed, .notStarted: break
        }
        failures[recordID] = nil
        inFlight[recordID] = Date()
        Task { await self.encode(recordID: recordID, sourcePath: sourcePath,
                                 volumeRoot: volumeRoot, spinning: volumeIsSpinningDisk) }
        return .preparing(startedAt: inFlight[recordID] ?? Date())
    }

    private func encode(recordID: UUID, sourcePath: String, volumeRoot: String, spinning: Bool) async {
        await acquire(volumeRoot: volumeRoot, limit: spinning ? 1 : maxConcurrent)
        defer { release(volumeRoot: volumeRoot) }
        let partial = partialURL(for: recordID)
        let final = proxyURL(for: recordID)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: partial)
            try await runner(HallieWebProxyPlan(sourcePath: sourcePath, outputPath: partial.path, height: height))
            guard let size = try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber,
                  size.int64Value > 0 else {
                throw NSError(domain: "HallieWebProxy", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "ffmpeg produced no output"])
            }
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: partial, to: final)
            appLog.write("Hallie web: proxy ready for \(recordID) (\(size.int64Value) bytes)")
        } catch {
            try? FileManager.default.removeItem(at: partial)
            failures[recordID] = error.localizedDescription
            appLog.write("Hallie web: proxy FAILED for \(recordID) — \(error.localizedDescription)")
        }
        inFlight[recordID] = nil
    }

    // MARK: Limiter (global + per volume)

    private func acquire(volumeRoot: String, limit: Int) async {
        while inFlight.count > maxConcurrent || (perVolume[volumeRoot] ?? 0) >= limit {
            await withCheckedContinuation { waiters.append($0) }
        }
        perVolume[volumeRoot, default: 0] += 1
    }

    private func release(volumeRoot: String) {
        perVolume[volumeRoot, default: 1] -= 1
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    // MARK: Production runner

    static let ffmpeg: HallieWebProxyRunner = { plan in
        let ffmpegPath = ToolLocator.ffmpegPath
        guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
            throw NSError(domain: "HallieWebProxy", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "ffmpeg not found (install via Homebrew or set VS_FFMPEG_PATH)"])
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = plan.arguments
            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { proc in
                let text = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let reason = text.split(separator: "\n").last.map(String.init) ?? "exit \(proc.terminationStatus)"
                    continuation.resume(throwing: NSError(
                        domain: "HallieWebProxy", code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: reason]))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
