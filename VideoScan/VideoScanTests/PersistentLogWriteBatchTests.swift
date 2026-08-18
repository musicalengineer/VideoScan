import Testing
import Foundation
@testable import VideoScan

// MARK: - PersistentLogWriteBatchTests
//
// GH #162 QA (2026-08-18). `PersistentLog.writeBatch` exists so the
// Reconcile-preview logger can dump thousands–100k `[PREVIEW]` lines
// without a DateFormatter + write + fsync PER LINE on the main actor.
// Two things to pin:
//
//   1. Logic — a batch lands in the file as exactly the same stamped
//      lines N single `write` calls would produce (same "[HH:mm:ss] "
//      prefix, same order, one line each).
//   2. Scale sensor — 100k lines cost ONE fsync (synchronizeCount seam),
//      and finish well inside a stated budget. If someone "simplifies"
//      writeBatch back into a loop over write(), this fails.
//
// Hermetic: each test writes to its own temp directory via the
// PersistentLog(name:directory:) injection seam.

@Suite("PersistentLog.writeBatch (GH #162 QA)")
struct PersistentLogWriteBatchTests {

    private func makeLog(_ tag: String) throws -> (log: PersistentLog, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-writebatch-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (PersistentLog(name: "batch", directory: dir), dir)
    }

    /// Body lines after the 2-line start() header, with the "[HH:mm:ss] "
    /// stamp stripped so a second-boundary between two writes can't flake
    /// the comparison.
    private func bodyLines(of url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst(2)                       // header + rule
            .filter { !$0.isEmpty }
            .map { line -> String in
                // "[12:34:56] rest" → "rest"
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return String(line) }
                return String(line[line.index(close, offsetBy: 2)...])
            }
    }

    @Test("writeBatch == N writes (same lines, same order, same stamp shape)")
    func batchMatchesSingleWrites() throws {
        let lines = (0..<50).map { "[PREVIEW][RECONCILE] adopted: /Volumes/Src/\($0).mov → /Volumes/Dest/\($0).mov" }

        let single = try makeLog("single")
        single.log.start(append: true)
        for l in lines { single.log.write(l) }
        single.log.close()

        let batched = try makeLog("batched")
        batched.log.start(append: true)
        batched.log.writeBatch(lines)
        batched.log.close()

        let a = try bodyLines(of: single.log.url)
        let b = try bodyLines(of: batched.log.url)
        // Both end with the close() footer ("────", "Log closed."); the
        // 50 payload lines must be identical and in order.
        #expect(Array(a.prefix(50)) == lines)
        #expect(Array(b.prefix(50)) == lines)
        #expect(a == b)

        // Every batched line carries the same "[HH:mm:ss] " stamp shape
        // as a single write.
        let raw = try String(contentsOf: batched.log.url, encoding: .utf8)
            .split(separator: "\n").dropFirst(2).prefix(50)
        let stampRE = try NSRegularExpression(pattern: #"^\[\d\d:\d\d:\d\d\] "#)
        for line in raw {
            let s = String(line)
            #expect(stampRE.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil, "unstamped: \(s)")
        }
        try? FileManager.default.removeItem(at: single.dir)
        try? FileManager.default.removeItem(at: batched.dir)
    }

    @Test("empty batch is a no-op — no bytes, no fsync")
    func emptyBatchNoOp() throws {
        let t = try makeLog("empty")
        t.log.start(append: true)
        let before = t.log.synchronizeCount
        let sizeBefore = (try? FileManager.default.attributesOfItem(atPath: t.log.url.path))?[.size] as? Int
        t.log.writeBatch([])
        #expect(t.log.synchronizeCount == before)
        let sizeAfter = (try? FileManager.default.attributesOfItem(atPath: t.log.url.path))?[.size] as? Int
        #expect(sizeBefore == sizeAfter)
        try? FileManager.default.removeItem(at: t.dir)
    }

    @Test("writeBatch before start() is a silent no-op like write()")
    func batchBeforeStartIsNoOp() throws {
        let t = try makeLog("nostart")
        t.log.writeBatch(["x", "y"])
        #expect(!FileManager.default.fileExists(atPath: t.log.url.path))
        #expect(t.log.synchronizeCount == 0)
        try? FileManager.default.removeItem(at: t.dir)
    }

    // regression: scale sensor — the whole reason writeBatch exists. 100k
    // lines (a whole-volume Reconcile preview at catalog scale) must be
    // ONE fsync and land in well under a second. Budget: 2 s on any of
    // the fleet's SSDs (M4 measures tens of ms); per-line write() at this
    // count is tens of seconds of fsync.
    @Test("100k lines: one fsync, inside budget")
    func scale100kLinesOneFsync() throws {
        let t = try makeLog("scale")
        t.log.start(append: true)
        let base = t.log.synchronizeCount
        let lines = (0..<100_000).map {
            "[PREVIEW][RECONCILE] safely-redundant: /Volumes/Src/dir/\($0)/clip.mov — 3 witness(es), first: /Volumes/Other/clip.mov"
        }
        let t0 = Date()
        t.log.writeBatch(lines)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(t.log.synchronizeCount - base == 1, "expected exactly one fsync for the batch, got \(t.log.synchronizeCount - base)")
        #expect(elapsed < 2.0, "100k-line batch took \(elapsed)s (budget 2 s)")
        t.log.close()
        // And every line actually landed.
        let body = try bodyLines(of: t.log.url)
        #expect(body.count == 100_000 + 2)   // + close() footer lines
        #expect(body.first == lines.first)
        #expect(body[99_999] == lines[99_999])
        try? FileManager.default.removeItem(at: t.dir)
    }
}
