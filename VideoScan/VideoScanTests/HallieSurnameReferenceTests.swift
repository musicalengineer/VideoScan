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
            "Tell me about David McGill",
            "Who is Rick Breen's father?",
            "Show me videos of the Breen family",
            "Show me the Breen clan at Christmas",
            "Show the family tree for the Hudson family",
            "Find photos of Eileen Latta",
        ] {
            #expect(HallieSurnameReference.answer(question) == nil)
        }
    }

    @Test func tableAnswersOtherSupportedSurnamesWithoutClaimingLineage() throws {
        let cases = [
            ("Where does the Hudson surname come from?", "Hudson", "Middle English", "public.familysearch.hudson"),
            ("What are the origins of the Latta family name?", "Latta", "honesty or loyalty", "public.familysearch.latta"),
            ("What is the McGill surname's Gaelic etymology?", "McGill", "several documented", "public.familysearch.mcgill"),
        ]
        for (question, surname, phrase, firstCitation) in cases {
            let result = try #require(HallieSurnameReference.answer(question))
            #expect(result.prose.contains(phrase))
            #expect(result.basisLine.contains("not a claim about the \(surname) family tree"))
            #expect(result.queryDescription == "public surname history: \(surname)")
            #expect(result.knowledgeCitations.first?.id == firstCitation)
            #expect(result.offeredActions == [.openFamilyTreeSurname(surname)])
        }
        #expect(HallieSurnameReference.supportedSurnames == ["Breen", "Hudson", "Latta", "McGill"])
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
