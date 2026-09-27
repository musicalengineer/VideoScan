// CatalogOpenScaleTests.swift
// Night hardening 2026-09-26 — coverage audit of 48708aba + 7d2a9674
// (Catalog ⌘O). CatalogOpenShortcutTests pins logic, isolation and the
// one-path sensor on 2–4 rows; nothing ran `CatalogOpenAction.open` at
// catalog scale, although it iterates the table (`rows.filter`) and ⌘A ⌘O
// on the Catalog makes "open everything" a two-key gesture.
//
// SCALE dimension (CLAUDE.md feature-test checklist): 100k synthetic rows.
//   • select-all: one O(n) pass, table order kept, the looks-moved check
//     runs exactly once per row, one launch, one console line — under an
//     explicit budget.
//   • one highlighted row in a 100k table (the double-click case): the
//     looks-moved check runs ONCE, not across the table — each check is a
//     stat() against a volume, so a regression to "check every row" would
//     be 100k stats per double-click.
//
// The closure overload is used throughout: nothing is launched, no file is
// touched. (C++ readers: the closures are the injected function pointers
// of a test double; `#expect` is EXPECT_*, `#require` is ASSERT_*.)

import Foundation
import Testing
@testable import VideoScan

@Suite("Catalog ⌘O — scale (100k rows)", .serialized)
@MainActor
struct CatalogOpenScaleTests {

    static let rowCount = 100_000

    /// 100k rows cycling through the media-matrix codec shapes so the
    /// player summary does real per-row work (QuickTime and VLC both hit).
    private static func makeRows() -> [VideoRecord] {
        let shapes: [(ext: String, video: String, audio: String)] = [
            ("MP4", "h264", "aac"), ("MOV", "prores", "pcm_s16le"),
            ("MKV", "ffv1", "pcm_s16le"), ("MXF", "dvvideo", "pcm_s16le"),
            ("AVI", "dvvideo", "pcm_s16le"),
        ]
        var rows: [VideoRecord] = []
        rows.reserveCapacity(rowCount)
        for i in 0..<rowCount {
            let s = shapes[i % shapes.count]
            let r = VideoRecord()
            r.filename = "test_\(i).\(s.ext.lowercased())"
            r.fullPath = "/Volumes/TestScale/\(r.filename)"
            r.directory = "/Volumes/TestScale"
            r.ext = s.ext
            r.videoCodec = s.video
            r.audioCodec = s.audio
            rows.append(r)
        }
        return rows
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    @Test("scale: select-all on 100k rows — one pass, table order, one check per row, one launch, within budget",
          .timeLimit(.minutes(1)))
    func selectAllOnHundredThousandRows() throws {
        let rows = Self.makeRows()
        let ids = Set(rows.map(\.id))
        var checks = 0
        var asked: [Int] = []
        var launches: [[VideoRecord]] = []
        var lines: [String] = []

        let clock = ContinuousClock()
        let start = clock.now
        let opened = CatalogOpenAction.open(
            ids: ids, rows: rows, gesture: "⌘O", hasVLC: true,
            log: { lines.append($0) },
            confirm: { asked.append($0.count); return true },   // the user said Open (GH #203)
            noteMissing: { _ in checks += 1; return false },
            launch: { launches.append($0) })
        let elapsed = Self.seconds(clock.now - start)

        #expect(opened.count == Self.rowCount)
        #expect(opened.first?.id == rows.first?.id && opened.last?.id == rows.last?.id,
                "table order, not Set order")
        #expect(zip(opened, rows).allSatisfy { $0.id == $1.id }, "every row in table order")
        #expect(asked == [Self.rowCount], "select-all asks once before opening 100k files (GH #203)")
        #expect(checks == Self.rowCount, "the looks-moved check runs exactly once per opened row")
        #expect(launches.count == 1, "one hand-off to the opener for the whole selection")
        #expect(lines == ["Open (⌘O): 100000 file(s) — by codec: 40000 for QuickTime Player, 60000 for VLC (offline files are skipped by the opener)"],
                "\(lines)")

        // Measured 2026-09-26 on the M5 Pro, Debug, quiet: 0.046 s. The
        // ceiling is ~20× that: it catches an O(n·k) lookup (the pre-⌘O
        // `ids.compactMap { rows.first … }` shape takes minutes at this
        // size), not jitter.
        let budget = PerformanceLane.loadAwareDebugCeiling(
            PerformanceLane.isDebugBuild ? .seconds(1) : .milliseconds(250))
        print("SCALE[\(PerformanceLane.configurationName)] ⌘O select-all 100k: \(elapsed) s (budget \(Self.seconds(budget)) s)")
        #expect(elapsed < Self.seconds(budget),
                "⌘O on 100k selected rows took \(elapsed) s (\(PerformanceLane.loadDescription()))")
    }

    /// GH #203 sensor at production scale: ⌘A ⌘O then Cancel on 100k rows
    /// stats nothing and launches nothing.
    @Test("scale: select-all on 100k rows then Cancel — no looks-moved check, no launch",
          .timeLimit(.minutes(1)))
    func selectAllThenCancelOnHundredThousandRows() throws {
        let rows = Self.makeRows()
        var asked = 0
        var checks = 0
        var launches = 0
        let opened = CatalogOpenAction.open(
            ids: Set(rows.map(\.id)), rows: rows, gesture: "⌘O", hasVLC: true,
            log: { _ in },
            confirm: { asked += 1; #expect($0.count == Self.rowCount); return false },
            noteMissing: { _ in checks += 1; return false },
            launch: { _ in launches += 1 })
        #expect(opened.isEmpty)
        #expect(asked == 1)
        #expect(checks == 0, "Cancel is asked before the per-row stat pass")
        #expect(launches == 0)
    }

    @Test("scale: one highlighted row in a 100k table — ONE looks-moved check, one row launched",
          .timeLimit(.minutes(1)))
    func oneRowInHundredThousand() throws {
        let rows = Self.makeRows()
        let target = rows[Self.rowCount - 1]            // last row: a linear search pays full price
        var checked: [UUID] = []
        var launched: [VideoRecord] = []

        let clock = ContinuousClock()
        let start = clock.now
        let opened = CatalogOpenAction.open(
            ids: [target.id], rows: rows, gesture: "double-click", hasVLC: true,
            log: { _ in },
            confirm: { _ in Issue.record("one row never asks"); return false },
            noteMissing: { checked.append($0.id); return false },
            launch: { launched = $0 })
        let elapsed = Self.seconds(clock.now - start)

        #expect(opened.map(\.id) == [target.id])
        #expect(launched.map(\.id) == [target.id])
        #expect(checked == [target.id], "a double-click must not stat the other 99,999 rows")
        let budget = PerformanceLane.loadAwareDebugCeiling(
            PerformanceLane.isDebugBuild ? .milliseconds(250) : .milliseconds(60))   // measured 0.010 s Debug
        print("SCALE[\(PerformanceLane.configurationName)] ⌘O one-of-100k: \(elapsed) s")
        #expect(elapsed < Self.seconds(budget), "one row in 100k took \(elapsed) s")
    }
}
