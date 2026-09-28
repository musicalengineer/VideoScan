// PersonRefreshAuditLogTests.swift
// GH #198 — audit-grade logging for "Refresh from FamilySearch…".
//
// Rick, 2026-09-26, after the Ellen Ronan refresh (G9P1-3PZ: birthDate
// '1883' → '18 March 1882', birthPlace 'Ireland' → 'County Cork, Ireland'):
// "I looked at the log and don't see the expected 'Refresh Ellen Ronan …
// from …'. This kind of change needs better logging if we were to go back
// and see what happened." The lines had gone to videoscan.log only.
//
// Five dimensions (CLAUDE.md):
//   LOGIC     PersonRefreshAuditLineTests (wording, pure) and
//             PersonRefreshAuditSinkTests (the line set per run kind, both
//             destinations captured)
//   ISOLATION PersonRefreshAuditIsolationTests — journal unreadable → the
//             lines still go out, the card shows nothing; no console
//             attached → videoscan.log still gets every line
//   SENSOR    PersonRefreshAuditSensorTests — every run kind leaves exactly
//             one `started` and exactly one outcome in BOTH destinations,
//             and the two destinations carry the same sentences
//   SCALE     n/a (one person per run; the journal replay is O(entries)
//             once per Apply/Undo, never per card)
//   MEDIA     n/a (no media files are opened)

import Foundation
import Testing
@testable import VideoScan
@testable import VideoScanCore

private typealias AF = PersonRefreshAppFixtures

/// A clock the test advances by hand — so "received … in 22 s" is exact.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval
    /// Starts at the real now: the fixture's tree pull is dated "yesterday",
    /// and an apply older than the pull is (correctly) retired as superseded.
    init(_ seconds: TimeInterval = Date().timeIntervalSince1970) { self.seconds = seconds }
    func now() -> Date { lock.withLock { Date(timeIntervalSince1970: seconds) } }
    func advance(_ by: TimeInterval) { lock.withLock { seconds += by } }
}

/// Both destinations of one sink, captured.
@MainActor
private final class Captured {
    let videoscan = AF.Lines()
    let console = AF.Lines()
    var sink: PersonRefreshNoteSink {
        let v = videoscan, c = console
        return PersonRefreshNoteSink(videoscanLog: { v.append($0) }, console: { c.append($0) })
    }
    /// Console lines must be the videoscan lines with the tag stripped.
    var consoleMatchesVideoscan: Bool {
        videoscan.all.map { $0.replacingOccurrences(of: PersonRefreshNoteSink.tag + " ", with: "") } == console.all
    }
    func lines(matching needle: String) -> [String] { console.all.filter { $0.contains(needle) } }
}

private let walter = "Refresh from FamilySearch: Walter James Dunn (WWWW-111) — "

private let outcomeMarkers = [" — done:", " — refused:", " — failed:", " — cancelled "]

private func isOutcome(_ line: String) -> Bool { outcomeMarkers.contains { line.contains($0) } }

// MARK: - Rig (the lifecycle harness, with both destinations and a clock)

@MainActor
private struct Rig {
    let layout: AF.Layout
    let model: FamilyTreeLiveModel
    let captured = Captured()
    let clock = TestClock()

    init(_ tag: String) throws {
        layout = try AF.layout(tag: "audit-\(tag)")
        model = FamilyTreeLiveModel(originalsDirectory: layout.gedcom)
        model.personRefreshOverlayStore = layout.overlayStore
        model.loadNow()
    }

    func coordinator(personID: String = "@I1@", installed: (@MainActor () -> PersonFacts?)? = nil,
                     journalDirectory: URL? = nil, tool: String? = "default") -> PersonRefreshCoordinator {
        let target = model.personRefreshTarget(for: personID)!
        let model = self.model
        let clock = self.clock
        return PersonRefreshCoordinator(
            target: target, root: layout.refreshRoot, overlayStore: layout.overlayStore,
            journalDirectory: journalDirectory,
            installedFacts: installed ?? { model.personFacts(familySearchID: target.familySearchID) },
            locator: FamilySearchToolLocator(overridePath: tool == "default" ? layout.tool.path : tool, candidatePaths: []),
            launcher: AF.SilentLauncher(), pollInterval: .milliseconds(20),
            sink: captured.sink, now: { clock.now() })
    }

    func answer(_ coordinator: PersonRefreshCoordinator, with text: String) throws {
        guard case .waiting(let output) = coordinator.phase else {
            Issue.record("not waiting: \(coordinator.phase)"); return
        }
        try text.write(to: output, atomically: true, encoding: .utf8)
    }

    func remove() { layout.remove() }
}

@MainActor
private func isReady(_ c: PersonRefreshCoordinator) -> Bool { if case .ready = c.phase { true } else { false } }
@MainActor
private func isRefused(_ c: PersonRefreshCoordinator) -> Bool { if case .refused = c.phase { true } else { false } }
@MainActor
private func isFailed(_ c: PersonRefreshCoordinator) -> Bool { if case .failed = c.phase { true } else { false } }

// MARK: - LOGIC: the wording, pure

@Suite("Refresh from FamilySearch — audit lines (pure)")
struct PersonRefreshAuditLineTests {

    @Test func everyLineNamesThePersonAndTheID() {
        #expect(PersonRefreshAuditLines.subject(person: "Ellen Ronan", familySearchID: "G9P1-3PZ")
                == "Refresh from FamilySearch: Ellen Ronan (G9P1-3PZ) — ")
    }

    @Test func elapsedReadsLikeAPerson() {
        #expect(PersonRefreshAuditLines.elapsed(22) == "22 s")
        #expect(PersonRefreshAuditLines.elapsed(0.4) == "0 s")
        #expect(PersonRefreshAuditLines.elapsed(185) == "3 min 5 s")
        #expect(PersonRefreshAuditLines.elapsed(3_720) == "1 h 2 min")
        #expect(PersonRefreshAuditLines.elapsed(-5) == "0 s")
    }

    @Test func homeIsAbbreviatedOnlyAsAPrefix() {
        #expect(PersonRefreshAuditLines.abbreviated("/Users/rick/Library/x.json", home: "/Users/rick") == "~/Library/x.json")
        #expect(PersonRefreshAuditLines.abbreviated("/Volumes/Users/rick/x", home: "/Users/rick") == "/Volumes/Users/rick/x")
        #expect(PersonRefreshAuditLines.abbreviated("/Users/rickb/x", home: "/Users/rick") == "/Users/rickb/x")
    }

    @Test func theEllenRonanRunReadsAsRickAskedFor() {
        let at = Date(timeIntervalSince1970: 1_790_400_000)   // 2026-09-26 UTC
        let entry = PersonRefreshAudit.Entry(
            at: at, action: .applied, familySearchID: "G9P1-3PZ", person: "Ellen Ronan",
            changes: [.init(field: "birthDate", before: "1883", after: "18 March 1882"),
                      .init(field: "birthPlace", before: "Ireland", after: "County Cork, Ireland")],
            source: "G9P1-3PZ-20260926-205541/person.ged", relationshipNotes: 0)
        let lines = PersonRefreshAudit.lines(entry, overlayPath: "/Users/rick/Library/Application Support/VideoScan/family-tree/person-refresh/overlay.json")
        #expect(lines.count == 3)
        #expect(lines[0] == "Refresh from FamilySearch: Ellen Ronan (G9P1-3PZ) — applied birthDate '1883' → '18 March 1882' (from FamilySearch, 2026-09-26)")
        #expect(lines[1] == "Refresh from FamilySearch: Ellen Ronan (G9P1-3PZ) — applied birthPlace 'Ireland' → 'County Cork, Ireland' (from FamilySearch, 2026-09-26)")
        #expect(lines[2].hasPrefix("Refresh from FamilySearch: Ellen Ronan (G9P1-3PZ) — done: 2 fields changed, 0 relationship notes. Overlay: "))
        #expect(lines[2].hasSuffix("person-refresh/overlay.json. Revert: right-click Ellen Ronan in the Family Tree ▸ Undo last refresh for this person"))

        #expect(PersonRefreshAuditLines.started(answerFile: "G9P1-3PZ-20260926-205541/person.ged")
                == "started; the answer will land in G9P1-3PZ-20260926-205541/person.ged")
        #expect(PersonRefreshAuditLines.received(people: 2, after: 22, file: "G9P1-3PZ-20260926-205541/person.ged")
                == "received 2 people from FamilySearch in 22 s (G9P1-3PZ-20260926-205541/person.ged)")
        #expect(PersonRefreshAuditLines.received(people: 1, after: 3, file: "x/person.ged")
                == "received 1 person from FamilySearch in 3 s (x/person.ged)")
        #expect(PersonRefreshAuditLines.differences(fields: ["birthDate", "birthPlace"], relationshipNotes: 0)
                == "2 fields differ: birthDate, birthPlace; 0 relationship notes — waiting for review")
        #expect(PersonRefreshAuditLines.alreadyMatches(relationshipNotes: 1)
                == "done: already matches FamilySearch, nothing to apply; 1 relationship note; nothing was changed")
        #expect(PersonRefreshAuditLines.cancelled(pendingFields: ["birthDate"], stage: "at review")
                == "cancelled at review; nothing was changed (pending review: birthDate)")
        #expect(PersonRefreshAuditLines.cancelled(pendingFields: nil, stage: "while waiting for Terminal")
                == "cancelled while waiting for Terminal; nothing was changed")
        #expect(PersonRefreshAuditLines.failed("boom") == "failed: boom")
        #expect(PersonRefreshAuditLines.refused("Nothing was changed.") == "refused: Nothing was changed.")
    }

    @Test func aMissingValueIsADashAndAnUndoNamesEveryRestoredField() {
        let entry = PersonRefreshAudit.Entry(
            at: Date(), action: .undone, familySearchID: "G9P1-3PZ", person: "Ellen Ronan",
            changes: [.init(field: "birthDate", before: "18 March 1882", after: "1883"),
                      .init(field: "deathPlace", before: "Boston", after: nil)],
            source: nil)
        let lines = PersonRefreshAudit.lines(entry, overlayPath: "/x/overlay.json", tail: "the tree shows the pulled facts again")
        #expect(lines == ["Refresh from FamilySearch: Ellen Ronan (G9P1-3PZ) — undone: 2 fields restored: "
                          + "birthDate '18 March 1882' → '1883'; deathPlace 'Boston' → — — the tree shows the pulled facts again"])
    }

    @Test func aJournalWrittenBeforeThisChangeStillDecodes() throws {
        // No `relationshipNotes` key — the pre-#198 shape.
        let old = #"{"action":"applied","at":"2026-09-21T20:00:00Z","changes":[{"after":"1929","before":"1928","field":"birthDate"}],"familySearchID":"WWWW-111","person":"Walter","source":"WWWW-111-x/person.ged"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(PersonRefreshAudit.Entry.self, from: Data(old.utf8))
        #expect(entry.relationshipNotes == nil)
        #expect(PersonRefreshAudit.lines(entry, overlayPath: "/x").last?.contains("done: 1 field changed, 0 relationship notes") == true)
    }

    @Test func theCardSummaryIsTheJournalReplayed() {
        func e(_ action: PersonRefreshAudit.Action, _ fsid: String, at: TimeInterval, _ changes: [PersonRefreshAudit.FieldChange]) -> PersonRefreshAudit.Entry {
            .init(at: Date(timeIntervalSince1970: at), action: action, familySearchID: fsid, person: "P", changes: changes, source: nil)
        }
        let first = [PersonRefreshAudit.FieldChange(field: "birthDate", before: "1883", after: "1882")]
        let second = [PersonRefreshAudit.FieldChange(field: "birthPlace", before: nil, after: "Cork"),
                      PersonRefreshAudit.FieldChange(field: "deathDate", before: "1950", after: "1951")]
        let journal = [e(.applied, "g9p1-3pz", at: 1_790_400_000, first),
                       e(.applied, "G9P1-3PZ", at: 1_790_500_000, second),
                       e(.applied, "OTHR-001", at: 1_790_500_000, first),
                       e(.undone, "OTHR-001", at: 1_790_600_000, first)]
        let current = PersonRefreshHistory.current(journal)
        #expect(current.keys.sorted() == ["G9P1-3PZ"], "an undo of the only apply leaves nothing to show")
        let ellen = current["G9P1-3PZ"]!
        #expect(ellen.changes == second, "the newest apply is the current one")
        #expect(ellen.headline == "Refreshed from FamilySearch on 27 Sep 2026 — 2 fields")
        #expect(ellen.diffLines == ["birthPlace: — → 'Cork'", "deathDate: '1950' → '1951'"])
        #expect(ellen.tooltip == "Refreshed from FamilySearch on 27 Sep 2026 — 2 fields\nbirthPlace: — → 'Cork'\ndeathDate: '1950' → '1951'")

        // Undo the latest of two: the earlier one is current again.
        let undone = PersonRefreshHistory.current(journal + [e(.undone, "G9P1-3PZ", at: 1_790_700_000, second)])
        #expect(undone["G9P1-3PZ"]?.changes == first)
        #expect(undone["G9P1-3PZ"]?.headline == "Refreshed from FamilySearch on 26 Sep 2026 — 1 field")
        #expect(PersonRefreshHistory.current([]).isEmpty)
    }
}

// MARK: - LOGIC: the line set per run, both destinations

@Suite("Refresh from FamilySearch — the audit sink (lifecycle)", .serialized)
@MainActor
struct PersonRefreshAuditSinkTests {

    @Test func anAppliedRunTellsTheWholeStoryInBothPlaces() async throws {
        let rig = try Rig("applied")
        defer { rig.remove() }
        let coordinator = rig.coordinator()
        coordinator.launch()
        rig.clock.advance(22)
        try rig.answer(coordinator, with: AF.onePerson())
        #expect(await AF.waitUntil { isReady(coordinator) })
        guard case .ready(let diff) = coordinator.phase else { return }
        #expect(await coordinator.apply(selectedFieldKeys: Set(diff.changes.map(\.field.key))))

        let console = rig.captured.console.all
        let stamp = PersonRefreshAuditLines.dateStamp(rig.clock.now())
        #expect(console.count == 7, "\(console)")
        #expect(console[0].hasPrefix(walter + "started; the answer will land in WWWW-111-"))
        #expect(console[0].hasSuffix("/person.ged"))
        #expect(console[1].hasPrefix(walter + "received 2 people from FamilySearch in 22 s (WWWW-111-"))
        #expect(console[2] == walter + "3 fields differ: birthDate, deathPlace, marriageDate:MMMM-222; 0 relationship notes — waiting for review")
        #expect(console[3] == walter + "applied birthDate '21 Feb 1928' → '21 Feb 1929' (from FamilySearch, \(stamp))")
        #expect(console[4] == walter + "applied deathPlace — → 'Pittsfield, Massachusetts' (from FamilySearch, \(stamp))")
        #expect(console[5] == walter + "applied marriageDate:MMMM-222 '1950' → '12 Jun 1950' (from FamilySearch, \(stamp))")
        #expect(console[6].hasPrefix(walter + "done: 3 fields changed, 0 relationship notes. Overlay: "))
        #expect(console[6].contains("/person-refresh/overlay.json. Revert: right-click Walter James Dunn in the Family Tree ▸ Undo last refresh for this person"))
        #expect(rig.captured.consoleMatchesVideoscan)
        #expect(rig.captured.videoscan.all.allSatisfy { $0.hasPrefix("[fs-refresh] Refresh from FamilySearch: Walter James Dunn (WWWW-111) — ") })

        // The journal entry is the same story.
        let journal = PersonRefreshAudit.entries(directory: rig.layout.refreshRoot)
        #expect(journal.count == 1)
        #expect(journal.first?.relationshipNotes == 0)
        #expect(journal.first.map { PersonRefreshAudit.lines($0, overlayPath: rig.layout.overlayStore.fileURL.path) } == Array(console[3...6]))
    }

    @Test func aNoChangeRunIsDoneAtTheDiffAndACancelAfterItIsNotACancellation() async throws {
        let rig = try Rig("nodiff")
        defer { rig.remove() }
        // Apply once so the tree already matches the answer.
        let first = rig.coordinator()
        first.launch()
        try rig.answer(first, with: AF.onePerson())
        #expect(await AF.waitUntil { isReady(first) })
        guard case .ready(let diff) = first.phase else { return }
        await first.apply(selectedFieldKeys: Set(diff.changes.map(\.field.key)))
        await rig.model.reloadAfterPersonRefresh(selecting: "@I1@")

        let before = rig.captured.console.all.count
        let again = rig.coordinator()
        again.launch()
        rig.clock.advance(3)
        try rig.answer(again, with: AF.onePerson())
        #expect(await AF.waitUntil { isReady(again) })
        again.cancel()                       // the banner's Cancel after "already matches"
        let run = Array(rig.captured.console.all.dropFirst(before))
        #expect(run.count == 3, "\(run)")
        #expect(run[0].hasPrefix(walter + "started"))
        #expect(run[1].hasPrefix(walter + "received 2 people from FamilySearch in 3 s"))
        #expect(run[2] == walter + "done: already matches FamilySearch, nothing to apply; 0 relationship notes; nothing was changed")
        #expect(!run.contains { $0.contains("cancelled") })
        #expect(rig.captured.consoleMatchesVideoscan)
    }

    @Test func aCancelWhileWaitingAndACancelAtReviewSayWhatWasPending() async throws {
        let rig = try Rig("cancel")
        defer { rig.remove() }
        let waiting = rig.coordinator()
        waiting.launch()
        waiting.cancel()
        #expect(rig.captured.console.all.last == walter + "cancelled while waiting for Terminal; nothing was changed")

        let reviewing = rig.coordinator()
        reviewing.launch()
        try rig.answer(reviewing, with: AF.onePerson())
        #expect(await AF.waitUntil { isReady(reviewing) })
        reviewing.cancel()
        #expect(rig.captured.console.all.last == walter
                + "cancelled at review; nothing was changed (pending review: birthDate, deathPlace, marriageDate:MMMM-222)")
        reviewing.cancel()                   // a second Cancel says nothing more
        #expect(rig.captured.console.all.filter { $0.contains("cancelled at review") }.count == 1)
        #expect(rig.captured.consoleMatchesVideoscan)
    }

    @Test func aRefusalAndTheFailuresCarryTheReason() async throws {
        let rig = try Rig("refuse")
        defer { rig.remove() }

        let merged = rig.coordinator()
        merged.launch()
        try rig.answer(merged, with: AF.onePerson(fsid: "WXYZ-999"))
        #expect(await AF.waitUntil { isRefused(merged) })
        let refusal = rig.captured.console.all.last ?? ""
        #expect(refusal.hasPrefix(walter + "refused: "))
        #expect(refusal.contains("different person, WXYZ-999") && refusal.contains("Nothing was changed"))

        let noTool = rig.coordinator(tool: nil)
        noTool.launch()
        let tail = rig.captured.console.all.suffix(2)
        #expect(tail.first?.hasPrefix(walter + "started; the answer will land in") == true, "the attempt is on record even when nothing could start")
        #expect(tail.last == walter + "failed: could not start — " + FamilySearchPullError.toolNotFound.errorDescription!)

        let gone = rig.coordinator(installed: { nil })
        gone.launch()
        try rig.answer(gone, with: AF.onePerson())
        #expect(await AF.waitUntil { isFailed(gone) })
        #expect(rig.captured.console.all.last == walter
                + "failed: Walter James Dunn (WWWW-111) is no longer in the loaded tree, so there is nothing to compare. Nothing was changed.")

        let nothingTicked = rig.coordinator()
        nothingTicked.launch()
        try rig.answer(nothingTicked, with: AF.onePerson())
        #expect(await AF.waitUntil { isReady(nothingTicked) })
        #expect(await nothingTicked.apply(selectedFieldKeys: []))
        #expect(rig.captured.console.all.last == walter + "done: 0 fields applied (nothing was ticked); nothing was changed")
        #expect(rig.captured.consoleMatchesVideoscan)
    }

    @Test func anUndoIsOneLineNamingEveryRestoredField() async throws {
        let rig = try Rig("undo")
        defer { rig.remove() }
        let coordinator = rig.coordinator()
        coordinator.launch()
        try rig.answer(coordinator, with: AF.onePerson())
        #expect(await AF.waitUntil { isReady(coordinator) })
        await coordinator.apply(selectedFieldKeys: ["birthDate", "deathPlace"])
        _ = await PersonRefreshCoordinator.undoLast(
            familySearchID: "WWWW-111", personName: "Walter James Dunn", overlayStore: rig.layout.overlayStore,
            journalDirectory: rig.layout.refreshRoot, sink: rig.captured.sink, now: rig.clock.now())
        #expect(rig.captured.console.all.last == walter
                + "undone: 2 fields restored: birthDate '21 Feb 1929' → '21 Feb 1928'; deathPlace 'Pittsfield, Massachusetts' → — "
                + "— the tree shows the pulled facts again")
        #expect(rig.captured.consoleMatchesVideoscan)
    }
}

// MARK: - ISOLATION

@Suite("Refresh from FamilySearch — audit isolation", .serialized)
@MainActor
struct PersonRefreshAuditIsolationTests {

    /// The journal cannot be written or read (a directory squats on its
    /// name): every line still goes out, plus one saying the journal was
    /// not written; the Apply stands; the card shows nothing rather than
    /// something stale.
    @Test func anUnreadableJournalStillLogsAndTheCardShowsNothing() async throws {
        let rig = try Rig("journal-unreadable")
        defer { rig.remove() }
        let squatter = rig.layout.refreshRoot.appendingPathComponent(PersonRefreshPaths.journalFileName, isDirectory: true)
        try FileManager.default.createDirectory(at: squatter, withIntermediateDirectories: true)

        let coordinator = rig.coordinator()
        coordinator.launch()
        try rig.answer(coordinator, with: AF.onePerson())
        #expect(await AF.waitUntil { isReady(coordinator) })
        guard case .ready(let diff) = coordinator.phase else { return }
        #expect(await coordinator.apply(selectedFieldKeys: Set(diff.changes.map(\.field.key))))
        #expect(coordinator.phase == .applied(fields: 3))

        let console = rig.captured.console.all
        #expect(console.filter { $0.contains(" — applied ") }.count == 3)
        #expect(console.filter { $0.contains(" — done: 3 fields changed") }.count == 1)
        #expect(console.last?.hasPrefix(walter + "note: the journal line was not written (") == true)
        #expect(console.last?.hasSuffix("); the lines above are the record") == true)
        #expect(rig.captured.consoleMatchesVideoscan)

        // The overlay has the facts; the journal has nothing readable; the
        // center offers Undo but no "Refreshed on" line.
        let center = PersonRefreshCenter(root: rig.layout.refreshRoot, overlayStore: rig.layout.overlayStore)
        #expect(center.hasRefresh(for: "WWWW-111"))
        #expect(center.summary(for: "WWWW-111") == nil)
    }

    /// No console attached (a test host, or before the app has wired one):
    /// videoscan.log still gets every line — nothing depends on the console.
    @Test func noConsoleStillReachesVideoscanLog() throws {
        let lines = AF.Lines()
        let sink = PersonRefreshNoteSink(videoscanLog: { lines.append($0) })
        sink.note("Refresh from FamilySearch: Ellen Ronan (G9P1-3PZ) — started")
        #expect(lines.all == ["[fs-refresh] Refresh from FamilySearch: Ellen Ronan (G9P1-3PZ) — started"])
    }

    /// The card's summary follows the overlay, not the journal alone: an
    /// entry the overlay no longer carries (retired by a newer pull) is
    /// not shown as current.
    @Test func aSummaryNeedsTheOverlayToStillCarryThePerson() throws {
        let layout = try AF.layout(tag: "audit-stale")
        defer { layout.remove() }
        let entry = PersonRefreshAudit.Entry(
            at: Date(), action: .applied, familySearchID: "GONE-001", person: "Gone",
            changes: [.init(field: "birthDate", before: "1", after: "2")], source: nil)
        try PersonRefreshAudit.append(entry, directory: layout.refreshRoot)
        let center = PersonRefreshCenter(root: layout.refreshRoot, overlayStore: layout.overlayStore)
        #expect(center.summary(for: "GONE-001") == nil)
        #expect(center.summary(for: nil) == nil)
    }
}

// MARK: - SENSOR

@Suite("Refresh from FamilySearch — audit sensor (START + OUTCOME everywhere)", .serialized)
@MainActor
struct PersonRefreshAuditSensorTests {

    private func startsAndOutcomes(_ lines: [String]) -> (started: Int, outcomes: Int) {
        (lines.filter { $0.contains(" — started") }.count, lines.filter(isOutcome).count)
    }

    @Test(arguments: ["applied", "no-diff", "cancel-waiting", "cancel-review", "refused", "no-tool", "not-in-tree", "nothing-ticked"])
    func everyRunLeavesExactlyOneStartAndOneOutcomeInBothDestinations(_ kind: String) async throws {
        let rig = try Rig("sensor-\(kind)")
        defer { rig.remove() }
        var skip = 0
        if kind == "no-diff" {
            // Apply once and reload, so the next answer already matches;
            // only the second run's lines are judged.
            let first = rig.coordinator()
            first.launch()
            try rig.answer(first, with: AF.onePerson())
            #expect(await AF.waitUntil { isReady(first) })
            guard case .ready(let diff) = first.phase else { return }
            await first.apply(selectedFieldKeys: Set(diff.changes.map(\.field.key)))
            await rig.model.reloadAfterPersonRefresh(selecting: "@I1@")
            skip = rig.captured.console.all.count
        }
        let coordinator: PersonRefreshCoordinator
        switch kind {
        case "no-tool":
            coordinator = rig.coordinator(tool: nil)
            coordinator.launch()
        case "not-in-tree":
            coordinator = rig.coordinator(installed: { nil })
            coordinator.launch()
            try rig.answer(coordinator, with: AF.onePerson())
            #expect(await AF.waitUntil { isFailed(coordinator) })
        case "refused":
            coordinator = rig.coordinator()
            coordinator.launch()
            try rig.answer(coordinator, with: AF.onePerson(fsid: "WXYZ-999"))
            #expect(await AF.waitUntil { isRefused(coordinator) })
        case "cancel-waiting":
            coordinator = rig.coordinator()
            coordinator.launch()
            coordinator.cancel()
        case "no-diff":
            coordinator = rig.coordinator()
            coordinator.launch()
            try rig.answer(coordinator, with: AF.onePerson())
            #expect(await AF.waitUntil { isReady(coordinator) })
            guard case .ready(let diff) = coordinator.phase, diff.factsMatch else {
                Issue.record("expected a no-change answer: \(coordinator.phase)"); return
            }
            coordinator.cancel()
        default:
            coordinator = rig.coordinator()
            coordinator.launch()
            try rig.answer(coordinator, with: AF.onePerson())
            #expect(await AF.waitUntil { isReady(coordinator) })
            guard case .ready(let diff) = coordinator.phase else { return }
            if kind == "cancel-review" {
                coordinator.cancel()
            } else {
                await coordinator.apply(selectedFieldKeys: kind == "nothing-ticked" ? [] : Set(diff.changes.map(\.field.key)))
            }
        }
        for (name, lines) in [("videoscan.log", Array(rig.captured.videoscan.all.dropFirst(skip))),
                              ("console", Array(rig.captured.console.all.dropFirst(skip)))] {
            let counts = startsAndOutcomes(lines)
            #expect(counts.started == 1, "\(kind) \(name): \(lines)")
            #expect(counts.outcomes == 1, "\(kind) \(name): \(lines)")
            #expect(lines.allSatisfy { $0.contains("Walter James Dunn (WWWW-111)") }, "\(kind) \(name): \(lines)")
        }
        #expect(rig.captured.consoleMatchesVideoscan)
    }

    /// The production path end to end: the center builds the sink from
    /// `appLog` and the console the app attached, and both get the lines.
    @Test func theCenterFansOutToAppLogAndTheAttachedConsole() throws {
        let layout = try AF.layout(tag: "audit-center")
        defer { layout.remove() }
        let model = FamilyTreeLiveModel(originalsDirectory: layout.gedcom)
        model.personRefreshOverlayStore = layout.overlayStore
        model.loadNow()
        let target = model.personRefreshTarget(for: "@I1@")!
        let console = AF.Lines()
        let center = PersonRefreshCenter(
            root: layout.refreshRoot, overlayStore: layout.overlayStore,
            makeCoordinator: { target, facts, sink in
                PersonRefreshCoordinator(
                    target: target, root: layout.refreshRoot, overlayStore: layout.overlayStore, installedFacts: facts,
                    locator: FamilySearchToolLocator(overridePath: layout.tool.path, candidatePaths: []),
                    launcher: AF.SilentLauncher(), sink: sink)
            })
        center.console = { console.append($0) }
        let appLogLines = InMemoryLogSink()
        try withAppLog(appLogLines) {
            center.begin(target: target, installedFacts: { model.personFacts(familySearchID: "WWWW-111") })
            center.cancel()
        }
        #expect(console.all.count == 2)
        #expect(console.all.first?.hasPrefix(walter + "started") == true)
        #expect(console.all.last == walter + "cancelled while waiting for Terminal; nothing was changed")
        #expect(appLogLines.lines == console.all.map { "[fs-refresh] " + $0 })
    }
}
