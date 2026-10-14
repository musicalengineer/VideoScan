// EventsIsolationTests.swift
// Events v1 — ISOLATION (feature-test checklist item 4; plan §7): the
// store reads and writes a file in App Support and the planner reads the
// People tab's birthdays, so each gets a poisoned-state test — under the
// test host the DEFAULT store directory is a per-process temp folder and
// the real ~/Library/Application Support/VideoScan tree is never touched;
// a damaged decisions file loads what it can and refuses to be written
// over; no People profiles means no birthdays, not a crash.
// Media matrix: not applicable — no media opened.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Events — isolation", .serialized)
@MainActor
struct EventsIsolationTests {

    private typealias F = EventsFixture

    @Test("the default store under the test host is a temp folder; a confirm + save never touches real Application Support")
    func storeUnderTestHostNeverTouchesRealAppSupport() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        let dir = EventsDecisionStore.defaultDirectory.resolvingSymlinksInPath().path
        #expect(dir.hasPrefix(tempRoot), "default directory escaped temp: \(dir)")
        #expect(!dir.contains("/Library/Application Support/"))
        #expect(EventsStore.shared.decisions.directory.resolvingSymlinksInPath().path.hasPrefix(tempRoot),
                "the shared store (what the page uses) is the temp one too")

        let before = AppSupportSnapshot.take()
        let store = EventsDecisionStore()        // the DEFAULT directory
        _ = await store.load()
        store.confirm(name: "Isolation", categories: ["Birthday"], members: [ContentRange(contentKey: "sha-iso")])
        #expect(await store.save())
        let stats = EventsStats(plan: .empty, decisions: store.snapshot(), now: Date())
        #expect(await EventsStats.write(stats, to: store.statsURL))
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(store.fileURL.resolvingSymlinksInPath().path.hasPrefix(tempRoot))
        #expect(AppSupportSnapshot.take() == before, "Events wrote into the REAL ~/Library/Application Support/VideoScan")
    }

    @Test("a poisoned decisions file loads what it can, is read-only, and is never written over")
    func poisonedDecisionsFileLoadsWhatItCanAndRefusesToOverwrite() async throws {
        let dir = try F.scratchDirectory("poison")
        let good = UUID()
        // One readable event, one event missing its name, one readable
        // decision, one decision that is not even an object.
        let json = """
        {"storeVersion": 1, "savedAt": "2026-10-14T12:00:00Z",
         "events": [{"id": "\(good.uuidString)", "name": "Good", "categories": ["Christmas"], "state": "confirmed",
                     "createdAt": "2026-10-14T12:00:00Z", "updatedAt": "2026-10-14T12:00:00Z"},
                    {"id": "\(UUID().uuidString)", "categories": ["Birthday"], "state": "confirmed"}],
         "decisions": [{"kind": "member", "eventID": "\(good.uuidString)", "range": {"contentKey": "sha-g"}, "verdict": "accepted"},
                       "garbage"]}
        """
        let store = EventsDecisionStore(directory: dir)
        try json.write(to: store.fileURL, atomically: true, encoding: .utf8)
        let bytes = try Data(contentsOf: store.fileURL)
        let outcome = await store.load()
        guard case .readOnly(let why) = outcome else { Issue.record("expected read-only, got \(outcome)"); return }
        #expect(why.contains("2 entries could not be read"), "\(why)")
        #expect(store.eventCount == 1 && store.decisionCount == 1, "what could be read, was")
        #expect(store.snapshot().members(of: good).map(\.contentKey) == ["sha-g"])
        // Every write path is refused, and the bytes stay exactly as they were.
        #expect(store.confirm(name: "x", categories: [], members: []) == nil)
        #expect(!store.record(.merged(from: good, into: good)))
        #expect(!store.setMember(event: good, range: ContentRange(contentKey: "z"), verdict: .rejected))
        #expect(store.split(good, ranges: [ContentRange(contentKey: "sha-g")], name: "y") == nil)
        #expect(await store.save() == false)
        #expect(try Data(contentsOf: store.fileURL) == bytes)
        #expect(!FileManager.default.fileExists(atPath: store.previousURL.path))

        // Not JSON at all: nothing to read, still read-only, still untouched.
        let broken = EventsDecisionStore(directory: try F.scratchDirectory("broken"))
        try "{ not json".write(to: broken.fileURL, atomically: true, encoding: .utf8)
        guard case .readOnly(let why2) = await broken.load() else { Issue.record("expected read-only"); return }
        #expect(why2.contains("not readable as JSON"))
        #expect(broken.eventCount == 0 && broken.isReadOnly)
        #expect(await broken.save() == false)
        #expect(try String(contentsOf: broken.fileURL, encoding: .utf8) == "{ not json")

        // The page says so, in the plan it shows.
        let page = EventsStore(decisions: store)
        let model = VideoScanModel()
        model.records = [F.record("/Volumes/Tapes/Xmas/a.mov", caption: "A Christmas tree.")]
        await page.refresh(model: model)?.value
        #expect(page.plan?.readOnlyReason == why)
        #expect(page.plan?.suggestions.count == 1, "read-only is not empty: the queue still shows")
    }

    @Test("no People profiles (the test host's environment) means no birthdays — the plan builds, with no birthday date lines")
    func missingPeopleProfilesMeansNoBirthdaysNotACrash() async throws {
        #expect(AngelEnvironment.familyBirthdaysReader(isTestHost: true)().isEmpty, "a test host never reads the real POI store")
        let rows = [F.row("/Volumes/Tapes/1998/clip.mov", key: "sha-1", userDate: F.iso(1998, 6, 5))]
        let none = F.plan(rows, birthdays: [])
        #expect(none.suggestions.isEmpty && none.leftOut[.noEvidence] == 1, "a bare Jun 5 says nothing without the family's birthdays")
        let some = F.plan(rows, birthdays: F.birthdays)
        #expect(some.suggestions.count == 1)
        #expect(some.suggestions[0].members[0].strength == .dateOnly)
        #expect(some.suggestions[0].members[0].evidence.map(\.words) == ["on Matt's 8th birthday"])
        // The model's build with the production default reader, under the test host: completes, no birthdays.
        let model = VideoScanModel()
        model.records = [F.record("/Volumes/Tapes/1998/clip.mov", userDate: F.iso(1998, 6, 5))]
        let plan = await model.buildEventsPlan(decisions: .empty)
        #expect(plan.rowCount == 1 && plan.suggestions.isEmpty)
    }
}
