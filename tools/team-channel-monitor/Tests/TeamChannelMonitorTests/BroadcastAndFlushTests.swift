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
}
