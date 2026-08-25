// HalliePersonDescriptionTests.swift
// "describe X" answers deterministically from told family accounts,
// quoted with their tellers (Rick 2026-08-25). "show me a photo of X"
// routes deterministically too.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
@Suite("Person description — attributed testimony, deterministic")
struct HalliePersonDescriptionTests {
    typealias Q = HallieLineageQuestion

    @Test func describeAndLikeAndPhotoShapesDetect() {
        #expect(Q.detect("describe Donna") == .personDescription(person: "Donna"))
        #expect(Q.detect("describe donna's personality and physical appearance as told to you by Rick")
                == .personDescription(person: "Donna"))
        #expect(Q.detect("what was Muriel Lamb like?") == .personDescription(person: "Muriel Lamb"))
        #expect(Q.detect("tell me about donna's physical appearance") == .personDescription(person: "Donna"))
        #expect(Q.detect("show mr a photo of Fred Lamb") == .personPhoto(person: "Fred Lamb"))
        #expect(Q.detect("do we have any pictures of Mary OConnor") == .personPhoto(person: "Mary Oconnor"))
        #expect(Q.detect("tell me about Donna") == nil)          // biography stays
        #expect(Q.detect("show me Donna at the cape") == nil)    // catalog stays
    }

    private func brain() throws -> CyberBrainIndex {
        let told = Date(timeIntervalSince1970: 1_787_300_000)
        return try CyberBrainIndex(archive: CyberBrainArchive(
            archiveID: "t", displayName: "T",
            people: [CyberBrainPerson(
                id: "person.donna", gedcomPersonID: nil,
                canonicalName: "Donna Breen", aliases: ["Donna"],
                biographyPassages: [
                    CyberBrainItem(id: "told.1", kind: .biography,
                                   text: "Donna is slim, attractive, with striking blonde hair.",
                                   subjectPersonIDs: ["person.donna"], sourceIDs: ["source.rick"],
                                   confidence: .probable, privacy: .family,
                                   createdAt: told, updatedAt: told),
                ])],
            sources: [CyberBrainSource(id: "source.rick", type: .firstPerson,
                                       title: "Told by Rick", attribution: "Rick Breen")]))
    }

    @Test func describeQuotesTheTellerVerbatim() throws {
        let context = HallieTurnExecutor.Context(profiles: [], cyberBrain: try brain())
        let r = try #require(HallieLineageAnswer.personDescription("Donna", context: context))
        #expect(r.outcome == .answered)
        #expect(r.prose.contains("According to Rick Breen: “Donna is slim, attractive, with striking blonde hair.”"))
        #expect(r.composedBy == .template)
        #expect(r.answerPlan == nil)     // fixed wording; the model never rewrites it
    }

    @Test func describeWithNoAccountsInvitesTelling() throws {
        let empty = try CyberBrainIndex(archive: CyberBrainArchive(
            archiveID: "t", displayName: "T",
            people: [CyberBrainPerson(id: "person.x", gedcomPersonID: nil,
                                      canonicalName: "Glen Hudson", aliases: [])],
            sources: []))
        let context = HallieTurnExecutor.Context(profiles: [], cyberBrain: empty)
        let r = try #require(HallieLineageAnswer.personDescription("Glen Hudson", context: context))
        #expect(r.outcome == .declined)
        #expect(r.prose.contains("let me tell you about Glen Hudson"))
    }

    @Test func unknownPersonFallsThroughToTheNormalRoute() throws {
        let context = HallieTurnExecutor.Context(profiles: [], cyberBrain: try brain())
        #expect(HallieLineageAnswer.personDescription("Thankful Pratt", context: context) == nil)
    }
}
