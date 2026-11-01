// PythonClipWorker.swift (VideoScanCore/ModelLab)
// ONE SENTENCE: the Swift half of the model watchdog (#406) — the model
// lives in a CHILD PROCESS (`<python> -I <repo>/tools/video-llm-bench/
// bench.py worker --factory clip-service:a2-py:<model dir>`), spoken to in
// JSON lines; a load or a clip past its cap kills the child (the GPU is freed
// with the process) and the next clip respawns and reloads (design §6
// isolation: the unit is `failed`, the job goes on).
//
// Protocol (bench.py `worker_command`): one request per stdin line,
//   {"method": "load" | "analyze_clip" | "__peak_rss__" | "__exit__", "args": [...]}
// one reply per stdout line, {"ok": <value>} or {"error": "...", "type": "..."};
// everything the model stack prints goes to the child's stderr, which is
// kept as a bounded tail for the failure words (never parsed).
//
// Rule 13 in code: `PayloadGate.check(descriptor, payload: .pixels)` runs
// before the FIRST spawn; the descriptor's host is `.pythonWorker` (this Mac
// by construction). A `.remote*` host can never reach `spawn` — the gate
// throws first (sensor: PythonClipWorkerTests).
//
// The model id, approach id and revision come from the worker's `load` reply
// (`LoadInfo`), never from the caller, so every `by` names what really ran.
//
// Memory (Swift side, worst case): one reply line, capped at
// `maxReplyBytes` (8 MB; a clip record is a few KB) + a 64 KB stderr tail.
// The child holds the model (A2 ≈ 6–7 GB peak) — reported by `peakRSSBytes`.
//
// C++ reading: an actor (≈ a class with an implicit mutex, re-entrant at
// `await`) owning a child process and two pipes; a watchdog timer kills the
// child on silence; `LineChannel` is a condition-variable queue of lines.

import Foundation

public enum PythonClipWorkerError: Error, Equatable, Sendable, CustomStringConvertible {
    case payloadRefused(String)
    case notFound(String)
    case spawnFailed(String)
    /// The call passed its cap; the worker was killed.
    case timeout(method: String, seconds: Int)
    /// The worker exited (or its pipe broke) during the call.
    case died(method: String, stderrTail: String)
    /// The worker answered with an exception.
    case workerError(type: String, message: String)
    case protocolError(String)

    public var description: String {
        switch self {
        case .payloadRefused(let w): return w
        case .notFound(let w): return w
        case .spawnFailed(let w): return "could not start the clip worker: \(w)"
        case .timeout(let m, let s): return "\(m) exceeded \(s) s; the worker was killed and the GPU freed"
        case .died(let m, let tail): return "the worker died during \(m)" + (tail.isEmpty ? "" : " — last words: \(tail)")
        case .workerError(let t, let m): return "the worker raised \(t): \(m)"
        case .protocolError(let w): return "protocol: \(w)"
        }
    }
}

public actor PythonClipWorker {

    public struct Configuration: Sendable {
        public var python: URL
        public var script: URL
        public var factory: String
        public var loadTimeout: Duration
        public var clipTimeout: Duration
        public var environment: [String: String]?

        public static let defaultLoadTimeout: Duration = .seconds(300)
        public static let defaultClipTimeout: Duration = .seconds(180)

        public init(python: URL, script: URL, factory: String, loadTimeout: Duration = defaultLoadTimeout,
                    clipTimeout: Duration = defaultClipTimeout, environment: [String: String]? = nil) {
            self.python = python
            self.script = script
            self.factory = factory
            self.loadTimeout = loadTimeout
            self.clipTimeout = clipTimeout
            self.environment = environment
        }

        /// `<repo>/venv-mlx/bin/python3 -I <repo>/tools/video-llm-bench/bench.py worker --factory …`.
        /// `python` overrides the interpreter (a worktree without its own venv-mlx).
        public static func repo(_ repo: URL, factory: String, python: URL? = nil) throws -> Configuration {
            let interpreter = python ?? repo.appendingPathComponent("venv-mlx/bin/python3")
            let script = repo.appendingPathComponent("tools/video-llm-bench/bench.py")
            guard FileManager.default.isExecutableFile(atPath: interpreter.path) else {
                throw PythonClipWorkerError.notFound("the Python interpreter is not at \(interpreter.path)")
            }
            guard FileManager.default.fileExists(atPath: script.path) else {
                throw PythonClipWorkerError.notFound("bench.py is not at \(script.path)")
            }
            return Configuration(python: interpreter, script: script, factory: factory)
        }
    }

    /// What the worker's `load` reply says it is.
    public struct LoadInfo: Sendable, Equatable {
        public let approachID: ApproachID
        public let revision: Int
        public let model: String
        /// The whole reply, JSON.
        public let json: Data

        public var signer: String { "machine:\(approachID.rawValue)@r\(revision)" }
    }

    public static let maxReplyBytes = 8 * 1024 * 1024

    public let configuration: Configuration
    private let descriptor: ApproachDescriptor
    private let log: @Sendable (String) -> Void
    private var child: Child?
    private var gateChecked = false
    public private(set) var loadInfo: LoadInfo?
    public private(set) var spawns = 0
    public private(set) var timeouts = 0
    private var peakRSS: Int64 = 0

    public init(configuration: Configuration, descriptor: ApproachDescriptor, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.configuration = configuration
        self.descriptor = descriptor
        self.log = log
    }

    // MARK: Verbs

    /// Spawn (after the payload gate) and load; idempotent while alive.
    @discardableResult
    public func load() async throws -> LoadInfo {
        if let child, child.isRunning, let loadInfo { return loadInfo }
        if !gateChecked {
            do { try PayloadGate.check(descriptor, payload: .pixels) } catch {
                throw PythonClipWorkerError.payloadRefused(error.description)
            }
            gateChecked = true
        }
        kill(why: "respawn")
        let fresh = try spawn()
        child = fresh
        spawns += 1
        if spawns > 1 { log("clip worker respawned (pid \(fresh.pid)) — reloading the model") }
        let reply = try await call(fresh, "load", [], timeout: configuration.loadTimeout)
        let info = try Self.loadInfo(reply)
        loadInfo = info
        return info
    }

    /// One clip → the worker's record (JSON object bytes). A timeout or a
    /// death kills the worker and throws; the next call respawns + reloads.
    public func analyzeClip(path: String, durationS: Double, context: String? = nil) async throws -> Data {
        try await load()
        guard let child else { throw PythonClipWorkerError.protocolError("no worker after load") }
        let args: [Any] = [path, durationS.isFinite ? durationS : 0, context.map { $0 as Any } ?? NSNull()]
        return try await call(child, "analyze_clip", args, timeout: configuration.clipTimeout)
    }

    /// The worker's peak RSS (bytes), the largest seen this session; nil
    /// when never measured. Asked only of a live worker (a 10 s cap).
    public func peakRSSBytes() async -> Int64? {
        if let child, child.isRunning,
           let data = try? await call(child, "__peak_rss__", [], timeout: .seconds(10)),
           let n = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? NSNumber {
            peakRSS = max(peakRSS, n.int64Value)
        }
        return peakRSS > 0 ? peakRSS : nil
    }

    public var workerPID: Int32? { child?.pid }

    /// A live worker with its model loaded (EraJob defers while trickling and this is false).
    public var isLoaded: Bool { child?.isRunning == true && loadInfo != nil }

    /// Ask the worker to exit; kill it if it does not within 5 s.
    public func close() async {
        guard let child else { return }
        if child.isRunning {
            peakRSS = max(peakRSS, await peakRSSBytes() ?? 0)
            child.send(Data("{\"method\":\"__exit__\"}\n".utf8))
            for _ in 0..<50 where child.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        }
        kill(why: "close")
    }

    // MARK: Process

    private func spawn() throws -> Child {
        let process = Process()
        process.executableURL = configuration.python
        process.arguments = ["-I", configuration.script.path, "worker", "--factory", configuration.factory]
        if let environment = configuration.environment { process.environment = environment }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let child = Child(process: process, stdin: stdin.fileHandleForWriting)
        stdout.fileHandleForReading.readabilityHandler = { [lines = child.lines] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; lines.finish() } else { lines.append(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [tail = child.stderrTail] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { tail.append(data) }
        }
        process.terminationHandler = { [lines = child.lines] _ in lines.finishSoon() }
        do { try process.run() } catch { throw PythonClipWorkerError.spawnFailed("\(configuration.python.path): \(error)") }
        return child
    }

    private func kill(why: String) {
        guard let child else { return }
        self.child = nil
        loadInfo = nil
        if child.isRunning {
            Darwin.kill(child.pid, SIGKILL)       // our own child, nothing else
            log("clip worker pid \(child.pid) killed (\(why))")
        }
        child.lines.finish()
    }

    /// One request, one reply line, under `timeout`.
    private func call(_ child: Child, _ method: String, _ args: [Any], timeout: Duration) async throws -> Data {
        guard let request = try? JSONSerialization.data(withJSONObject: ["method": method, "args": args]) else {
            throw PythonClipWorkerError.protocolError("could not encode \(method)")
        }
        guard child.send(request + Data([0x0A])) else {
            kill(why: "stdin broken")
            throw PythonClipWorkerError.died(method: method, stderrTail: child.stderrTail.text)
        }
        let watchdog = Watchdog()
        let pid = child.pid
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if Task.isCancelled { return }
            watchdog.fire()
            Darwin.kill(pid, SIGKILL)
        }
        let line = await child.lines.next()
        timer.cancel()
        if watchdog.fired {
            timeouts += 1
            kill(why: "\(method) exceeded \(timeout.components.seconds) s")
            throw PythonClipWorkerError.timeout(method: method, seconds: Int(timeout.components.seconds))
        }
        guard let line else {
            let tail = child.stderrTail.text
            kill(why: "died during \(method)")
            throw PythonClipWorkerError.died(method: method, stderrTail: tail)
        }
        guard line.count <= Self.maxReplyBytes,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            kill(why: "an unreadable reply")
            throw PythonClipWorkerError.protocolError("the reply to \(method) is not a JSON object (\(line.count) bytes)")
        }
        if let message = object["error"] as? String {
            throw PythonClipWorkerError.workerError(type: object["type"] as? String ?? "Error", message: message)
        }
        guard let ok = object["ok"] else { throw PythonClipWorkerError.protocolError("the reply to \(method) has no ok") }
        guard let data = try? JSONSerialization.data(withJSONObject: ok, options: [.fragmentsAllowed]) else {
            throw PythonClipWorkerError.protocolError("the reply to \(method) is not JSON")
        }
        return data
    }

    static func loadInfo(_ data: Data) throws -> LoadInfo {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw PythonClipWorkerError.protocolError("the load reply is not an object")
        }
        guard let raw = o["approach_id"] as? String, let id = ApproachID(rawValue: raw) else {
            throw PythonClipWorkerError.protocolError("the load reply names no valid approach_id (\(String(describing: o["approach_id"])))")
        }
        guard let revision = o["revision"] as? Int, revision >= 1 else {
            throw PythonClipWorkerError.protocolError("the load reply names no revision ≥ 1")
        }
        guard let model = o["model"] as? String, !model.isEmpty else {
            throw PythonClipWorkerError.protocolError("the load reply names no model")
        }
        return LoadInfo(approachID: id, revision: revision, model: model, json: data)
    }
}

// MARK: - The child and its pipes

private final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var _fired = false
    func fire() { lock.lock(); _fired = true; lock.unlock() }
    var fired: Bool { lock.lock(); defer { lock.unlock() }; return _fired }
}

private final class Child: @unchecked Sendable {
    let process: Process
    let stdin: FileHandle
    let lines = LineChannel(maxLineBytes: PythonClipWorker.maxReplyBytes)
    let stderrTail = Tail(limit: 64 * 1024)

    init(process: Process, stdin: FileHandle) {
        self.process = process
        self.stdin = stdin
    }

    /// Known once `run()` returned.
    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    /// false when the pipe is broken (the worker is gone).
    @discardableResult
    func send(_ data: Data) -> Bool {
        do { try stdin.write(contentsOf: data); return true } catch { return false }
    }
}

/// Bytes → lines, one waiter at a time (the actor serialises calls).
private final class LineChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [Data] = []
    private var finished = false
    private var waiter: CheckedContinuation<Data?, Never>?
    private let maxLineBytes: Int

    init(maxLineBytes: Int) { self.maxLineBytes = maxLineBytes }

    func append(_ data: Data) {
        lock.lock()
        if buffer.count <= maxLineBytes { buffer.append(data) }
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[buffer.startIndex..<nl]))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        let resume = waiter != nil && !lines.isEmpty ? waiter : nil
        let line = resume != nil ? lines.removeFirst() : nil
        if resume != nil { waiter = nil }
        lock.unlock()
        resume?.resume(returning: line)
    }

    /// The process ended: give the stdout handler a moment to deliver its last bytes.
    func finishSoon() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { self.finish() }
    }

    func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let resume = waiter
        waiter = nil
        let line = resume != nil && !lines.isEmpty ? lines.removeFirst() : nil
        lock.unlock()
        resume?.resume(returning: line)
    }

    func next() async -> Data? {
        await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            lock.lock()
            if !lines.isEmpty { let l = lines.removeFirst(); lock.unlock(); c.resume(returning: l); return }
            if finished { lock.unlock(); c.resume(returning: nil); return }
            let displaced = waiter
            waiter = c
            lock.unlock()
            displaced?.resume(returning: nil)
        }
    }
}

/// The last `limit` bytes of the worker's stderr, as words for a failure.
private final class Tail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(d)
        if data.count > limit { data.removeFirst(data.count - limit) }
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        let s = String(decoding: data, as: UTF8.self)
        return s.split(separator: "\n").suffix(3).joined(separator: " | ")
    }
}
