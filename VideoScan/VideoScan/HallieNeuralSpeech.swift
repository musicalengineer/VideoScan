// HallieNeuralSpeech.swift
//
// Optional local neural speech for Hallie.  Kokoro runs in a helper process,
// deliberately outside VideoScan: the catalog remains untouched, a failed TTS
// model cannot take down the app's MLX captioning process, and Apple speech is
// always available as the fallback.  The helper and its model live in
// ~/Library/Application Support/VideoScan/HallieKokoro rather than in the
// catalog or source tree.

import Foundation

struct HallieNeuralVoice: Identifiable, Equatable, Sendable {
    let modelName: String
    let displayName: String
    let speed: Float

    var id: String { "kokoro:\(modelName)" }

    static let choices = [
        HallieNeuralVoice(modelName: "af_heart", displayName: "Heart — warm American", speed: 0.92),
        HallieNeuralVoice(modelName: "af_bella", displayName: "Bella — gentle American", speed: 0.92),
        HallieNeuralVoice(modelName: "af_sarah", displayName: "Sarah — clear American", speed: 0.92),
        HallieNeuralVoice(modelName: "bf_emma", displayName: "Emma — warm British", speed: 0.92),
    ]

    static func selected(_ identifier: String?) -> HallieNeuralVoice? {
        choices.first { $0.id == identifier }
    }
}

enum HallieNeuralSpeech {
    enum Failure: LocalizedError {
        case notInstalled
        case launch(String)
        case synthesis(Int32, String)
        case missingOutput

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Hallie's neural voice is not installed"
            case .launch(let detail):
                return "Hallie's neural voice could not start: \(detail)"
            case .synthesis(let status, let detail):
                return "Hallie's neural voice stopped with status \(status): \(detail)"
            case .missingOutput:
                return "Hallie's neural voice did not produce audio"
            }
        }
    }

    static let directoryName = "HallieKokoro"
    static let executableName = "kokoro-tts"
    static let modelName = "kokoro-v1_0.safetensors"
    static let voicesName = "voices.npz"

    static var installationDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static var isInstalled: Bool {
        let directory = installationDirectory
        let executable = directory.appendingPathComponent(executableName).path
        return FileManager.default.isExecutableFile(atPath: executable)
            && FileManager.default.fileExists(atPath: directory.appendingPathComponent(modelName).path)
            && FileManager.default.fileExists(atPath: directory.appendingPathComponent(voicesName).path)
            && FileManager.default.fileExists(atPath: directory.appendingPathComponent("mlx.metallib").path)
    }

    static func job(for text: String, voice: HallieNeuralVoice) -> HallieNeuralSpeechJob {
        HallieNeuralSpeechJob(text: text, voice: voice)
    }

    static func removeTemporaryAudio(_ url: URL?) {
        guard let url,
              url.deletingLastPathComponent().lastPathComponent.hasPrefix("VideoScan-Hallie-") else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

/// One cancellable helper invocation. `Process` is protected by the lock;
/// the unchecked conformance is confined to this small ownership boundary.
final class HallieNeuralSpeechJob: @unchecked Sendable {
    private let text: String
    private let voice: HallieNeuralVoice
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    init(text: String, voice: HallieNeuralVoice) {
        self.text = text
        self.voice = voice
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }

    /// Synthesize one complete answer. Every request gets its own directory,
    /// so a quickly interrupted answer cannot overwrite the next one.
    func synthesize() async throws -> URL {
        guard HallieNeuralSpeech.isInstalled else { throw HallieNeuralSpeech.Failure.notInstalled }

        let install = HallieNeuralSpeech.installationDirectory
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoScan-Hallie-\(UUID().uuidString)", isDirectory: true)
        let output = outputDirectory.appendingPathComponent("hallie-\(voice.modelName).wav")
        let arguments = synthesisArguments(install: install, outputDirectory: outputDirectory)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = install.appendingPathComponent(HallieNeuralSpeech.executableName)
                process.arguments = arguments
                process.currentDirectoryURL = install
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    self.lock.lock()
                    if self.cancelled {
                        self.lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.process = process
                    self.lock.unlock()

                    try FileManager.default.createDirectory(
                        at: outputDirectory,
                        withIntermediateDirectories: true
                    )
                    try process.run()
                    self.lock.lock()
                    let cancelAfterLaunch = self.cancelled
                    self.lock.unlock()
                    if cancelAfterLaunch { process.terminate() }
                    process.waitUntilExit()

                    self.lock.lock()
                    self.process = nil
                    let wasCancelled = self.cancelled
                    self.lock.unlock()
                    if wasCancelled {
                        try? FileManager.default.removeItem(at: outputDirectory)
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    let detailData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let detail = (String(bytes: detailData, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard process.terminationStatus == 0 else {
                        try? FileManager.default.removeItem(at: outputDirectory)
                        continuation.resume(throwing: HallieNeuralSpeech.Failure.synthesis(
                            process.terminationStatus, detail
                        ))
                        return
                    }
                    guard FileManager.default.fileExists(atPath: output.path) else {
                        try? FileManager.default.removeItem(at: outputDirectory)
                        continuation.resume(throwing: HallieNeuralSpeech.Failure.missingOutput)
                        return
                    }
                    continuation.resume(returning: output)
                } catch {
                    self.lock.lock()
                    self.process = nil
                    self.lock.unlock()
                    try? FileManager.default.removeItem(at: outputDirectory)
                    if error is CancellationError {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: HallieNeuralSpeech.Failure.launch(
                            error.localizedDescription
                        ))
                    }
                }
            }
        }
    }

    private func synthesisArguments(install: URL, outputDirectory: URL) -> [String] {
        [
            "--model", install.appendingPathComponent(HallieNeuralSpeech.modelName).path,
            "--voices", install.appendingPathComponent(HallieNeuralSpeech.voicesName).path,
            "--output", outputDirectory.path,
            "--voice", voice.modelName,
            "--speed", String(voice.speed),
            "--text", text,
        ]
    }
}
