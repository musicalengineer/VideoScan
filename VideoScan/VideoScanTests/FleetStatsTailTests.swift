import Testing
import Foundation
@testable import VideoScan

// MARK: - Fleet-stat tail-read + raw-byte line-count tests
//
// 2026-06-10 beachball fix: the Dossier Dashboard's 5s fleet refresh
// was reading every worker JSONL whole (≈58 MB across hosts) and doing
// a grapheme-aware String split on the main thread — ~2s of contiguous
// main-thread work per tick (measured via `sample`, baseline at
// /tmp/vs_sample.txt). The fix:
//
//   1. refreshFleet now loads off the main actor
//   2. the sentinel is found via a 4 KB FileHandle tail read
//      (it's always the LAST line of the JSONL)
//   3. line counting is raw 0x0A byte counting in chunked reads,
//      gated by an (mtime, size) cache from the previous tick
//
// These tests pin the pure pieces — FleetStats.lastLine(ofTail:) and
// FleetStats.newlineCount(in:) — plus the thin I/O wrappers
// (readTail, countNewlines) and the cache-reuse contract of
// load(from:cache:). Boundary cases matter here: the tail window can
// land mid-line and mid-UTF-8-character, and a regression back to
// String-based counting would re-introduce the beachball silently.

// MARK: - lastLine(ofTail:)

@Suite("FleetStats.lastLine(ofTail:) — tail-line extraction")
struct FleetStatsLastLineTests {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    @Test func empty_tail_returns_nil() {
        #expect(FleetStats.lastLine(ofTail: Data()) == nil)
    }

    @Test func tail_of_only_newlines_returns_nil() {
        #expect(FleetStats.lastLine(ofTail: data("\n\n\n")) == nil)
    }

    @Test func single_line_without_trailing_newline() {
        // Partial final write — worker flushed the JSON but not the \n.
        #expect(FleetStats.lastLine(ofTail: data(#"{"a":1}"#)) == #"{"a":1}"#)
    }

    @Test func single_line_with_trailing_newline() {
        #expect(FleetStats.lastLine(ofTail: data("{\"a\":1}\n")) == #"{"a":1}"#)
    }

    @Test func multiple_lines_returns_last() {
        let tail = data("{\"a\":1}\n{\"b\":2}\n{\"_status\":\"done\"}\n")
        #expect(FleetStats.lastLine(ofTail: tail) == #"{"_status":"done"}"#)
    }

    @Test func multiple_trailing_newlines_are_stripped() {
        let tail = data("{\"a\":1}\n{\"b\":2}\n\n\n")
        #expect(FleetStats.lastLine(ofTail: tail) == #"{"b":2}"#)
    }

    @Test func whole_small_file_as_tail_returns_its_last_line() {
        // File smaller than the tail window — the "tail" IS the file,
        // so the first segment is a complete line too. We still only
        // want the last one.
        let tail = data("{\"first\":1}\n{\"last\":2}")
        #expect(FleetStats.lastLine(ofTail: tail) == #"{"last":2}"#)
    }

    @Test func tail_starting_mid_multibyte_char_without_newline_returns_nil() {
        // Seek landed inside a multi-byte UTF-8 sequence AND the window
        // contains no newline — decoding must fail and we must return
        // nil, never a garbled partial line. "é" is 0xC3 0xA9; dropping
        // the lead byte leaves an orphaned continuation byte.
        var bytes = Data("é tail without newline".utf8)
        bytes = bytes.dropFirst()  // orphan the continuation byte 0xA9
        #expect(FleetStats.lastLine(ofTail: bytes) == nil)
    }

    @Test func tail_starting_mid_multibyte_char_with_newline_recovers_last_line() {
        // Seek landed mid-character, but a newline exists later in the
        // window. Since 0x0A never appears inside a multi-byte UTF-8
        // sequence, the slice AFTER the last newline is valid — the
        // garbage prefix must not poison extraction.
        var bytes = Data("日本語 partial head\n".utf8).dropFirst()  // mid-char start
        bytes.append(Data("{\"_status\":\"done\"}\n".utf8))
        #expect(FleetStats.lastLine(ofTail: bytes) == #"{"_status":"done"}"#)
    }

    @Test func multibyte_content_in_last_line_survives() {
        let tail = data("{\"a\":1}\n{\"caption\":\"Donna’s café 日本\"}\n")
        #expect(FleetStats.lastLine(ofTail: tail) == #"{"caption":"Donna’s café 日本"}"#)
    }
}

// MARK: - newlineCount(in:) / countNewlines(at:)

@Suite("FleetStats raw-byte line counting")
struct FleetStatsNewlineCountTests {

    @Test func empty_data_counts_zero() {
        #expect(FleetStats.newlineCount(in: Data()) == 0)
    }

    @Test func counts_newline_bytes_only() {
        #expect(FleetStats.newlineCount(in: Data("a\nb\nc\n".utf8)) == 3)
    }

    @Test func final_line_without_trailing_newline_is_not_counted() {
        // Same semantics as the original dashboard counter: record
        // count == number of \n bytes. Workers append "<json>\n" per
        // record, so a missing final newline means a partial write —
        // not yet a complete record.
        #expect(FleetStats.newlineCount(in: Data("a\nb\nc".utf8)) == 2)
    }

    @Test func multibyte_utf8_does_not_confuse_byte_counting() {
        // UTF-8 continuation bytes are all >= 0x80, so 0x0A can never
        // appear inside a character. Counting bytes is exact.
        #expect(FleetStats.newlineCount(in: Data("é\n日本語\n🎬\n".utf8)) == 3)
    }

    // MARK: chunked file counter

    private func makeTempFile(label: String, content: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-nlcount-\(label)-\(UUID().uuidString)")
        try content.write(to: url)
        return url
    }

    @Test func countNewlines_empty_file_is_zero() throws {
        let url = try makeTempFile(label: "empty", content: Data())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FleetStats.countNewlines(at: url) == 0)
    }

    @Test func countNewlines_missing_file_is_zero() {
        let bogus = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).jsonl")
        #expect(FleetStats.countNewlines(at: bogus) == 0)
    }

    @Test func countNewlines_no_trailing_newline() throws {
        let url = try makeTempFile(label: "tail",
                                   content: Data("{\"a\":1}\n{\"b\":2}".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FleetStats.countNewlines(at: url) == 1)
    }

    @Test func countNewlines_spanning_many_chunks_matches_total() throws {
        // 10,000 lines counted with a deliberately tiny 1 KB chunk so
        // the file spans hundreds of chunk boundaries — including
        // boundaries that land mid-line. Total must be exact.
        let line = "{\"fullPath\":\"/Volumes/X/clip.mov\",\"fields\":{}}\n"
        let content = Data(String(repeating: line, count: 10_000).utf8)
        let url = try makeTempFile(label: "chunks", content: content)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FleetStats.countNewlines(at: url, chunkSize: 1024) == 10_000)
    }
}

// MARK: - readTail(of:)

@Suite("FleetStats.readTail(of:) — seek-based tail read")
struct FleetStatsReadTailTests {

    private func makeTempFile(label: String, content: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-tail-\(label)-\(UUID().uuidString)")
        try content.write(to: url)
        return url
    }

    @Test func file_smaller_than_window_returns_whole_file() throws {
        let content = Data("{\"a\":1}\n{\"b\":2}\n".utf8)
        let url = try makeTempFile(label: "small", content: content)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FleetStats.readTail(of: url, maxBytes: 4096) == content)
    }

    @Test func file_larger_than_window_returns_exactly_the_last_bytes() throws {
        // 8 KB file, 4 KB window → tail must be the final 4096 bytes,
        // and the sentinel on the last line must still be extractable.
        let filler = String(repeating: "{\"pad\":0}\n", count: 800)  // 8000 bytes
        let sentinel = "{\"_status\":\"done\"}\n"
        let content = Data((filler + sentinel).utf8)
        let url = try makeTempFile(label: "big", content: content)
        defer { try? FileManager.default.removeItem(at: url) }

        let tail = try #require(FleetStats.readTail(of: url, maxBytes: 4096))
        #expect(tail.count == 4096)
        #expect(tail == content.suffix(4096))
        #expect(FleetStats.lastLine(ofTail: tail) == #"{"_status":"done"}"#)
    }

    @Test func missing_file_returns_nil() {
        let bogus = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).jsonl")
        #expect(FleetStats.readTail(of: bogus) == nil)
    }

    @Test func empty_file_returns_empty_data() throws {
        let url = try makeTempFile(label: "zero", content: Data())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FleetStats.readTail(of: url) == Data())
    }
}

// MARK: - load(from:cache:) — cache reuse + tail-based sentinel

@Suite("FleetStats.load(from:cache:) — per-tick cache")
struct FleetStatsLoadCacheTests {

    private func makeFixtureDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-fleetcache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func sentinel_on_last_line_is_parsed_and_excluded_from_record_count() throws {
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = """
        {"fullPath":"/a","fields":{}}
        {"fullPath":"/b","fields":{}}
        {"_status":"done","processedOk":2,"processedFailed":0,"targetsTotal":2,"exitedAt":"2026-06-09T12:00:00Z"}
        """ + "\n"
        try content.write(to: dir.appendingPathComponent("m4.jsonl"),
                          atomically: true, encoding: .utf8)

        let (stats, cache) = FleetStats.load(from: dir, cache: [:])
        #expect(stats[.m4].recordCount == 2, "Sentinel line is not a delta record.")
        let s = try #require(stats[.m4].sentinel)
        #expect(s.status == "done")
        #expect(s.processedOk == 2)
        #expect(s.processedFailed == 0)
        #expect(s.targetsTotal == 2)
        #expect(s.exitedAt != nil)
        #expect(cache[.m4] != nil, "Parsed result must be cached for the next tick.")
    }

    @Test func unchanged_file_reuses_cached_result_without_rereading() throws {
        // Proof of cache reuse: fabricate a cache entry whose (mtime,
        // size) match the real file but whose recordCount is a marker
        // value the file can't produce. If load() returns the marker,
        // it trusted the cache and never re-read the bytes.
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("m4.jsonl")
        try "{\"a\":1}\n{\"b\":2}\n".write(to: file, atomically: true, encoding: .utf8)

        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let mtime = attrs[.modificationDate] as? Date
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let fabricated = FleetStats.CachedEntry(mtime: mtime, size: size,
                                                recordCount: 999, sentinel: nil)

        let (stats, cache) = FleetStats.load(from: dir, cache: [.m4: fabricated])
        #expect(stats[.m4].recordCount == 999,
                "Matching (mtime, size) must short-circuit to the cached result.")
        #expect(cache[.m4]?.recordCount == 999)
    }

    @Test func changed_file_size_invalidates_cache_and_recounts() throws {
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("m4.jsonl")
        try "{\"a\":1}\n{\"b\":2}\n".write(to: file, atomically: true, encoding: .utf8)

        // Cache from a "previous tick" when the file was a different size.
        let stale = FleetStats.CachedEntry(mtime: Date(timeIntervalSince1970: 0),
                                           size: 1, recordCount: 999, sentinel: nil)
        let (stats, cache) = FleetStats.load(from: dir, cache: [.m4: stale])
        #expect(stats[.m4].recordCount == 2,
                "Mismatched (mtime, size) must trigger a real recount.")
        #expect(cache[.m4]?.recordCount == 2)
    }

    @Test func running_worker_without_sentinel_counts_all_lines() throws {
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n"
            .write(to: dir.appendingPathComponent("m5.jsonl"),
                   atomically: true, encoding: .utf8)
        let (stats, _) = FleetStats.load(from: dir, cache: [:])
        #expect(stats[.m5].recordCount == 3)
        #expect(stats[.m5].sentinel == nil)
    }
}
