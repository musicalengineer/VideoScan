// HallieNeuralSpeech.swift
//
// Optional local neural speech for Hallie.  Kokoro runs in a helper process,
// deliberately outside VideoScan: the catalog remains untouched, a failed TTS
// model cannot take down the app's MLX captioning process, and Apple speech is
// always available as the fallback.  The helper and its model live in
// ~/Library/Application Support/VideoScan/HallieKokoro rather than in the
// catalog or source tree.

import Darwin
import Foundation

struct HallieNeuralVoice: Identifiable, Equatable, Sendable {
    let modelName: String
    let displayName: String

    var id: String { "kokoro:\(modelName)" }

    static let choices = [
        HallieNeuralVoice(modelName: "af_heart", displayName: "Heart — warm American"),
        HallieNeuralVoice(modelName: "af_bella", displayName: "Bella — gentle American"),
        HallieNeuralVoice(modelName: "af_sarah", displayName: "Sarah — clear American"),
        HallieNeuralVoice(modelName: "bf_emma", displayName: "Emma — warm British"),
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

    static func job(for text: String, voice: HallieNeuralVoice,
                    speed: Float) -> HallieNeuralSpeechJob {
        HallieNeuralSpeechJob(text: text, voice: voice, speed: speed)
    }

    static func removeTemporaryAudio(_ url: URL?) {
        guard let url,
              url.deletingLastPathComponent().lastPathComponent.hasPrefix("VideoScan-Hallie-") else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

struct HallieNeuralSpeechDiagnosticsSnapshot: Equatable, Sendable {
    let failureCount: Int
    let retryRecoveryCount: Int
    let lastFailure: String?
}

/// Process-wide counters for `:session` and support diagnostics. The lock is
/// the complete ownership boundary; speech can fail off the main actor.
final class HallieNeuralSpeechDiagnostics: @unchecked Sendable {
    static let shared = HallieNeuralSpeechDiagnostics()

    private let lock = NSLock()
    private var failureCount = 0
    private var retryRecoveryCount = 0
    private var lastFailure: String?

    func recordFailure(_ detail: String) {
        lock.lock()
        failureCount += 1
        lastFailure = String(detail.suffix(1_024))
        lock.unlock()
    }

    func recordRetryRecovery() {
        lock.lock()
        retryRecoveryCount += 1
        lock.unlock()
    }

    func snapshot() -> HallieNeuralSpeechDiagnosticsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return HallieNeuralSpeechDiagnosticsSnapshot(
            failureCount: failureCount,
            retryRecoveryCount: retryRecoveryCount,
            lastFailure: lastFailure)
    }

    func resetForTesting() {
        lock.lock()
        failureCount = 0
        retryRecoveryCount = 0
        lastFailure = nil
        lock.unlock()
    }
}

private struct HallieNeuralWorkerRequest: Encodable {
    let id: String
    let outputDirectory: String
    let voiceName: String
    let speed: Float
    let text: String
}

private struct HallieNeuralWorkerResponse: Decodable {
    let id: String
    let ok: Bool
    let error: String?
}

private struct HallieNeuralWorkerAttemptFailure: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

private final class HallieNeuralLineChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [String] = []
    private var finished = false
    private var waiter: CheckedContinuation<String?, Never>?
    private let maximumBufferBytes = 1 * 1_024 * 1_024

    func append(_ data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if buffer.count < maximumBufferBytes { buffer.append(data) }
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            lines.append(String(data: lineData, encoding: .utf8) ?? "")
        }
        var continuation: CheckedContinuation<String?, Never>?
        var line: String?
        if waiter != nil, !lines.isEmpty {
            continuation = waiter
            waiter = nil
            line = lines.removeFirst()
        }
        lock.unlock()
        continuation?.resume(returning: line)
    }

    func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = waiter
        waiter = nil
        var line: String?
        if continuation != nil, !lines.isEmpty { line = lines.removeFirst() }
        lock.unlock()
        continuation?.resume(returning: line)
    }

    func nextLine() async -> String? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !lines.isEmpty {
                let line = lines.removeFirst()
                lock.unlock()
                continuation.resume(returning: line)
            } else if finished {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                let displaced = waiter
                waiter = continuation
                lock.unlock()
                displaced?.resume(returning: nil)
            }
        }
    }
}

private final class HallieNeuralStderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let maximumBytes = 64 * 1_024

    func append(_ incoming: Data) {
        lock.lock()
        data.append(incoming)
        if data.count > maximumBytes { data = Data(data.suffix(maximumBytes)) }
        lock.unlock()
    }

    var tail: String {
        lock.lock(); defer { lock.unlock() }
        return (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class HallieNeuralWorkerHandle: @unchecked Sendable {
    enum StopCause { case cancelled, timeout, idle, recycle }

    let process: Process
    let input: FileHandle
    let output: FileHandle
    let errorOutput: FileHandle
    let lines: HallieNeuralLineChannel
    let errors: HallieNeuralStderrBuffer

    private let lock = NSLock()
    private var _stopCause: StopCause?

    init(process: Process, input: FileHandle, output: FileHandle,
         errorOutput: FileHandle, lines: HallieNeuralLineChannel,
         errors: HallieNeuralStderrBuffer) {
        self.process = process
        self.input = input
        self.output = output
        self.errorOutput = errorOutput
        self.lines = lines
        self.errors = errors
    }

    var isRunning: Bool { process.isRunning }
    var stopCause: StopCause? {
        lock.lock(); defer { lock.unlock() }
        return _stopCause
    }

    func stop(_ cause: StopCause) {
        lock.lock()
        if _stopCause == nil { _stopCause = cause }
        lock.unlock()
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGTERM)
        let process = process
        let pid = process.processIdentifier
        Task.detached {
            try? await Task.sleep(for: .seconds(1))
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }

    func detach() {
        output.readabilityHandler = nil
        errorOutput.readabilityHandler = nil
        try? input.close()
    }
}

/// One warm Kokoro process. Requests are serialized by this actor; a broken
/// pipe, crash, malformed response, or worker-reported generation failure gets
/// exactly one clean respawn. The process leaves memory after an idle period.
actor HallieNeuralSpeechWorker {
    static let shared = HallieNeuralSpeechWorker()
    private static let responsePrefix = "@hallie-response@"

    private let installationDirectory: URL
    private let idleTimeoutSeconds: Double
    private let requestTimeoutSeconds: Double
    private let diagnostics: HallieNeuralSpeechDiagnostics
    private var handle: HallieNeuralWorkerHandle?
    private var idleTask: Task<Void, Never>?
    private var requestGeneration = 0
    private var activeRequestID: String?
    private(set) var totalSpawns = 0

    init(
        installationDirectory: URL = HallieNeuralSpeech.installationDirectory,
        idleTimeoutSeconds: Double = 120,
        requestTimeoutSeconds: Double = 90,
        diagnostics: HallieNeuralSpeechDiagnostics = .shared
    ) {
        self.installationDirectory = installationDirectory
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.diagnostics = diagnostics
    }

    func synthesize(requestID: String, text: String,
                    voice: HallieNeuralVoice, speed: Float) async throws -> URL {
        requestGeneration += 1
        idleTask?.cancel()
        idleTask = nil
        defer { scheduleIdleShutdown() }

        if activeRequestID != nil, let existing = handle {
            existing.stop(.recycle)
            tearDown(existing)
        }

        var lastDetail = "worker failed twice"
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let outputDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("VideoScan-Hallie-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true)
                let result = try await performRequest(
                    requestID: requestID, text: text, voice: voice,
                    speed: speed, outputDirectory: outputDirectory)
                if attempt == 1 { diagnostics.recordRetryRecovery() }
                return result
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: outputDirectory)
                if let current = handle {
                    current.stop(.cancelled)
                    tearDown(current)
                }
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: outputDirectory)
                lastDetail = error.localizedDescription
                if let current = handle {
                    current.stop(.recycle)
                    tearDown(current)
                }
            }
        }
        throw HallieNeuralSpeech.Failure.synthesis(-1, lastDetail)
    }

    func cancel(requestID: String) {
        guard activeRequestID == requestID, let handle else { return }
        handle.stop(.cancelled)
    }

    func shutdown() {
        idleTask?.cancel()
        idleTask = nil
        if let handle {
            handle.stop(.idle)
            tearDown(handle)
        }
    }

    private func performRequest(
        requestID: String, text: String, voice: HallieNeuralVoice,
        speed: Float, outputDirectory: URL
    ) async throws -> URL {
        let worker = try ensureWorker()
        activeRequestID = requestID
        defer {
            if activeRequestID == requestID { activeRequestID = nil }
        }

        var payload = try JSONEncoder().encode(HallieNeuralWorkerRequest(
            id: requestID, outputDirectory: outputDirectory.path,
            voiceName: voice.modelName, speed: speed, text: text))
        payload.append(UInt8(ascii: "\n"))
        do {
            try worker.input.write(contentsOf: payload)
        } catch {
            throw HallieNeuralWorkerAttemptFailure(
                detail: "stdin write failed: \(error.localizedDescription)")
        }

        let timeout = requestTimeoutSeconds
        let timeoutTask = Task { [worker] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            worker.stop(.timeout)
        }
        defer { timeoutTask.cancel() }

        var responseLine: String?
        for _ in 0..<128 {
            let line = await withTaskCancellationHandler {
                await worker.lines.nextLine()
            } onCancel: {
                worker.stop(.cancelled)
            }
            guard let line else { break }
            if line.hasPrefix(Self.responsePrefix) {
                responseLine = String(line.dropFirst(Self.responsePrefix.count))
                break
            }
        }

        guard let responseLine else {
            let reason: String
            switch worker.stopCause {
            case .cancelled: throw CancellationError()
            case .timeout: reason = "worker timed out after \(Int(timeout)) seconds"
            default: reason = "worker exited before answering"
            }
            let stderr = worker.errors.tail
            throw HallieNeuralWorkerAttemptFailure(
                detail: stderr.isEmpty ? reason : "\(reason): \(stderr)")
        }
        try Task.checkCancellation()

        guard let response = try? JSONDecoder().decode(
            HallieNeuralWorkerResponse.self, from: Data(responseLine.utf8)),
              response.id == requestID else {
            throw HallieNeuralWorkerAttemptFailure(detail: "invalid worker response")
        }
        guard response.ok else {
            throw HallieNeuralWorkerAttemptFailure(
                detail: response.error ?? "worker reported synthesis failure")
        }

        let output = outputDirectory
            .appendingPathComponent("hallie-\(voice.modelName).wav")
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw HallieNeuralSpeech.Failure.missingOutput
        }
        return output
    }

    private func ensureWorker() throws -> HallieNeuralWorkerHandle {
        if let handle, handle.isRunning { return handle }
        if let handle { tearDown(handle) }

        let executable = installationDirectory
            .appendingPathComponent(HallieNeuralSpeech.executableName)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw HallieNeuralSpeech.Failure.notInstalled
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let lines = HallieNeuralLineChannel()
        let errors = HallieNeuralStderrBuffer()
        process.executableURL = executable
        process.arguments = [
            "--worker",
            "--model", installationDirectory.appendingPathComponent(HallieNeuralSpeech.modelName).path,
            "--voices", installationDirectory.appendingPathComponent(HallieNeuralSpeech.voicesName).path,
        ]
        process.currentDirectoryURL = installationDirectory
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                lines.finish()
            } else {
                lines.append(data)
            }
        }
        errorHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errors.append(data)
            }
        }
        process.terminationHandler = { _ in lines.finish() }

        do {
            try process.run()
        } catch {
            outputHandle.readabilityHandler = nil
            errorHandle.readabilityHandler = nil
            throw HallieNeuralSpeech.Failure.launch(error.localizedDescription)
        }

        let worker = HallieNeuralWorkerHandle(
            process: process,
            input: inputPipe.fileHandleForWriting,
            output: outputHandle,
            errorOutput: errorHandle,
            lines: lines,
            errors: errors)
        handle = worker
        totalSpawns += 1
        return worker
    }

    private func tearDown(_ worker: HallieNeuralWorkerHandle) {
        worker.detach()
        if handle === worker { handle = nil }
    }

    private func scheduleIdleShutdown() {
        guard handle != nil else { return }
        let generation = requestGeneration
        let timeout = idleTimeoutSeconds
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.idleKill(ifStillGeneration: generation)
        }
    }

    private func idleKill(ifStillGeneration generation: Int) {
        guard generation == requestGeneration, activeRequestID == nil,
              let handle else { return }
        handle.stop(.idle)
        tearDown(handle)
    }
}

/// One cancellable request sent to the shared warm helper.
final class HallieNeuralSpeechJob: @unchecked Sendable {
    private let text: String
    private let voice: HallieNeuralVoice
    private let speed: Float
    private let lock = NSLock()
    private let requestID = UUID().uuidString
    private let worker: HallieNeuralSpeechWorker
    private var cancelled = false

    init(text: String, voice: HallieNeuralVoice, speed: Float,
         worker: HallieNeuralSpeechWorker = .shared) {
        self.text = text
        self.voice = voice
        self.speed = speed
        self.worker = worker
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        let requestID = requestID
        Task { await worker.cancel(requestID: requestID) }
    }

    func synthesize() async throws -> URL {
        guard HallieNeuralSpeech.isInstalled else { throw HallieNeuralSpeech.Failure.notInstalled }
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        return try await worker.synthesize(
            requestID: requestID, text: text, voice: voice, speed: speed)
    }
}
