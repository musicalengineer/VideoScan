// CleanupTestSupport.swift
// Shared fixtures + stubs for the Clean Up Video five-dimension suite
// (scale / media matrix / isolation / sensor — testing agent 2026-07-07).
// The LOGIC dimension lives in CleanupTests.swift (feature-dev) and is
// deliberately not duplicated here.

import Foundation
import CryptoKit
@testable import VideoScan

// MARK: - Stub engine

/// A CleanupRecipeEngine that "renders" instantly by copying the source
/// file into the scratch directory. Lets full CleanupJob runs (naming,
/// scratch acquisition, atomic publish, catalog registration, provenance)
/// execute deterministically with zero ffmpeg cost.
///
/// `onRender` is an observation hook — sensor tests use it to inspect the
/// destination directory MID-render (the atomic-publish invariant).
/// (For Rick: this is the classic C++ mock-the-strategy pattern — the
/// protocol seam CleanupJob.init exposes for exactly this purpose.)
struct StubCleanupEngine: CleanupRecipeEngine {
    let engineID = "stub-test-engine"
    var onRender: (@Sendable (_ scratchDirectory: URL, _ source: CleanupSource) throws -> Void)? = nil

    func canExecute(_ recipe: CleanupRecipe) -> Bool { true }

    func render(recipe: CleanupRecipe,
                source: CleanupSource,
                scratchDirectory: URL,
                progress: @escaping @Sendable (CleanupProgress) -> Void) async throws -> URL {
        try onRender?(scratchDirectory, source)
        let out = scratchDirectory.appendingPathComponent("cleanup-render.mov")
        // Copy the (real, playable) source so probeFile can catalog the
        // published output honestly.
        try FileManager.default.copyItem(atPath: source.path, toPath: out.path)
        progress(CleanupProgress(phase: "Stub render", fraction: 1.0))
        return out
    }
}

// MARK: - Cross-thread observation box

/// Minimal thread-safe box for observations captured inside @Sendable
/// engine callbacks. (≈ a std::mutex-guarded struct; NSLock is fine here
/// because contention is a handful of calls per test.)
final class CleanupObservationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ initial: T) { stored = initial }
    var value: T {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func mutate(_ body: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&stored)
    }
}

// MARK: - ffmpeg fixture generation (media matrix)

/// Generates the checklist's media-matrix fixtures at test time with
/// ffmpeg — same convention as TestMediaGenerator (synthetic testsrc+sine,
/// `test_` prefix, temp-dir output, throws on failure), extended with the
/// per-case flags the matrix needs (interlaced x264, dvvideo pixel format)
/// that TestMediaGenerator's simpler surface doesn't expose.
enum CleanupTestMedia {

    static var ffmpegPath: String { ToolLocator.ffmpegPath }
    static var ffprobePath: String { ToolLocator.ffprobePath }

    static var toolsAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: ffmpegPath)
            && FileManager.default.isExecutableFile(atPath: ffprobePath)
    }

    /// Fresh per-test directory under the system temp dir. Callers remove
    /// it in a defer. `test_` prefix keeps it inside the fixture-naming
    /// convention (and TestMediaGenerator.cleanupAll-style sweeps).
    static func makeScratchDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_cleanup_\(label)_\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Run ffmpeg with `args` producing `output`; throws with the stderr
    /// tail on failure.
    static func runFFmpeg(_ args: [String], output: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = ["-y", "-hide_banner", "-loglevel", "error"] + args + [output]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              FileManager.default.fileExists(atPath: output) else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            throw CleanupFixtureError.ffmpegFailed(
                status: proc.terminationStatus,
                stderr: String(err.suffix(400)))
        }
    }

    /// Generate one synthetic A/V (or video-only) fixture.
    @discardableResult
    static func generate(into dir: URL,
                         name: String,
                         duration: Double,
                         size: String,
                         rate: String,
                         videoCodec: String,
                         extraVideoArgs: [String] = [],
                         audioCodec: String?) throws -> String {
        let out = dir.appendingPathComponent(name).path
        var args: [String] = [
            "-f", "lavfi", "-i", "testsrc=duration=\(duration):size=\(size):rate=\(rate)"
        ]
        if let audioCodec {
            args += ["-f", "lavfi",
                     "-i", "sine=frequency=440:duration=\(duration):sample_rate=48000"]
            args += ["-c:v", videoCodec] + extraVideoArgs + ["-c:a", audioCodec]
        } else {
            args += ["-c:v", videoCodec] + extraVideoArgs + ["-an"]
        }
        try runFFmpeg(args, output: out)
        return out
    }

    enum CleanupFixtureError: Error, CustomStringConvertible {
        case ffmpegFailed(status: Int32, stderr: String)
        case ffprobeFailed(status: Int32, stderr: String)
        var description: String {
            switch self {
            case .ffmpegFailed(let s, let e): return "ffmpeg failed (\(s)): \(e)"
            case .ffprobeFailed(let s, let e): return "ffprobe failed (\(s)): \(e)"
            }
        }
    }

    // MARK: ffprobe verification

    struct ProbedStream: Decodable {
        let codec_type: String?
        let codec_name: String?
        let profile: String?
        let field_order: String?
    }
    struct ProbedFormat: Decodable { let duration: String? }
    struct ProbeReport: Decodable {
        let streams: [ProbedStream]
        let format: ProbedFormat?

        var video: ProbedStream? { streams.first { $0.codec_type == "video" } }
        var audio: ProbedStream? { streams.first { $0.codec_type == "audio" } }
        var durationSeconds: Double { Double(format?.duration ?? "") ?? 0 }
    }

    /// Full-stream + format probe via ffprobe JSON — the verification side
    /// of the matrix tests (independent of the app's probe pipeline, so a
    /// probeFile bug can't mask an engine bug).
    static func probe(_ path: String) throws -> ProbeReport {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffprobePath)
        proc.arguments = [
            "-v", "error",
            "-show_entries", "stream=codec_type,codec_name,profile,field_order",
            "-show_entries", "format=duration",
            "-of", "json", path
        ]
        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            throw CleanupFixtureError.ffprobeFailed(status: proc.terminationStatus,
                                                    stderr: String(err.suffix(400)))
        }
        return try JSONDecoder().decode(ProbeReport.self, from: data)
    }

    // MARK: Source-integrity snapshot

    struct FileFingerprint: Equatable {
        let sha256: String
        let sizeBytes: UInt64
        let modificationDate: Date
    }

    /// SHA-256 + size + mtime — the "original untouched" proof.
    static func fingerprint(_ path: String) throws -> FileFingerprint {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return FileFingerprint(
            sha256: digest,
            sizeBytes: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: (attrs[.modificationDate] as? Date) ?? .distantPast)
    }
}

// MARK: - Record factory

/// Minimal catalog record pointing at a real on-disk fixture, shaped the
/// way the cleanup path reads it (fullPath / durationSeconds / scanType /
/// streamTypeRaw / resolution drive the job's behavior).
@MainActor
func makeCleanupSourceRecord(path: String,
                             durationSeconds: Double,
                             fieldOrder: String,
                             streamType: StreamType = .videoAndAudio,
                             resolution: String = "720x480") -> VideoRecord {
    let r = VideoRecord()
    r.filename = (path as NSString).lastPathComponent
    r.fullPath = path
    r.directory = (path as NSString).deletingLastPathComponent
    r.durationSeconds = durationSeconds
    r.scanType = fieldOrder
    r.streamTypeRaw = streamType.rawValue
    r.resolution = resolution
    let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
    r.sizeBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
    return r
}
