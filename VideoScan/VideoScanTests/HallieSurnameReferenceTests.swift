import Testing
@testable import VideoScan

@Suite("Hallie sourced surname reference")
struct HallieSurnameReferenceTests {
    @Test func answersBreenHeritageQuestionsWithQualifiedSources() throws {
        for question in [
            "What is the origin of the Breen surname?",
            "Is Breen an O'Brien clan name?",
            "What does the Irish name Breen mean?",
            "Where are the Breens from?",
        ] {
            let result = try #require(HallieSurnameReference.answer(question))
            #expect(result.route == .conversation)
            #expect(result.outcome == .answered)
            #expect(result.prose.contains("Ó Braoin"))
            #expect(result.prose.contains("does not establish descent"))
            #expect(result.knowledgeCitations.count == 2)
            #expect(result.basisLine.contains("not a claim about the Breen family tree"))
        }
    }

    @Test func personAndCatalogQuestionsAreNotHijacked() {
        for question in [
            "Tell me about Rick Breen",
            "Who is Rick Breen's father?",
            "Show me videos of the Breen family",
            "Show me the Breen clan at Christmas",
        ] {
            #expect(HallieSurnameReference.answer(question) == nil)
        }
    }

    @Test func preTranslationReturnsTheSourcedAnswerWithoutAModelCall() throws {
        let pre = HallieTurnExecutor.preTranslation(
            question: "Where does the Breen last name come from?",
            playAfterAnswer: false,
            memory: .init(),
            isKnownPerson: { _ in false })
        guard case .answer(let result) = pre else {
            Issue.record("surname history should answer before translation")
            return
        }
        #expect(result.queryDescription == "public surname history: Breen")
        #expect(result.knowledgeCitations.map(\.id) == [
            "public.woulfe.o-braoin",
            "public.familysearch.breen",
        ])
    }
}
