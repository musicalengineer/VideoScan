import Testing
import Foundation
@testable import VideoScan

// MARK: - ReformatJob progress-line parser
//
// ffmpeg progress output is famously inconsistent — different versions
// and different `-progress` modes emit slightly different lines. The
// parser has to handle both the structured `out_time=` and the legacy
// `time=` formats without false-positiving on similar-looking fields
// like `start_time=`.

struct ReformatJobProgressTests {

    @Test("structured out_time= parses hours/minutes/seconds correctly")
    func outTimeParses() {
        let s = ReformatJob.parseProgressSeconds(line: "out_time=01:23:45.678")
        #expect(s != nil)
        #expect(abs((s ?? 0) - (3600 + 23*60 + 45.678)) < 0.001)
    }

    @Test("legacy time= parses correctly")
    func legacyTimeParses() {
        let s = ReformatJob.parseProgressSeconds(line: "frame= 1234 fps=30 time=00:00:42.50 bitrate=...")
        #expect(s != nil)
        #expect(abs((s ?? 0) - 42.5) < 0.001)
    }

    @Test("zero time parses to 0 (not nil)")
    func zeroTime() {
        let s = ReformatJob.parseProgressSeconds(line: "out_time=00:00:00.00")
        #expect(s == 0)
    }

    @Test("garbage lines return nil")
    func garbageReturnsNil() {
        #expect(ReformatJob.parseProgressSeconds(line: "") == nil)
        #expect(ReformatJob.parseProgressSeconds(line: "[swscaler @ 0x...]") == nil)
        #expect(ReformatJob.parseProgressSeconds(line: "Stream #0:0 Video") == nil)
    }

    @Test("HH:MM:SS with no decimals parses")
    func noDecimals() {
        let s = ReformatJob.parseProgressSeconds(line: "out_time=00:01:30")
        #expect(s == 90.0)
    }

    @Test("malformed time field returns nil instead of partial parse")
    func malformedReturnsNil() {
        #expect(ReformatJob.parseProgressSeconds(line: "out_time=abc:def:ghi") == nil)
        #expect(ReformatJob.parseProgressSeconds(line: "out_time=") == nil)
    }
}
