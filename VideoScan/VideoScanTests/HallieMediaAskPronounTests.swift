// HallieMediaAskPronounTests.swift
// Live regression 2026-08-27 03:26Z (build ac42b745): "tell me about
// Nathaniel Parker" → which-one chip → "Nathaniel Parker Sr (b. 1651,
// d. 1737)" → bio → "are there any photos of him" → "I don't find “Him” in
// the family tree". The deterministic photo / video shapes run BEFORE the
// translator's pronoun rewrite, so the pronoun reached the tree as a name.
// These pin: the pronoun resolves through conversation memory's subject
// (the person the which-one chip settled on), the photography floor
// answers with no search, plural pronouns decline politely, and with no
// subject in memory Hallie asks who. Pure fixture, no model.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// Two Nathaniel Parkers (Sr 1651–1737, and Nathaniel Caleb 1760–1826 —
/// neither is an exact "Nathaniel Parker", so the name is a which-one, as
/// live), Mid Century (F, 1790–1850, photograph possible), Donna Hudson
/// (F, b. 1959).
private let tree = """
0 HEAD
0 @I1@ INDI
1 NAME Nathaniel /Parker/ Sr
1 SEX M
1 BIRT
2 DATE 16 MAY 1651
1 DEAT
2 DATE 7 DEC 1737
0 @I2@ INDI
1 NAME Nathaniel Caleb /Parker/
1 SEX M
1 BIRT
2 DATE 14 JUL 1760
1 DEAT
2 DATE 4 MAR 1826
0 @I3@ INDI
1 NAME Mid /Century/
1 SEX F
1 BIRT
2 DATE 1790
1 DEAT
2 DATE 1850
0 @I4@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 BIRT
2 DATE 1959
0 TRLR
"""

@Suite("Media asks with a pronoun object resolve through conversation memory")
struct HallieMediaAskPronounTests {
    typealias Q = HallieLineageQuestion
    typealias Exec = HallieTurnExecutor
    let graph = GedcomFamilyGraph(gedcomText: tree)
    var context: Exec.Context {
        .init(profiles: [], graph: graph,
              speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
    }
    private func pre(_ q: String, memory: Exec.ConversationMemory = .init()) -> Exec.PreTranslation {
        Exec.preTranslation(
            question: q, playAfterAnswer: false, memory: memory, isKnownPerson: { _ in false },
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context) })
    }

    private static let nathanielLine =
        "Nathaniel Parker Sr died in 1737, about a century before photography begins in 1838 — there can’t be a photograph of him. "
        + "If the family has a painting, engraving, or gravestone photo, put it in his People folder and I’ll show it."

    // MARK: Detection — the pronoun is the object, and "his photo" is a photo ask

    @Test func pronounObjectsAreDetectedAsMediaAsks() {
        #expect(Q.detect("are there any photos of him") == .personPhoto(person: "Him"))
        #expect(Q.detect("any photos of her") == .personPhoto(person: "Her"))
        #expect(Q.detect("show me his photo") == .personPhoto(person: "His"))
        #expect(Q.detect("videos of them") == .personVideos(person: "Them"))
        #expect(Q.detect("show me her videos") == .personVideos(person: "Her"))
        #expect(Q.detect("are there any photos of him")?.mediaAskPerson == "Him")
        #expect(Q.detect("tell me about him")?.mediaAskPerson == nil)
    }

    // MARK: The live three-turn sequence

    /// Runs "tell me about Nathaniel Parker" through the real executor,
    /// answers the which-one chip with Sr, and records both turns in
    /// memory exactly as the app and the shell do.
    private func memoryAfterChoosingSr() async throws -> Exec.ConversationMemory {
        let context = self.context
        let intent = Exec.Intent(
            originalQuestion: "tell me about Nathaniel Parker",
            ast: .graph(.init(people: ["nathaniel parker"], operation: .biography)))
        let asked = try await Exec.execute(.init(intent: intent), context: context)
        #expect(asked.outcome == .needsClarification)
        let pending = try #require(asked.clarification)
        let labels = pending.candidates.map(\.label)
        #expect(labels == ["Nathaniel Caleb Parker (b. 14 JUL 1760, d. 4 MAR 1826)",
                           "Nathaniel Parker Sr (b. 16 MAY 1651, d. 7 DEC 1737)"], Comment(rawValue: labels.joined(separator: " | ")))
        var memory = Exec.ConversationMemory()
        memory.record(intent: intent, result: asked)
        #expect(memory.lastSubject == "nathaniel parker", "before the chip, the typed name is the best we have")

        let chosen = try await Exec.continue(
            pending: pending, selecting: .gedcomPersonID("@I1@"), context: context)
        #expect(chosen.outcome == .answered)
        #expect(chosen.catalogPersonName == "Nathaniel Parker Sr")
        memory.record(intent: intent, result: chosen)
        #expect(memory.lastSubject == "Nathaniel Parker Sr", "the chip's person is the subject, not the typed name")
        #expect(memory.pronounReferents == ["Nathaniel Parker Sr"])
        return memory
    }

    @Test func photosOfHimAfterTheChipHitsThePhotographyFloorWithNoSearch() async throws {
        let memory = try await memoryAfterChoosingSr()
        guard case .answer(let r) = pre("are there any photos of him", memory: memory) else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(r.route == .graph)
        #expect(r.outcome == .declined)
        #expect(r.prose == Self.nathanielLine)
        #expect(r.queryDescription == "photo: Nathaniel Parker Sr (before photography)")
        #expect(r.basisLine.contains("No search was run"))
        #expect(!r.prose.contains("Him"))

        // The same subject serves "his photo" and the video shape.
        guard case .answer(let his) = pre("show me his photo", memory: memory) else {
            Issue.record("'his photo' went to the translator"); return
        }
        #expect(his.queryDescription == "photo: Nathaniel Parker Sr (before photography)")
        guard case .answer(let film) = pre("videos of him", memory: memory) else {
            Issue.record("the video ask went to the translator (presence search)"); return
        }
        #expect(film.queryDescription == "videos: Nathaniel Parker Sr (before motion pictures)")
    }

    @Test func photosOfHerAfterAFemaleSubjectTakesThePhotoOfferPath() async throws {
        let bio = Exec.Intent(
            originalQuestion: "tell me about Mid Century",
            ast: .graph(.init(people: ["mid century"], operation: .biography)))
        let answered = try await Exec.execute(.init(intent: bio), context: context)
        #expect(answered.outcome == .answered)
        var memory = Exec.ConversationMemory()
        memory.record(intent: bio, result: answered)
        #expect(memory.lastSubject == "Mid Century")

        // d. 1850 — photographs were possible: the ordinary "not yet" answer.
        guard case .answer(let r) = pre("any photos of her", memory: memory) else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(r.route == .graph)
        #expect(r.queryDescription == "photo: Mid Century")
        #expect(r.prose == "I don’t have a photo of Mid Century yet.")
        #expect(r.catalogPersonName == "Mid Century")
    }

    // MARK: No subject → ask; plural → decline politely

    @Test func withNoSubjectInMemoryHallieAsksWhoInsteadOfLookingUpHim() {
        guard case .answer(let r) = pre("are there any photos of him") else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(r.outcome == .declined)
        #expect(r.prose == HalliePronounContinuity.whoDoYouMean("him"))
        #expect(r.queryDescription == "media ask: pronoun him (no subject)")
        #expect(!r.prose.contains("Him"))
        #expect(!r.prose.contains("don't find"))

        // Two people in memory: "he" is a guess — ask.
        var memory = Exec.ConversationMemory()
        memory.record(
            intent: .init(originalQuestion: "videos of rick and donna",
                          ast: .presence(.init(people: ["Rick", "Donna"]))),
            result: .init(route: .presence, outcome: .declined, prose: "none", basisLine: "Basis: none",
                          queryDescription: nil, citations: [], catalogPersonName: nil))
        #expect(memory.lastSubject == nil)
        guard case .answer(let two) = pre("show me a photo of him", memory: memory) else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(two.prose == HalliePronounContinuity.whoDoYouMean("him"))
    }

    @Test func pluralPronounsDeclinePolitelyEvenWithASubject() async throws {
        let memory = try await memoryAfterChoosingSr()
        guard case .answer(let r) = pre("videos of them", memory: memory) else {
            Issue.record("the video ask went to the translator (presence search)"); return
        }
        #expect(r.outcome == .declined)
        #expect(r.prose == "I can look for pictures of one person at a time — who do you mean?")
        #expect(r.queryDescription == "media ask: pronoun them (plural)")
        guard case .answer(let photos) = pre("any photos of them") else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(photos.queryDescription == "media ask: pronoun them (plural)")
    }

    // MARK: codex #716 — a local one-person answer replaces the older pair

    @Test func aLocalAnswerAboutOnePersonReplacesTheOlderASTsPeople() {
        var memory = Exec.ConversationMemory()
        // Turn 1: a two-person search (an AST with people).
        memory.record(
            intent: .init(originalQuestion: "videos of rick and donna",
                          ast: .presence(.init(people: ["Rick", "Donna"]))),
            result: .init(route: .presence, outcome: .declined, prose: "none", basisLine: "Basis: none",
                          queryDescription: nil, citations: [], catalogPersonName: nil))
        #expect(memory.pronounReferents == ["Rick", "Donna"])
        // Turn 2: a LOCAL photo answer (no intent) about one tree person.
        guard case .answer(let photo) = pre("show me a photo of Nathaniel Parker Sr", memory: memory) else {
            Issue.record("the photo ask went to the translator"); return
        }
        memory.record(intent: nil, result: photo)
        #expect(memory.lastSubject == "Nathaniel Parker Sr")
        #expect(memory.lastPeople == ["Nathaniel Parker Sr"], "the stale pair is gone")
        #expect(memory.pronounReferents == ["Nathaniel Parker Sr"])
        // Turn 3: "him" is Nathaniel — not Rick and Donna, not a guess.
        guard case .answer(let him) = pre("are there any photos of him", memory: memory) else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(him.queryDescription == "photo: Nathaniel Parker Sr (before photography)")
        #expect(pre("when did they get married", memory: memory)
                == .translate(question: "when did Nathaniel Parker Sr get married", playAfterAnswer: false))
    }

    // MARK: The lineage answer itself never looks up a pronoun (belt and braces)

    @Test func theLineageAnswerRefusesABarePronoun() {
        let photo = HallieLineageAnswer.answer(.personPhoto(person: "Him"), context: context)
        #expect(photo?.prose == HalliePronounContinuity.whoDoYouMean("him"))
        #expect(photo?.queryDescription == "media ask: pronoun him (no subject)")
        let video = HallieLineageAnswer.answer(.personVideos(person: "Her"), context: context)
        #expect(video?.prose == HalliePronounContinuity.whoDoYouMean("her"))
    }

    // MARK: Regressions — named asks are untouched

    @Test func namedAsksAreUnchanged() {
        #expect(pre("photos of Donna") == .translate(question: "photos of Donna", playAfterAnswer: false),
                "no lead verb: the translator's presence lane, as before")
        guard case .answer(let r) = pre("show me a photo of Nathaniel Parker Sr") else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(r.prose == Self.nathanielLine)
        // A pronoun in a NON-media shape still takes the translator rewrite.
        var memory = Exec.ConversationMemory()
        memory.record(
            intent: .init(originalQuestion: "who did Rick marry",
                          ast: .graph(.init(people: ["Rick"], operation: .kinship, relation: .spouse))),
            result: .init(route: .graph, outcome: .answered, prose: "Donna.", basisLine: "Basis: GEDCOM",
                          queryDescription: "shape=graph", citations: [], catalogPersonName: nil))
        #expect(pre("when did he get married", memory: memory)
                == .translate(question: "when did Rick get married", playAfterAnswer: false))
    }
}
