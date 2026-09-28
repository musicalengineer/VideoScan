import XCTest
@testable import TeamChannelMonitor

/// "Review cycles" section: colour thresholds, dead pid, 24 h drop-off,
/// and a missing/garbled review-cycles.json never crashing the monitor.
final class ReviewCyclesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func stamp(_ secondsAgo: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: now.addingTimeInterval(-secondsAgo))
    }

    private func cycle(_ id: Int, _ phase: String, ago: TimeInterval, pid: Int32? = nil,
                       closedBy: String? = nil, failure: String? = nil, findings: Int? = nil) -> ReviewCycle {
        ReviewCycle(id: id, title: "⌘O", range: "de54a7ca11..48708aba", phase: phase,
                    phaseSince: stamp(ago), pid: pid, closedBy: closedBy, findings: findings, failure: failure)
    }

    private func line(_ c: ReviewCycle, alive: Bool = true) -> ReviewCycleLine {
        ReviewCycles.lines([c], now: now, pidAlive: { _ in alive })[0]
    }

    func testThresholdBoundaries() {
        // codex's own steps: 10 / 30 min
        XCTAssertEqual(line(cycle(1, "briefed", ago: 9 * 60 + 59)).colour, .green)
        XCTAssertEqual(line(cycle(1, "briefed", ago: 10 * 60)).colour, .yellow)
        XCTAssertEqual(line(cycle(1, "running", ago: 29 * 60 + 59, pid: 4242)).colour, .yellow)
        XCTAssertEqual(line(cycle(1, "running", ago: 30 * 60, pid: 4242)).colour, .red)
        // an agent's fix round: 60 min / 2 h
        XCTAssertEqual(line(cycle(1, "fixing", ago: 59 * 60 + 59)).colour, .green)
        XCTAssertEqual(line(cycle(1, "fixing", ago: 60 * 60)).colour, .yellow)
        XCTAssertEqual(line(cycle(1, "fixing", ago: 2 * 3600 - 1)).colour, .yellow)
        XCTAssertEqual(line(cycle(1, "fixing", ago: 2 * 3600)).colour, .red)
    }

    func testRunningWithDeadPidIsRedEvenWhenFresh() {
        XCTAssertEqual(line(cycle(1, "running", ago: 60, pid: 4242), alive: false).colour, .red)
        XCTAssertEqual(line(cycle(1, "running", ago: 60, pid: 4242), alive: true).colour, .green)
        XCTAssertEqual(line(cycle(1, "running", ago: 60, pid: nil), alive: true).colour, .red)
    }

    func testFailedIsRedImmediately() {
        let l = line(cycle(1, "failed", ago: 5, failure: "timeout"))
        XCTAssertEqual(l.colour, .red)
        XCTAssertEqual(l.text, "⌘O (de54a7ca) — failed (timeout) 0m")
    }

    func testClosedStaysGreenAndShowsItsSha() {
        let l = line(cycle(1, "closed", ago: 23 * 3600, closedBy: "7d2a9674ffff"))
        XCTAssertEqual(l.colour, .green)
        XCTAssertEqual(l.text, "⌘O — closed 7d2a9674")
    }

    func testClosedOlderThanADayIsHiddenButOpenOnesAreNot() {
        let lines = ReviewCycles.lines([cycle(1, "closed", ago: 24 * 3600 + 1, closedBy: "a"),
                                        cycle(2, "fixing", ago: 48 * 3600, findings: 2)],
                                       now: now, pidAlive: { _ in true })
        XCTAssertEqual(lines.map(\.id), [2])
        XCTAssertEqual(lines[0].text, "⌘O (de54a7ca) — fixing 2 findings 2d")
        XCTAssertEqual(lines[0].colour, .red)
    }

    func testOnlyTheNewestThreeAreShown() {
        let cycles = (1...6).map { cycle($0, "fixing", ago: 60) }
        XCTAssertEqual(ReviewCycles.lines(cycles, now: now, pidAlive: { _ in true }).map(\.id), [6, 5, 4])
    }

    func testRunningLineReadsLikeTheSpec() {
        XCTAssertEqual(line(cycle(1, "running", ago: 4 * 60 + 10, pid: 1)).text, "⌘O (de54a7ca) — codex running 4m")
    }

    func testAbsentOrMalformedFileHidesTheSection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("review-cycles.json")
        XCTAssertEqual(ReviewCycles.load(from: url), [])
        try Data("{not json".utf8).write(to: url)
        XCTAssertEqual(ReviewCycles.load(from: url), [])
        try Data(#"{"id": 1}"#.utf8).write(to: url)
        XCTAssertEqual(ReviewCycles.load(from: url), [])
        // Entries missing a phase or with a bad timestamp are skipped, not fatal.
        try Data(#"[{"id": 1}, {"id": 2, "phase": "running", "phaseSince": "yesterday"}]"#.utf8).write(to: url)
        XCTAssertTrue(ReviewCycles.lines(ReviewCycles.load(from: url), now: now).isEmpty)
    }

    func testDecodesWhatThePythonWriterWrites() throws {
        let json = """
        [{"id": 3, "title": "Dates", "range": "a..b", "phase": "fixing", "phaseSince": "\(stamp(120))",
          "startedAt": "\(stamp(900))", "messageIDs": [10, 11], "pid": 99, "doc": "docs/x.md",
          "tokens": 12345, "findings": 1, "verdict": "fix", "failure": null}]
        """
        let cycles = try JSONDecoder().decode([ReviewCycle].self, from: Data(json.utf8))
        XCTAssertEqual(ReviewCycles.lines(cycles, now: now, pidAlive: { _ in true }).first?.text,
                       "Dates (a) — fixing 1 finding 2m")
    }

    func testOwnPidIsAliveAndAnUnusedPidIsNot() {
        XCTAssertTrue(ReviewCycles.isAlive(getpid()))
        XCTAssertFalse(ReviewCycles.isAlive(0))
        XCTAssertFalse(ReviewCycles.isAlive(99_999_999 & 0x3fff_ffff))
    }
}
