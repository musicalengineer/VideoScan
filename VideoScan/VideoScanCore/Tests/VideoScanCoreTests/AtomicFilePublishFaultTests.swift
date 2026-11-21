// AtomicFilePublishFaultTests.swift
//
// What a publish does when one of its disk steps FAILS — the paths no real
// disk will produce on demand (survey 2026-11-20: "fsync fails, rename fails
// after the temp is written, directory fsync fails" were untestable).
//
// The faults come through `AtomicFilePublish.$hooks` (task-local: each test
// binds its own, so the suite runs in parallel and no other test's publish
// ever sees a fault).
//
// The contract, for every step that can fail the publish:
//   - the destination keeps its OLD bytes (or stays absent),
//   - no `.vspublish.tmp` is left beside it,
//   - the thrown error names the step and carries the errno,
//   - nothing is left in the in-flight registry.
// One step is best-effort BY DESIGN — the directory fsync after the rename —
// and its test pins that: the save has landed, so it reports success.
//
// Five dimensions:
//   1. Logic     — every step × both durabilities × destination present/absent
//   2. Scale     — n/a (one small file per publish; no per-record work)
//   3. Media     — n/a (no media opened)
//   4. Isolation — a fault bound in one task does not reach a publish outside it
//   5. Sensor    — the binding stays internal; the file makes no syscall of a
//                  hooked step outside `Hooks.live`

import Darwin
import Foundation
import Testing
@testable import VideoScanCore

@Suite("AtomicFilePublish — a failed step keeps the old file and leaves no temp")
struct AtomicFilePublishFaultTests {

    // MARK: Helpers

    /// A lock-protected counter a `@Sendable` hook can bump.
    /// (C++: a `std::atomic<int>` shared by reference.)
    final class Hits: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func hit() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        var wasHit: Bool { lock.lock(); defer { lock.unlock() }; return n > 0 }
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtomicFaultTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func names(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private static let old = Data("OLD — the file as it was before the failed publish\n".utf8)
    private static let new = Data(repeating: UInt8(ascii: "N"), count: 64 * 1024)

    struct Fault: Sendable, CustomTestStringConvertible {
        let step: AtomicFilePublish.Hooks.Step
        let durability: AtomicFilePublish.Durability
        let code: Int32
        /// `Failure.operation` for the steps this type reports itself; nil
        /// for `.fast`'s write, whose error is Foundation's.
        let operation: String?
        var testDescription: String { "\(step.rawValue) fails with errno \(code) (\(durability))" }
    }

    static let faults: [Fault] = [
        Fault(step: .writeFast, durability: .fast, code: ENOSPC, operation: nil),
        Fault(step: .write, durability: .fullFsync, code: ENOSPC, operation: "write"),
        Fault(step: .write, durability: .fullFsync, code: EIO, operation: "write"),
        Fault(step: .fullFsync, durability: .fullFsync, code: EIO, operation: "F_FULLFSYNC"),
        Fault(step: .rename, durability: .fast, code: EXDEV, operation: "rename"),
        Fault(step: .rename, durability: .fullFsync, code: EACCES, operation: "rename"),
        Fault(step: .rename, durability: .fullFsync, code: EIO, operation: "rename"),
    ]

    // MARK: 1. Logic — each failing step

    @Test("the destination keeps its old bytes, no temp is left, the error names the step",
          arguments: faults, [true, false])
    func aFailedStepPublishesNothing(_ fault: Fault, destinationExists: Bool) throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("state.json")
        if destinationExists { try Self.old.write(to: dest) }
        let hits = Hits()

        let thrown = #expect(throws: (any Error).self) {
            try AtomicFilePublish.$hooks.withValue(.failing(fault.step, errno: fault.code, onHit: { hits.hit() })) {
                try AtomicFilePublish.write(Self.new, to: dest, durability: fault.durability)
            }
        }

        #expect(hits.count >= 1, "the fault was never reached — this test proved nothing")
        if destinationExists {
            #expect(try Data(contentsOf: dest) == Self.old, "the old file must survive byte for byte")
        } else {
            #expect(!FileManager.default.fileExists(atPath: dest.path), "nothing may appear at the destination")
        }
        #expect(try names(in: dir) == (destinationExists ? ["state.json"] : []), "a temp was left behind")
        #expect(!AtomicFilePublish.inFlight().contains { $0.destination == dest.path })

        if let operation = fault.operation {
            let failure = try #require(thrown as? AtomicFilePublish.Failure)
            #expect(failure.operation == operation)
            #expect(failure.errnoValue == fault.code)
            #expect(failure.localizedDescription.contains(operation))
            #expect(failure.localizedDescription.contains("errno \(fault.code)"))
        } else {
            #expect((thrown as? POSIXError)?.code.rawValue == fault.code)
        }
    }

    @Test("a directory fsync failure does not fail a save that has landed (best-effort by design)")
    func aDirectoryFsyncFailureStillReportsTheLandedSave() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("state.json")
        try Self.old.write(to: dest)
        let hits = Hits()

        try AtomicFilePublish.$hooks.withValue(.failing(.directoryFsync, errno: EIO, onHit: { hits.hit() })) {
            try AtomicFilePublish.write(Self.new, to: dest, durability: .fullFsync)
        }

        #expect(hits.count == 1)
        #expect(try Data(contentsOf: dest) == Self.new, "the rename happened: the new file is what is there")
        #expect(try names(in: dir) == ["state.json"])
    }

    @Test(".fast makes no fsync at all — neither the payload's nor the directory's")
    func fastDurabilityNeverSyncs() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("state.json")
        let hits = Hits()
        var hooks = AtomicFilePublish.Hooks.live
        hooks.fullFsync = { _ in hits.hit(); return EIO }
        hooks.directoryFsync = { _ in hits.hit(); return EIO }
        hooks.write = { _, _, _ in hits.hit(); return (-1, EIO) }

        try AtomicFilePublish.$hooks.withValue(hooks) {
            try AtomicFilePublish.write(Self.new, to: dest, durability: .fast)
        }

        #expect(!hits.wasHit)
        #expect(try Data(contentsOf: dest) == Self.new)
    }

    @Test("an interrupted write (EINTR) is retried, and short writes are continued, to the full payload")
    func interruptedAndShortWritesStillWriteEverything() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("state.json")
        let calls = Hits()
        var hooks = AtomicFilePublish.Hooks.live
        hooks.write = { fd, bytes, count in
            calls.hit()
            if calls.count == 1 { return (-1, EINTR) }
            return (Darwin.write(fd, bytes, min(count, 7_000)), 0)      // short, like a slow pipe
        }

        try AtomicFilePublish.$hooks.withValue(hooks) {
            try AtomicFilePublish.write(Self.new, to: dest, durability: .fullFsync)
        }

        #expect(calls.count > 2)
        #expect(try Data(contentsOf: dest) == Self.new)
        #expect(try names(in: dir) == ["state.json"])
    }

    @Test("publish(_:as:) — a failed rename leaves the destination old and the caller's source in place")
    func aFailedLowLevelPublishTouchesNeitherFile() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("catalog.sqlite")
        let source = dir.appendingPathComponent("rendered.tmp")
        try Self.old.write(to: dest)
        try Self.new.write(to: source)

        let thrown = #expect(throws: AtomicFilePublish.Failure.self) {
            try AtomicFilePublish.$hooks.withValue(.failing(.rename, errno: EXDEV)) {
                try AtomicFilePublish.publish(source, as: dest)
            }
        }

        #expect(thrown?.operation == "rename")
        #expect(thrown?.errnoValue == EXDEV)
        #expect(try Data(contentsOf: dest) == Self.old)
        #expect(try Data(contentsOf: source) == Self.new, "the source is the caller's to clean up, not this call's")
    }

    @Test("with nothing bound the live syscalls publish, both durabilities")
    func unboundIsTheLivePublish() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        for durability in [AtomicFilePublish.Durability.fast, .fullFsync] {
            let dest = dir.appendingPathComponent("\(durability).json")
            try Self.old.write(to: dest)
            try AtomicFilePublish.write(Self.new, to: dest, durability: durability)
            #expect(try Data(contentsOf: dest) == Self.new)
        }
        #expect(try names(in: dir) == ["fast.json", "fullFsync.json"])
    }

    // MARK: The watchdog's evidence

    // The watchdog itself only LOGS (os.Logger, after 10 s) — it changes no
    // outcome, so there is nothing of it to assert. What it reads is the
    // in-flight registry, and that is testable: a publish stalled in the
    // kernel must be visible, by destination, from another thread.
    @Test("a publish stalled in rename is visible in inFlight(), and gone once it returns")
    func aStalledPublishIsVisibleToAnotherThread() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("stalled.json")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        var hooks = AtomicFilePublish.Hooks.live
        let liveRename = hooks.renameSyscall
        hooks.renameSyscall = { from, to in
            entered.signal()
            release.wait()
            return liveRename(from, to)
        }
        let stalling = hooks
        let payload = Self.new
        // A plain thread has no task: the hooks are bound on it directly.
        // (C++: setting the thread_local at the top of the std::thread body.)
        Thread.detachNewThread {
            try? AtomicFilePublish.$hooks.withValue(stalling) {
                try AtomicFilePublish.write(payload, to: dest, durability: .fast)
            }
            finished.signal()
        }

        try #require(entered.wait(timeout: .now() + 10) == .success)
        let stalled = AtomicFilePublish.inFlight().first { $0.destination == dest.path }
        #expect(stalled?.byteCount == Self.new.count)
        #expect(AtomicFilePublish.inFlightSummary()?.contains(dest.path) == true)

        release.signal()
        try #require(finished.wait(timeout: .now() + 10) == .success)
        #expect(!AtomicFilePublish.inFlight().contains { $0.destination == dest.path })
        #expect(try Data(contentsOf: dest) == Self.new)
    }

    // MARK: 4. Isolation

    @Test("a fault bound in one task does not reach a publish outside that task tree")
    func aFaultIsScopedToItsTask() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bystander = dir.appendingPathComponent("bystander.json")
        let payload = Self.new

        try await AtomicFilePublish.$hooks.withValue(.failing(.rename, errno: EIO)) {
            // Detached = outside the task tree: the stand-in for another
            // test running in parallel (and the documented THREAD HOPS caveat).
            try await Task.detached {
                try AtomicFilePublish.write(payload, to: bystander, durability: .fullFsync)
            }.value
        }
        try AtomicFilePublish.write(payload, to: bystander, durability: .fast)   // after the scope: live again

        #expect(try Data(contentsOf: bystander) == Self.new)
    }

    // MARK: 5. Sensor

    @Test("sensor: the hook binding is not public, and no hooked syscall is made outside Hooks.live")
    func theSeamIsInternalAndComplete() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VideoScanCore/AtomicFilePublish.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        for forbidden in ["@TaskLocal public static var hooks", "public struct Hooks"] {
            #expect(!text.contains(forbidden), "\(forbidden) — reachable from the app target")
        }
        // Each hooked syscall appears exactly where Hooks.live makes it (the
        // fault-injecting `failing` helper's own short write is the one more
        // `Darwin.write`). A new direct call would be a step no test can fail.
        func count(_ needle: String) -> Int { text.components(separatedBy: needle).count - 1 }
        #expect(count("Darwin.rename(") == 1)
        #expect(count("fcntl(fd, F_FULLFSYNC)") == 2)
        #expect(count("Darwin.write(") == 2)
        #expect(count("data.write(to:") == 1)
    }
}
