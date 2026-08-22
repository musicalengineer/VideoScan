import Foundation
import Testing
@testable import VideoScan

/// "Where did that come from?" is answered from the last answer's own
/// trail — route, basis line, citations, family knowledge — never by the
/// model (overnight cycle 1, 2026-08-21).
struct HallieProvenanceFollowUpTests {
    typealias P = HallieProvenanceFollowUp

    @Test func detectsSourceAndConfidenceQuestionsOnly() {
        for text in ["Where did that come from?", "how do you know that", "What's your source?",
                     "Which records support that?", "is that from the family tree or the catalog",
                     "Hallie, where did that come from exactly?", "who told you that"] {
            #expect(P.detect(text) == .source, Comment(rawValue: text))
        }
        // The interaction corpus's own phrasings (cycle 1): a lead plus a
        // back-referencing object.
        for text in ["Which records support that biography?", "Where did that come from?",
                     "What is that based on?", "is that from the family tree or the catalog?"] {
            #expect(P.detect(text) == .source, Comment(rawValue: text))
        }
        for text in ["How certain are you about that date?", "how sure are you about that count",
                     "Are you sure about that?"] {
            #expect(P.detect(text) == .confidence, Comment(rawValue: text))
        }
        for text in ["How sure are you?", "are you certain", "is that verified?", "Really?",
                     "how do you know for sure"] {
            #expect(P.detect(text) == .confidence, Comment(rawValue: text))
        }
        for text in ["where did Donna grow up", "how do you know Donna", "show me the source tape",
                     "what is the source of the Connecticut river", "tell me about my dad",
                     "which records support Donna's claim to the cottage", "are you sure Donna was there"] {
            #expect(P.detect(text) == nil, Comment(rawValue: text))
        }
    }

    private func presenceResult() -> HallieTurnExecutor.Result {
        .init(route: .presence, outcome: .answered,
              prose: "I found 7 catalog items matching that.",
              basisLine: "Basis: 2 cited of 7 matching catalog items.",
              queryDescription: "shape=presence person=Donna",
              citations: [
                .init(recordID: UUID(), fullPath: "/v/a.mov", filename: "Cape_1993.mov", playbackSeconds: nil,
                      bases: [.humanPersonTag(queryIdentity: "donna", taggedName: "Donna", confirmedAt: Date())]),
                .init(recordID: UUID(), fullPath: "/v/b.mov", filename: "Cape_1995.mov", playbackSeconds: nil, bases: []),
              ],
              catalogPersonName: "Donna", matchCount: 7, composedBy: .model)
    }

    @Test func sourceAnswerNamesTheCatalogTheTrailAndTheCitedFiles() {
        var memory = HallieTurnExecutor.ConversationMemory()
        let intent = HallieTurnExecutor.Intent(originalQuestion: "show me donna at the cape",
                                               ast: .presence(.init(people: ["Donna"])))
        memory.record(intent: intent, result: presenceResult())
        let answer = P.answer(.source, provenance: memory.lastProvenance)
        #expect(answer.route == .followUp)
        #expect(answer.outcome == .answered)
        #expect(answer.prose == "That came from the video catalog — the people tags on those files were confirmed by a person, not guessed. "
                + "The trail: 2 cited of 7 matching catalog items. "
                + "I cited 2 of 7 matching items: Cape_1993.mov, Cape_1995.mov. "
                + "The wording was phrased by the local model, but every sentence was checked against those facts before I showed it.")
    }

    @Test func confidenceAnswerIsHonestAboutUnverifiedFamilyKnowledge() {
        var memory = HallieTurnExecutor.ConversationMemory()
        let graph = HallieTurnExecutor.Result(
            route: .graph, outcome: .answered,
            prose: "The family tree doesn't record any children for Richard Harding Breen Jr. But Rick Breen told me (not yet verified): “Rick and Donna have four adult sons.”",
            basisLine: "Basis: GEDCOM; Family knowledge: told.rick.1.",
            queryDescription: "shape=graph", citations: [],
            knowledgeCitations: [.init(id: "s1", title: "Told to Hallie by Rick, 2026-08-21", attribution: "Rick", locator: nil)],
            catalogPersonName: nil)
        memory.record(intent: .init(originalQuestion: "who are rick's sons", ast: .graph(.init(people: ["Rick"], operation: .kinship, relation: .children))),
                      result: graph)
        let answer = P.answer(.confidence, provenance: memory.lastProvenance)
        #expect(answer.prose.hasPrefix("That came from the family tree together with what the family has told me."))
        #expect(answer.prose.contains("Family knowledge: Told to Hallie by Rick, 2026-08-21 (Rick)."))
        #expect(answer.prose.contains("marked not yet verified, so treat it as a recollection, not a record."))
    }

    @Test func noPriorAnswerSaysSoAndAFollowUpDoesNotClobberTheListMemory() {
        let fresh = P.answer(.source, provenance: nil)
        #expect(fresh.prose.hasPrefix("Ask me something first"))

        var memory = HallieTurnExecutor.ConversationMemory()
        let intent = HallieTurnExecutor.Intent(originalQuestion: "show me donna", ast: .presence(.init(people: ["Donna"])))
        memory.record(intent: intent, result: presenceResult())
        // The provenance turn itself is a follow-up with no AST: memory keeps the list.
        let pre = HallieTurnExecutor.preTranslation(
            question: "where did that come from?", playAfterAnswer: false,
            memory: memory, isKnownPerson: { _ in false })
        guard case .answer(let result) = pre else { Issue.record("should answer locally"); return }
        #expect(result.queryDescription == "provenance")
        memory.record(intent: nil, result: result)
        #expect(memory.lastResultSet?.citations.count == 2, "\"play the first one\" still works afterwards")
        #expect(memory.lastProvenance?.route == .presence)
    }
}
