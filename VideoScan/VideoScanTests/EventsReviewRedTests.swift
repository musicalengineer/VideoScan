// EventsReviewRedTests.swift
// QA review of feat/events-v1 (2026-10-14): RED tests, one per reproducible
// finding. Each names the file:line it pins. Expected to FAIL on the
// branch as reviewed; the fix agent lands them red → green.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Events — QA red tests", .serialized)
struct EventsReviewRedTests {

    private typealias F = EventsFixture

    /// Pins EventsPlan.swift:391 — `reapplying` compares the dismissal's
    /// facts against the UNFILTERED suggestion, but the page records the
    /// facts of the SHOWN (filtered) one. Reject one member, then Dismiss:
    /// the dismissal never matches and the card never leaves the queue.
    @Test("Dismiss after 'Not this one' still dismisses the suggestion")
    func dismissAfterRejectStillDismisses() throws {
        let rows = ["cake", "song", "hats"].map {
            F.row("/Volumes/Tapes/June98/\($0).mov", key: "sha-\($0)", caption: "A birthday cake with lit candles.",
                  userDate: F.iso(1998, 6, 5))
        }
        let plan = F.plan(rows)
        let s = try #require(plan.suggestions.first)
        #expect(s.members.count == 3)
        // Rick: "Not this one" on the first member (EventsStore.reject → categoryRejected).
        let rejected = EventsDecisionSnapshot(events: [], decisions: [
            .categoryRejected(range: s.members[0].range, category: "Birthday"),
        ])
        let shown = try #require(plan.reapplying(rejected).suggestions.first)
        #expect(shown.members.count == 2, "the card now shows two")
        // Rick: "Dismiss" on the card he sees (EventsStore.dismiss → s.facts of the SHOWN card).
        let dismissed = EventsDecisionSnapshot(events: [], decisions: [
            .categoryRejected(range: s.members[0].range, category: "Birthday"),
            .suggestionDismissed(key: shown.key, facts: shown.facts),
        ])
        let after = plan.reapplying(dismissed)
        #expect(after.suggestions.isEmpty, "dismissed, yet still in the queue: \(after.suggestions.map(\.name))")
        #expect(after.leftOut[.dismissed] ?? 0 > 0)
    }

    /// Pins EventsDecisionStore.swift:355-391 and :465 — no write path
    /// checks `hasLoaded`. A decision recorded before `load()` schedules a
    /// save that publishes the in-memory (empty) store over Rick's file;
    /// a second save then rolls `.prev` too. Nothing in the store refuses it.
    @Test("a write before load() never publishes over the file on disk")
    @MainActor
    func writeBeforeLoadDoesNotClobberTheFile() async throws {
        let store = EventsDecisionStore(directory: try F.scratchDirectory("preload"))
        let json = """
        {"storeVersion": 1, "savedAt": "2026-10-14T12:00:00Z", "events": [],
         "decisions": [{"kind": "differentOccasions", "a": {"contentKey": "sha-a"}, "b": {"contentKey": "sha-b"}}]}
        """
        try json.write(to: store.fileURL, atomically: true, encoding: .utf8)
        // No load(). Two decisions, two saves.
        store.record(.categoryRejected(range: ContentRange(contentKey: "sha-c"), category: "Birthday"))
        _ = await store.save()
        store.record(.categoryRejected(range: ContentRange(contentKey: "sha-d"), category: "Birthday"))
        _ = await store.save()
        let again = EventsDecisionStore(directory: store.directory)
        _ = await again.load()
        let kept = again.decisions.contains(.differentOccasions(a: ContentRange(contentKey: "sha-a"), b: ContentRange(contentKey: "sha-b")))
        #expect(kept, "Rick's decision from before the first write is gone from the file (and from .prev after the second save)")
    }

    /// Pins EventsDecisionStore.swift:426-428 and :513-527 — `changed()`
    /// discards the save task's Bool and the writer swallows the error, so
    /// a failed save (disk full, permissions, a stalled volume) leaves the
    /// decision in memory only and tells nobody. The page shows nothing.
    @Test("a failed save is surfaced on the page, not swallowed")
    @MainActor
    func failedSaveIsSurfaced() async throws {
        let dir = try F.scratchDirectory("nowrite")
        let store = EventsDecisionStore(directory: dir)
        _ = await store.load()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        store.record(.categoryRejected(range: ContentRange(contentKey: "sha-c"), category: "Birthday"))
        #expect(await store.save() == false, "the write really failed")
        let page = EventsStore(decisions: store)
        let model = VideoScanModel()
        model.records = [F.record("/Volumes/Tapes/Xmas/a.mov", caption: "A Christmas tree.")]
        await page.refresh(model: model)?.value
        #expect(page.plan?.readOnlyReason != nil, "a save that failed must show on the page; today the decision silently lives in memory only")
    }

    /// Pins EventsPlan.swift:738 — `EventsLink.init` copies
    /// `run.members.map(\.contentKey)` for EVERY candidate check, so one
    /// big folder whose name is an event word (every file "name only",
    /// undated, all joining one run) costs O(n²) string retains. An Avid
    /// MediaFiles folder or a "Christmas" dump of 30k clips is realistic.
    @Test("one folder of 30k name-only witnesses plans in linear-ish time", .timeLimit(.minutes(3)))
    func oneFolderOfNameOnlyWitnessesIsNotQuadratic() {
        let rows = (0..<30_000).map { F.row("/Volumes/Tapes/Christmas/clip\($0).mov") }
        let clock = ContinuousClock()
        var plan = EventsPlan.empty
        let elapsed = clock.measure { plan = F.plan(rows) }
        print("EVENTS_ONE_FOLDER_30K_MS=\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000) \(PerformanceLane.configurationName)")
        #expect(plan.suggestions.count == 1 && plan.suggestions[0].members.count == 30_000)
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(2)), "one folder took \(elapsed); 100k rows in EventsPlanScaleTests spread over 6,000 folders never hits this path")
    }

    /// Pins EventsPane.swift:457-458 vs EventsStore.confirm/dismiss guards —
    /// in read-only the card's Confirm/Dismiss stay enabled and the store
    /// refuses silently; only the sheet's buttons are disabled (:85, :113).
    /// Source-level: the card row must carry the same disabled state.
    @Test("the card's Confirm / Dismiss are disabled when the store is read-only")
    func cardButtonsDisabledWhenReadOnly() throws {
        let pane = try SourceTree.appCode(named: "EventsPane.swift")
        let card = try #require(pane.range(of: "struct EventCardRow: View {"))
        let body = String(pane[card.lowerBound...].prefix(1_600))
        #expect(body.contains(".disabled("), "EventCardRow has no read-only gate; a click on Confirm does nothing and says nothing")
    }
}
