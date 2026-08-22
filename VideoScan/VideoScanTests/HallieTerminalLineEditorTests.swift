import Testing
@testable import VideoScan

@Suite("Hallie terminal line editor")
struct HallieTerminalLineEditorTests {
    @Test func upArrowRecallsPreviousEntryForEditing() {
        var editor = HallieLineEditor()
        type("show me Rick Breen", into: &editor)
        #expect(editor.handle(.enter) == .submit("show me Rick Breen"))

        editor.beginLine()
        #expect(editor.handle(.historyPrevious) == .continueEditing)
        #expect(editor.text == "show me Rick Breen")
        #expect(editor.cursor == editor.characters.count)

        _ = editor.handle(.moveToStart)
        type("Please ", into: &editor)
        _ = editor.handle(.moveToEnd)
        type(" again", into: &editor)
        #expect(editor.text == "Please show me Rick Breen again")
    }

    @Test func controlAAndControlEMoveToLineBoundaries() {
        var editor = HallieLineEditor()
        type("middle", into: &editor)
        _ = editor.handle(.moveToStart)
        type("start ", into: &editor)
        _ = editor.handle(.moveToEnd)
        type(" end", into: &editor)

        #expect(editor.text == "start middle end")
    }

    @Test func recalledEntrySupportsCursorMovementAndBackspace() {
        var editor = HallieLineEditor()
        type("Rick Brren", into: &editor)
        _ = editor.handle(.enter)
        editor.beginLine()
        _ = editor.handle(.historyPrevious)

        _ = editor.handle(.left)
        _ = editor.handle(.left)
        _ = editor.handle(.backspace)
        type("e", into: &editor)

        #expect(editor.text == "Rick Breen")
    }

    @Test func terminalSequencesMapToRequestedEditingKeys() {
        #expect(HallieTerminalKeyDecoder.decode([0x1b, 0x5b, 0x41]) == .historyPrevious)
        #expect(HallieTerminalKeyDecoder.decode([0x1b, 0x4f, 0x41]) == .historyPrevious)
        #expect(HallieTerminalKeyDecoder.decode(
            [0x1b, 0x5b, 0x31, 0x3b, 0x32, 0x41]) == .historyPrevious)
        #expect(HallieTerminalKeyDecoder.decode([0x01]) == .moveToStart)
        #expect(HallieTerminalKeyDecoder.decode([0x05]) == .moveToEnd)
        #expect(HallieTerminalKeyDecoder.decode([0x1b, 0x5b, 0x44]) == .left)
        #expect(HallieTerminalKeyDecoder.decode([0x1b, 0x5b, 0x43]) == .right)
    }

    private func type(_ text: String, into editor: inout HallieLineEditor) {
        for character in text {
            _ = editor.handle(.character(character))
        }
    }
}
