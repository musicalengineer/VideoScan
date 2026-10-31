// BackgroundCLI.swift — VideoScan Background as `videoscan-bg`
//
// The design's one-line CLI (§0.4, §3.1) in the helper binary: with any of
// these flags the process is an XPC CLIENT of the running service — launchd
// starts the service if it is down — prints one line, exits 0, or prints a
// refusal and exits 1.
//
//   "…/VideoScan Background" --status
//   "…/VideoScan Background" --enqueue noop [units] [sleepMilliseconds]
//   "…/VideoScan Background" --pause <id> | --resume <id> | --stop <id>

import Foundation
import VideoScanCore

enum BackgroundCLI {
    enum Verb {
        case status
        case enqueueNoop(units: Int, sleepMilliseconds: Int)
        case pause(String), resume(String), stop(String)
    }

    static let usage = "usage: --status | --enqueue noop [units] [sleepMilliseconds] | --pause <id> | --resume <id> | --stop <id>"

    static func verb(in arguments: [String]) -> Verb? {
        guard let first = arguments.first, first.hasPrefix("--"), first != "--full" else { return nil }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "--status": return .status
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
