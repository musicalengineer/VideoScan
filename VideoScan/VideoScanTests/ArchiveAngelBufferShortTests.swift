// ArchiveAngelBufferShortTests.swift
// Rick 2026-09-19: "archive angel does not advance files … it just shows a
// list". One 42 GB tape needed 125 GB of buffer (×3 with lossless), 87 GB
// was free, and the loop `break`-ed at "buffer full after 0 of 10" —
// silently, with nine smaller files that fit. A file that does not fit is
// now left for a later batch with the numbers on its row, and the loop
// goes on. These pin the pure half: the arithmetic, the row's reason, the
// counts, and that the left-out file is NOT reserved from the next batch.

import Foundation
import Testing
@testable import VideoScan

@Suite("Archive Angel — a file too big for the buffer waits; the batch goes on")
struct ArchiveAngelBufferShortTests {
    private static let gb: Int64 = 1_000_000_000

    private func entry(_ status: ArchiveAngelPlan.EntryStatus, failure: String? = nil) -> ArchiveAngelPlan.Entry {
        var e = ArchiveAngelPlan.Entry(
            id: UUID(), sourcePath: "/v/tape.mkv", filename: "tape.mkv", sizeBytes: 42 * Self.gb,
            durationSeconds: 3600, score: 100, evidence: [], proposedName: "tape.mkv",
            proposedDate: nil, status: status)
        e.failure = failure
        return e
    }

    @Test func needIsThreeTimesWithLosslessTwiceWithout() {
        #expect(ArchiveAngelPlan.bufferNeed(sizeBytes: 42 * Self.gb, lossless: true) == 126 * Self.gb)
        #expect(ArchiveAngelPlan.bufferNeed(sizeBytes: 42 * Self.gb, lossless: false) == 84 * Self.gb)
    }

    @Test func theRowSaysWhatItNeedsAndWhatIsFree() throws {
        let note = try #require(ArchiveAngelPlan.bufferShortNote(need: 126 * Self.gb, free: 87 * Self.gb))
        #expect(note.hasPrefix(ArchiveAngelPlan.bufferShortPrefix))
        #expect(note.contains("126 GB") && note.contains("87 GB"), Comment(rawValue: note))
        #expect(note.contains("later batch"))
        #expect(ArchiveAngelPlan.bufferShortNote(need: 10 * Self.gb, free: 87 * Self.gb) == nil, "it fits: no note")
        #expect(ArchiveAngelPlan.bufferShortNote(need: 87 * Self.gb, free: 87 * Self.gb) == nil, "exactly fits")
    }

    @Test func waitingForSpaceIsCountedApartFromRealFailures() throws {
        let short = entry(.failed, failure: ArchiveAngelPlan.bufferShortNote(need: 126 * Self.gb, free: 87 * Self.gb))
        let broken = entry(.failed, failure: "Source file is missing — cannot promote.")
        let plan = ArchiveAngelPlan(batchDir: "/tmp/batch-x", requestedCount: 10, makeLossless: true,
                                    entries: [short, broken, entry(.ready), entry(.skipped)])
        #expect(short.isBufferShort && !broken.isBufferShort)
        #expect(plan.bufferShortCount == 1)
        #expect(plan.bufferShortClause == " · 1 waiting for buffer space")
        #expect(plan.skippedCount == 1, "a buffer-short row is never counted as the user's skip")
        let empty = ArchiveAngelPlan(batchDir: "/tmp/batch-y", requestedCount: 1, makeLossless: true,
                                     entries: [entry(.ready)])
        #expect(empty.bufferShortClause == "")
    }

    /// Isolation: a real buffer folder with a finished batch holding one
    /// prepared row and one left out for space. Only the prepared row is
    /// reserved — the big tape comes back when there is room.
    @Test func theLeftOutFileIsNotReservedFromTheNextBatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_angel_buffershort_\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = entry(.ready)
        let short = entry(.failed, failure: ArchiveAngelPlan.bufferShortNote(need: 126 * Self.gb, free: 87 * Self.gb))
        var plan = ArchiveAngelPlan(batchDir: root.appendingPathComponent("batch-a").path, requestedCount: 10,
                                    makeLossless: true, entries: [short, ready])
        plan.status = .ready
        try ArchiveAngelPlanStore.save(plan)
        #expect(ArchiveAngelPlanStore.inFlightRecordIDs(bufferRoot: root) == [ready.id])
    }
}
