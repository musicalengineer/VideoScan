// PromoteProgressLoggingTests.swift
//
// The per-file BEGIN line on the promote path (overnight findings
// 2026-09-14, item 1b, 🔴; fixed 2026-09-15).
//
// WHAT WENT WRONG. A 263 GB promote logged one batch begin line at
// 20:53:29 and then went completely silent for five minutes while a single
// large file copied. Every per-file `model.log` on the normal path fired on
// COMPLETION. From the durable log alone that is indistinguishable from a
// hang — and an unkillable hang had just cost two days that same week, so
// "is it working or is it wedged?" was not a theoretical question.
//
// The window was never the problem: `applyPhaseSubtitle` already posts
// "Copying <file> · 4.2 GB of 18.4 GB · 61 MB/s · ~4 min" about four times
// a second. It was the persisted record that went quiet.
//
// Five dimensions:
//   1. Logic     — the two text helpers, at their boundaries
//   2. Scale     — n/a (no per-record work; these format one number)
//   3. Media     — n/a (no media is opened by any of this)
//   4. Isolation — n/a (pure functions, no defaults/paths/global state)
//   5. Sensor    — the BEGIN line must appear BEFORE the copy call in the
//                  source. A log line that moved below the copy would
//                  compile, pass every behavioural test, and restore the
//                  exact silence this fixed.

import Foundation
import Testing
@testable import VideoScan

@Suite("Promote — per-file begin/end line text")
struct PromoteProgressTextTests {

    typealias J = PromoteToArchiveJob

    @Test func bytesReadAsFileSizes() {
        #expect(J.promoteByteText(0) == ByteCountFormatter.string(
            fromByteCount: 0, countStyle: .file))
        // Agreeing with the progress subtitle's formatter is the point:
        // the log line and the window must not describe one file two ways.
        let fmt = ByteCountFormatter(); fmt.countStyle = .file
        for bytes: Int64 in [1, 999, 1_000, 1_048_576, 18_400_000_000, 263_000_000_000] {
            #expect(J.promoteByteText(bytes) == fmt.string(fromByteCount: bytes))
        }
    }

    @Test func secondsBelowAMinuteKeepOneDecimal() {
        #expect(J.promoteElapsedText(0) == "0.0s")
        #expect(J.promoteElapsedText(0.04) == "0.0s")
        #expect(J.promoteElapsedText(33.14) == "33.1s")
        #expect(J.promoteElapsedText(59.94) == "59.9s")
    }

    @Test func aMinuteAndOverReadsAsMinutesAndSeconds() {
        #expect(J.promoteElapsedText(60) == "1m 0s")
        #expect(J.promoteElapsedText(61.4) == "1m 1s")
        #expect(J.promoteElapsedText(252) == "4m 12s")
        // The five minutes of silence that prompted all of this.
        #expect(J.promoteElapsedText(300) == "5m 0s")
        #expect(J.promoteElapsedText(3_671) == "61m 11s")
    }

    /// A clock adjustment mid-copy must not write "-0.3s" into the durable
    /// record of an irreversible operation.
    @Test func aBackwardsClockNeverProducesANegativeDuration() {
        #expect(J.promoteElapsedText(-0.3) == "0.0s")
        #expect(J.promoteElapsedText(-9_999) == "0.0s")
    }
}

@Suite("Promote — the begin line precedes the bytes (sensor)")
struct PromoteBeginLineSensorTests {

    private static func stepsSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // VideoScanTests
            .deletingLastPathComponent()          // VideoScan
            .appendingPathComponent("VideoScan/PromoteToArchiveJob+Steps.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// SENSOR. This is a source sensor on purpose: the behaviour it pins —
    /// "something reached the log before a multi-minute copy started" — has
    /// no observable difference from "nothing did" until you are five
    /// minutes into a copy wondering whether the app is alive.
    @Test func theCopyingLineComesBeforeTheCopyCall() throws {
        let src = try Self.stepsSource()
        let begin = try #require(src.range(of: #"model.log("Promote: copying "#),
                                 "the per-file BEGIN line is gone — see this file's header")
        let copy = try #require(src.range(of: "Self.copyOffMain("),
                                "copyOffMain moved or was renamed; re-point this sensor")
        #expect(begin.lowerBound < copy.lowerBound,
                "the BEGIN line must be logged BEFORE the copy starts, not after it finishes")
    }

    /// Promote is irreversible, so its per-file outcome has to survive into
    /// the persisted log — `.info` is not persisted by default
    /// (docs/findings_2026_09_14_overnight.md, row 14).
    @Test func theOsLogLinesArePersistedLevels() throws {
        let src = try Self.stepsSource()
        #expect(src.contains(#"promoteLog.notice("promote BEGIN"#))
        #expect(src.contains(#"promoteLog.notice("promote DONE"#))
        #expect(!src.contains(#"promoteLog.info("promoted"#),
                "the DONE line went back to .info — it will not survive for post-hoc reading")
    }
}
