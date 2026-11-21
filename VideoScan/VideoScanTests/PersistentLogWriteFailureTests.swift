// PersistentLogWriteFailureTests.swift
//
// Codex r1 on the publish/debounce seams (2026-11-21), P1: the one log sink
// could take the app down on a full disk. `PersistentLog` wrote with
// `FileHandle.write(_:)`, which RAISES NSFileHandleOperationException (an
// Objective-C exception — Swift's `catch` cannot contain it) when write(2)
// fails. The lines most likely to be written on a full disk are exactly the
// "…could not be written" diagnostics.
//
// The fault here needs no full disk: the sink's own file descriptor is
// swapped underneath it (dup2) for a READ-ONLY one, so every write(2) fails
// with EBADF — and swapped back to show recovery. Before the fix the first
// `write` in these tests killed the test host with
// "NSFileHandleOperationException … Bad file descriptor".
//
// The contract: a line that cannot be written is dropped and COUNTED; when
// writing works again the sink says so once ("N log lines could not be
// written: <reason>"); it never throws or traps; and when writes succeed the
// file is byte-for-byte what it always was.
//
// Five dimensions: logic (here) · scale (10k failing lines: bounded state,
// no growth) · media n/a · isolation (each test its own directory and its
// own descriptor) · sensor (no raising FileHandle call is left in the sinks).
//
// C++ readers: dup2(newfd, fd) atomically re-points `fd` at another open
// file — the handle object keeps its number and never knows.

import Darwin
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("PersistentLog — a line that cannot be written is dropped and counted, never a crash")
struct PersistentLogWriteFailureTests {

    private func scratch(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_logfail_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The process's open descriptors on `url` (the sink's handle).
    static func descriptors(on url: URL) -> [Int32] {
        let want = url.resolvingSymlinksInPath().path
        var found: [Int32] = []
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for fd in Int32(3)..<4096 where fcntl(fd, F_GETPATH, &buffer) == 0 {
            if URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).resolvingSymlinksInPath().path == want { found.append(fd) }
        }
        return found
    }

    /// Re-point `fd` at `url` opened with `flags`.
    static func repoint(_ fd: Int32, at url: URL, flags: Int32) throws {
        let fresh = open(url.path, flags)
        try #require(fresh >= 0)
        try #require(dup2(fresh, fd) == fd)
        close(fresh)
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test("writes that fail are dropped without a crash, the file is untouched, and the first write that works says how many were lost and why")
    func failedWritesAreDroppedCountedAndSaid() throws {
        let dir = try scratch("drop"); defer { try? FileManager.default.removeItem(at: dir) }
        let log = PersistentLog(name: "sink", directory: dir)
        log.start()
        log.write("before the disk went away")
        let before = try Data(contentsOf: log.url)
        let fd = try #require(Self.descriptors(on: log.url).first, "the sink's descriptor")

        try Self.repoint(fd, at: log.url, flags: O_RDONLY)              // every write(2) now fails: EBADF
        log.write("lost 1")
        log.write("lost 2")
        log.writeBatch(["lost 3", "lost 4"])
        log.flush()
        #expect(try Data(contentsOf: log.url) == before, "nothing reached the file")
        #expect(log.droppedLineCount == 4, "every lost line is counted (a batch by its lines)")

        try Self.repoint(fd, at: log.url, flags: O_WRONLY | O_APPEND)   // writing works again
        log.write("after it came back")
        log.write("and one more")

        let tail = try text(log.url).split(separator: "\n").suffix(3).map(String.init)
        #expect(tail.count == 3)
        #expect(tail[0].hasSuffix("] 4 log lines could not be written: Bad file descriptor (errno 9)"), "\(tail)")
        #expect(tail[1].hasSuffix("] after it came back"))
        #expect(tail[2].hasSuffix("] and one more"), "said once, not on every line after")
        #expect(try text(log.url).components(separatedBy: "could not be written").count == 2)
        log.close()
    }

    @Test("SCALE: 10k lines into a failing descriptor return promptly, hold no backlog, and are reported as one number")
    func aLongOutageIsOneNumber() throws {
        let dir = try scratch("scale"); defer { try? FileManager.default.removeItem(at: dir) }
        let log = PersistentLog(name: "sink", directory: dir)
        log.start()
        let fd = try #require(Self.descriptors(on: log.url).first)
        try Self.repoint(fd, at: log.url, flags: O_RDONLY)
        let took = ContinuousClock().measure {
            for i in 0..<10_000 { log.write("lost \(i)") }
        }
        #expect(took < .seconds(10), "\(took)")
        #expect(log.droppedLineCount == 10_000)
        #expect(log.synchronizeCount == 0, "no fsync for a line that did not land")
        try Self.repoint(fd, at: log.url, flags: O_WRONLY | O_APPEND)
        log.write("back")
        log.close()
        #expect(try text(log.url).contains("] 10000 log lines could not be written: Bad file descriptor (errno 9)\n"))
    }

    @Test("start's header, close's footer and flush on a failing descriptor do not crash either")
    func headerFooterAndFlushAreContained() throws {
        let dir = try scratch("edges"); defer { try? FileManager.default.removeItem(at: dir) }
        let log = PersistentLog(name: "sink", directory: dir)
        log.start()
        let fd = try #require(Self.descriptors(on: log.url).first)
        try Self.repoint(fd, at: log.url, flags: O_RDONLY)
        log.write("lost")
        log.flush()
        log.close()                                                      // the footer cannot be written
        #expect(!log.isOpen)
        #expect(try !text(log.url).contains("Log closed."))

        log.start(append: true)                                          // a fresh handle: the sink works again
        log.write("a new session")
        log.close()
        #expect(try text(log.url).contains("] a new session\n"))
    }

    @Test("when writes succeed the file is byte-for-byte the old layout: header, stamped lines, a batch with one stamp, footer")
    func theLayoutIsUnchangedWhenWritesSucceed() throws {
        let dir = try scratch("layout"); defer { try? FileManager.default.removeItem(at: dir) }
        let log = PersistentLog(name: "sink", directory: dir)
        log.start()
        log.write("one")
        log.writeBatch(["two", "three"])
        log.close()
        let rule = "─────────────────────────────────────────────"
        let lines = try text(log.url).components(separatedBy: "\n")
        #expect(lines.count == 8, "\(lines)")
        #expect(lines[0].wholeMatch(of: /VideoScan sink log — started \d{4}-\d\d-\d\d \d\d:\d\d:\d\d/) != nil)
        #expect(lines[1] == rule)
        #expect(lines[2].wholeMatch(of: /\[\d\d:\d\d:\d\d\] one/) != nil)
        #expect(lines[3].wholeMatch(of: /\[\d\d:\d\d:\d\d\] two/) != nil)
        #expect(lines[4].wholeMatch(of: /\[\d\d:\d\d:\d\d\] three/) != nil)
        #expect(lines[5] == rule)
        #expect(lines[6] == "Log closed.")
        #expect(lines[7].isEmpty)
        #expect(log.synchronizeCount == 2, "one fsync per write, one per batch — as before")
    }
}
