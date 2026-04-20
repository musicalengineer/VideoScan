// TestMediaGenerator.swift
// On-the-fly media fixture generation using ffmpeg for unit tests.
// Generates temp files with specified properties (codec, container, duration,
// stream type) and cleans them up. Eliminates dependence on checked-in fixtures
// and enables parametric testing (vary resolution, codec, duration, etc.).

import Foundation

enum StreamConfig {
    case videoAndAudio
    case videoOnly
    case audioOnly
}

struct TestMediaGenerator {

    /// Default ffmpeg path (Homebrew on Apple Silicon)
    private static let ffmpegPath: String = {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "ffmpeg"
    }()

    /// Check if ffmpeg is available
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: ffmpegPath)
    }

    // MARK: - Generate Single File

    /// Generate a media file with the specified properties.
    /// Returns the path to the generated temporary file.
    @discardableResult
    static func generate(
        container: String = "mp4",
        streams: StreamConfig = .videoAndAudio,
        videoCodec: String = "libx264",
        audioCodec: String = "aac",
        duration: Double = 3.0,
        resolution: String = "320x240",
        frameRate: Int = 25,
        sampleRate: Int = 44100,
        prefix: String = "test_gen"
    ) throws -> String {
        let tmpDir = NSTemporaryDirectory()
        let filename = "\(prefix)_\(UUID().uuidString.prefix(8)).\(container)"
        let outputPath = (tmpDir as NSString).appendingPathComponent(filename)

        var args: [String] = ["-y", "-hide_banner", "-loglevel", "error"]

        switch streams {
        case .videoAndAudio:
            // Video source: SMPTE color bars
            args += ["-f", "lavfi", "-i", "testsrc=duration=\(duration):size=\(resolution):rate=\(frameRate)"]
            // Audio source: sine tone
            args += ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(duration):sample_rate=\(sampleRate)"]
            args += ["-c:v", videoCodec, "-c:a", audioCodec]
            // For MXF, use pcm_s16le audio
            if container == "mxf" {
                args.removeLast()
                args += ["pcm_s16le"]
            }
        case .videoOnly:
            args += ["-f", "lavfi", "-i", "testsrc=duration=\(duration):size=\(resolution):rate=\(frameRate)"]
            args += ["-c:v", videoCodec, "-an"]
        case .audioOnly:
            args += ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(duration):sample_rate=\(sampleRate)"]
            args += ["-c:a", audioCodec]
            // For wav, use pcm
            if container == "wav" {
                args.removeLast()
                args += ["pcm_s16le"]
            }
            if container == "mxf" {
                args.removeLast()
                args += ["pcm_s16le"]
            }
        }

        args += [outputPath]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = args

        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice

        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw GeneratorError.ffmpegFailed(status: proc.terminationStatus, message: errMsg)
        }

        guard FileManager.default.fileExists(atPath: outputPath) else {
            throw GeneratorError.outputMissing(path: outputPath)
        }

        return outputPath
    }

    // MARK: - Generate Pair (for Combine tests)

    /// Generate a matched video-only + audio-only pair for combine/mux testing.
    /// Both files have the same duration so they sync properly.
    static func createPair(
        videoCodec: String = "libx264",
        audioCodec: String = "aac",
        videoContainer: String = "mp4",
        audioContainer: String = "m4a",
        duration: Double = 3.0,
        resolution: String = "320x240"
    ) throws -> (videoPath: String, audioPath: String) {
        let video = try generate(
            container: videoContainer,
            streams: .videoOnly,
            videoCodec: videoCodec,
            duration: duration,
            resolution: resolution,
            prefix: "test_pair_v"
        )
        let audio = try generate(
            container: audioContainer,
            streams: .audioOnly,
            audioCodec: audioCodec,
            duration: duration,
            prefix: "test_pair_a"
        )
        return (video, audio)
    }

    // MARK: - Cleanup

    /// Remove generated temp files.
    static func cleanup(_ paths: String...) {
        for path in paths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Remove all test_gen* files from the temp directory.
    static func cleanupAll() {
        let tmpDir = NSTemporaryDirectory()
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: tmpDir) else { return }
        for file in contents where file.hasPrefix("test_gen") || file.hasPrefix("test_pair") {
            try? fm.removeItem(atPath: (tmpDir as NSString).appendingPathComponent(file))
        }
    }

    // MARK: - Errors

    enum GeneratorError: Error, LocalizedError {
        case ffmpegFailed(status: Int32, message: String)
        case outputMissing(path: String)

        var errorDescription: String? {
            switch self {
            case .ffmpegFailed(let status, let msg):
                return "ffmpeg exited with status \(status): \(msg)"
            case .outputMissing(let path):
                return "Output file not created: \(path)"
            }
        }
    }
}
