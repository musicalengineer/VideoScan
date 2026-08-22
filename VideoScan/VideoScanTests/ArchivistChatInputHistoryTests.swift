import Testing
@testable import VideoScan

@Suite("Hallie in-app chat input history")
struct ArchivistChatInputHistoryTests {
    @Test func upRecallsNewestThenOlderEntries() {
        var history = ArchivistChatInputHistory()
        history.record("show me Donna")
        history.record("when was that?")

        #expect(history.previous(current: "") == "when was that?")
        #expect(history.previous(current: "when was that?") == "show me Donna")
        #expect(history.previous(current: "show me Donna") == "show me Donna")
    }

    @Test func downReturnsTowardDraftBeingEdited() {
        var history = ArchivistChatInputHistory()
        history.record("first")
        history.record("second")

        #expect(history.previous(current: "unfinished draft") == "second")
        #expect(history.previous(current: "second") == "first")
        #expect(history.next() == "second")
        #expect(history.next() == "unfinished draft")
        #expect(history.next() == nil)
    }

    @Test func submittedRecallCanBeModifiedAndRecordedAgain() {
        var history = ArchivistChatInputHistory()
        history.record("show me Rick Brren")
        let recalled = history.previous(current: "")
        #expect(recalled == "show me Rick Brren")

        history.record("show me Rick Breen")
        #expect(history.previous(current: "") == "show me Rick Breen")
    }

    @Test func emptyAndConsecutiveDuplicateEntriesAreNotStored() {
        var history = ArchivistChatInputHistory(limit: 2)
        history.record("   ")
        history.record("one")
        history.record("one")
        history.record("two")
        history.record("three")

        #expect(history.entries == ["two", "three"])
    }
}
