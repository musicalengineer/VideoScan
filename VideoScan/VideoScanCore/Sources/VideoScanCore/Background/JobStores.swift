// JobStores.swift — VideoScanCore/Background
//
// Durable state is files (design §3.4) so a crash of either process loses
// nothing: `queue/<id>.json` holds the JobRequest, `checkpoints/<id>.json`
// the last completed unit. Both are written with AtomicFilePublish (write a
// unique temp beside the destination, rename(2) over it), so a reader sees
// a whole file or none; a temp left by a crash carries
// `AtomicFilePublish.temporarySuffix` and the scan skips it.
//
// The two protocols exist so tests (and the disk-full simulation) can swap
// in memory; the supervisor never touches a path itself.
//
// Memory: a scan decodes one file at a time; the list it returns is the
// requests (≈ 200 B each). A checkpoint is one small struct.

import Foundation

/// Last completed unit of a job (design §3.4). Units `0..<completedUnits`
/// are done; the next to run is `completedUnits`.
public struct JobCheckpoint: Codable, Equatable, Sendable {
    public var jobID: JobID
    public var completedUnits: Int
    public var totalUnits: Int
    public var unitsRun: Int
    public var unitsSkipped: Int
    public var unitsFailed: Int
    public var startedAt: Date
    public var updatedAt: Date

    public init(jobID: JobID, totalUnits: Int, startedAt: Date = Date()) {
        self.jobID = jobID
        self.completedUnits = 0
        self.totalUnits = totalUnits
        self.unitsRun = 0
        self.unitsSkipped = 0
        self.unitsFailed = 0
        self.startedAt = startedAt
        self.updatedAt = startedAt
    }
}

public enum CheckpointReadOutcome: Equatable, Sendable {
    case none
    case found(JobCheckpoint)
    /// A file is there but cannot be read: the job restarts from zero and
    /// the log says so (design §6 isolation).
    case corrupt(words: String)
}

public protocol CheckpointStore: Sendable {
    func load(_ id: JobID) -> CheckpointReadOutcome
    func save(_ checkpoint: JobCheckpoint) throws
    func remove(_ id: JobID)
}

public protocol JobQueueStore: Sendable {
    /// Every readable request, oldest first. `ignored` names the files
    /// skipped and why (temps, partial writes, foreign files).
    func list() -> (requests: [JobRequest], ignored: [String])
    func put(_ request: JobRequest) throws
    func remove(_ id: JobID)
    func contains(_ id: JobID) -> Bool
}

// MARK: - Files

public final class FileCheckpointStore: CheckpointStore, @unchecked Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private func url(_ id: JobID) -> URL { directory.appendingPathComponent("\(id.rawValue).json") }

    public func load(_ id: JobID) -> CheckpointReadOutcome {
        let u = url(id)
        guard FileManager.default.fileExists(atPath: u.path) else { return .none }
        do {
            let data = try Data(contentsOf: u)
            return .found(try BackgroundPayloadCodec.decode(JobCheckpoint.self, from: data))
        } catch {
            return .corrupt(words: String(describing: error))
        }
    }

    public func save(_ checkpoint: JobCheckpoint) throws {
        try AtomicFilePublish.write(try BackgroundPayloadCodec.encode(checkpoint), to: url(checkpoint.jobID))
    }

    public func remove(_ id: JobID) {
        try? FileManager.default.removeItem(at: url(id))
    }
}

public final class FileJobQueueStore: JobQueueStore, @unchecked Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private func url(_ id: JobID) -> URL { directory.appendingPathComponent("\(id.rawValue).json") }

    public func list() -> (requests: [JobRequest], ignored: [String]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return ([], []) }
        var requests: [JobRequest] = []
        var ignored: [String] = []
        for name in names.sorted() {
            if AtomicFilePublish.isTemporaryPublishArtifact(name) { ignored.append("\(name): in-flight temp"); continue }
            guard name.hasSuffix(".json") else { ignored.append("\(name): not a queue file"); continue }
            do {
                let data = try Data(contentsOf: directory.appendingPathComponent(name))
                let request = try BackgroundPayloadCodec.decode(JobRequest.self, from: data)
                guard "\(request.id.rawValue).json" == name else {
                    ignored.append("\(name): names job \(request.id)"); continue
                }
                requests.append(request)
            } catch {
                ignored.append("\(name): \(error)")
            }
        }
        requests.sort { ($0.requestedAt, $0.id.rawValue) < ($1.requestedAt, $1.id.rawValue) }
        return (requests, ignored)
    }

    public func put(_ request: JobRequest) throws {
        try AtomicFilePublish.write(try BackgroundPayloadCodec.encode(request), to: url(request.id))
    }

    public func remove(_ id: JobID) {
        try? FileManager.default.removeItem(at: url(id))
    }

    public func contains(_ id: JobID) -> Bool {
        FileManager.default.fileExists(atPath: url(id).path)
    }
}

// MARK: - Memory (tests, scale, fault injection)

public final class InMemoryCheckpointStore: CheckpointStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [JobID: JobCheckpoint] = [:]
    private var corrupt: Set<JobID> = []
    /// Set to make the NEXT saves fail (a full disk): the error is thrown
    /// from `save` until cleared.
    public var saveError: (any Error)?
    public private(set) var saveCount = 0

    public init() {}

    public func load(_ id: JobID) -> CheckpointReadOutcome {
        lock.lock(); defer { lock.unlock() }
        if corrupt.contains(id) { return .corrupt(words: "simulated corrupt checkpoint") }
        return storage[id].map { .found($0) } ?? .none
    }

    public func save(_ checkpoint: JobCheckpoint) throws {
        lock.lock(); defer { lock.unlock() }
        saveCount += 1
        if let saveError { throw saveError }
        storage[checkpoint.jobID] = checkpoint
    }

    public func remove(_ id: JobID) {
        lock.lock(); defer { lock.unlock() }
        storage[id] = nil
        corrupt.remove(id)
    }

    public func markCorrupt(_ id: JobID) {
        lock.lock(); defer { lock.unlock() }
        corrupt.insert(id)
    }

    public func checkpoint(_ id: JobID) -> JobCheckpoint? {
        lock.lock(); defer { lock.unlock() }
        return storage[id]
    }
}

public final class InMemoryJobQueueStore: JobQueueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [JobID: JobRequest] = [:]
    public var putError: (any Error)?

    public init(_ requests: [JobRequest] = []) {
        for r in requests { storage[r.id] = r }
    }

    public func list() -> (requests: [JobRequest], ignored: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (storage.values.sorted { ($0.requestedAt, $0.id.rawValue) < ($1.requestedAt, $1.id.rawValue) }, [])
    }

    public func put(_ request: JobRequest) throws {
        lock.lock(); defer { lock.unlock() }
        if let putError { throw putError }
        storage[request.id] = request
    }

    public func remove(_ id: JobID) {
        lock.lock(); defer { lock.unlock() }
        storage[id] = nil
    }

    public func contains(_ id: JobID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storage[id] != nil
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }
}
