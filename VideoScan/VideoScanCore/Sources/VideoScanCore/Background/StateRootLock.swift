// StateRootLock.swift — VideoScanCore/Background
//
// One supervisor per state root (design §3.4, amended 2026-11-02). The
// service and a hand run (`--run era`) share the same queue, checkpoint and
// journal folders on purpose — that is how the Settings pane can read a hand
// run's checkpoint — which means both can find the SAME queued job and both
// would run it: two model workers over one checkpoint, each clobbering the
// other's count. Seen on the Ultra 2026-11-02 19:58: launchd started the
// helper while the hand run was at unit 2,840 of 4,709 and the helper
// "resumed" that job.
//
// The guard is an advisory `flock(2)` on `<root>/owner.lock`, held for the
// life of the owning process. The kernel drops it when the holder dies —
// a `kill -9` or a reboot leaves nothing stale to clean up — and a second
// claimant gets EWOULDBLOCK at once. The file's contents name the holder in
// words so the refusal can say who: "pid 1861 · cli --run era · since 14:31".
//
// C++ reading: `open` + `flock(fd, LOCK_EX | LOCK_NB)`, RAII on the fd.
// O_CLOEXEC matters: the hand run spawns Python workers, and a child that
// inherited the fd would keep the lock alive after its parent died.

import Foundation

/// What the supervisor asks before it adopts or accepts a job. `claim` is
/// idempotent: once owned, every later call answers `.success`.
public protocol StateRootOwnership: Sendable {
    func claim() -> Result<Void, Refusal>
    func release()
}

/// In-memory stores have no root to contend for (tests, the scale lane).
public struct UncontestedStateRoot: StateRootOwnership {
    public init() {}
    public func claim() -> Result<Void, Refusal> { .success(()) }
    public func release() {}
}

public final class FileStateRootLock: StateRootOwnership, @unchecked Sendable {
    public static let fileName = "owner.lock"

    public let root: URL
    /// Who this process is, for the lock file: "service …" or "cli --run era".
    public let owner: String
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    public init(root: URL, owner: String) {
        self.root = root
        self.owner = owner
    }

    deinit { release() }

    public var url: URL { root.appendingPathComponent(Self.fileName) }

    public var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return descriptor >= 0
    }

    public func claim() -> Result<Void, Refusal> {
        lock.lock(); defer { lock.unlock() }
        if descriptor >= 0 { return .success(()) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            return .failure(Refusal("could not open \(url.path): \(String(cString: strerror(errno)))"))
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            let holder = Self.holderWords(fd)
            close(fd)
            if code == EWOULDBLOCK {
                return .failure(Refusal("\(root.path) is owned by \(holder) — one VideoScan Background per state root"))
            }
            return .failure(Refusal("could not lock \(url.path): \(String(cString: strerror(code)))"))
        }
        descriptor = fd
        Self.write(Self.words(pid: ProcessInfo.processInfo.processIdentifier, owner: owner, since: Date()), to: fd)
        return .success(())
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    /// "pid 1861 · cli --run era · since 14:31"
    static func words(pid: Int32, owner: String, since: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "pid \(pid) · \(owner) · since \(f.string(from: since))"
    }

    private static func holderWords(_ fd: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = pread(fd, &buffer, buffer.count, 0)
        guard n > 0, let text = String(bytes: buffer[0..<n], encoding: .utf8) else { return "another process" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "another process" : trimmed
    }

    private static func write(_ text: String, to fd: Int32) {
        ftruncate(fd, 0)
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { pwrite(fd, $0.baseAddress, $0.count, 0) }
    }
}
