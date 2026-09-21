// HalliePresenceRenamedProfileTagsTests.swift
//
// THE LIVE FAILURE, 2026-09-21 13:54 (Rick, app) and nine replay misses
// since 2026-09-18 (cs029, tm002, ft013, lv260901-001, lv260906-002,
// lv260902-023, ft005, cc015, cs023):
//
//   Rick:   find videos of tim
//   Hallie: "I took “tim” to mean Timothy. I don't have any videos tagged
//            with Timothy yet."
//   Rick:   videos of my dad
//   Hallie: "I don't have any videos tagged with Richard Harding Breen Sr
//            yet."
//
// On 2026-09-19/20 Rick renamed his People profiles to legal given names
// with surnames: "Tim" became "Timothy" (Christopher Breen, alias Tim),
// "Timmy" became "Timothy" (William Breen, alias Timmy), "Dad" became
// "Richard" (Harding Breen Sr, aliases Dad Breen / Grampa Breen / Dick).
// Catalog person tags are plain strings captured when the video was tagged
// — "Tim", "Timmy", "Dad" (live catalog.json: Dad 10, Tim 6, Timmy 2) — and
// the presence lane matched them against the RESOLVED profile's name:
//
//   1. recoverPresencePeople rewrote the typed "tim" to the canonical
//      "Timothy", which two profiles now share, so presenceAliases (keyed
//      by the rewritten string) found two profiles, gave up, and the
//      catalog was searched for the one spelling "Timothy".
//   2. "my dad" bound the unambiguous FULL name ("Richard Harding Breen
//      Sr"), which presenceAliases matched against canonical names and
//      aliases only — never the full-name forms — so again one spelling.
//
// Fix (additive, no schema change): a person resolves to the SET of every
// string they have been known by — canonical name, aliases, full-name
// forms, the bare kin word of a "Dad Breen"-shaped alias, the pinned tree
// name — and a tag proves the person under any of them. The typed spelling
// is kept as the search identity when the canonical is shared. Tags keyed
// by POI UUID are the proper long-term fix and a separate job.
//
// Five dimensions: 1 logic (three live questions), 2 scale n/a (profiles),
// 3 media n/a, 4 isolation (in-memory records and profiles), 5 sensor —
// the two Timothys never collapse into one, and a tag that belongs to the
// OTHER Timothy is never cited for this one.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Hallie — renamed People profiles still find their tagged videos", .serialized)
struct HalliePresenceRenamedProfileTagsTests {
    typealias Exec = HallieTurnExecutor

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc) ?? .distantPast
    }

    private static let dadUUID = UUID(uuidString: "FF6C5474-EBB4-4D32-A9EF-B2D38647A146")!
    private static let rickUUID = UUID(uuidString: "71393E0E-0000-4000-8000-000000000001")!
    private static let timUUID = UUID(uuidString: "3DFF616F-0000-4000-8000-000000000003")!
    private static let timmyUUID = UUID(uuidString: "945BAEDD-0000-4000-8000-000000000004")!

    /// The People tab after Rick's 2026-09-19/20 renames.
    private static let profiles: [Exec.ProfileSnapshot] = [
        .init(stableID: "tim", canonicalName: "Timothy", aliases: ["Tim"],
              birthdate: date(1960, 6, 21), sex: .male, uuid: timUUID,
              surname: "Breen", middleName: "Christopher"),
        .init(stableID: "timmy", canonicalName: "Timothy", aliases: ["Timmy"],
              birthdate: date(1996, 4, 22), sex: .male, uuid: timmyUUID,
              surname: "Breen", middleName: "William"),
        .init(stableID: "dad", canonicalName: "Richard",
              aliases: ["Dad Breen", "Grampa Breen", "Dick"],
              birthdate: date(1929, 2, 21),
              kinships: [Kinship(relation: .parent, relativeTo: .profile(id: rickUUID))],
              sex: .male, uuid: dadUUID,
              treeIdentity: .familySearchID("G2S4-JF4"),
              deathdate: date(2008, 6, 25),
              surname: "Breen", middleName: "Harding", suffix: "Sr"),
        .init(stableID: "rick", canonicalName: "Richard", aliases: ["Dicky", "Rick"],
              birthdate: date(1959, 3, 4),
              kinships: [
                Kinship(relation: .child, relativeTo: .profile(id: dadUUID)),
                Kinship(relation: .sibling, relativeTo: .profile(id: timUUID)),
                Kinship(relation: .parent, relativeTo: .profile(id: timmyUUID)),
              ],
              sex: .male, uuid: rickUUID,
              treeIdentity: .familySearchID("GVQV-NW3"),
              surname: "Breen", middleName: "Harding", suffix: "Jr"),
    ]

    private static let confirmedAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// A catalog tagged the way Rick tagged it BEFORE the renames.
    private static func record(_ path: String, tags: [String]) -> VideoRecord {
        let value = VideoRecord()
        value.fullPath = path
        value.directory = (path as NSString).deletingLastPathComponent
        value.filename = (path as NSString).lastPathComponent
        value.streamTypeRaw = StreamType.videoAndAudio.rawValue
        value.confirmedByUserPeople = tags.map { ConfirmedTag(name: $0, confirmedAt: confirmedAt) }
        return value
    }

    private static let timPath = "/Archive/1975/tim_baseball.mov"
    private static let timmyPath = "/Archive/2001/timmy_glasses.mov"
    private static let dadPath = "/Archive/1988/dad_typewriters.mov"
    private static let donnaPath = "/Archive/1995/donna.mov"

    private func context() async -> Exec.Context {
        let records = [
            Self.record(Self.timPath, tags: ["Tim"]),
            Self.record(Self.timmyPath, tags: ["Timmy"]),
            Self.record(Self.dadPath, tags: ["Dad"]),
            Self.record(Self.donnaPath, tags: ["Donna"]),
        ]
        let snapshots = await ArchivistPresenceRecordSnapshot.capture(records)
        return Exec.Context(
            presenceRecords: snapshots, profiles: Self.profiles, graph: nil,
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae",
                            archivistPersonName: nil),
            mode: .catalog)
    }

    private func videos(of people: [String], question: String) async throws -> Exec.Result {
        try await Exec.execute(
            .init(intent: .init(
                originalQuestion: question,
                ast: .presence(.init(people: people, mediaKind: .video)))),
            context: await context())
    }

    // MARK: - The live questions

    @Test func findVideosOfTimCitesTheVideoTaggedTim() async throws {
        let r = try await videos(of: ["tim"], question: "find videos of tim")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(!r.prose.contains("don't have any videos tagged"), Comment(rawValue: r.prose))
        #expect(r.citations.map(\.fullPath) == [Self.timPath], Comment(rawValue: r.prose))
    }

    @Test func showVideosOfTimmyCitesTheVideoTaggedTimmy() async throws {
        let r = try await videos(of: ["timmy"], question: "show videos of timmy")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.citations.map(\.fullPath) == [Self.timmyPath], Comment(rawValue: r.prose))
    }

    @Test func videosOfMyDadCitesTheVideoTaggedDad() async throws {
        let r = try await videos(of: ["my dad"], question: "videos of my dad")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(!r.prose.contains("don't have any videos tagged"), Comment(rawValue: r.prose))
        #expect(r.citations.map(\.fullPath) == [Self.dadPath], Comment(rawValue: r.prose))
    }

    /// Live 2026-09-05 row 914 shape, now that "Dad" is no longer a
    /// profile's own name: the typed word still reaches the tagged video.
    @Test func showMeVideosOfDadCitesTheVideoTaggedDad() async throws {
        let r = try await videos(of: ["Dad"], question: "show me videos of Dad")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.citations.map(\.fullPath) == [Self.dadPath], Comment(rawValue: r.prose))
    }

    /// The full name the kinship binder hands on resolves to the same set.
    @Test func theBoundFullNameStillFindsTheTaggedVideo() async throws {
        let r = try await videos(of: ["Richard Harding Breen Sr"],
                                 question: "videos of Richard Harding Breen Sr")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.citations.map(\.fullPath) == [Self.dadPath], Comment(rawValue: r.prose))
    }

    // MARK: - Sensors

    /// Two profiles both NAMED Timothy never collapse into one: "tim" and
    /// "timmy" cite different videos, and neither cites the other's.
    @Test func theTwoTimothysNeverCollapseIntoOne() async throws {
        let tim = try await videos(of: ["tim"], question: "videos of tim")
        let timmy = try await videos(of: ["timmy"], question: "videos of timmy")
        #expect(tim.citations.map(\.fullPath) == [Self.timPath], Comment(rawValue: tim.prose))
        #expect(timmy.citations.map(\.fullPath) == [Self.timmyPath], Comment(rawValue: timmy.prose))
        #expect(!tim.citations.map(\.fullPath).contains(Self.timmyPath))
        #expect(!timmy.citations.map(\.fullPath).contains(Self.timPath))
    }

    /// The spelling set is per PROFILE, never the union of same-named
    /// profiles: a video tagged "Timmy" is not a video of Tim.
    @Test func aTagThatBelongsToTheOtherTimothyIsNeverCited() async throws {
        let r = try await videos(of: ["tim"], question: "videos of tim")
        #expect(!r.citations.map(\.fullPath).contains(Self.timmyPath), Comment(rawValue: r.prose))
        #expect(r.citations.count == 1, Comment(rawValue: r.prose))
    }

    /// The spelling set knows every name the person has carried.
    @Test func everyKnownSpellingOfDadProvesATag() {
        let spellings = Exec.presenceAliases(for: ["Dad Breen"], context: Exec.Context(profiles: Self.profiles))
        let set = Set((spellings["dad breen"] ?? []).map { $0.lowercased() })
        #expect(set.contains("dad"), Comment(rawValue: set.sorted().joined(separator: ", ")))
        #expect(set.contains("richard harding breen sr"), Comment(rawValue: set.sorted().joined(separator: ", ")))
        #expect(set.contains("richard breen sr"), Comment(rawValue: set.sorted().joined(separator: ", ")))
        #expect(set.contains("dick"), Comment(rawValue: set.sorted().joined(separator: ", ")))
        // Names the OTHER Richard also answers to are never in Dad's set.
        #expect(!set.contains("richard"), Comment(rawValue: set.sorted().joined(separator: ", ")))
        #expect(!set.contains("richard breen"), Comment(rawValue: set.sorted().joined(separator: ", ")))
        #expect(!set.contains("rick"), Comment(rawValue: set.sorted().joined(separator: ", ")))
    }
}
