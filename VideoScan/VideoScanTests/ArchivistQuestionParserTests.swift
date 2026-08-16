import Foundation
import Testing
@testable import VideoScan

struct ArchivistQuestionParserTests {
    @Test func biographyAcceptsRealWorldUnicodeAndPunctuation() {
        #expect(ArchivistQuestionParser.general(
            "Who is Élise-Marie O'Connor?")
            == .biography(personText: "Élise-Marie O'Connor"))
        #expect(ArchivistQuestionParser.general("tell me about Hallie Mae!")
            == .biography(personText: "Hallie Mae"))
    }

    @Test func lifeDatesAndAncestryStayOnTheLocalRoute() {
        #expect(ArchivistQuestionParser.general("When was Renée Smith born?")
            == .lifeDate(personText: "Renée Smith", birth: true))
        #expect(ArchivistQuestionParser.general("When did José Silva die?")
            == .lifeDate(personText: "José Silva", birth: false))
        #expect(ArchivistQuestionParser.general("Open the family history")
            == .ancestry)
    }

    @Test func productionKinshipExampleSeparatesCarrierWordsFromPerson() throws {
        let parsed = try #require(ArchivistQuestionParser.kinship(
            "show videos of Rick’s father at Christmas"))

        #expect(parsed.relation == .father)
        #expect(parsed.relationWord == "father")
        #expect(parsed.possessors.map(\.personText) == [
            "show videos of Rick", "videos of Rick", "of Rick", "Rick",
        ])
        #expect(parsed.possessors.last?.matchedPhrase == "Rick’s father")
    }

    @Test func productionDispatchDoesNotLetGeneralRouteStealKinship() {
        #expect(ArchivistQuestionParser.general("Who was Rick's father?")
                == nil)
        #expect(ArchivistQuestionParser.kinship("Who was Rick's father?")
                != nil)
        #expect(ArchivistQuestionParser.general(
            "When was Rick's father born?") == nil)
        #expect(ArchivistQuestionParser.kinship(
            "When was Rick's father born?") != nil)
    }

    @Test func multiwordPossessorIsOfferedBeforeShorterSuffixes() throws {
        let parsed = try #require(ArchivistQuestionParser.kinship(
            "Hallie Mae McGill's mother"))
        #expect(parsed.possessors.first?.personText == "Hallie Mae McGill")
        #expect(parsed.possessors.first?.matchedPhrase
                == "Hallie Mae McGill's mother")
    }

    @Test func unknownRelationDoesNotStealCatalogQuestion() {
        #expect(ArchivistQuestionParser.kinship("Rick's cousin") == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func possessorCandidatesAreBoundedForHugeUntrustedQuestion() throws {
        let prefix = Array(repeating: "noise", count: 100_000)
            .joined(separator: " ")
        let started = ContinuousClock.now
        let parsed = try #require(
            ArchivistQuestionParser.kinship(prefix + " Rick's father"))
        let elapsed = started.duration(to: .now)

        #expect(parsed.possessors.count == 6)
        #expect(parsed.possessors.last?.personText == "Rick")
        #expect(elapsed < .seconds(2),
                "100k-word kinship parse exceeded 2 seconds: \(elapsed)")
    }
}
