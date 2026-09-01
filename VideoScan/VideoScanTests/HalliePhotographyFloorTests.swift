// HalliePhotographyFloorTests.swift
// Rick 2026-08-26, after "tell me about Nathaniel Parker Sr" (1651–1737)
// came back with a "put a photo in his People folder" card: "there can be
// no photo of anyone who died before 1820, or certainly 1800." The rule
// lives in VideoScanCore (WorldKnowledge.MediumFeasibility); these tests
// pin every Hallie route that offers a picture or a video to the MEDIUM
// it is offering (codex gate 2026-08-26: photo asks → photograph fact
// 1838, video asks → film fact 1888; a known death year only — an early
// birth with no death is "unknown", never a veto). Pure fixture, temp-dir
// asset store, no model.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// Nathaniel Parker Sr 1651–1737 (M) ← Thomas Parker (no dates)
///   Thankful Pratt 1761–1849 (F) · David Latta 1902–1980 (M)
///   Early Bird b. ABT 1700, no death (F) · Donna Hudson 1959
///   Mid Century 1790–1850 (F): photograph possible, film impossible
private let tree = """
0 HEAD
0 @I1@ INDI
1 NAME Nathaniel /Parker/ Sr
1 SEX M
1 BIRT
2 DATE 16 MAY 1651
1 DEAT
2 DATE 7 DEC 1737
1 FAMC @F1@
0 @I2@ INDI
1 NAME Thankful /Pratt/
1 SEX F
1 BIRT
2 DATE 6 OCT 1761
1 DEAT
2 DATE 1 NOV 1849
0 @I3@ INDI
1 NAME David /Latta/
1 SEX M
1 BIRT
2 DATE 1902
1 DEAT
2 DATE 1980
0 @I4@ INDI
1 NAME Early /Bird/
1 SEX F
1 BIRT
2 DATE ABT 1700
0 @I5@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 BIRT
2 DATE 1959
0 @I6@ INDI
1 NAME Thomas /Parker/
1 SEX M
1 FAMS @F1@
0 @I7@ INDI
1 NAME Mid /Century/
1 SEX F
1 BIRT
2 DATE 1790
1 DEAT
2 DATE 1850
0 @F1@ FAM
1 HUSB @I6@
1 CHIL @I1@
0 TRLR
"""

@Suite("Photography floor — no photo offer for anyone who predates photography")
struct HalliePhotographyFloorTests {
    typealias Q = HallieLineageQuestion
    typealias Exec = HallieTurnExecutor
    let graph = GedcomFamilyGraph(gedcomText: tree)
    var context: Exec.Context {
        .init(profiles: [], graph: graph,
              speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
    }
    private func pre(_ q: String) -> Exec.PreTranslation {
        Exec.preTranslation(
            question: q, playAfterAnswer: false, memory: .init(), isKnownPerson: { _ in false },
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context) })
    }
    private func person(_ id: String) -> GedcomFamilyGraph.Person { graph.people[id]! }
    private func hasPhotoRequest(_ r: Exec.Result) -> Bool {
        r.attachments.contains { if case .photoRequest = $0 { return true } else { return false } }
    }

    private static let nathanielLine =
        "Nathaniel Parker Sr died in 1737, about a century before photography begins in 1838 — there can’t be a photograph of him. "
        + "If the family has a painting, engraving, or gravestone photo, put it in his People folder and I’ll show it."
    private static let nathanielFilmLine =
        "Nathaniel Parker Sr died in 1737, about a century before motion pictures begin in 1888 — there can’t be film of him. "
        + "There can’t be a photograph either; a painting, engraving, or gravestone photo in his People folder is the best the family can do, and I’ll show it."
    private static let midFilmLine =
        "Mid Century died in 1850, decades before motion pictures begin in 1888 — there can’t be film of her. "
        + "If the family has a photograph of her, put it in her People folder and I’ll show it."
    /// Early Bird, b. ABT 1700 (upper 1702) and NO death: 1702 + 125 = 1827
    /// < 1838, so WorldKnowledge rule 5 (the lifespan cap, 2026-09-01)
    /// vetoes a photograph AND film on the birth alone.
    private static let earlyPhotoLine =
        "Early Bird was born about 1700, about a century before photography begins in 1838 — no one lives that long, so there can’t be a photograph of her. "
        + "If the family has a painting, engraving, or gravestone photo, put it in her People folder and I’ll show it."
    private static let earlyFilmLine =
        "Early Bird was born about 1700, nearly two centuries before motion pictures begin in 1888 — no one lives that long, so there can’t be film of her. "
        + "There can’t be a photograph either; a painting, engraving, or gravestone photo in her People folder is the best the family can do, and I’ll show it."

    // MARK: Detection

    @Test func videosOfAPersonIsDetectedButOnlyAsASuppressor() {
        #expect(Q.detect("videos of nathaniel parker sr") == .personVideos(person: "Nathaniel Parker Sr"))
        #expect(Q.detect("show me videos of Donna Hudson") == .personVideos(person: "Donna Hudson"))
        #expect(Q.detect("any film of early bird") == .personVideos(person: "Early Bird"))
        // Year-bounded and superlative media asks keep their own shapes.
        #expect(Q.detect("videos of donna from 1992 to 1995") != .personVideos(person: "Donna From 1992 To 1995"))
        #expect(Q.detect("find the oldest photo of the oldest person in the tree")
                == .superlative(kind: .earliestBorn, scope: .wholeTree, media: "photo"))
        // The suppressor answers NOTHING for a person who could be filmed.
        // An unknown death year is no veto by itself — but a birth more
        // than a lifetime before film is (Early Bird, b. about 1700; rule 5).
        #expect(HallieLineageAnswer.answer(.personVideos(person: "Donna Hudson"), context: context) == nil)
        #expect(HallieLineageAnswer.answer(.personVideos(person: "David Latta"), context: context) == nil)
        #expect(HallieLineageAnswer.answer(.personVideos(person: "Early Bird"), context: context)?.prose == Self.earlyFilmLine)
        #expect(HallieLineageAnswer.answer(.personVideos(person: "Nobody Known"), context: context) == nil)
        #expect(HallieLineageAnswer.answer(.personVideos(person: "the family"), context: context) == nil)
    }

    // MARK: Direct asks — honest line, never a keyword search (router sensor)

    @Test func directPhotoAskGetsTheHonestLineAndNoSearch() throws {
        guard case .answer(let r) = pre("show me a photo of Nathaniel Parker Sr") else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(r.route == .graph)
        #expect(r.outcome == .declined)
        #expect(r.prose == Self.nathanielLine)
        #expect(r.queryDescription == "photo: Nathaniel Parker Sr (before photography)")
        #expect(r.attachments.isEmpty)
        #expect(r.basisLine.contains("No search was run"))
        #expect(r.basisLine.contains("1838"), "the basis cites the photograph fact")
        #expect(r.offeredActions == [.openFamilyTreePerson(personID: "@I1@", personName: "Nathaniel Parker Sr")])

        // Birth-only, very early, NO death year: a birth more than a
        // lifetime before photography is "can't" too (rule 5, 2026-09-01)
        // — the honest line, no folder card.
        guard case .answer(let early) = pre("do we have any pictures of Early Bird") else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(early.prose == Self.earlyPhotoLine)
        #expect(early.queryDescription == "photo: Early Bird (before photography)")
        #expect(early.outcome == .declined)
        #expect(early.basisLine.contains("No search was run"))
        #expect(early.attachments.isEmpty)
    }

    @Test func photoAskUsesThePhotographFactNotTheFilmOne() throws {
        // d. 1850 — after photography (1838), before film (1888): a photo
        // ask is ordinary, a video ask is vetoed by the FILM fact.
        guard case .answer(let photo) = pre("show me a photo of Mid Century") else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(photo.prose == "I don’t have a photo of Mid Century yet.")
        #expect(photo.queryDescription == "photo: Mid Century")
        #expect(!photo.basisLine.contains("No search was run"), "not the floor's basis")

        guard case .answer(let video) = pre("videos of Mid Century") else {
            Issue.record("the video ask went to the translator (presence search)"); return
        }
        #expect(video.outcome == .declined)
        #expect(video.prose == Self.midFilmLine)
        #expect(video.queryDescription == "videos: Mid Century (before motion pictures)")
        #expect(video.basisLine.contains("1888"), "the basis cites the film fact")
        #expect(!video.basisLine.contains("1838"), "not the photograph fact")
    }

    @Test func directPhotoAskForA1902PersonKeepsTheOldBehaviour() throws {
        guard case .answer(let r) = pre("show me a photo of David Latta") else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(r.prose == "I don’t have a photo of David Latta yet.")
        #expect(r.queryDescription == "photo: David Latta")
        // Thankful Pratt died in 1849 — ten years INTO photography; no floor.
        guard case .answer(let thankful) = pre("show me a photo of Thankful Pratt") else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(thankful.prose == "I don’t have a photo of Thankful Pratt yet.")
    }

    @Test func directVideoAskGetsOneHonestLineAndNoPresenceSearch() throws {
        guard case .answer(let r) = pre("videos of Nathaniel Parker Sr") else {
            Issue.record("the video ask went to the translator (presence search)"); return
        }
        #expect(r.route == .graph)
        #expect(r.outcome == .declined)
        #expect(r.prose == Self.nathanielFilmLine)
        #expect(r.queryDescription == "videos: Nathaniel Parker Sr (before motion pictures)")
        #expect(r.citations.isEmpty && r.attachments.isEmpty)

        // Everyone else still goes to the presence route, as typed.
        // Early Bird (b. about 1700, no death) is vetoed by the lifespan
        // cap on the FILM fact (rule 5): one honest line, no search.
        #expect(pre("videos of David Latta") == .translate(question: "videos of David Latta", playAfterAnswer: false))
        guard case .answer(let early) = pre("videos of Early Bird") else {
            Issue.record("Early Bird's video ask went to the translator (presence search)"); return
        }
        #expect(early.prose == Self.earlyFilmLine)
        #expect(early.queryDescription == "videos: Early Bird (before motion pictures)")
        #expect(pre("show me videos of Donna Hudson") == .translate(question: "show me videos of Donna Hudson", playAfterAnswer: false))
        #expect(pre("videos of the family") == .translate(question: "videos of the family", playAfterAnswer: false))
    }

    // MARK: Superlative media asks resolve the person first, then hit the floor

    @Test func superlativeMediaAsksHonourTheFloor() throws {
        guard case .answer(let photo) = pre("find the oldest photo of the oldest person in the tree") else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(photo.prose.hasPrefix("The earliest birth year in the family tree is born 1651: Nathaniel Parker Sr"))
        #expect(photo.prose.hasSuffix(Self.nathanielLine))
        #expect(!hasPhotoRequest(photo))

        guard case .answer(let video) = pre("find videos of the oldest person in the tree") else {
            Issue.record("the video ask went to the translator (presence search)"); return
        }
        #expect(video.prose.hasSuffix(Self.nathanielFilmLine))
        #expect(video.queryDescription == "videos: Nathaniel Parker Sr (before motion pictures)")

        // The youngest person is filmable: the presence route by name.
        #expect(pre("find videos of the youngest person in the tree")
                == .translate(question: "videos of Donna Hudson", playAfterAnswer: false))
    }

    // MARK: Superlative / who-is answers never carry a photo-request card

    @Test func superlativeAnswerAttachesNoPhotoRequest() throws {
        let oldest = try #require(HallieLineageAnswer.answer(.superlative(kind: .earliestBorn, scope: .wholeTree), context: context))
        #expect(oldest.prose.contains("Nathaniel Parker Sr"))
        #expect(!hasPhotoRequest(oldest))
        let youngest = try #require(HallieLineageAnswer.answer(.superlative(kind: .latestBorn, scope: .wholeTree), context: context))
        #expect(youngest.prose.contains("Donna Hudson"))
        #expect(!hasPhotoRequest(youngest))
    }

    // MARK: Biography route (the live bug) — HallieBiographyPhotoOffer

    private func temporaryStore() throws -> FamilyAssetStore {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-floor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return FamilyAssetStore(
            root: base.appendingPathComponent("40_Family_Tree", isDirectory: true),
            cacheRoot: base.appendingPathComponent("thumbs", isDirectory: true))
    }

    @Test func biographyDropsTheFolderCardForNathanielAndKeepsItForDavid() throws {
        let store = try temporaryStore()
        let nathaniel = HallieBiographyPhotoOffer.decide(
            canonicalName: "Nathaniel Parker Sr", graphMatches: [person("@I1@")], assets: store)
        #expect(nathaniel.attachments.isEmpty)
        #expect(nathaniel.suppressedNote == "d. 1737 < photograph 1838")
        #expect(nathaniel.folderError == nil)
        // No folder was created for him either.
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: store.peopleDirectory.path)) ?? []
        #expect(folders.isEmpty)

        let david = HallieBiographyPhotoOffer.decide(
            canonicalName: "David Latta", graphMatches: [person("@I3@")], assets: store)
        #expect(david.suppressedNote == nil)
        guard case .photoRequest(let name, let folder)? = david.attachments.first else {
            Issue.record("the 1902 person lost his folder card"); return
        }
        #expect(name == "David Latta")
        #expect(FileManager.default.fileExists(atPath: folder.path))

        // Birth-only early person: no death, but b. about 1700 + 125 <
        // 1838 — the lifespan cap drops the card (rule 5). A d. 1850
        // person (photograph possible even though film is not) and a
        // person known only by name keep the folder card.
        let early = HallieBiographyPhotoOffer.decide(
            canonicalName: "Early Bird", graphMatches: [person("@I4@")], assets: store)
        #expect(early.suppressedNote == "b. about 1700 + 125 < photograph 1838")
        #expect(early.attachments.isEmpty)
        let mid = HallieBiographyPhotoOffer.decide(
            canonicalName: "Mid Century", graphMatches: [person("@I7@")], assets: store)
        #expect(mid.suppressedNote == nil && !mid.attachments.isEmpty)
        let unknown = HallieBiographyPhotoOffer.decide(
            canonicalName: "Somebody Else", graphMatches: [], assets: store)
        #expect(unknown.suppressedNote == nil && !unknown.attachments.isEmpty)
    }

    @Test func aPaintingInHisFolderStillShows() throws {
        let store = try temporaryStore()
        // Create his folder the sanctioned way, then plant a "painting".
        let folder = try store.folderForPhotoRequest(person: FamilyAssetPerson(person("@I1@")))
        let png = folder.appendingPathComponent("engraving.png")
        // Smallest valid PNG (1×1) so the store's image verification accepts it.
        let bytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82,
        ]
        try Data(bytes).write(to: png)
        let decision = HallieBiographyPhotoOffer.decide(
            canonicalName: "Nathaniel Parker Sr", graphMatches: [person("@I1@")], assets: store)
        #expect(decision.suppressedNote == nil)
        guard case .photo(let photo)? = decision.attachments.first else {
            Issue.record("the family's own engraving was not shown"); return
        }
        #expect(photo.fileURL.lastPathComponent == "engraving.png")
        #expect(photo.personGedcomID == "@I1@")
    }

    // MARK: Legacy chat-window "Videos of X" chip — a VIDEO offer, so the film fact

    @MainActor @Test func legacyVideosChipHonoursTheFilmFloor() {
        #expect(ArchivistChatWindow.mayOfferMedia(for: "Nathaniel Parker Sr", in: graph) == false)
        #expect(ArchivistChatWindow.mayOfferMedia(for: "Mid Century", in: graph) == false, "d. 1850 < film 1888")
        #expect(ArchivistChatWindow.mayOfferMedia(for: "Early Bird", in: graph) == false, "b. about 1700 + 125 < film 1888 (rule 5)")
        #expect(ArchivistChatWindow.mayOfferMedia(for: "David Latta", in: graph) == true)
        // Thankful Pratt d. 1849: a PHOTO is possible, but this chip offers
        // VIDEO — the film fact (1888) decides, and it says no.
        #expect(ArchivistChatWindow.mayOfferMedia(for: "Thankful Pratt", in: graph) == false, "d. 1849 < film 1888")
        // Not in the tree / no dates: never guess.
        #expect(ArchivistChatWindow.mayOfferMedia(for: "Somebody Else", in: graph) == true)
        #expect(ArchivistChatWindow.mayOfferMedia(for: "Thomas Parker", in: graph) == true)
    }
}
