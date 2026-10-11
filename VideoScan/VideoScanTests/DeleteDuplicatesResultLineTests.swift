// DeleteDuplicatesResultLineTests.swift
// G1 (Rick, 2026-10-09 evening): a Delete Duplicates run must SAY what it
// did, in the window — the MFO row's summary and the status line — not only
// in the log. "Moved N (X) to the Trash · M held (reasons) · K not on disk ·
// L left alone". Before: "· 115 held back" with the reasons only in the
// log, so a run that held most copies looked like "nothing happened".

import Foundation
import Testing
@testable import VideoScan

@Suite("Delete Duplicates — the result line names why copies stayed (G1)")
struct DeleteDuplicatesResultLineTests {

    private func entry(_ name: String, size: Int64 = 10, _ status: DeleteDuplicatesPlan.EntryStatus,
                       kind: DeleteDuplicatesOutcomeKind? = nil, note: String = "") -> DeleteDuplicatesPlan.Entry {
        var e = DeleteDuplicatesPlan.Entry(id: UUID(), path: "/Volumes/S/\(name)", filename: name, sizeBytes: size,
                                           keeperID: UUID(), keeperPath: "/Volumes/S/k.mov", keeperFilename: "k.mov")
        e.status = status; e.outcomeKind = kind; e.note = note
        return e
    }

    private func report(_ entries: [DeleteDuplicatesPlan.Entry]) -> DeleteDuplicatesOutcomeReport {
        DeleteDuplicatesPlan(volumePath: "/Volumes/S", catalogLocation: "/c", crossVolumeMode: false,
                             skippedBeforePlan: 0, summaryLine: "", entries: entries).outcomeReport
    }

    @Test func heldCopiesCarryTheirReasonsAndMissingSaysNotOnDisk() {
        let r = report([
            entry("a.mov", size: 1_000, .trashed),
            entry("b.mov", .refused, note: "could not read k.mov to verify"),
            entry("c.mov", .refused, note: "could not read k.mov to verify"),
            entry("d.mov", .skipped, note: "left alone — in use by the Archive Angel"),
            entry("e.mov", .skipped, kind: .missing, note: "not on disk at /Volumes/S/e.mov — nothing to move"),
        ])
        let size = ByteCountFormatter.string(fromByteCount: 1_000, countStyle: .file)
        #expect(r.line == "Moved 1 (\(size)) to the Trash · 3 held (could not read k.mov to verify ×2; "
                + "left alone — in use by the Archive Angel) · 1 not on disk", Comment(rawValue: r.line))
    }

    /// Many different reasons: the line names the commonest few and counts the rest.
    @Test func theLineStaysOneLine() {
        var rows = [entry("m.mov", .trashed)]
        for i in 0..<6 { rows += Array(repeating: entry("h\(i).mov", .skipped, note: "reason \(i)"), count: 6 - i) }
        let line = report(rows).line
        #expect(line.contains("21 held (reason 0 ×6; reason 1 ×5; reason 2 ×4; +3 more reasons)"), Comment(rawValue: line))
        #expect(!line.contains("\n"))
    }
}
