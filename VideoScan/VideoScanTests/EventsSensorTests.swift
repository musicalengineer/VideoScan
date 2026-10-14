// EventsSensorTests.swift
// Events v1 — SENSORS (feature-test checklist item 5; plan §7) pinning
// the page's shape at the source level: the pane's bodies read only the
// store (no O(records) work in a view); TriageView wires the row and the
// pane without observing the store; the sidebar's count is the plan's
// numbers; the words are pinned; the metrics object has exactly the
// publisher's keys. Fails closed: an empty source read is a failure.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Events — sensors", .serialized)
@MainActor
struct EventsSensorTests {

    private typealias F = EventsFixture

    @Test("SENSOR: the page and the sheet read only the store — never the catalog, never the planner")
    func paneBodyReadsOnlyTheStore() throws {
        let pane = try SourceTree.appCode(named: "EventsPane.swift")
        let sheet = try SourceTree.appCode(named: "EventDetailSheet.swift")
        #expect(pane.count > 5_000 && sheet.count > 3_000, "the scan is reading nothing")
        for (name, code) in [("EventsPane", pane), ("EventDetailSheet", sheet)] {
            for token in ["model.records", ".records.", "records.filter", "records.map", "EventsPlanner.", "eventsInputs()",
                          "for r in records", "first(where:"] {
                #expect(!code.contains(token), "\(name) contains `\(token)` — the page reads EventsStore only")
            }
        }
        // The pane's views observe the store; the plan is built by the model, off-main, from a handler.
        #expect(pane.contains("@ObservedObject var store: EventsStore"))
        #expect(pane.contains("await model.buildEventsPlan(decisions: self.decisions.snapshot())"))
        #expect(pane.contains(".onAppear { if store.plan == nil { store.refresh(model: model) } }"))
        #expect(pane.contains("LazyVStack(alignment: .leading, spacing: 8)"))
        // The sheet looks its subject up by key (O(1)) and opens through the catalog's opener.
        #expect(sheet.contains("store.suggestionByKey[key]") && sheet.contains("store.confirmedByID[id]"))
        #expect(sheet.contains("CatalogOpenAction.open(ids: [rec.id], rows: [rec], gesture: \"Events\", model: model)"))
        #expect(sheet.contains("disk.lookup(path: path, mtime: sig.mtime, size: sig.size)"), "thumbnails from the preview cache only")
        #expect(!sheet.contains("AVAsset") && !sheet.contains("renderThumbnail"), "the sheet never decodes video")
        // TriageView: a plain reference to the store, the row under Cleanup, the pane beside Cleanup's.
        let triage = try SourceTree.appCode(named: "TriageView.swift")
        #expect(triage.contains("private let eventsStore = EventsStore.shared"))
        #expect(triage.contains("@State private var showingEvents = false"))
        #expect(triage.contains("EventsSidebarRow(isSelected: showingEvents) {"))
        #expect(triage.contains("} else if showingEvents {") && triage.contains("EventsPane(model: model, store: eventsStore)"))
        #expect(!triage.contains("@ObservedObject private var eventsStore") && !triage.contains("@ObservedObject var eventsStore"),
                "TriageView must not observe the Events store (its body would redraw for every plan)")
        #expect(triage.components(separatedBy: "showingEvents = false").count - 1 == 4,
                "the declaration, then Cleanup, Clean Up and every filter row leave the page")
    }

    @Test("the sidebar count is the plan's numbers: suggestions + questions to review")
    func sidebarCountMatchesPlanNumbers() async throws {
        #expect(EventsWords.sidebarCount(nil) == "", "nothing until the first plan lands")
        var n = EventsStore.Numbers()
        n.toReview = 1_234
        #expect(EventsWords.sidebarCount(n) == "1,234 to review")

        let store = EventsStore(decisions: EventsDecisionStore(directory: try F.scratchDirectory("sidebar")))
        let model = VideoScanModel()
        model.records = [
            F.record("/Volumes/Tapes/Xmas/a.mov", caption: "Ornaments on a Christmas tree.", userDate: F.iso(1996, 12, 25)),
            F.record("/Volumes/Tapes/Xmas/b.mov", caption: "Santa by the Christmas tree.", userDate: F.iso(1999, 12, 25)),
            F.record("/Volumes/Tapes/June98/cake.mov", caption: "A cake with lit candles.", userDate: F.iso(1998, 6, 5)),
        ]
        await store.refresh(model: model)?.value
        let plan = try #require(store.plan)
        #expect(plan.suggestions.count == 3 && plan.questions.count == 1)
        #expect(store.numbers.toReview == plan.suggestions.count + plan.questions.count)
        #expect(store.numbers.toReview == plan.toReview)
        #expect(EventsWords.sidebarCount(store.numbers) == "4 to review")
        #expect(store.numbers.byCategory == ["Christmas": 2, "Birthday": 1])
        #expect(store.numbers.confirmed == 0 && store.numbers.questions == 1)
        // A decision moves the numbers without a rebuild: confirm one.
        let before = store.builtAt
        store.confirm(plan.suggestions[0])
        #expect(store.numbers.toReview == 3 - 1 + (store.plan?.questions.count ?? 0))
        #expect(store.numbers.confirmed == 1)
        #expect(store.builtAt == before, "a decision never rebuilds")
        #expect(FileManager.default.fileExists(atPath: store.decisions.statsURL.path), "the counts-only object was written")
    }

    @Test("the page's words are pinned")
    func wordsArePinned() {
        #expect(EventsWords.title == "Events")
        #expect(EventsWords.question == "Which recordings belong to the same family memory?")
        #expect(EventsWords.sameOccasion == "Same occasion, or different years?")
        #expect(EventsWords.sameOccasionYes == "Same occasion" && EventsWords.sameOccasionNo == "Different occasions")
        #expect(EventsWords.confirm == "Confirm" && EventsWords.dismiss == "Dismiss" && EventsWords.details == "Details…")
        #expect(EventsWords.nothingToReview == "Nothing to review — every suggestion has your answer.")
        #expect(EventsWords.coveredNote == "Grouping never marks a recording covered or safe to remove.")
        #expect(EventsWords.readOnly("x") == "Your decisions can't be saved right now — x. You can still look.")
        #expect(EventsWords.recordings(1) == "1 recording" && EventsWords.recordings(2_000) == "2,000 recordings")
        #expect(EventsWords.summary(strength: .seenAndSaid, members: 3) == "seen and said · 3 recordings")
        #expect(EventsWords.summary(strength: nil, members: 1) == "no words of its own · 1 recording")
        #expect(EventsWords.copies(1) == nil && EventsWords.copies(3) == "3 copies")
        #expect(EventsWords.leftOut(12) == "Left out: 12 recordings")
        #expect(EventsNaming.suggestionName(category: "Birthday", dateWords: "date unknown") == "Birthday · date unknown")
        #expect(EventsNaming.untimedTranscriptNote.hasPrefix("A long tape: its transcript isn't timed"))
        #expect(EventsDate.none.words == "no date")
        #expect(EventsDate(year: 1998, month: 6, day: 5, source: .you, trusted: true).words == "Jun 5, 1998 (your date)")
        #expect(EventsDate(year: 1998, month: 6, day: nil, source: .camera, trusted: true).words == "Jun 1998 (camera)")
        #expect(EventsDate(year: 1998, month: nil, day: nil, source: .folderYear, trusted: false).words == "1998 (folder name (year only))")
        #expect(EventEvidenceStrength.allCases.map(\.words) == ["date only", "name only", "said", "seen", "seen and said"])
        #expect(EventsExclusion.noEvidence.words == "no event words in its captions, transcript, names or dates")
    }

    @Test("the metrics object has exactly the publisher's EVENTS_KEYS, and the publisher's list is what it was")
    func statsObjectHasExactlyTheMetricsKeys() throws {
        let plan = F.plan([F.row("/Volumes/Tapes/June98/cake.mov", key: "sha-cake", caption: "A cake with lit candles.",
                                 userDate: F.iso(1998, 6, 5))])
        let stats = EventsStats(plan: plan, decisions: .empty, now: F.day(2026, 10, 14))
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let object = try #require(try JSONSerialization.jsonObject(with: enc.encode(stats)) as? [String: Any])
        #expect(Set(object.keys) == Set(EventsStats.keys))
        #expect(object["ts"] as? String == "2026-10-14T12:00:00Z")
        #expect(object["active_records"] as? Int == 1 && object["clips_with_evidence"] as? Int == 1)
        #expect(object["candidate_events"] as? Int == 1 && object["strong_events"] as? Int == 0)
        #expect((object["by_category"] as? [String: Int])?.count == 9)
        #expect(object["marks_yes"] is NSNull && object["marks_no"] is NSNull && object["precision_by_category"] is NSNull,
                "null until Rick has decided something — the prototype's contract")

        // The publisher's allowlist, read from tools/publish_metrics.py itself.
        let repo = SourceTree.appSourceRoot.deletingLastPathComponent().deletingLastPathComponent()
        let publisher = try String(contentsOf: repo.appendingPathComponent("tools/publish_metrics.py"), encoding: .utf8)
        let start = try #require(publisher.range(of: "EVENTS_KEYS = ("))
        let end = try #require(publisher.range(of: ")", range: start.upperBound..<publisher.endIndex))
        let keys = publisher[start.upperBound..<end.lowerBound].split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
        #expect(keys == EventsStats.keys, "tools/publish_metrics.py EVENTS_KEYS moved: \(keys)")

        // With a decision, the marks are counts only — no name, path or words anywhere in the object.
        let e = EventRecord(name: "Matt's 8th", categories: ["Birthday"])
        let d = EventsDecisionSnapshot(events: [e], decisions: [.member(eventID: e.id, range: ContentRange(contentKey: "sha-cake"), verdict: .accepted),
                                                                .categoryRejected(range: ContentRange(contentKey: "sha-x"), category: "Christmas")])
        let decided = try #require(try JSONSerialization.jsonObject(with: enc.encode(EventsStats(plan: plan, decisions: d, now: Date()))) as? [String: Any])
        #expect(decided["marks_yes"] as? Int == 1 && decided["marks_no"] as? Int == 1)
        #expect((decided["precision_by_category"] as? [String: [String: Int]])?["Birthday"] == ["yes": 1, "no": 0])
        let text = String(decoding: try enc.encode(EventsStats(plan: plan, decisions: d, now: Date())), as: UTF8.self)
        #expect(!text.contains("Matt") && !text.contains("cake") && !text.contains("/Volumes"), "counts only")
    }
}
