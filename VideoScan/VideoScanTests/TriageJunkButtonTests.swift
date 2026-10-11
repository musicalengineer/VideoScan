// TriageJunkButtonTests.swift
// 🔴 fix 1 (docs/design/triage_delete_streamline_2026_10_09.md §2.2,
// "Marking is deciding"): Triage's orange Junk button is a HUMAN decision,
// so it marks Confirmed Junk — the set "Delete Junk" acts on. Before the
// fix it marked Suspected Junk, so Rick marked a pile and nothing was
// deletable. Machine guesses stay Suspected until a human agrees.

import Foundation
import Testing
@testable import VideoScan

@Suite("Triage Junk button — a human click is Confirmed Junk")
@MainActor
struct TriageJunkButtonTests {

    @Test("the Junk button marks Confirmed Junk, and its help says so")
    func junkButtonMarksConfirmedJunk() {
        #expect(TriageView.junkButtonDisposition == .confirmedJunk)
        #expect(TriageView.junkButtonHelp.contains("Confirmed Junk"))
        #expect(!TriageView.junkButtonHelp.contains("Suspected"))
    }

    /// The round trip that broke: a record marked by the button is in the
    /// set Delete Junk offers (`triageConfirmedJunkRecords`).
    @Test("a record marked by the Junk button is in Delete Junk's set")
    func markedRecordIsDeletable() {
        let model = VideoScanModel()
        let marked = VideoRecord()
        marked.filename = "test_marked.mov"
        marked.fullPath = "/tmp/test_marked.mov"
        let machineGuess = VideoRecord()
        machineGuess.filename = "test_guess.mov"
        machineGuess.fullPath = "/tmp/test_guess.mov"
        machineGuess.mediaDisposition = .suspectedJunk
        model.records = [marked, machineGuess]

        marked.mediaDisposition = TriageView.junkButtonDisposition

        let deletable = model.triageConfirmedJunkRecords().map(\.id)
        #expect(deletable == [marked.id], "the human's mark is deletable; the machine's guess is not")
    }

    /// Sensor: the button reads the constant (so the test above pins the
    /// real button), and the machine-guess path still says Suspected.
    @Test("sensor: the toolbar button uses the pinned constant; the right-click keeps both choices")
    func buttonUsesTheConstant() throws {
        let src = try SourceTree.appSource(named: "TriageView.swift")
        #expect(src.contains("triageSelected(Self.junkButtonDisposition)"))
        #expect(src.contains(".help(Self.junkButtonHelp)"))
        #expect(src.contains("applyDisposition(.suspectedJunk, to: ids)"), "Suspected stays reachable by hand")
        #expect(src.contains("applyDisposition(.confirmedJunk, to: ids)"))
    }
}
