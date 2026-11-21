// ContainedLogWriteTests.swift
//
// Codex r1 (2026-11-21). P1: a file log sink's write must never take the
// process down (`FileHandle.write(_:)` raises an ObjC exception when
// write(2) fails) — `ContainedLogWrite` drops, counts and later says.
// P2: `TimingBudget.nanoseconds` saturates instead of trapping.
//
// The failing handle needs no full disk: a handle opened for READING fails
// every write(2) with EBADF, and for the whole sink its descriptor is
// re-pointed underneath it with dup2.
//
// Five dimensions: logic · scale (100k failed lines: constant state) ·
// media n/a · isolation (own scratch file per test) · sensor (no raising
// FileHandle write is left in the sinks' sources).

import Darwin
import Foundation
import Testing
@testable import VideoScanCore

@Suite("ContainedLogWrite — a failed log write is dropped, counted and said; never raised")
struct ContainedLogWriteTests {

    private func scratchFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainedLogWrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sink.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    @Test("a write that succeeds adds nothing: the bytes on disk are exactly the bytes given")
    func successIsByteForByte() throws {
        let url = try scratchFile(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let handle = try FileHandle(forWritingTo: url)
        var sink = ContainedLogWrite()
        do { let landed = sink.write(Data("[00:00:01] one\n".utf8), lines: 1, to: handle, stampPrefix: "[X] "); #expect(landed) }
        do { let landed = sink.write(Data("[00:00:02] two\n".utf8), lines: 1, to: handle, stampPrefix: "[X] "); #expect(landed) }
        try handle.close()
        #expect(try String(contentsOf: url, encoding: .utf8) == "[00:00:01] one\n[00:00:02] two\n")
        #expect(sink.droppedLines == 0 && sink.totalDroppedLines == 0)
    }

    @Test("failed writes are counted with the errno's words; the next good write carries ONE notice first, then nothing more")
    func failuresAreCountedThenSaidOnce() throws {
        let url = try scratchFile(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let broken = try FileHandle(forReadingFrom: url)                 // write(2) → EBADF
        let good = try FileHandle(forWritingTo: url)
        var sink = ContainedLogWrite()

        do { let landed = sink.write(Data("a\n".utf8), lines: 1, to: broken, stampPrefix: "[T] "); #expect(!landed) }
        do { let landed = sink.write(Data("b\nc\n".utf8), lines: 2, to: broken, stampPrefix: "[T] "); #expect(!landed) }
        do { let landed = sink.write(Data("header\n".utf8), lines: 0, to: broken, stampPrefix: "[T] "); #expect(!landed) }
        #expect(sink.droppedLines == 3)
        #expect(sink.lastFailure == "Bad file descriptor (errno 9)")
        #expect(try Data(contentsOf: url).isEmpty)

        do { let landed = sink.write(Data("d\n".utf8), lines: 1, to: good, stampPrefix: "[T] "); #expect(landed) }
        do { let landed = sink.write(Data("e\n".utf8), lines: 1, to: good, stampPrefix: "[T] "); #expect(landed) }
        #expect(try String(contentsOf: url, encoding: .utf8)
                == "[T] 3 log lines could not be written: Bad file descriptor (errno 9)\nd\ne\n")
        #expect(sink.droppedLines == 0)
        #expect(sink.totalDroppedLines == 3, "the lifetime count is kept")

        do { let landed = sink.write(Data("f\n".utf8), lines: 1, to: broken, stampPrefix: "[T] "); #expect(!landed) }
        do { let landed = sink.write(Data("g\n".utf8), lines: 1, to: good, stampPrefix: "[T] "); #expect(landed) }
        #expect(try String(contentsOf: url, encoding: .utf8).hasSuffix("[T] 1 log line could not be written: Bad file descriptor (errno 9)\ng\n"))
    }

    @Test("SCALE: 100k failed lines cost no memory beyond the counter, and a count at Int.max saturates",
          .tags(.quietMachine))   // judges a wall-time bound: the serial phase (QuietMachine.swift)
    func aLongOutageIsBounded() throws {
        let url = try scratchFile(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let broken = try FileHandle(forReadingFrom: url)
        var sink = ContainedLogWrite()
        let line = Data("x\n".utf8)
        let clock = ContinuousClock()
        let took = clock.measure {
            for _ in 0..<100_000 { sink.write(line, lines: 1, to: broken, stampPrefix: "[T] ") }
        }
        #expect(sink.droppedLines == 100_000)
        #expect(MemoryLayout<ContainedLogWrite>.size <= 64, "two integers and a string — nothing accumulates")
        expectBudget(took, under: .seconds(10), "\(took)")
        sink.write(line, lines: .max, to: broken, stampPrefix: "[T] ")
        #expect(sink.droppedLines == .max && sink.totalDroppedLines == .max, "saturates, never traps")
        sink.write(line, lines: -5, to: broken, stampPrefix: "[T] ")
        #expect(sink.droppedLines == .max)
    }

    @Test("BackgroundFileLog: its descriptor failing underneath it drops and counts; the line after recovery says so")
    func theBackgroundSinkIsContained() throws {
        let url = try scratchFile(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = BackgroundFileLog(url: url)
        log.start()
        log.write("before")
        let want = url.resolvingSymlinksInPath().path
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let fd = try #require((Int32(3)..<4096).first { fcntl($0, F_GETPATH, &buffer) == 0
            && URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).resolvingSymlinksInPath().path == want })
        func repoint(_ flags: Int32) throws {
            let fresh = open(url.path, flags)
            try #require(fresh >= 0 && dup2(fresh, fd) == fd)
            close(fresh)
        }

        try repoint(O_RDONLY)
        log.write("lost 1")                                              // raised NSFileHandleOperationException before the fix
        log.write("lost 2")
        #expect(log.droppedLineCount == 2)
        try repoint(O_WRONLY | O_APPEND)
        log.write("after")
        log.close()

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").suffix(2).map(String.init)
        #expect(lines.first?.hasSuffix("] 2 log lines could not be written: Bad file descriptor (errno 9)") == true, "\(lines)")
        #expect(lines.last?.hasSuffix("] after") == true)
    }

    @Test("SENSOR: the file sinks make no raising FileHandle call (write(_:), seekToEndOfFile, synchronizeFile, closeFile)")
    func noRaisingFileHandleCallIsLeft() throws {
        let core = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = [core.appendingPathComponent("Sources/VideoScanCore/Background/BackgroundLogSink.swift"),
                     core.deletingLastPathComponent().appendingPathComponent("VideoScan/Shared/PersistentLog.swift")]
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for raising in ["handle.write(data)", "handle?.write(data)", "seekToEndOfFile", "synchronizeFile", "closeFile", ".write(data)\n"] {
                #expect(!code.contains(raising), "\(file.lastPathComponent): \(raising) raises an ObjC exception when the disk fails")
            }
            #expect(code.contains("contained.write("), "\(file.lastPathComponent) writes through ContainedLogWrite")
        }
    }
}

@Suite("TimingBudget.nanoseconds — saturating")
struct TimingBudgetNanosecondsTests {

    @Test("exact where it fits; zero for zero and negative; UInt64.max past the end — never a trap")
    func saturates() {
        #expect(TimingBudget.nanoseconds(.seconds(2)) == 2_000_000_000, "the production debounce, exactly")
        #expect(TimingBudget.nanoseconds(.milliseconds(50)) == 50_000_000)
        #expect(TimingBudget.nanoseconds(.nanoseconds(1)) == 1)
        #expect(TimingBudget.nanoseconds(.zero) == 0)
        #expect(TimingBudget.nanoseconds(.seconds(-5)) == 0)
        #expect(TimingBudget.nanoseconds(.milliseconds(-1)) == 0)
        #expect(TimingBudget.nanoseconds(.seconds(18_446_744_073)) == 18_446_744_073_000_000_000, "the last whole second that fits")
        #expect(TimingBudget.nanoseconds(.seconds(18_446_744_073) + .milliseconds(800)) == .max, "the sum overflows")
        #expect(TimingBudget.nanoseconds(.seconds(18_446_744_074)) == .max)
        #expect(TimingBudget.nanoseconds(.seconds(Int64.max)) == .max)
        #expect(TimingBudget.nanoseconds(.seconds(Int64.min)) == 0)
    }
}
