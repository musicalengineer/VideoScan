// HoldoutReviewQueueTests.swift
// Tests for the in-app blind holdout review queue (Rick 2026-07-25).
//
// Covers:
//   1. CSV parse — contract header, quoted comma-in-path fields
//   2. Pending detection + resume-at-first-unanswered + wrap navigation
//   3. Write-back — write-through persistence, atomic file contents,
//      quoting for commas/quotes in notes, unknown-id rejection
//   4. Byte round-trip — an untouched load→serialize is byte-identical
//      (the CSV was produced by Python csv.writer: CRLF + QUOTE_MINIMAL,
//      and codex's tooling ingests the same file back)
//   5. Discovery — newest dated directory wins; person sidecar; default
//   6. BLINDNESS SENSOR — pins that the types driving the holdout sheet
//      carry no prediction/score/candidate fields (POI-leakage contract,
//      team-channel 2026-07-25-1115)
//
// All tests operate on fixtures in per-test temp directories — the real
// output/person-eval-private/ CSV and real prefs are never touched
// (settings-pollution class).

import Testing
import Foundation
@testable import VideoScan

@Suite("Holdout Review Queue")
struct HoldoutReviewQueueTests {

    // MARK: - Fixture helpers

    /// The contract header, exactly as make_neutral_review_csv.py writes it.
    static let header = "reviewId,fullPath,rickConfirm(yes/no),notes"

    /// Build a CSV in Python csv.writer style: CRLF terminators
    /// (including trailing) — rows passed as pre-escaped strings.
    private func csvText(_ dataLines: [String]) -> String {
        ([Self.header] + dataLines).map { $0 + "\r\n" }.joined()
    }

    /// Fresh temp dir per call — cleaned up by the OS, never a real path.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holdout-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write a queue CSV into <dir> and return its URL.
    private func writeCSV(_ text: String, in dir: URL,
                          name: String = HoldoutReviewQueue.csvFilename) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Three-row fixture: row 2's path has a comma (quoted, like the
    /// real "Jul 23, 2010" iPhoto paths), row 3 is pre-answered.
    private var fixtureText: String {
        csvText([
            "AAAA00000001,/Volumes/T/plain/IMG_0001.MOV,,",
            "BBBB00000002,\"/Volumes/T/iPhoto/Jul 23, 2010/IMG_0532.MOV\",,",
            "CCCC00000003,/Volumes/T/plain/IMG_0003.MOV,no,too dark to tell",
        ])
    }

    // MARK: - 1. Parse

    @Test func parse_contractHeaderAndRows() throws {
        let dir = try makeTempDir()
        let url = try writeCSV(fixtureText, in: dir)
        let q = try HoldoutReviewQueue.load(csvURL: url)

        #expect(q.header == ["reviewId", "fullPath", "rickConfirm(yes/no)", "notes"])
        #expect(q.rows.count == 3)
        #expect(q.rows[0].reviewId == "AAAA00000001")
        #expect(q.rows[0].fullPath == "/Volumes/T/plain/IMG_0001.MOV")
        #expect(q.rows[2].rickConfirm == "no")
        #expect(q.rows[2].notes == "too dark to tell")
    }

    @Test func parse_quotedCommaInPath() throws {
        let dir = try makeTempDir()
        let url = try writeCSV(fixtureText, in: dir)
        let q = try HoldoutReviewQueue.load(csvURL: url)

        // The comma inside the quoted path must NOT split the field.
        #expect(q.rows[1].fullPath == "/Volumes/T/iPhoto/Jul 23, 2010/IMG_0532.MOV")
        #expect(q.rows[1].filename == "IMG_0532.MOV")
    }

    @Test func parse_rejectsWrongHeader() throws {
        let dir = try makeTempDir()
        let url = try writeCSV("id,path,answer,notes\r\nX,/a,,\r\n", in: dir)
        #expect(throws: HoldoutReviewQueue.QueueError.self) {
            _ = try HoldoutReviewQueue.load(csvURL: url)
        }
    }

    @Test func parse_lfOnlyLineEndingsAlsoAccepted() throws {
        // Defensive: a hand edit in a Unix editor may convert CRLF → LF.
        let dir = try makeTempDir()
        let lf = ([Self.header, "AAAA00000001,/Volumes/T/a.mov,,"]).joined(separator: "\n") + "\n"
        let url = try writeCSV(lf, in: dir)
        let q = try HoldoutReviewQueue.load(csvURL: url)
        #expect(q.rows.count == 1)
        #expect(q.rows[0].isPending)
    }

    // MARK: - 2. Pending + resume

    @Test func pending_emptyAnswerIsPending() throws {
        let dir = try makeTempDir()
        let q = try HoldoutReviewQueue.load(csvURL: writeCSV(fixtureText, in: dir))
        #expect(q.rows[0].isPending)
        #expect(q.rows[1].isPending)
        #expect(!q.rows[2].isPending)
        #expect(q.pendingCount == 2)
        #expect(q.answeredCount == 1)
    }

    @Test func resume_firstPendingSkipsAnswered() throws {
        let dir = try makeTempDir()
        let text = csvText([
            "AAAA00000001,/Volumes/T/a.mov,yes,",
            "BBBB00000002,/Volumes/T/b.mov,no,",
            "CCCC00000003,/Volumes/T/c.mov,,",
            "DDDD00000004,/Volumes/T/d.mov,,",
        ])
        let q = try HoldoutReviewQueue.load(csvURL: writeCSV(text, in: dir))
        // Reopening lands on the FIRST unanswered row — index 2.
        #expect(q.firstPendingIndex == 2)
    }

    @Test func resume_allAnsweredHasNoPendingIndex() throws {
        let dir = try makeTempDir()
        let text = csvText(["AAAA00000001,/Volumes/T/a.mov,yes,seen at 0:12"])
        let q = try HoldoutReviewQueue.load(csvURL: writeCSV(text, in: dir))
        #expect(q.firstPendingIndex == nil)
        #expect(q.pendingCount == 0)
    }

    @Test func navigation_nextPendingWrapsAndExcludesCurrent() throws {
        let dir = try makeTempDir()
        let text = csvText([
            "AAAA00000001,/Volumes/T/a.mov,,",
            "BBBB00000002,/Volumes/T/b.mov,yes,",
            "CCCC00000003,/Volumes/T/c.mov,,",
        ])
        let q = try HoldoutReviewQueue.load(csvURL: writeCSV(text, in: dir))
        #expect(q.nextPendingIndex(after: 0) == 2)   // skips answered row 1
        #expect(q.nextPendingIndex(after: 2) == 0)   // wraps to the front
        // A row is never its own successor (Skip on the last pending
        // row must return nil, not spin in place).
        let onePending = try HoldoutReviewQueue.load(
            csvURL: writeCSV(csvText(["AAAA00000001,/Volumes/T/a.mov,,"]),
                             in: makeTempDir()))
        #expect(onePending.nextPendingIndex(after: 0) == nil)
    }

    // MARK: - 3. Write-back

    @Test func writeback_isWriteThroughPerAnswer() throws {
        let dir = try makeTempDir()
        let url = try writeCSV(fixtureText, in: dir)
        var q = try HoldoutReviewQueue.load(csvURL: url)

        try q.recordAnswer(reviewId: "AAAA00000001", confirm: "yes", notes: "on the porch swing")

        // A FRESH load from disk must already show the answer — the
        // write happened during recordAnswer, not at sheet close.
        let reloaded = try HoldoutReviewQueue.load(csvURL: url)
        #expect(reloaded.rows[0].rickConfirm == "yes")
        #expect(reloaded.rows[0].notes == "on the porch swing")
        #expect(reloaded.pendingCount == 1)
        // Untouched rows preserved verbatim.
        #expect(reloaded.rows[1].fullPath == "/Volumes/T/iPhoto/Jul 23, 2010/IMG_0532.MOV")
        #expect(reloaded.rows[2].rickConfirm == "no")
    }

    @Test func writeback_quotesCommaAndQuoteInNotes() throws {
        let dir = try makeTempDir()
        let url = try writeCSV(fixtureText, in: dir)
        var q = try HoldoutReviewQueue.load(csvURL: url)

        try q.recordAnswer(reviewId: "AAAA00000001", confirm: "no",
                           notes: "blonde, thin — she said \"hi\"")

        // On-disk bytes: field quoted, embedded quotes doubled (what
        // Python csv.reader in apply_label_csv.py expects).
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"blonde, thin — she said \"\"hi\"\"\""))

        // And it round-trips back through our own parser.
        let reloaded = try HoldoutReviewQueue.load(csvURL: url)
        #expect(reloaded.rows[0].notes == "blonde, thin — she said \"hi\"")
        #expect(reloaded.rows[0].rickConfirm == "no")
    }

    @Test func writeback_unknownReviewIdThrowsAndWritesNothing() throws {
        let dir = try makeTempDir()
        let url = try writeCSV(fixtureText, in: dir)
        let before = try Data(contentsOf: url)
        var q = try HoldoutReviewQueue.load(csvURL: url)

        #expect(throws: HoldoutReviewQueue.QueueError.unknownReviewId("ZZZZ99999999")) {
            try q.recordAnswer(reviewId: "ZZZZ99999999", confirm: "yes", notes: "")
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func writeback_reAnswerOverwrites() throws {
        // Back-navigation lets Rick change a saved answer; the CSV must
        // reflect the LATEST decision only.
        let dir = try makeTempDir()
        let url = try writeCSV(fixtureText, in: dir)
        var q = try HoldoutReviewQueue.load(csvURL: url)

        try q.recordAnswer(reviewId: "BBBB00000002", confirm: "yes", notes: "first pass")
        try q.recordAnswer(reviewId: "BBBB00000002", confirm: "no", notes: "second look — not her")

        let reloaded = try HoldoutReviewQueue.load(csvURL: url)
        #expect(reloaded.rows[1].rickConfirm == "no")
        #expect(reloaded.rows[1].notes == "second look — not her")
        #expect(reloaded.rows.count == 3)   // no duplicate rows
    }

    // MARK: - 4. Byte round-trip

    @Test func roundTrip_untouchedLoadSerializeIsByteIdentical() throws {
        // The gate: codex's tooling must receive the file it produced,
        // plus filled answers and nothing else. An untouched
        // load→serialize must therefore be byte-for-byte identical
        // (CRLF terminators, minimal quoting, trailing newline).
        let dir = try makeTempDir()
        let url = try writeCSV(fixtureText, in: dir)
        let original = try Data(contentsOf: url)
        let q = try HoldoutReviewQueue.load(csvURL: url)
        #expect(q.serialized() == original)
    }

    @Test func roundTrip_preservesExtraColumns() throws {
        // Future-proofing: a 5th column added by tooling must survive an
        // app-side answer write untouched.
        let dir = try makeTempDir()
        let text = ([Self.header + ",era"] + [
            "AAAA00000001,/Volumes/T/a.mov,,,1980s",
            "BBBB00000002,/Volumes/T/b.mov,,,2000s",
        ]).map { $0 + "\r\n" }.joined()
        let url = try writeCSV(text, in: dir)
        var q = try HoldoutReviewQueue.load(csvURL: url)
        #expect(q.rows[0].extraColumns == ["1980s"])

        try q.recordAnswer(reviewId: "AAAA00000001", confirm: "yes", notes: "")
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk.contains("AAAA00000001,/Volumes/T/a.mov,yes,,1980s\r\n"))
        #expect(onDisk.contains("BBBB00000002,/Volumes/T/b.mov,,,2000s\r\n"))
    }

    // MARK: - 5. Discovery

    @Test func discovery_picksNewestDatedDirectory() throws {
        let root = try makeTempDir()
        let older = root.appendingPathComponent("output/person-eval-private/2026-07-11", isDirectory: true)
        let newer = root.appendingPathComponent("output/person-eval-private/2026-07-23", isDirectory: true)
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
        _ = try writeCSV(csvText(["OLD000000001,/Volumes/T/old.mov,,"]), in: older)
        _ = try writeCSV(csvText(["NEW000000001,/Volumes/T/new.mov,,"]), in: newer)

        let q = HoldoutReviewQueue.discover(repoRoot: root)
        #expect(q?.rows.first?.reviewId == "NEW000000001")
    }

    @Test func discovery_skipsDatedDirWithoutCSV() throws {
        // The newest dated dir may hold other artifacts but no queue —
        // fall back to the next-newest that has one.
        let root = try makeTempDir()
        let older = root.appendingPathComponent("output/person-eval-private/2026-07-11", isDirectory: true)
        let newer = root.appendingPathComponent("output/person-eval-private/2026-07-30", isDirectory: true)
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
        _ = try writeCSV(csvText(["OLD000000001,/Volumes/T/old.mov,,"]), in: older)

        let q = HoldoutReviewQueue.discover(repoRoot: root)
        #expect(q?.rows.first?.reviewId == "OLD000000001")
    }

    @Test func discovery_missingTreeReturnsNilNotCrash() throws {
        let root = try makeTempDir()   // no output/ tree at all
        #expect(HoldoutReviewQueue.discover(repoRoot: root) == nil)
    }

    @Test func discovery_personDefaultsToDonna() throws {
        let root = try makeTempDir()
        let dated = root.appendingPathComponent("output/person-eval-private/2026-07-23", isDirectory: true)
        try FileManager.default.createDirectory(at: dated, withIntermediateDirectories: true)
        _ = try writeCSV(fixtureText, in: dated)

        // No sidecar → the queue is Donna's (today's real queue).
        #expect(HoldoutReviewQueue.discover(repoRoot: root)?.personName == "Donna")
    }

    @Test func discovery_personSidecarOverridesDefault() throws {
        let root = try makeTempDir()
        let dated = root.appendingPathComponent("output/person-eval-private/2026-07-23", isDirectory: true)
        try FileManager.default.createDirectory(at: dated, withIntermediateDirectories: true)
        _ = try writeCSV(fixtureText, in: dated)
        try Data("Timmy\n".utf8).write(
            to: dated.appendingPathComponent(HoldoutReviewQueue.personSidecarFilename))

        #expect(HoldoutReviewQueue.discover(repoRoot: root)?.personName == "Timmy")
    }

    // MARK: - 6. Blindness sensor

    /// Pins the POI-leakage contract: the ONLY data the holdout sheet
    /// can render for a queued video is what HoldoutReviewRow carries —
    /// id, path, answer, notes (+ opaque passthrough columns). If anyone
    /// adds a score/signal/prediction field to the types that drive the
    /// holdout pane, this fails and forces a contract conversation.
    @Test func blindness_rowExposesOnlyContractFields() {
        let row = HoldoutReviewRow(
            reviewId: "AAAA00000001", fullPath: "/Volumes/T/a.mov",
            rickConfirm: "", notes: "", extraColumns: [])
        let labels = Mirror(reflecting: row).children.compactMap(\.label)
        #expect(Set(labels) == ["reviewId", "fullPath", "rickConfirm", "notes", "extraColumns"])

        let forbidden = ["score", "signal", "candidate", "predict", "detect",
                         "confidence", "rating", "match", "model", "face"]
        for label in labels {
            for term in forbidden {
                #expect(!label.lowercased().contains(term),
                        "HoldoutReviewRow.\(label) smells like prediction data (\(term))")
            }
        }
    }

    @Test func blindness_queueExposesOnlyPlumbingFields() throws {
        let dir = try makeTempDir()
        let q = try HoldoutReviewQueue.load(csvURL: writeCSV(fixtureText, in: dir))
        let labels = Mirror(reflecting: q).children.compactMap(\.label)
        // csvURL/personName/header/rows — file plumbing only. (Mirror
        // shows the backing store `rows` for the private(set) property.)
        #expect(Set(labels) == ["csvURL", "personName", "header", "rows"])

        let forbidden = ["score", "signal", "candidate", "predict", "detect",
                         "confidence", "rating", "match", "model"]
        for label in labels {
            for term in forbidden {
                #expect(!label.lowercased().contains(term),
                        "HoldoutReviewQueue.\(label) smells like prediction data (\(term))")
            }
        }
    }

    /// The sheet is driven by ConfirmSheetTarget — in holdout mode it
    /// must carry the profile + the blind queue and nothing predictive.
    @Test func blindness_sheetTargetCarriesOnlyProfileAndQueue() throws {
        let dir = try makeTempDir()
        let q = try HoldoutReviewQueue.load(csvURL: writeCSV(fixtureText, in: dir))
        let target = ConfirmSheetTarget(
            profile: POIProfile(name: "Donna", referencePath: ""),
            holdoutQueue: q)
        let labels = Mirror(reflecting: target).children.compactMap(\.label)
        #expect(Set(labels) == ["id", "profile", "holdoutQueue"])
    }
}
