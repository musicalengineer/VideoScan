// HallieTagOnlyNameTests.swift
//
// Demo hardening, 2026-10-09. Commit 25e3f42ca added Catalog ▸ People ▸
// "Other people" / "Families": New Person… / New Family… tag the selected
// videos with a free-text name via `setPerson` — a confirmed people tag —
// WITHOUT creating a People-tab profile. Those names must be findable:
//
//   (a) by the Catalog search bar (plain words and `people:`), and
//   (b) by Hallie, for the shapes a visitor actually says:
//         "videos with <First>"           → tag "<First>"
//         "videos of the <X> family"      → tag "<X> Family" or bare "<X>"
//         "the <X>s at Thanksgiving"      → the same family tag
//
// The plural shape was the live gap: "<X>s" matched no tag exactly, so the
// presence lane's spelling recovery took it as a one-edit typo of a People
// profile's maiden-name form ("<First> <X>") and answered with THAT person's
// videos — "I took '<X>s' to mean <First>." And "<X> family" against a bare
// "<X>" tag demanded a "family" token the tag never had.
//
// All names here are synthetic (privacy rule: no family names in git).
//
// Five dimensions: 1 logic (each visitor shape), 2 scale n/a (per-turn set
// over in-memory records), 3 media n/a, 4 isolation (in-memory records and
// profiles; no UserDefaults, no real paths), 5 sensor — a People-tab person
// is never handed a family group's videos, and a plain profile name still
// finds only its own tag.
//
// C++ analogy: `@Suite` is a test fixture class, `@Test` a TEST_F body, and
// `#expect(cond, comment)` is EXPECT_TRUE that also prints the sub-values.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Hallie — tag-only names (no People profile) are found", .serialized)
struct HallieTagOnlyNameTests {
    typealias Exec = HallieTurnExecutor

    private static let confirmedAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// One People-tab profile whose MAIDEN name is the family-group name —
    /// the shape that made the plural a one-edit "typo" of her full name.
    private static let profiles: [Exec.ProfileSnapshot] = [
        .init(stableID: "alice", canonicalName: "Alice", aliases: ["Alice"],
              uuid: UUID(uuidString: "00000000-0000-4000-8000-0000000000A1"),
              surname: "Sample", maidenName: "Testwood"),
    ]

    private static func record(_ path: String, tags: [String]) -> VideoRecord {
        let value = VideoRecord()
        value.fullPath = path
        value.directory = (path as NSString).deletingLastPathComponent
        value.filename = (path as NSString).lastPathComponent
        value.streamTypeRaw = StreamType.videoAndAudio.rawValue
        value.confirmedByUserPeople = tags.map {
            ConfirmedTag(name: $0, confirmedAt: confirmedAt)
        }
        return value
    }

    private static let familyA = "/Synthetic/2001/gathering_a.mov"
    private static let familyB = "/Synthetic/2003/gathering_b.mov"
    private static let carolPath = "/Synthetic/1999/visit.mov"
    private static let quenbyPath = "/Synthetic/1988/reunion.mov"
    private static let alicePath = "/Synthetic/1995/alice.mov"

    private static func records() -> [VideoRecord] {
        [
            record(familyA, tags: ["Testwood Family"]),
            record(familyB, tags: ["Testwood Family"]),
            record(carolPath, tags: ["Carol"]),
            record(quenbyPath, tags: ["Quenby"]),
            record(alicePath, tags: ["Alice"]),
        ]
    }

    private func context() async -> Exec.Context {
        let snapshots = await ArchivistPresenceRecordSnapshot.capture(Self.records())
        return Exec.Context(
            presenceRecords: snapshots, profiles: Self.profiles, graph: nil,
            speakers: .init(ownerName: "Test Owner", archivistName: "Hallie Mae",
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

    private func paths(_ r: Exec.Result) -> Set<String> {
        Set(r.citations.map(\.fullPath))
    }

    // MARK: - (b) Hallie

    @Test func aTagOnlyFirstNameIsFound() async throws {
        let r = try await videos(of: ["Carol"], question: "show me videos with Carol")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(paths(r) == [Self.carolPath], Comment(rawValue: r.prose))
    }

    @Test func theFamilyPhraseFindsAFamilyTag() async throws {
        let r = try await videos(of: ["Testwood family"],
                                 question: "videos of the Testwood family")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(paths(r) == [Self.familyA, Self.familyB], Comment(rawValue: r.prose))
    }

    /// RED before the fix: "I took “Testwoods” to mean Alice." + Alice's video.
    @Test func thePluralSurnameFindsTheFamilyTagNotTheMaidenNamePerson() async throws {
        let r = try await videos(of: ["Testwoods"],
                                 question: "the Testwoods at the reunion")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(paths(r) == [Self.familyA, Self.familyB], Comment(rawValue: r.prose))
        #expect(!r.prose.contains("to mean Alice"), Comment(rawValue: r.prose))
    }

    @Test func theDefiniteArticlePluralAlsoFindsTheFamilyTag() async throws {
        let r = try await videos(of: ["the Testwoods"],
                                 question: "show me the Testwoods")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(paths(r) == [Self.familyA, Self.familyB], Comment(rawValue: r.prose))
    }

    /// RED before the fix: the "family" token is required of a bare tag.
    @Test func theFamilyPhraseFindsABareSurnameTag() async throws {
        let r = try await videos(of: ["Quenby family"],
                                 question: "show me videos of the Quenby family")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(paths(r) == [Self.quenbyPath], Comment(rawValue: r.prose))
    }

    /// RED before the fix: "Aunt <First>" needed an "aunt" token in the tag.
    @Test func aKinTitleBeforeATagOnlyNameStillFindsIt() async throws {
        let r = try await videos(of: ["Aunt Carol"], question: "videos with Aunt Carol")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(paths(r) == [Self.carolPath], Comment(rawValue: r.prose))
    }

    /// The translator put the plural in KEYWORDS ("find the <X>s" →
    /// keyword=<x>s, live probe): a family-shaped word that names a tag is
    /// searched as that tag.
    @Test func aFamilyShapedKeywordThatNamesATagIsSearchedAsTheTag() async throws {
        let r = try await Exec.execute(
            .init(intent: .init(
                originalQuestion: "find the Testwoods",
                ast: .presence(.init(keywords: ["testwoods"])))),
            context: await context())
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(paths(r) == [Self.familyA, Self.familyB], Comment(rawValue: r.prose))
    }

    /// person=<first> keyword=aunt (live probe shape for "videos with Aunt
    /// <First>"): the title is how she is named, not a word in the video.
    @Test func aKinTitleKeywordBeforeTheNamedPersonIsNotSearched() async throws {
        let r = try await Exec.execute(
            .init(intent: .init(
                originalQuestion: "videos with Aunt Carol",
                ast: .presence(.init(people: ["carol"], keywords: ["aunt"])))),
            context: await context())
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(paths(r) == [Self.carolPath], Comment(rawValue: r.prose))
    }

    // MARK: - The pure resolver

    @Test func theResolverMapsOnlyFamilyShapesOntoExistingTags() {
        let tags = ["Testwood Family", "Carol", "Quenby", "Family"]
        #expect(HallieTagOnlyName.resolve("the Testwoods", taggedNames: tags) == "Testwood Family")
        #expect(HallieTagOnlyName.resolve("Testwoods'", taggedNames: tags) == "Testwood Family")
        #expect(HallieTagOnlyName.resolve("the Testwood's family", taggedNames: tags) == "Testwood Family")
        #expect(HallieTagOnlyName.resolve("Quenby family", taggedNames: tags) == "Quenby")
        #expect(HallieTagOnlyName.resolve("the Quenbys", taggedNames: tags) == "Quenby")
        #expect(HallieTagOnlyName.resolve("Uncle Carol", taggedNames: tags) == "Carol")
        // Never: an exact tag, a bare non-plural, the wildcard, two words.
        #expect(HallieTagOnlyName.resolve("testwood family", taggedNames: tags) == nil)
        #expect(HallieTagOnlyName.resolve("Testwood", taggedNames: tags) == nil)
        #expect(HallieTagOnlyName.resolve("family", taggedNames: tags) == nil)
        #expect(HallieTagOnlyName.resolve("families", taggedNames: tags) == nil)
        #expect(HallieTagOnlyName.resolve("Carols Testwood", taggedNames: tags) == nil)
        #expect(HallieTagOnlyName.resolve("Zorbins", taggedNames: tags) == nil)
        // Both a bare and a "Family" tag: the bare one proves both.
        #expect(HallieTagOnlyName.resolve(
            "Quenby family", taggedNames: ["Quenby Family", "Quenby"]) == "Quenby")
    }

    // MARK: - The co-occurrence misroute (live probe 2026-10-09)
    //
    // The translator read "show me videos with <First>" as a co-occurrence
    // ranking anchored on <First>. That lane admits People profiles only,
    // and its fallback asked "is this a known person?" without looking at
    // catalog tags — so the answer was "I couldn't resolve the anchor".

    private func coOccurrence(_ anchors: [String], question: String) async throws -> Exec.Result {
        try await Exec.execute(
            .init(intent: .init(
                originalQuestion: question,
                ast: .aggregate(.init(operation: .coOccurrence, anchorPeople: anchors)))),
            context: await context())
    }

    /// RED before the fix: "I couldn't resolve the anchor Carol."
    @Test func videosWithATagOnlyNameReadAsCoOccurrenceStillSearchesTheCatalog() async throws {
        let r = try await coOccurrence(["Carol"], question: "show me videos with Carol")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(!r.prose.contains("couldn't resolve"), Comment(rawValue: r.prose))
        #expect(paths(r) == [Self.carolPath], Comment(rawValue: r.prose))
    }

    @Test func aFamilyGroupReadAsCoOccurrenceStillFindsTheFamilyTag() async throws {
        let r = try await coOccurrence(["Testwood family"],
                                       question: "show me videos with the Testwood family")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(paths(r) == [Self.familyA, Self.familyB], Comment(rawValue: r.prose))
    }

    /// Sensor: an anchor that is neither a profile nor a tag still declines.
    @Test func anUnknownCoOccurrenceAnchorStillDeclines() async throws {
        let r = try await coOccurrence(["Zorbin"], question: "who is with Zorbin")
        #expect(r.citations.isEmpty, Comment(rawValue: r.prose))
        #expect(r.outcome != .answered, Comment(rawValue: r.prose))
    }

    // MARK: - A tree namesake never answers for a tagged name
    //
    // Live probe: "videos of the <X>s" → "<tree namesake> died in 1387, more
    // than five centuries before motion pictures". A catalog tag says the
    // family IS on video; the pre-film floor must step aside.

    private static let medievalTree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Quenby /Burke/
    1 SEX M
    1 BIRT
    2 DATE 1320
    1 DEAT
    2 DATE 1387
    0 @I2@ INDI
    1 NAME Rockwell /Burke/
    1 SEX M
    1 BIRT
    2 DATE 1322
    1 DEAT
    2 DATE 1388
    0 TRLR
    """

    @Test func aTaggedNameIsNeverAnsweredByAPreFilmTreeNamesake() async throws {
        let graph = GedcomFamilyGraph(gedcomText: Self.medievalTree)
        let tagged = await context()
        let withTag = Exec.Context(
            presenceRecords: tagged.presenceRecords, profiles: Self.profiles, graph: graph,
            speakers: tagged.speakers, mode: .catalog)
        #expect(HallieLineageAnswer.answer(.personVideos(person: "Quenby"), context: withTag) == nil)
        #expect(HallieLineageAnswer.answer(.personVideos(person: "the Quenbys"), context: withTag) == nil)
        // Sensor: with no such tag the honest pre-film line still answers.
        let untagged = Exec.Context(presenceRecords: [], profiles: Self.profiles, graph: graph,
                                    speakers: tagged.speakers, mode: .catalog)
        let floor = HallieLineageAnswer.answer(.personVideos(person: "Quenby"), context: untagged)
        #expect(floor?.prose.contains("motion pictures") == true, Comment(rawValue: floor?.prose ?? "nil"))
    }

    /// The real pre-translation path has NO catalog records in its context,
    /// so the tag guard above cannot see the tag there. The live miss was a
    /// near-spelling guess ("<X>s" → a 1387 "Rickard"-style namesake): a
    /// spelling-recovered person never answers the pre-film floor.
    @Test func aNearSpellingGuessNeverAnswersThePreFilmFloor() {
        let graph = GedcomFamilyGraph(gedcomText: Self.medievalTree)
        let noRecords = Exec.Context(presenceRecords: [], profiles: Self.profiles, graph: graph,
                                     speakers: .none, mode: .catalog)
        // "Rackwells" is two edits from the tree's "Rockwell" (the 8+ letter
        // band that spelling recovery accepts) — the live shape.
        let guess = HallieLineageAnswer.answer(.personVideos(person: "Rackwells"), context: noRecords)
        #expect(guess == nil, Comment(rawValue: guess?.prose ?? "nil"))
        // Sensor: the exact name still gets the honest pre-film line.
        let exact = HallieLineageAnswer.answer(.personVideos(person: "Rockwell Burke"), context: noRecords)
        #expect(exact?.prose.contains("motion pictures") == true, Comment(rawValue: exact?.prose ?? "nil"))
    }

    // MARK: - Sensors

    /// A People-tab person still finds exactly her own tag — the family
    /// rewrite never widens a profile name.
    @Test func aProfileNameStillFindsOnlyItsOwnTag() async throws {
        let r = try await videos(of: ["Alice"], question: "videos of Alice")
        #expect(paths(r) == [Self.alicePath], Comment(rawValue: r.prose))
    }

    /// A plural that matches no tag is left alone (never invents a family).
    @Test func aPluralWithNoMatchingTagIsNotRewrittenToAFamily() async throws {
        let r = try await videos(of: ["Zorbins"], question: "videos of the Zorbins")
        // The relax ladder may OFFER other videos (outcome stays declined),
        // but nothing is ever cited as a person-tag match for "Zorbins".
        #expect(r.outcome != .answered, Comment(rawValue: r.prose))
        let tagBased = r.citations.filter { citation in
            citation.bases.contains {
                if case .humanPersonTag = $0 { return true }
                return false
            }
        }
        #expect(tagBased.isEmpty, Comment(rawValue: r.prose))
    }

    // MARK: - (a) Catalog search bar (same records, pure matcher)

    @Test func catalogSearchFindsTagOnlyNames() {
        let recs = Self.records()
        func hits(_ q: String) -> Set<String> {
            Set(recs.filter { pfRecordFilenameOrPersonMatch($0, query: q) }.map(\.fullPath))
        }
        #expect(hits("carol") == [Self.carolPath])
        #expect(hits("people:carol") == [Self.carolPath])
        #expect(hits("testwood") == [Self.familyA, Self.familyB])
        #expect(hits("Testwood Family") == [Self.familyA, Self.familyB])
        #expect(hits("people:testwood") == [Self.familyA, Self.familyB])
        #expect(hits("quenby") == [Self.quenbyPath])
    }
}
