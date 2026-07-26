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

    @Test func parse_rejectsBlankDuplicateAndInvalidContractValues() throws {
        let dir = try makeTempDir()
        #expect(throws: HoldoutReviewQueue.QueueError.blankReviewId(line: 2)) {
            _ = try HoldoutReviewQueue.load(csvURL: writeCSV(
                csvText([",/a.mov,,"]), in: dir, name: "blank-id.csv"))
        }
        #expect(throws: HoldoutReviewQueue.QueueError.blankPath(line: 2)) {
            _ = try HoldoutReviewQueue.load(csvURL: writeCSV(
                csvText(["A,,,"]), in: dir, name: "blank-path.csv"))
        }
        #expect(throws: HoldoutReviewQueue.QueueError.duplicateReviewId("A")) {
            _ = try HoldoutReviewQueue.load(csvURL: writeCSV(
                csvText(["A,/a.mov,,", "A,/b.mov,,"]),
                in: dir, name: "duplicate.csv"))
        }
    }

    @Test func parse_strayAnswerValueIsPreservedButRemainsPending() throws {
        // LOAD is lenient: one hand-edited stray cell ("Yes", "maybe")
        // must not make the queue unloadable (and the badge silently
        // vanish). Stored values are byte-verbatim — no lowercasing on
        // load. Classification is strict-but-tolerant of whitespace:
        // ONLY an exact trimmed "yes"/"no" closes the gate; any other
        // value (even "Yes") remains PENDING so the badge stays lit
        // until Rick replaces it with an exact yes/no through the app.
        // Writes are strict too (see writeback_rejectsInvalidAnswer...).
        let dir = try makeTempDir()
        let text = csvText([
            "AAAA00000001,/Volumes/T/a.mov,Yes,",
            "BBBB00000002,/Volumes/T/b.mov,maybe,had to squint",
            "CCCC00000003,/Volumes/T/c.mov,,",
        ])
        let url = try writeCSV(text, in: dir)
        let q = try HoldoutReviewQueue.load(csvURL: url)

        #expect(q.rows[0].rickConfirm == "Yes")     // verbatim, not "yes"
        #expect(q.rows[0].isPending)                // only exact lowercase yes/no closes gate
        #expect(q.rows[1].rickConfirm == "maybe")   // verbatim
        #expect(q.rows[1].isPending)                // unknown value ≠ gate answer
        #expect(q.rows[2].isPending)                // blank = pending
        #expect(q.pendingCount == 3)
        #expect(q.firstPendingIndex == 0)
        // Byte-verbatim round trip survives the stray values.
        #expect(q.serialized() == (try Data(contentsOf: url)))
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

    @Test func writeback_rejectsInvalidAnswerAndMaintainsCachedCount() throws {
        let dir = try makeTempDir()
        let url = try writeCSV(fixtureText, in: dir)
        var q = try HoldoutReviewQueue.load(csvURL: url)
        #expect(q.pendingCount == 2)
        // WRITES are strict yes/no even though load is lenient.
        #expect(throws: HoldoutReviewQueue.QueueError.invalidAnswer("maybe")) {
            try q.recordAnswer(reviewId: "AAAA00000001", confirm: "maybe", notes: "")
        }
        #expect(q.pendingCount == 2)
        try q.recordAnswer(reviewId: "AAAA00000001", confirm: "yes", notes: "")
        #expect(q.pendingCount == 1)
        // Re-answering an already-answered row must not double-decrement.
        try q.recordAnswer(reviewId: "AAAA00000001", confirm: "no", notes: "changed")
        #expect(q.pendingCount == 1)
        // Cached count agrees with a fresh recount from disk.
        let reloaded = try HoldoutReviewQueue.load(csvURL: url)
        #expect(reloaded.pendingCount == q.pendingCount)
        #expect(reloaded.rows.filter(\.isPending).count == q.pendingCount)
    }

    // regression: stale-snapshot open clobbered answers recorded on disk
    // after discovery — the first in-app answer rewrote the whole CSV
    // from stale memory, destroying external answers/hand edits
    // (QA 2026-07-25 blocker). The sheet's startHoldout() must seed its
    // working copy through freshCopyFromDisk(), never from the
    // discovery-time snapshot.
    @Test func regression_staleSnapshotOpenPreservesExternalAnswer() throws {
        let dir = try makeTempDir()
        let url = try writeCSV(fixtureText, in: dir)
        // Discovery-time snapshot — what ConfirmSheetTarget carries.
        let snapshot = try HoldoutReviewQueue.load(csvURL: url)

        // Behind the snapshot's back: row B gets answered externally
        // (hand edit in an editor, or a prior sheet session's write).
        var external = try HoldoutReviewQueue.load(csvURL: url)
        try external.recordAnswer(reviewId: "BBBB00000002", confirm: "yes",
                                  notes: "answered externally")

        // Sheet opens with the now-stale snapshot; the working copy is
        // seeded via freshCopyFromDisk() — the open-time reload decision.
        var opened = try snapshot.freshCopyFromDisk()
        // First in-app answer, on a DIFFERENT row.
        try opened.recordAnswer(reviewId: "AAAA00000001", confirm: "no", notes: "")

        // The externally recorded answer must SURVIVE the write-through.
        let reloaded = try HoldoutReviewQueue.load(csvURL: url)
        #expect(reloaded.rows[1].rickConfirm == "yes")
        #expect(reloaded.rows[1].notes == "answered externally")
        #expect(reloaded.rows[0].rickConfirm == "no")
        #expect(reloaded.pendingCount == 0)
    }

    // regression: recordAnswer rewrote the WHOLE CSV from in-memory queue
    // state — an external edit landing while the sheet was OPEN (codex's
    // Python tooling, a hand edit) was silently reverted wholesale by the
    // next in-app answer. recordAnswer must merge-on-write: reload disk as
    // the base, replace only the answered row (QA 2026-07-25 gate finding 1).
    @Test func regression_externalEditDuringOpenSessionSurvivesRecordAnswer() throws {
        let dir = try makeTempDir()
        let url = try writeCSV(fixtureText, in: dir)
        // Sheet opens with a fresh load — then STAYS open.
        var opened = try HoldoutReviewQueue.load(csvURL: url)

        // Behind the open sheet's back: an external tool answers row B,
        // exactly as apply_label_csv-lineage tooling or a hand edit would.
        var external = try HoldoutReviewQueue.load(csvURL: url)
        try external.recordAnswer(reviewId: "BBBB00000002", confirm: "yes",
                                  notes: "answered externally mid-session")

        // In-app answer on a DIFFERENT row, from the still-open copy.
        try opened.recordAnswer(reviewId: "AAAA00000001", confirm: "no",
                                notes: "not her")

        let reloaded = try HoldoutReviewQueue.load(csvURL: url)
        // The external modification SURVIVES the in-app write-through...
        #expect(reloaded.rows[1].rickConfirm == "yes")
        #expect(reloaded.rows[1].notes == "answered externally mid-session")
        // ...AND the in-app answer is recorded.
        #expect(reloaded.rows[0].rickConfirm == "no")
        #expect(reloaded.rows[0].notes == "not her")
        #expect(reloaded.pendingCount == 0)
        // The open copy's cached state tracks the merged truth it wrote.
        #expect(opened.rows[1].rickConfirm == "yes")
        #expect(opened.pendingCount == 0)
    }

    // regression companion (same finding): if an external writer REMOVED
    // the row being answered (truncated queue regenerated mid-session),
    // that's an error on the existing strict path — never re-append the
    // row from memory, never clobber the truncation.
    @Test func regression_externallyRemovedRowIsAnErrorNotAClobber() throws {
        let dir = try makeTempDir()
        let url = try writeCSV(fixtureText, in: dir)
        var opened = try HoldoutReviewQueue.load(csvURL: url)

        // External truncation: row A vanishes from disk.
        let truncated = csvText([
            "BBBB00000002,\"/Volumes/T/iPhoto/Jul 23, 2010/IMG_0532.MOV\",,",
            "CCCC00000003,/Volumes/T/plain/IMG_0003.MOV,no,too dark to tell",
        ])
        try Data(truncated.utf8).write(to: url)

        #expect(throws: HoldoutReviewQueue.QueueError.unknownReviewId("AAAA00000001")) {
            try opened.recordAnswer(reviewId: "AAAA00000001", confirm: "yes", notes: "")
        }
        // Disk keeps the external truncation, byte-for-byte.
        #expect(try Data(contentsOf: url) == Data(truncated.utf8))
        // Nothing was saved, so memory must not have changed either.
        #expect(opened.rows.count == 3)
        #expect(opened.pendingCount == 2)
    }

    // regression: recordAnswer mutated rows BEFORE the throwing write —
    // on write failure, memory diverged from disk (QA 2026-07-25 minor 1).
    @Test func regression_failedWriteLeavesMemoryMatchingDisk() throws {
        let dir = try makeTempDir()
        let url = try writeCSV(fixtureText, in: dir)
        var q = try HoldoutReviewQueue.load(csvURL: url)

        // Make the atomic write fail: remove the CSV's directory.
        try FileManager.default.removeItem(at: dir)
        #expect(throws: Error.self) {
            try q.recordAnswer(reviewId: "AAAA00000001", confirm: "yes",
                               notes: "lost to disk")
        }
        // Nothing reached disk, so nothing may change in memory either.
        #expect(q.rows[0].rickConfirm.isEmpty)
        #expect(q.rows[0].notes.isEmpty)
        #expect(q.rows[0].isPending)
        #expect(q.pendingCount == 2)
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

    // regression: discovery sorted ALL subdirectories lexicographically —
    // any letter-named dir (archive/, scratch/) sorts above digits and
    // permanently shadowed the real dated queues (QA 2026-07-25 minor 2).
    @Test func regression_discoveryIgnoresNonDatedDirectories() throws {
        let root = try makeTempDir()
        let dated = root.appendingPathComponent("output/person-eval-private/2026-07-23", isDirectory: true)
        let archive = root.appendingPathComponent("output/person-eval-private/archive", isDirectory: true)
        try FileManager.default.createDirectory(at: dated, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        _ = try writeCSV(csvText(["DATED0000001,/Volumes/T/dated.mov,,"]), in: dated)
        _ = try writeCSV(csvText(["ARCH00000001,/Volumes/T/arch.mov,,"]), in: archive)

        // "archive" > "2026-07-23" in ASCII descending sort — it must be
        // filtered out, not win.
        let q = HoldoutReviewQueue.discover(repoRoot: root)
        #expect(q?.rows.first?.reviewId == "DATED0000001")
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

    @Test func discovery_emptyPersonSidecarIsAnError() throws {
        // A sidecar that EXISTS but is blank is a broken config, not a
        // silent fall-back to Donna — surface it via the throwing path
        // (the People UI shows the error label instead of a wrong badge).
        let root = try makeTempDir()
        let dated = root.appendingPathComponent("output/person-eval-private/2026-07-23", isDirectory: true)
        try FileManager.default.createDirectory(at: dated, withIntermediateDirectories: true)
        _ = try writeCSV(fixtureText, in: dated)
        try Data("  \n".utf8).write(
            to: dated.appendingPathComponent(HoldoutReviewQueue.personSidecarFilename))

        #expect(throws: HoldoutReviewQueue.QueueError.invalidPersonSidecar) {
            _ = try HoldoutReviewQueue.discoverLatest(repoRoot: root)
        }
        // The non-throwing badge path degrades to nil, never crashes.
        #expect(HoldoutReviewQueue.discover(repoRoot: root) == nil)
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

    @Test func discovery_rejectsBlankPersonSidecar() throws {
        let root = try makeTempDir()
        let dated = root.appendingPathComponent(
            "output/person-eval-private/2026-07-23", isDirectory: true)
        try FileManager.default.createDirectory(at: dated, withIntermediateDirectories: true)
        _ = try writeCSV(fixtureText, in: dated)
        try Data(" \n".utf8).write(
            to: dated.appendingPathComponent(HoldoutReviewQueue.personSidecarFilename))
        #expect(throws: HoldoutReviewQueue.QueueError.invalidPersonSidecar) {
            _ = try HoldoutReviewQueue.discoverLatest(repoRoot: root)
        }
    }

    @Test func discovery_propagatesDirectoryReadFailure() throws {
        let root = try makeTempDir()
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(
            to: output.appendingPathComponent("person-eval-private"))
        #expect(throws: Error.self) {
            _ = try HoldoutReviewQueue.discoverLatest(repoRoot: root)
        }
    }

    @Test func discovery_throwingVariantSurfacesMalformedNewestQueue() throws {
        let root = try makeTempDir()
        let dated = root.appendingPathComponent(
            "output/person-eval-private/2026-07-30", isDirectory: true)
        try FileManager.default.createDirectory(at: dated, withIntermediateDirectories: true)
        _ = try writeCSV("wrong,header\r\n", in: dated)
        #expect(throws: HoldoutReviewQueue.QueueError.self) {
            _ = try HoldoutReviewQueue.discoverLatest(repoRoot: root)
        }
    }

    @Test func scale_loadsOneHundredThousandRowsWithinBudget() throws {
        let dir = try makeTempDir()
        var text = Self.header + "\r\n"
        text.reserveCapacity(4_500_000)
        for index in 0..<100_000 {
            text += "R\(index),/Volumes/Test/video_\(index).mov,,\r\n"
        }
        let url = try writeCSV(text, in: dir)
        let clock = ContinuousClock()
        var loaded: HoldoutReviewQueue?
        let elapsed = try clock.measure {
            loaded = try HoldoutReviewQueue.load(csvURL: url)
        }
        #expect(loaded?.rows.count == 100_000)
        #expect(loaded?.pendingCount == 100_000)
        #expect(elapsed < .seconds(8))
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
        #expect(Set(labels) == ["csvURL", "personName", "header", "rows", "pendingCount"])

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
