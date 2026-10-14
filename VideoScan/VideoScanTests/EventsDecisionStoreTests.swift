// EventsDecisionStoreTests.swift
// Events v1 — LOGIC for Rick's decisions (plan §3, §7): keyed by content,
// they survive a regrouped suggestion, a rerun and a rescan that moved a
// drive; rejecting a category is not rejecting a membership; a dismissed
// suggestion returns only when its facts move; a NEWER store version is
// read-only and never empty; a decision kind this build cannot read is
// written back unchanged. Every store here lives in a per-test temp
// folder. Media matrix: not applicable.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Events — decisions", .serialized)
@MainActor
struct EventsDecisionStoreTests {

    private typealias F = EventsFixture

    private func store(_ tag: String) throws -> EventsDecisionStore {
        EventsDecisionStore(directory: try F.scratchDirectory(tag))
    }

    /// Two captioned birthday clips, one folder, one day: one suggestion.
    private var party: [EventsRow] {
        [F.row("/Volumes/Tapes/June98/cake.mov", key: "sha-cake", caption: "A cake with lit candles.", userDate: F.iso(1998, 6, 5)),
         F.row("/Volumes/Tapes/June98/song.mov", key: "sha-song", transcript: "happy birthday dear Matt", userDate: F.iso(1998, 6, 5))]
    }

    @Test("a confirmed event survives the suggestion being regrouped under another key")
    func confirmSurvivesRegroupedSuggestionIDs() throws {
        let store = try store("regroup")
        let first = F.plan(party)
        let s = try #require(first.suggestions.first)
        #expect(s.key == "Birthday|sha-cake")
        let event = try #require(store.confirm(name: "Matt's 8th", categories: s.categories, members: s.members.map(\.range)))
        // A new clip with a smaller content key joins the run: the key moves.
        let rows = party + [F.row("/Volumes/Tapes/June98/arrive.mov", key: "sha-arrive", caption: "Party hats on the table.",
                                  userDate: F.iso(1998, 6, 5))]
        let second = F.plan(rows, decisions: store.snapshot())
        #expect(second.confirmed.map(\.id) == [event.id])
        #expect(second.confirmed[0].name == "Matt's 8th")
        #expect(Set(second.confirmed[0].members.map(\.filename)) == ["cake.mov", "song.mov"])
        #expect(second.confirmed[0].members.allSatisfy { $0.state == .accepted })
        // The settled members leave the queue; the newcomer is what is left to review.
        #expect(second.suggestions.flatMap(\.members).map(\.filename) == ["arrive.mov"])
        #expect(second.suggestions[0].key == "Birthday|sha-arrive")
        #expect(second.leftOut[.settled] == 2)
    }

    @Test("'different occasions' survives a rerun that would otherwise merge the two")
    func differentOccasionsSurvivesRerun() throws {
        let store = try store("different")
        #expect(F.plan(party).suggestions.count == 1, "they merge on their own")
        store.record(.differentOccasions(a: ContentRange(contentKey: "sha-cake"), b: ContentRange(contentKey: "sha-song")))
        let plan = F.plan(party, decisions: store.snapshot())
        #expect(plan.suggestions.count == 2, "\(plan.suggestions.map(\.name))")
        #expect(plan.questions.isEmpty, "the question is answered")
    }

    @Test("rejecting a category for a recording is not rejecting its membership of a confirmed event")
    func rejectCategoryIsNotRejectMembership() throws {
        let store = try store("category")
        let s = try #require(F.plan(party).suggestions.first)
        let event = try #require(store.confirm(name: s.name, categories: s.categories, members: s.members.map(\.range)))
        store.record(.categoryRejected(range: ContentRange(contentKey: "sha-song"), category: "Birthday"))
        let d = store.snapshot()
        #expect(d.members(of: event.id).map(\.contentKey).sorted() == ["sha-cake", "sha-song"], "still a member")
        #expect(d.categoryRejected.contains(EventsCategoryKey("sha-song", "Birthday")))
        // The other way round: a rejected membership says nothing about the category.
        store.setMember(event: event.id, range: ContentRange(contentKey: "sha-cake"), verdict: .rejected)
        let d2 = store.snapshot()
        #expect(d2.members(of: event.id).map(\.contentKey) == ["sha-song"])
        #expect(!d2.categoryRejected.contains(EventsCategoryKey("sha-cake", "Birthday")))
        #expect(F.plan(party, decisions: d2).confirmed[0].members.map(\.filename) == ["song.mov"])
    }

    @Test("a dismissed suggestion stays away on the same facts and returns when a member or evidence line changes")
    func dismissedComesBackOnlyWhenFactsChange() throws {
        let store = try store("dismiss")
        let s = try #require(F.plan(party).suggestions.first)
        store.record(.suggestionDismissed(key: s.key, facts: s.facts))
        let same = F.plan(party, decisions: store.snapshot())
        #expect(same.suggestions.isEmpty && same.leftOut[.dismissed] == 2)
        // A third recording joins: the facts moved, the suggestion is back.
        let more = party + [F.row("/Volumes/Tapes/June98/gifts.mov", key: "sha-z", caption: "Wrapping paper and party hats.",
                                  userDate: F.iso(1998, 6, 5))]
        let changed = F.plan(more, decisions: store.snapshot())
        #expect(changed.suggestions.count == 1 && changed.suggestions[0].members.count == 3)
        #expect(changed.suggestions[0].key == s.key, "same key, new facts")
    }

    @Test("decisions keyed by content survive a rescan that moved the drive")
    func decisionsKeyedByContentSurviveRescanPathChange() throws {
        let store = try store("rescan")
        let s = try #require(F.plan(party).suggestions.first)
        let event = try #require(store.confirm(name: "Matt's 8th", categories: s.categories, members: s.members.map(\.range)))
        let moved = [F.row("/Volumes/NewDrive/1998/June/cake.mov", key: "sha-cake", caption: "A cake with lit candles.", userDate: F.iso(1998, 6, 5)),
                     F.row("/Volumes/NewDrive/1998/June/song.mov", key: "sha-song", transcript: "happy birthday dear Matt", userDate: F.iso(1998, 6, 5))]
        let plan = F.plan(moved, decisions: store.snapshot())
        #expect(plan.confirmed.map(\.id) == [event.id])
        #expect(Set(plan.confirmed[0].members.map(\.path)) == ["/Volumes/NewDrive/1998/June/cake.mov", "/Volumes/NewDrive/1998/June/song.mov"])
        #expect(plan.suggestions.isEmpty)
        // A member whose content is not in the catalog now keeps its place, as a placeholder.
        let gone = F.plan([moved[0]], decisions: store.snapshot())
        #expect(gone.confirmed[0].members.map(\.filename).sorted() == ["(not in the catalog now)", "cake.mov"])
    }

    @Test("a file from a newer VideoScan loads what it holds and refuses every write — never treated as empty")
    func newerStoreVersionIsReadOnlyNotEmpty() async throws {
        let store = try store("newer")
        let eventID = UUID()
        let json = """
        {"storeVersion": 2, "savedAt": "2026-10-14T12:00:00Z",
         "events": [{"id": "\(eventID.uuidString)", "name": "Ma's 60th", "categories": ["Birthday"], "state": "confirmed",
                     "createdAt": "2026-10-14T12:00:00Z", "updatedAt": "2026-10-14T12:00:00Z", "range": {"start": 1, "end": 2}}],
         "decisions": [{"kind": "member", "eventID": "\(eventID.uuidString)", "range": {"contentKey": "sha-1"}, "verdict": "accepted"},
                       {"kind": "rangeAdjusted", "range": {"contentKey": "sha-1", "start": 10, "end": 20}}]}
        """
        try json.write(to: store.fileURL, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: store.fileURL)
        let outcome = await store.load()
        guard case .readOnly(let why) = outcome else { Issue.record("expected read-only, got \(outcome)"); return }
        #expect(why.contains("newer VideoScan") && why.contains("store version 2"))
        #expect(store.isReadOnly && store.eventCount == 1 && store.decisionCount == 2, "what it holds is read")
        #expect(store.snapshot().members(of: eventID).map(\.contentKey) == ["sha-1"])
        #expect(store.confirm(name: "x", categories: ["Birthday"], members: []) == nil)
        #expect(!store.record(.differentOccasions(a: ContentRange(contentKey: "a"), b: ContentRange(contentKey: "b"))))
        #expect(!store.rename(eventID, to: "y") && !store.setState(eventID, .dismissed))
        #expect(await store.save() == false)
        #expect(try Data(contentsOf: store.fileURL) == before, "the bytes are untouched")
        #expect(!FileManager.default.fileExists(atPath: store.previousURL.path), "no .prev either — nothing was written")
    }

    @Test("a decision kind this build cannot read is kept verbatim across a save; the previous file is kept as .prev")
    func unknownDecisionKindIsPreservedOnSave() async throws {
        let store = try store("unknown")
        let json = """
        {"storeVersion": 1, "savedAt": "2026-10-14T12:00:00Z", "events": [],
         "decisions": [{"kind": "rangeAdjusted", "range": {"contentKey": "sha-1", "start": 10.5, "end": 20}, "by": "rick"}]}
        """
        try json.write(to: store.fileURL, atomically: true, encoding: .utf8)
        let original = try Data(contentsOf: store.fileURL)
        #expect(await store.load() == .loaded)
        #expect(!store.isReadOnly && store.decisionCount == 1)
        guard case .unknown(let kind, let payload) = store.decisions[0] else { Issue.record("not preserved"); return }
        #expect(kind == "rangeAdjusted" && payload["by"] == .string("rick"))
        store.record(.differentOccasions(a: ContentRange(contentKey: "a"), b: ContentRange(contentKey: "b")))
        #expect(await store.save())
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        let decisions = try #require(saved?["decisions"] as? [[String: Any]])
        #expect(decisions.count == 2)
        #expect(decisions[0]["kind"] as? String == "rangeAdjusted" && decisions[0]["by"] as? String == "rick")
        #expect((decisions[0]["range"] as? [String: Any])?["start"] as? Double == 10.5)
        #expect(decisions[1]["kind"] as? String == "differentOccasions")
        #expect(saved?["storeVersion"] as? Int == 1)
        #expect(try Data(contentsOf: store.previousURL) == original, ".prev holds the file as it was")
        // Reload round-trips both.
        let again = EventsDecisionStore(directory: store.directory)
        #expect(await again.load() == .loaded && again.decisionCount == 2)
        #expect(again.decisions[0] == store.decisions[0])
    }
}
