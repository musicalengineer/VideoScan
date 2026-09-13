// MediaLedgerTests.swift
// The Media Ledger's file contract (promote-and-prune stage 2, Rick
// 2026-09-12):
//
//   LOGIC     one append per batch, batches land in call order, the file
//             is valid JSONL, the readers find lines by filename / content
//             key / record id, narrated sentences newest first and cached
//             per record until the next append (bounded cache).
//   OFF-MAIN  the writer seam records the thread: zero writes on the main
//             thread, and `append` returns before any write happens.
//   FAILURE   a writer that refuses logs the path + the real error and the
//             ledger keeps accepting later batches.
//   MIRROR    mirror(intoArchiveRoot:) lands 00_Index/media-ledger.jsonl
//             byte-identical, atomically (no .partial left), after the
//             appends issued before it; a missing 00_Index logs, no throw.
//   ISOLATION under a test host the DEFAULT directory is a per-process
//             scratch folder, never App Support; the real path is untouched.
//   SENSOR    the first successful write logs the ledger path once.
//
// Everything runs against temp directories; the log sink is swapped
// (serialized suite).

import Foundation
import Testing
@testable import VideoScan

/// A writer seam that counts calls, records the thread, and can refuse.
final class ThreadRecordingLedgerWriter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    private(set) var sawMainThread = false
    private(set) var bytes: [Int] = []
    var refuse = false
    var writer: MediaLedger.Writer {
        { [self] data, url in
            let main = Thread.isMainThread
            lock.lock()
            calls += 1; sawMainThread = sawMainThread || main; bytes.append(data.count)
            let refuse = self.refuse
            lock.unlock()
            if refuse { throw MediaLedger.Failure.io("write \(url.lastPathComponent)", errno: EACCES) }
            try MediaLedger.appendDurable(data, to: url)
        }
    }
}

/// Buffers every log line (for the path sensor + failure text).
final class BufferingLedgerLogSink: LogSink, @unchecked Sendable {
    let name = "ledger-buffer"
    var fileURL: URL? { nil }
    private let lock = NSLock()
    private var buffer: [String] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return buffer }
    func start(append: Bool) {}
    func flush() {}
    func close() {}
    func write(_ line: String) { lock.lock(); buffer.append(line); lock.unlock() }
    func writeBatch(_ lines: [String]) { lock.lock(); buffer.append(contentsOf: lines); lock.unlock() }
}

@Suite("Media Ledger — file contract", .serialized)
struct MediaLedgerTests {

    private let at = Date(timeIntervalSince1970: 1_757_700_000)

    private func tempDir(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_ledger_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func event(_ kind: MediaLedgerEvent.Kind, name: String = "a.mov", key: String = "h:v1:a",
                       id: UUID = UUID(), at offset: TimeInterval = 0, by: MediaLedgerEvent.Actor = .rick,
                       detail: [String: String] = [:]) -> MediaLedgerEvent {
        MediaLedgerEvent(at: at.addingTimeInterval(offset), event: kind, recordID: id, contentKey: key,
                         filename: name, fullPath: "/Volumes/T/\(name)", by: by, detail: detail)
    }

    @Test("one append per batch; batches land in call order; the file is valid JSONL; readers find lines")
    func appendsInOrderAndReadersFind() async throws {
        let dir = tempDir("order")
        defer { try? FileManager.default.removeItem(at: dir) }
        let seam = ThreadRecordingLedgerWriter()
        let ledger = MediaLedger(directory: dir, writer: seam.writer)
        let id = UUID()
        ledger.append([event(.cataloged, id: id), event(.setAside, id: id, at: 1, by: .tidy, detail: ["reason": "still-image"])])
        ledger.append([event(.putBack, id: id, at: 2)])
        ledger.append([event(.archived, name: "b.mov", key: "h:v1:b", at: 3, by: .promote)])
        #expect(ledger.append([]) == nil, "an empty batch is a no-op")
        await ledger.waitForPendingWrites()
        #expect(seam.calls == 3)
        #expect(ledger.appendCount == 3 && ledger.lineCount == 4)

        let text = try String(contentsOf: ledger.fileURL, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 4)
        #expect(text.hasSuffix("\n"))
        let all = ledger.allEvents()
        #expect(all.map(\.event) == [.cataloged, .setAside, .putBack, .archived], "file order == call order")

        #expect(ledger.events(forFilename: "a.mov").count == 3)
        #expect(ledger.events(forFilename: "").isEmpty)
        #expect(ledger.events(forContentKey: "h:v1:b").map(\.event) == [.archived])
        #expect(ledger.events(forContentKey: "").isEmpty)
        #expect(ledger.events(forRecordID: id).count == 3)
        #expect(ledger.events(recordID: UUID(), contentKey: "h:v1:a", filename: "zzz").count == 3, "content key joins copies")
        #expect(ledger.events(recordID: UUID(), contentKey: "", filename: "a.mov").count == 3, "filename only when the content is unknown")
        #expect(ledger.events(recordID: UUID(), contentKey: "h:v1:none", filename: "a.mov").isEmpty, "a known but different content never falls back to the filename")
    }

    @Test("OFF-MAIN: append returns before any write; no write ever runs on the main thread")
    @MainActor
    func writesNeverOnMain() async throws {
        let dir = tempDir("offmain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let seam = ThreadRecordingLedgerWriter()
        let ledger = MediaLedger(directory: dir, writer: seam.writer)
        var tasks: [Task<Void, Never>] = []
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<50 {
                if let t = ledger.append([event(.placeSet, at: TimeInterval(i), detail: ["place": "Cape Cod"])]) { tasks.append(t) }
            }
        }
        #expect(elapsed < .milliseconds(200), "50 appends must return without waiting on the file: \(elapsed)")
        for t in tasks { await t.value }
        #expect(seam.calls == 50)
        #expect(!seam.sawMainThread, "a write on the main thread is the beachball this design forbids")
        #expect(ledger.allEvents().count == 50)
    }

    @Test("FAILURE: a refusing writer logs the path and the real error; later batches still land")
    func refusalIsLoggedAndRecovers() async throws {
        let dir = tempDir("refuse")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = BufferingLedgerLogSink()
        let saved = appLog
        appLog = sink
        defer { appLog = saved }
        let seam = ThreadRecordingLedgerWriter()
        let ledger = MediaLedger(directory: dir, writer: seam.writer)
        seam.refuse = true
        await ledger.append([event(.restored)])?.value
        seam.refuse = false
        await ledger.append([event(.restored, at: 1)])?.value
        let failure = sink.lines.first { $0.hasPrefix("ledger: 1 line(s) not written to ") }
        #expect(failure != nil, "\(sink.lines)")
        #expect(failure?.contains(ledger.fileURL.path) == true)
        #expect(failure?.contains("errno 13") == true, "the REAL errno, never a generic message: \(failure ?? "")")
        #expect(ledger.allEvents().count == 1, "the refused batch is gone; the next one landed")
    }

    @Test("SENSOR: the first successful write logs the ledger path once")
    func firstWriteAnnouncesPath() async throws {
        let dir = tempDir("announce")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = BufferingLedgerLogSink()
        let saved = appLog
        appLog = sink
        defer { appLog = saved }
        let ledger = MediaLedger(directory: dir)
        await ledger.append([event(.dateSet)])?.value
        await ledger.append([event(.dateSet, at: 1)])?.value
        let announcements = sink.lines.filter { $0 == "ledger: media ledger at \(ledger.fileURL.path)" }
        #expect(announcements.count == 1, "\(sink.lines)")
    }

    @Test("narrated sentences are newest first, cached per record until the next append, and the cache is bounded")
    func narratedIsCachedAndBounded() async throws {
        let dir = tempDir("narrate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = MediaLedger(directory: dir)
        let id = UUID()
        await ledger.append([event(.cataloged, id: id, at: 0), event(.archived, id: id, at: 10, by: .promote, detail: ["verified": "true", "archive": "FamilyArchive"])])?.value
        let utc = TimeZone(identifier: "UTC")!
        let first = await ledger.narrated(recordID: id, contentKey: "h:v1:a", filename: "a.mov", timeZone: utc)
        #expect(first.count == 2)
        #expect(first[0].hasPrefix("Archived to FamilyArchive on"), "\(first)")
        #expect(first[1].hasPrefix("Cataloged on"))
        #expect(ledger.narratedCacheCount == 1)
        // A record with no lines: the empty state.
        let none = await ledger.narrated(recordID: UUID(), contentKey: "h:none", filename: "none.mov", timeZone: utc)
        #expect(none.isEmpty)
        #expect(ledger.narratedCacheCount == 2)
        // An append invalidates; the next read sees the new line on top.
        await ledger.append([event(.copyTrashed, id: id, at: 20)])?.value
        #expect(ledger.narratedCacheCount == 0)
        let again = await ledger.narrated(recordID: id, contentKey: "h:v1:a", filename: "a.mov", timeZone: utc)
        #expect(again.count == 3 && again[0].hasPrefix("You moved this copy to the Trash"))
        // Bounded: more records than the limit never grow past it.
        for _ in 0..<(MediaLedger.cacheLimit + 10) {
            _ = await ledger.narrated(recordID: UUID(), contentKey: "", filename: "", timeZone: utc)
        }
        #expect(ledger.narratedCacheCount <= MediaLedger.cacheLimit)
    }

    @Test("MIRROR: 00_Index/media-ledger.jsonl is byte-identical, atomic, and ordered after earlier appends; a missing index logs, never throws")
    @MainActor
    func mirrorIntoArchive() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("ledgermirror")
        defer { sb.cleanup() }
        _ = try VideoScanModel.scaffoldMasterArchive(rootURL: sb.archiveRoot)
        let dir = tempDir("mirror")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = MediaLedger(directory: dir)
        ledger.append([event(.archived, at: 0, by: .promote), event(.archived, name: "b.mov", key: "h:v1:b", at: 1, by: .promote)])
        // Issued right after the append, WITHOUT awaiting it — the mirror
        // must still include those lines (same ordered worker).
        await ledger.mirror(intoArchiveRoot: sb.archiveRoot.path).value
        let mirrorURL = MediaLedger.mirrorURL(rootPath: sb.archiveRoot.path)
        let source = try Data(contentsOf: ledger.fileURL)
        #expect(try Data(contentsOf: mirrorURL) == source)
        #expect(source.count > 0)
        let partial = sb.archiveRoot.appendingPathComponent(MasterArchiveLayout.indexFolder).appendingPathComponent(MediaLedger.mirrorPartialName)
        #expect(!FileManager.default.fileExists(atPath: partial.path), "no .partial left behind")
        // A second mirror after more lines replaces the whole file.
        await ledger.append([event(.attestation, at: 2, detail: ["kind": "cloud", "answer": "yes"])])?.value
        await ledger.mirror(intoArchiveRoot: sb.archiveRoot.path).value
        #expect(MediaLedger.events(at: mirrorURL).count == 3)
        #expect(try Data(contentsOf: mirrorURL) == (try Data(contentsOf: ledger.fileURL)))

        // Missing 00_Index (an unscaffolded root): logged, not thrown.
        let sink = BufferingLedgerLogSink()
        let saved = appLog
        appLog = sink
        defer { appLog = saved }
        let bogus = dir.appendingPathComponent("not-an-archive", isDirectory: true).path
        await ledger.mirror(intoArchiveRoot: bogus).value
        #expect(sink.lines.contains { $0.hasPrefix("ledger: mirror into \(bogus)/") }, "\(sink.lines)")
    }

    @Test("ISOLATION: the default directory under a test host is a per-process scratch folder, never App Support")
    @MainActor
    func defaultDirectoryIsIsolated() {
        let dir = MediaLedger.defaultDirectory
        #expect(dir.path.hasPrefix(NSTemporaryDirectory()) || dir.path.contains("/VideoScan-tests/ledger-"), "\(dir.path)")
        #expect(!dir.path.contains("Application Support"), "\(dir.path)")
        #expect(dir.lastPathComponent == "ledger-\(ProcessInfo.processInfo.processIdentifier)")
        // The model's default ledger lives there too.
        #expect(VideoScanModel().mediaLedger.directory == dir)
    }
}
