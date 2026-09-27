import XCTest
@testable import TeamChannelMonitor

final class BroadcastAndFlushTests: XCTestCase {
    func testSubjectIsTheFirstLineCutAtAWordBoundary() {
        XCTAssertEqual(Broadcast.subject(for: "ship it\nmore detail"), "ship it")
        let long = String(repeating: "word ", count: 40)
        let s = Broadcast.subject(for: long, limit: 30)
        XCTAssertTrue(s.count <= 31 && s.hasSuffix("…") && !s.contains("  "))
        XCTAssertEqual(Broadcast.subject(for: "   "), "(message)")
    }

    func testDeleteGoesThroughTheCLIAsRickForTheWholeMessage() {
        // Delete is the opposite of Flush: it is a database write, routed
        // through the CLI so validation (rick-only) stays in one place.
        XCTAssertEqual(ChannelCLI.deleteArguments(messageID: 1464), ["delete", "--by", "rick", "1464"])
    }

    func testFlushIsMonitorOnlyAndPrunesToOpenRows() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dismissed-\(UUID()).json")
        DismissedRows.save(["1:claude", "2:codex"], to: tmp)
        XCTAssertEqual(DismissedRows.load(from: tmp), ["1:claude", "2:codex"])
        let open = ChannelRow(messageID: 2, author: "claude", recipient: "codex", subject: "s", body: "",
                              replyTo: nil, createdAt: Date(), deliveredAt: nil, acknowledgedAt: nil,
                              repliedAt: nil, nudgedAt: nil, status: .waiting(10))
        XCTAssertEqual(DismissedRows.pruned(["1:claude", "2:codex"], keeping: [open]), ["2:codex"])
        // The channel database is never touched by a flush: the file lives beside it, nothing else.
        XCTAssertEqual(DismissedRows.fileURL.lastPathComponent, "monitor-dismissed.json")
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Rick 2026-09-27: Flush resets everything but work in progress.
    func testFlushKeepsRowsYoungerThanTheWIPWindow() {
        let now = Date()
        func row(_ id: Int, ageMinutes: Double) -> ChannelRow {
            ChannelRow(messageID: id, author: "claude", recipient: "codex", subject: "s", body: "",
                       replyTo: nil, createdAt: now.addingTimeInterval(-ageMinutes * 60), deliveredAt: nil,
                       acknowledgedAt: nil, repliedAt: nil, nudgedAt: nil, status: .stuck(ageMinutes * 60))
        }
        let rows = [row(1, ageMinutes: 300), row(2, ageMinutes: 15), row(3, ageMinutes: 14.9), row(4, ageMinutes: 1)]
        XCTAssertEqual(FlushRules.rowsToFlush(rows, now: now).map(\.messageID), [1, 2])
    }
}
