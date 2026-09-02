import Foundation
import Testing
@testable import VideoScan

/// "can we change donna's biography?" is a question about Hallie's powers,
/// not a biography lookup (Hallie log 2026-08-17). These pin the pure
/// classifier: what counts as a capability question, what does not, and the
/// exact honest answer with its offered next step.
@Suite("Family Archivist capability questions")
struct ArchivistCapabilityQuestionTests {

    @Test(arguments: [
        "can we change donna's biography?",
        "Can you edit Donna's biography",
        "could we update rick's birth date?",
        "how do i correct the spelling of timmy's name",
        "please add a note that donna loves the cape",
        "can you remember that donna's favorite place is the cape?",
        "will you remember this",
        "can you learn new facts about the family?",
        "is it possible to fix a date in the family tree?",
        "let's add matt's biography",
        "i'd like to update the biography for donna",
        "change donna's biography",
        "delete rick's biography",
    ])
    func editAndLearnRequestsAreCapabilityQuestions(text: String) {
        guard case .editKnowledge = ArchivistCapabilityQuestion.detect(text) else {
            Issue.record("\(text): expected editKnowledge, got \(String(describing: ArchivistCapabilityQuestion.detect(text)))")
            return
        }
    }

    @Test func theSubjectIsExtractedWhenTheSentenceNamesOne() {
        #expect(ArchivistCapabilityQuestion.detect("can we change donna's biography?")
                == .editKnowledge(subject: "Donna"))
        #expect(ArchivistCapabilityQuestion.detect("could you update the biography for rick")
                == .editKnowledge(subject: "Rick"))
        #expect(ArchivistCapabilityQuestion.detect("can you remember things?")
                == .editKnowledge(subject: nil))
    }

    @Test(arguments: [
        ("can you delete this video?", "delete"),
        ("could you email the first clip to matt", "email"),
        ("please export those files", "export"),
        ("upload it to the cloud", "upload"),
    ])
    func mediaMutationsAreUnsupportedActions(text: String, verb: String) {
        #expect(ArchivistCapabilityQuestion.detect(text) == .unsupportedMediaAction(verb: verb), Comment(rawValue: text))
    }

    @Test(arguments: [
        "who is donna?",
        "tell me about donna",
        "show donna's family tree",
        "can you show me donna in 1994?",
        "can you find timmy as a baby",
        "could you play the first one",
        "count how many videos of donna we have?",
        "who was donna's great grandmother on her maternal side?",
        "how old was timmy here?",
        "when was rick born?",
        "what about matt?",
        "and in the 90s?",
        "show more",
        "play one of them, say the first one",
        "how many videos of donna do we have?",
        "can we see the family tree",
        "get me the family tree for the breens",
    ])
    func questionsAboutTheArchiveAreNotCapabilityQuestions(text: String) {
        #expect(ArchivistCapabilityQuestion.detect(text) == nil, Comment(rawValue: text))
    }

    // Eval ic009 / ic015 (2026-09-01): "Can you play a video for me?" was
    // searched for the word "me"; "Can you help me find things in the
    // archive, or just tell me about them?" declined for lack of a search
    // term. Both are questions about her powers, answered yes.
    @Test(arguments: [
        "Can you play a video for me?",
        "can you show me a video?",
        "could you play something for me",
        "can you play videos",
        "are you able to show me some videos from the archive?",
        "can you pull up a clip for me",
    ])
    func contentFreePlaybackAsksAreCapabilityQuestions(text: String) {
        #expect(ArchivistCapabilityQuestion.detect(text) == .playback, Comment(rawValue: text))
    }

    @Test(arguments: [
        "Can you help me find things in the archive, or just tell me about them?",
        "can you help me find things?",
        "can you search the archive for me",
        "could you help me look through the videos",
        "can you find things in our family videos?",
    ])
    func contentFreeSearchAsksAreCapabilityQuestions(text: String) {
        #expect(ArchivistCapabilityQuestion.detect(text) == .searchHelp, Comment(rawValue: text))
    }

    @Test(arguments: [
        "can you play the first one",
        "could you play the first one",
        "can you show me donna in 1994?",
        "can you find timmy as a baby",
        "can you help me find Donna",
        "can you play the Cape video",
        "play a video",
        "show me a video",
        "can you show me the family tree",
    ])
    func asksWithContentStayRequests(text: String) {
        let detected = ArchivistCapabilityQuestion.detect(text)
        #expect(detected != .playback && detected != .searchHelp, Comment(rawValue: "\(text): \(String(describing: detected))"))
    }

    @Test func playbackAndSearchHelpAnswerYesWithOneExampleAsk() {
        let play = HallieTurnExecutor.capabilityResult(.playback)
        #expect(play.route == .capability)
        #expect(play.outcome == .answered)
        #expect(play.prose.hasPrefix("Yes — "))
        #expect(play.prose.contains("“play Donna at Christmas”"))
        #expect(play.citations.isEmpty)
        #expect(play.mediaAction == nil)
        #expect(play.offeredActions == [
            .ask(question: "play Donna at Christmas", label: "Play Donna at Christmas"),
        ])
        #expect(play.basisLine.contains("no catalog query"))

        let help = HallieTurnExecutor.capabilityResult(.searchHelp)
        #expect(help.outcome == .answered)
        #expect(help.prose.hasPrefix("Both."))
        #expect(help.prose.contains("by person, year or decade, place"))
        #expect(help.prose.contains("tell you about the family"))
        #expect(help.citations.isEmpty)

        // Through pre-translation: no model, no identity lookups, no search.
        let pre = HallieTurnExecutor.preTranslation(
            question: "Can you play a video for me?",
            playAfterAnswer: false,
            memory: .init(),
            isKnownPerson: { _ in
                Issue.record("capability answers must not consult identity sources")
                return false
            })
        guard case .answer(let result) = pre else {
            Issue.record("expected a local answer, got \(pre)")
            return
        }
        #expect(result.queryDescription == "capability playback")
    }

    @Test func theHonestAnswerNamesTheRoadmapAndOffersWhatExists() {
        let result = HallieTurnExecutor.capabilityResult(.editKnowledge(subject: "Donna"))
        #expect(result.route == .capability)
        #expect(result.outcome == .unsupported)
        #expect(result.prose == "I can't edit biographies or family facts yet — Rick maintains "
                + "the family knowledge (CyberBrain) by hand today; interviewing and edits "
                + "through me are on the roadmap. Want me to show what I currently have for Donna instead?")
        #expect(result.offeredActions == [
            .ask(question: "who is Donna?", label: "Show what I have for Donna"),
        ])
        #expect(result.citations.isEmpty)
        #expect(result.mediaAction == nil)
        #expect(result.basisLine.contains("no model call"))

        let action = HallieTurnExecutor.capabilityResult(.unsupportedMediaAction(verb: "delete"))
        #expect(action.outcome == .unsupported)
        #expect(action.prose.hasPrefix("Not yet — I can't delete media files"))
        #expect(action.prose.contains("What I can do:"))
    }

    @Test func preTranslationAnswersCapabilityBeforeAnyModelOrEvidence() {
        let pre = HallieTurnExecutor.preTranslation(
            question: "can we change donna's biography?",
            playAfterAnswer: false,
            memory: .init(),
            isKnownPerson: { _ in
                Issue.record("capability answers must not consult identity sources")
                return false
            })
        guard case .answer(let result) = pre else {
            Issue.record("expected a local answer, got \(pre)")
            return
        }
        #expect(result.route == .capability)
    }
}
