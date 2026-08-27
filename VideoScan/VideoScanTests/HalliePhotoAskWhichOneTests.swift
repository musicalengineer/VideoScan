// HalliePhotoAskWhichOneTests.swift
// Live 2026-08-27 03:27:06Z: "are there are photos of Nathaniel Parker"
// (typo) → translator decline. Expected: the photo path resolves the
// name, finds two Nathaniel Parkers, asks which with chips, and the chip
// RESUMES the photo ask (→ the photography-floor line for Sr). The
// deterministic shape hands a which-one to the executor as a photo intent
// (mediaKind photo), whose clarification carries the intent the way a
// play-after request rides through a chip. Pure fixture, no model.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

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
1 NAME David /Latta/
1 SEX M
1 BIRT
2 DATE 1902
1 DEAT
2 DATE 1980
0 TRLR
"""

@Suite("Photo asks — a which-one name gets chips, and the chip resumes the photo ask")
struct HalliePhotoAskWhichOneTests {
    typealias Q = HallieLineageQuestion
    typealias Exec = HallieTurnExecutor
    let graph = GedcomFamilyGraph(gedcomText: tree)
    var context: Exec.Context {
        .init(profiles: [], graph: graph,
              speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
    }
    private func pre(_ q: String, context: Exec.Context, memory: Exec.ConversationMemory = .init()) -> Exec.PreTranslation {
        Exec.preTranslation(
            question: q, playAfterAnswer: false, memory: memory, isKnownPerson: { _ in false },
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context) })
    }
    private static let nathanielLine =
        "Nathaniel Parker Sr died in 1737, about a century before photography begins in 1838 — there can’t be a photograph of him. "
        + "If the family has a painting, engraving, or gravestone photo, put it in his People folder and I’ll show it."
    private static let whichOne =
        "Which Nathaniel Parker do you mean — Nathaniel Caleb Parker (b. 14 JUL 1760, d. 4 MAR 1826) or Nathaniel Parker Sr (b. 16 MAY 1651, d. 7 DEC 1737)?"

    @Test func theTypoIsStillAPhotoAsk() {
        #expect(Q.detect("are there are photos of nathaniel parker") == .personPhoto(person: "Nathaniel Parker"))
        #expect(Q.detect("is there a picture of david latta") == .personPhoto(person: "David Latta"))
        // Not a photo ask: no lead word at all, or two people (a search).
        #expect(Q.detect("photos of donna") == nil)
        #expect(Q.detect("find photos of me and donna") == nil)
        #expect(Q.detect("are there any photos of rick and donna") == nil)
    }

    @Test func aWhichOneNameBecomesAPhotoIntentWithChipsAndTheChipResumesIt() async throws {
        let context = self.context
        guard case .run(let intent) = pre("are there are photos of Nathaniel Parker", context: context) else {
            Issue.record("the which-one photo ask was not handed to the executor"); return
        }
        #expect(intent.ast == .presence(.init(people: ["Nathaniel Parker"], mediaKind: .photo)))
        #expect(intent.originalQuestion == "are there are photos of Nathaniel Parker")

        let asked = try await Exec.execute(.init(intent: intent), context: context)
        #expect(asked.outcome == .needsClarification)
        #expect(asked.prose == Self.whichOne)
        #expect(asked.citations.isEmpty, "no catalog search")
        let pending = try #require(asked.clarification)
        #expect(pending.candidates.map(\.canonicalName) == ["Nathaniel Caleb Parker", "Nathaniel Parker Sr"])
        #expect(pending.intent == intent, "the PHOTO ask rides through the clarification")

        var memory = Exec.ConversationMemory()
        memory.record(intent: intent, result: asked)
        let resumed = try await Exec.continue(pending: pending, selecting: .gedcomPersonID("@I1@"), context: context)
        #expect(resumed.outcome == .declined)
        #expect(resumed.prose == Self.nathanielLine)
        #expect(resumed.queryDescription == "photo: Nathaniel Parker Sr (before photography)")
        #expect(resumed.basisLine.contains("No search was run"))
        #expect(resumed.offeredActions == [.openFamilyTreePerson(personID: "@I1@", personName: "Nathaniel Parker Sr")])

        // And the conversation now knows who "him" is.
        memory.record(intent: intent, result: resumed)
        #expect(memory.lastSubject == "Nathaniel Parker Sr")
        guard case .answer(let him) = pre("any videos of him", context: context, memory: memory) else {
            Issue.record("the follow-up went to the translator"); return
        }
        #expect(him.queryDescription == "videos: Nathaniel Parker Sr (before motion pictures)")

        // The other chip: a photograph was impossible for him too (d. 1826).
        let caleb = try await Exec.continue(pending: pending, selecting: .gedcomPersonID("@I2@"), context: context)
        #expect(caleb.queryDescription == "photo: Nathaniel Caleb Parker (before photography)")
        // A typed reply in words, resolved without a model.
        #expect(Exec.clarificationSelection("the one born in 1651", from: pending.candidates) == .gedcomPersonID("@I1@"))
        #expect(Exec.clarificationSelection("Nathaniel Parker Sr", from: pending.candidates) == .gedcomPersonID("@I1@"))
    }

    @Test func aUniqueNameIsStillAnsweredLocallyWithoutTheExecutor() {
        let context = self.context
        guard case .answer(let r) = pre("are there are photos of Nathaniel Parker Sr", context: context) else {
            Issue.record("a unique name should be answered in place"); return
        }
        #expect(r.prose == Self.nathanielLine)
        guard case .answer(let david) = pre("is there a picture of David Latta", context: context) else {
            Issue.record("a unique name should be answered in place"); return
        }
        #expect(david.queryDescription == "photo: David Latta")
        // Unknown name: the resolver's honest not-found, in place, as before.
        guard case .answer(let nobody) = pre("any photos of Zebulon Nobody", context: context) else {
            Issue.record("an unknown name should be answered in place"); return
        }
        #expect(nobody.outcome == .declined)
        #expect(nobody.clarification == nil)
        // No lineage answerer (no tree loaded): the translator, as before.
        #expect(Exec.preTranslation(question: "any photos of Nathaniel Parker", playAfterAnswer: false,
                                    memory: .init(), isKnownPerson: { _ in false })
                == .translate(question: "any photos of Nathaniel Parker", playAfterAnswer: false))
    }
}
