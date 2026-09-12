import XCTest
@testable import TeamChannelMonitor

/// A nudge row never offers or performs another nudge (codex #1388).
final class NudgeRowTests: XCTestCase {
    private func row(author: String, recipient: String, subject: String,
                     status: ChannelRow.Status, nudgedAt: Date? = nil) -> ChannelRow {
        ChannelRow(messageID: 42, author: author, recipient: recipient, subject: subject,
                   body: "", replyTo: nil, createdAt: Date(), deliveredAt: nil,
                   acknowledgedAt: nil, repliedAt: nil, nudgedAt: nudgedAt, status: status)
    }

    func testRicksReminderIsANudgeAndCannotBeNudged() {
        let r = row(author: "rick", recipient: "claude",
                    subject: ChannelDB.nudgeSubjectPrefix + "41", status: .stuck(3600))
        XCTAssertTrue(r.isNudge)
        XCTAssertFalse(r.canNudge)
    }

    func testAStuckAgentMessageCanBeNudgedOnce() {
        let open = row(author: "codex", recipient: "claude", subject: "REVIEW", status: .stuck(3600))
        XCTAssertFalse(open.isNudge)
        XCTAssertTrue(open.canNudge)
        let already = row(author: "codex", recipient: "claude", subject: "REVIEW",
                          status: .stuck(3600), nudgedAt: Date())
        XCTAssertFalse(already.canNudge)
    }

    func testRowsOwedByRickOrAlreadyAnsweredAreNotNudgeable() {
        XCTAssertFalse(row(author: "codex", recipient: "rick", subject: "x", status: .stuck(3600)).canNudge)
        XCTAssertFalse(row(author: "codex", recipient: "claude", subject: "x", status: .answered(Date())).canNudge)
    }

    func testAgentSubjectWithTheNudgePrefixIsNotRicksNudge() {
        // Only Rick's rows are reminders; an agent quoting the phrase is ordinary mail.
        let r = row(author: "codex", recipient: "claude",
                    subject: ChannelDB.nudgeSubjectPrefix + "41", status: .waiting(60))
        XCTAssertFalse(r.isNudge)
        XCTAssertTrue(r.canNudge)
    }
}
