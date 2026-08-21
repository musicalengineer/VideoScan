import Foundation
import Testing
@testable import VideoScan

/// "Let me tell you about Dad Breen, Rick's dad…" — the pure state machine
/// behind Hallie listening and remembering (Rick, 2026-08-21).
struct HallieTellingModeTests {

    // MARK: - Opening detection

    @Test func theCanonicalOpenerNamesThePersonAndTheRelation() throws {
        let opening = try #require(HallieTellingMode.detectOpening(
            "Let me tell you about Dad Breen, Rick's Dad"))
        #expect(opening.subject == "Dad Breen")
        #expect(opening.relation == "Rick's Dad")
        #expect(opening.pronoun == .he)
        #expect(opening.firstStatement == nil)
    }

    @Test func manyOpenerPhrasingsAreRecognised() throws {
        let phrasings = [
            "I want to tell you about Uncle Bob",
            "can I tell you about Uncle Bob?",
            "Hallie, let me tell you a bit about Uncle Bob.",
            "I'd like to tell you something about Uncle Bob",
            "Here's something about Uncle Bob",
            "I have a story about Uncle Bob",
            "write this down about Uncle Bob",
            "I'm going to tell you all about Uncle Bob",
        ]
        for text in phrasings {
            let opening = HallieTellingMode.detectOpening(text)
            #expect(opening?.subject == "Uncle Bob", Comment(rawValue: text))
            #expect(opening?.pronoun == .he, Comment(rawValue: text))
        }
    }

    @Test func questionsToHallieAreNeverOpeners() {
        for text in [
            "tell me about Donna", "can you tell me about my dad",
            "what do you know about Dad Breen", "who was Dad Breen",
            "tell me about my dad's time in the Marines",
            "show me rick playing guitar", "I told you about Dad Breen already",
        ] {
            #expect(HallieTellingMode.detectOpening(text) == nil, Comment(rawValue: text))
        }
    }

    @Test func aRelationWithoutANameAsksForTheName() throws {
        let opening = try #require(HallieTellingMode.detectOpening("let me tell you about my dad"))
        #expect(opening.subject == nil)
        #expect(opening.relation == "my dad")
        #expect(opening.pronoun == .he)
        var session = HallieTellingMode.Session(opening: opening)
        #expect(session.awaitingName)
        #expect(HallieTellingMode.openingReply(&session, alreadyKnown: false)
                == "Oh, please do — I'd love to hear about my dad. What was his name?")

        let grandmother = try #require(HallieTellingMode.detectOpening(
            "I want to tell you about our great grandmother"))
        #expect(grandmother.subject == nil)
        #expect(grandmother.pronoun == .she)
    }

    @Test func aKinshipWordPlusANameKeepsBoth() throws {
        let opening = try #require(HallieTellingMode.detectOpening("let me tell you about my uncle Bob"))
        #expect(opening.subject == "uncle Bob")
        #expect(opening.relation == "my uncle")
        #expect(opening.pronoun == .he)
    }

    @Test func contentInTheSameBreathBecomesTheFirstStatement() throws {
        let opening = try #require(HallieTellingMode.detectOpening(
            "Let me tell you about Dad Breen. He repaired typewriters for a living."))
        #expect(opening.subject == "Dad Breen")
        #expect(opening.firstStatement == "He repaired typewriters for a living.")
    }

    @Test func pronounsAreNeverGuessedFromANameAlone() throws {
        let opening = try #require(HallieTellingMode.detectOpening("let me tell you about Jordan Breen"))
        #expect(opening.pronoun == .they)
        var session = HallieTellingMode.Session(opening: opening)
        #expect(HallieTellingMode.openingReply(&session, alreadyKnown: false)
                .hasPrefix("Oh, tell me all about Jordan Breen — I'll remember it. Where and when were"))
    }

    // MARK: - Classifying turns while listening

    private func listening(_ opener: String = "let me tell you about Dad Breen, Rick's dad") -> HallieTellingMode.Session {
        HallieTellingMode.Session(opening: HallieTellingMode.detectOpening(opener)!)
    }

    @Test func statementsAreKeptVerbatimAndQuestionsEndTheTelling() {
        let session = listening()
        #expect(HallieTellingMode.classify("He repaired typewriters for a living.", session: session)
                == .statement("He repaired typewriters for a living."))
        #expect(HallieTellingMode.classify("Born in 1927 in Boston", session: session)
                == .statement("Born in 1927 in Boston"))
        for question in ["show me videos of rick", "who was his wife?", "how many videos do we have",
                         "tell me about Donna", "what do you know about him", "help"] {
            #expect(HallieTellingMode.classify(question, session: session) == .question, Comment(rawValue: question))
        }
    }

    @Test func closersAndThanksFinishTheTelling() {
        let session = listening()
        for closer in ["that's all", "That's it for now.", "ok I'm done", "nothing else",
                       "thanks", "thank you", "no", "start over", "I think that's all I remember"] {
            #expect(HallieTellingMode.classify(closer, session: session) == .finish, Comment(rawValue: closer))
        }
    }

    @Test func aNewOpenerSwitchesSubjectButNotForTheSamePerson() throws {
        let session = listening()
        guard case .switchSubject(let opening) = HallieTellingMode.classify(
            "let me tell you about Mom", session: session) else {
            Issue.record("a new person should switch the subject"); return
        }
        #expect(opening.relation == "Mom" || opening.subject == "Mom")
        #expect(HallieTellingMode.classify("I'll tell you about his temper", session: session)
                == .statement("I'll tell you about his temper"))
        #expect(HallieTellingMode.classify("let me tell you more about Dad Breen", session: session)
                == .statement("let me tell you more about Dad Breen"))
    }

    @Test func whileAwaitingANameAShortProperNameIsTheName() {
        let session = listening("let me tell you about my dad")
        #expect(HallieTellingMode.classify("Richard Breen", session: session) == .name("Richard Breen"))
        #expect(HallieTellingMode.classify("His name was Richard.", session: session) == .name("Richard"))
        #expect(HallieTellingMode.classify("everyone called him Dad Breen", session: session) == .name("Dad Breen"))
        #expect(HallieTellingMode.classify("He was born in 1927.", session: session)
                == .statement("He was born in 1927."), "a sentence with a verb is a statement")
    }

    // MARK: - The interview

    @Test func sheAsksAboutWhatHasNotBeenCoveredInStoryCorpsOrder() throws {
        var session = listening()
        #expect(HallieTellingMode.openingReply(&session, alreadyKnown: false)
                == "Oh, tell me all about Dad Breen — I'll remember it. Where and when was he born?")
        #expect(session.askedTopics == [.origins], "the opening question counts as asked")

        session.passages.append("He was born in Boston in 1927.")
        let first = HallieTellingMode.acknowledgement(&session)
        #expect(first == "I've written that down. Who were his parents — and did he have brothers or sisters?")
        #expect(session.askedTopics == [.origins, .family])

        // Work was already covered in what he said, so she skips it.
        session.passages.append("His father was a typewriter repairman and he went into the same work.")
        let second = HallieTellingMode.acknowledgement(&session)
        #expect(second == "Noted — thank you. Who did he marry, and how did they meet?")
        #expect(session.askedTopics == [.origins, .family, .marriage])
    }

    @Test func acknowledgementsVaryAndSheNeverRunsOutOfAGracefulNextStep() {
        var session = listening()
        var replies: [String] = []
        for i in 0..<14 {
            session.passages.append("Fact number \(i).")
            replies.append(HallieTellingMode.acknowledgement(&session))
        }
        #expect(Set(replies.map { $0.components(separatedBy: ". ").first ?? "" }).count >= 4)
        #expect(replies.last?.contains("Anything else you'd like me to keep about him?") == true)
        #expect(session.askedTopics.count == HallieTellingMode.Topic.allCases.count)
    }

    @Test func closingSaysWhatWasKeptAndWhetherItWasSaved() {
        var session = listening()
        #expect(HallieTellingMode.closingReply(session, persisted: true, speaker: "Rick")
                == "All right. Whenever you'd like to tell me about Dad Breen, I'm here.")
        session.passages = ["He was a Marine.", "He fixed typewriters."]
        session.persistedCount = 2
        #expect(HallieTellingMode.closingReply(session, persisted: true, speaker: "Rick")
                == "Thank you. I've kept 2 things you told me about Dad Breen — marked as told by Rick today, to be verified. Ask me about him any time.")
        #expect(HallieTellingMode.closingReply(session, persisted: false, speaker: "Rick")
                .contains("for this session only"))
        var unnamed = listening("let me tell you about my dad")
        unnamed.pendingPassages = ["He was tall."]
        unnamed.passages = ["He was tall."]
        #expect(HallieTellingMode.closingReply(unnamed, persisted: false, speaker: nil)
                .hasPrefix("I didn't catch his name"))
    }
}
