// BackgroundCLI.swift — VideoScan Background as `videoscan-bg`
//
// The design's one-line CLI (§0.4, §3.1) in the helper binary: with any of
// these flags the process is an XPC CLIENT of the running service — launchd
// starts the service if it is down — prints one line, exits 0, or prints a
// refusal and exits 1.
//
//   "…/VideoScan Background" --status
//   "…/VideoScan Background" --enqueue noop [units] [sleepMilliseconds]
//   "…/VideoScan Background" --enqueue era [limit N] [repo PATH] [python PATH] [catalog PATH]
//   "…/VideoScan Background" --pause <id> | --resume <id> | --stop <id>
//
// And one FOREGROUND mode (background service step 1): `--run era …
// [state-root PATH]` runs the job in THIS process with its own
// supervisor over `state-root` (default the service's folder) — for a smoke
// on a `.backup` copy of the catalog and the M4 corpus run, with the app and
// the service untouched. Its journal is <state-root>/journal; nothing reaches
// a catalog until an app whose journal folder that is applies it.

import Foundation
import VideoScanCore

enum BackgroundCLI {
    enum Verb {
        case status
        case enqueueNoop(units: Int, sleepMilliseconds: Int)
        case enqueueEra(EraCLIArguments)
        case runEra(EraCLIArguments)
        case refused(String)
        case pause(String), resume(String), stop(String)
    }

    static let usage = "usage: --status | --enqueue noop [units] [sleepMilliseconds] | --enqueue \(EraCLIArguments.usage) | --run \(EraCLIArguments.usage) | --pause <id> | --resume <id> | --stop <id>"

    static func verb(in arguments: [String]) -> Verb? {
        guard let first = arguments.first, first.hasPrefix("--") else { return nil }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "--status": return .status
        case "--enqueue" where rest.first == "era", "--run" where rest.first == "era":
            do {
                let parsed = try EraCLIArguments.parse(Array(rest.dropFirst()))
                return first == "--run" ? .runEra(parsed) : .enqueueEra(parsed)
            } catch {
                return .refused((error as? Refusal)?.words ?? "\(error)")
            }
        case "--enqueue":
            guard rest.first == "noop" else { return .status }
            let units = rest.count > 1 ? Int(rest[1]) ?? NoOpJob.defaultUnits : NoOpJob.defaultUnits
            let sleep = rest.count > 2 ? Int(rest[2]) ?? NoOpJob.defaultSleepMilliseconds : NoOpJob.defaultSleepMilliseconds
            return .enqueueNoop(units: units, sleepMilliseconds: sleep)
        case "--pause": return rest.first.map(Verb.pause) ?? .status
        case "--resume": return rest.first.map(Verb.resume) ?? .status
        case "--stop": return rest.first.map(Verb.stop) ?? .status
        default: return .status
        }
    }

    static func run(_ verb: Verb) async -> Int32 {
        if case .refused(let words) = verb {
            fputs("videoscan-bg: \(words)\n\(usage)\n", stderr)
            return 1
        }
        if case .runEra(let arguments) = verb { return await runForeground(arguments) }
        let connection = NSXPCConnection(machServiceName: BackgroundService.machServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: BackgroundServiceXPC.self)
        connection.resume()
        defer { connection.invalidate() }

        do {
            let line = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let once = OnceContinuation(continuation)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    once.resume(throwing: Refusal("VideoScan Background did not answer: \(error.localizedDescription) — is it enabled in Login Items and registered by the app?"))
                }) as? BackgroundServiceXPC else {
                    once.resume(throwing: Refusal("could not make the XPC proxy"))
                    return
                }
                switch verb {
                case .status:
                    proxy.status { data in
                        once.resume(with: Result { try BackgroundPayloadCodec.decode(ServiceStatus.self, from: data) }.map(Self.describe))
                    }
                case .enqueueNoop(let units, let sleep):
                    let request = NoOpJob.request(units: units, sleepMilliseconds: sleep, requestedBy: "cli")
                    guard let data = try? BackgroundPayloadCodec.encode(request) else {
                        once.resume(throwing: Refusal("could not encode the request")); return
                    }
                    proxy.enqueue(data) { reply in
                        once.resume(with: Result {
                            switch try BackgroundPayloadCodec.decode(EnqueueReply.self, from: reply) {
                            case .accepted(let id): return "queued noop \(id) — \(units) units, \(sleep) ms each"
                            case .refused(let refusal): throw refusal
                            }
                        })
                    }
                case .enqueueEra(let arguments):
                    let request = arguments.request(requestedBy: "cli")
                    guard let data = try? BackgroundPayloadCodec.encode(request) else {
                        once.resume(throwing: Refusal("could not encode the request")); return
                    }
                    proxy.enqueue(data) { reply in
                        once.resume(with: Result {
                            switch try BackgroundPayloadCodec.decode(EnqueueReply.self, from: reply) {
                            case .accepted(let id): return "queued era \(id) — \(arguments.limit.map { "\($0) files" } ?? "every uncached video file"), oldest first"
                            case .refused(let refusal): throw refusal
                            }
                        })
                    }
                case .runEra, .refused:
                    once.resume(throwing: Refusal("not an XPC verb"))
                case .pause(let id): Self.verb(proxy.pause, id: id, word: "pause", once)
                case .resume(let id): Self.verb(proxy.resume, id: id, word: "resume", once)
                case .stop(let id): Self.verb(proxy.stop, id: id, word: "stop", once)
                }
            }
            print(line)
            return 0
        } catch {
            fputs("videoscan-bg: \((error as? Refusal)?.words ?? error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func verb(_ call: (Data, @escaping @Sendable (Bool) -> Void) -> Void, id: String, word: String, _ once: OnceContinuation) {
        guard let data = try? BackgroundPayloadCodec.encode(JobID(rawValue: id)) else {
            once.resume(throwing: Refusal("could not encode the job id")); return
        }
        call(data) { ok in
            once.resume(with: .success(ok ? "\(word) accepted for \(id)" : "\(word) refused: no active job \(id)"))
        }
    }

    /// `--run era …`: one job in this process, its own supervisor and log,
    /// over `state-root` (default the service's). Prints the START / OUTCOME
    /// lines as they are logged; exit 0 when the job finished.
    static func runForeground(_ arguments: EraCLIArguments) async -> Int32 {
        let root = arguments.stateRoot.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? BackgroundService.stateRoot
        let fileLog = arguments.stateRoot == nil ? BackgroundFileLog.production()
            : BackgroundFileLog(url: root.appendingPathComponent("background.log"))
        fileLog.start()
        let log = EchoLog(fileLog)
        let activity = SystemActivitySource()
        activity.start()
        let backoff = Backoff(source: activity)
        let catalog = arguments.catalogPath.map { URL(fileURLWithPath: $0) } ?? DefaultJobFactory.productionCatalogURL
        let supervisor = JobSupervisor(queue: FileJobQueueStore(directory: root.appendingPathComponent("queue", isDirectory: true)),
                                       checkpoints: FileCheckpointStore(directory: root.appendingPathComponent("checkpoints", isDirectory: true)),
                                       factory: DefaultJobFactory(stateRoot: root, catalogURL: catalog),
                                       backoff: backoff, log: log,
                                       ownership: FileStateRootLock(root: root, owner: "cli --run era"))
        log.write("foreground --run era — state in \(root.path), catalog \(catalog.path) (read-only)")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("queue", isDirectory: true), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("checkpoints", isDirectory: true), withIntermediateDirectories: true)
        guard case .accepted = await supervisor.enqueue(arguments.request(requestedBy: "cli --run")) else {
            fileLog.close()
            return 1
        }
        await supervisor.drain()
        fileLog.close()
        return log.sawFinished ? 0 : 1
    }

    static func describe(_ status: ServiceStatus) -> String {
        var line = status.summaryLine
        for job in status.jobs where job.state.isActive {
            line += "\n  \(job.kind) \(job.id) — \(job.subtitle)"
        }
        return line
    }
}

/// A continuation that can be resumed from either the reply or the error
/// handler, whichever arrives first; the second is dropped.
final class OnceContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?

    init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }

    func resume(with result: Result<String, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }

    func resume(throwing error: Error) { resume(with: .failure(error)) }
}

/// The foreground run's log: every line to the file AND to stdout.
final class EchoLog: BackgroundLogSink, @unchecked Sendable {
    private let file: BackgroundFileLog
    private let lock = NSLock()
    private var finished = false
    init(_ file: BackgroundFileLog) { self.file = file }
    func write(_ line: String) {
        file.write(line)
        print(line)
        fflush(stdout)
        if line.hasPrefix("OUTCOME era") && line.contains("finished:") { lock.lock(); finished = true; lock.unlock() }
    }
    var sawFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
}
