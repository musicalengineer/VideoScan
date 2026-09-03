import Foundation
import Testing
@testable import VideoScan

/// Help / small talk / reset are whole-message commands answered locally
/// (Rick 2026-08-17, "family members will use this"). Positive matrix, the
/// negatives that must still be real questions, and the results the
/// pre-translation step hands back for them. No model, no I/O.
@Suite("Family Archivist conversation commands")
struct ArchivistConversationCommandTests {
    typealias Command = ArchivistConversationCommand

    @Test(arguments: [
        "help", "Help!", "?", "??", "help me", "hallie help", "help please",
        "what can you do", "What can you do?", "what can I ask", "what can i ask you about",
        "what do you know", "commands", "examples", "show me some examples",
        "how do I ask you things?", "how do i use this", "how does this work",
        "what kinds of questions can i ask", "what should I ask?", "who are you",
        "what kind of things can you help me with", "can you help me",
        "i don't know what to ask", "what now?",
    ])
    func helpPhrasesShowTheHelpCard(text: String) {
        #expect(Command.detect(text) == .help(), Comment(rawValue: text))
    }

    @Test(arguments: [
        ("thanks", Command.Smalltalk.thanks), ("Thank you!", .thanks),
        ("thanks so much hallie", .thanks), ("thx", .thanks), ("perfect, thanks", .thanks),
        ("hi", .greeting), ("Hello", .greeting), ("hey hallie", .greeting),
        ("good morning", .greeting), ("Good morning Hallie", .greeting),
        ("good evening", .greeting), ("how are you?", .wellbeing),
        ("Hi Hallie, how are you today?", .wellbeing),
        ("how re you hallie?", .wellbeing), ("how r you?", .wellbeing),
        ("I'm good", .userDoingWell), ("I had a rough day", .userHavingHardTime),
        ("I'm doing well, thanks.", .userDoingWell),
        ("I'm a little tired today.", .userHavingHardTime),
        ("It's nice to talk with you.", .companionship),
        ("Thanks, that's kind of you.", .thanks),
        ("Thank you for helping me.", .thanks),
        ("That was helpful.", .affirmation),
        ("Okay, that makes sense.", .understanding),
        ("You're welcome.", .userWelcome),
        ("Is it morning or afternoon?", .timeOfDay),
        ("I'll talk with you later.", .farewell),
        ("what is the date?", .date), ("what is the daye?", .date),
        ("what time is it?", .time),
        ("bye", .farewell), ("goodbye", .farewell), ("good night", .farewell),
        ("that's all for now", .farewell),
        ("great", .affirmation), ("wonderful!", .affirmation), ("nice work", .affirmation),
    ])
    func smalltalkGetsAFriendlyReply(text: String, kind: Command.Smalltalk) {
        #expect(Command.detect(text) == .smalltalk(kind), Comment(rawValue: text))
        #expect(!Command.smalltalkReply(kind).isEmpty)
    }

    // Eval 2026-09-01 (smalltalk 8 misses): everyday thanks, apologies,
    // "hold on" and goodbyes are social lines, not presence searches.
    @Test(arguments: [
        ("Thanks, that's really helpful.", Command.Smalltalk.thanks),
        ("I appreciate you.", .thanks),
        ("really appreciate your time hallie", .thanks),
        ("sorry, thanks anyway", .thanks),
        ("Sorry, I meant something else.", .apology),
        ("My apologies, I keep typing the wrong name.", .apology),
        ("oops, my bad", .apology),
        ("hold on a sec", .holdOn),
        ("one moment please", .holdOn),
        ("hang on, be right back", .holdOn),
        ("brb", .holdOn),
        ("ok gotta run, talk later", .farewell),
        ("Have a good night.", .farewell),
        ("see ya", .farewell),
        ("thanks, talk to you later", .farewell),
        ("take care hallie", .farewell),
        // Weather asides (eval sm022 / sm023 / sm024, verbatim): answered
        // here so the model never turns "Berkshires" into a catalog search
        // (full eval on d3725558: route=presence, 5 videos).
        ("It's pouring rain here in the Berkshires today.", .weather),
        ("beautiful day out isn't it", .weather),
        ("Supposed to snow tonight. First one of the year.", .weather),
        ("hallie, it's snowing up in Vermont again", .weather),
        ("raining again", .weather),
        ("such a gorgeous morning", .weather),
    ])
    func everydaySocialLinesGetAFriendlyReply(text: String, kind: Command.Smalltalk) {
        #expect(Command.detect(text) == .smalltalk(kind), Comment(rawValue: text))
        #expect(!Command.smalltalkReply(kind).isEmpty)
    }

    @Test(arguments: [
        "sorry, who was donna's mother?",
        "sorry, I meant Timmy",
        "hold on, show me the second one",
        "thanks for the videos",
        "one moment, what year was that",
        "that was terrible lol",
        "gotta go find the 1994 tape",
        "thanks, now play the first one",
        // Weather words inside a family fact, a question, or a search are
        // not an aside: an unlisted word, a possessive, a digit, a "?", or
        // a name with no preposition rejects the line.
        "it rained on our wedding day",
        "it snowed at Donna's wedding",
        "did it snow in 1994",
        "is it raining in the Berkshires?",
        "show me the snow video",
        "the 1994 snow storm",
        "Tim is cold",
        "snow",
        "it was cold the winter we moved to Westford",
    ])
    func socialLinesWithRealContentStayOnThePipeline(text: String) {
        #expect(Command.detect(text) == nil, Comment(rawValue: text))
    }

    @Test func apologyAndHoldOnRepliesInviteAnotherTry() {
        #expect(Command.smalltalkReply(.apology).contains("No need to apologize"))
        #expect(Command.smalltalkReply(.holdOn).contains("Take your time"))
    }

    @Test func localDateAndTimeRepliesUseTheSuppliedClock() throws {
        let instant = Date(timeIntervalSince1970: 1_787_328_000) // 2026-08-21 16:00Z
        let zone = try #require(TimeZone(secondsFromGMT: -4 * 60 * 60))
        #expect(Command.smalltalkReply(.date, now: instant, timeZone: zone)
            == "Today is Friday, August 21, 2026.")
        #expect(Command.smalltalkReply(.time, now: instant, timeZone: zone)
            == "It's 12:00 PM.")
        #expect(Command.smalltalkReply(.timeOfDay, now: instant, timeZone: zone)
            == "It's afternoon.")
    }

    @Test func yourselfAsksAreTheArchivistNotHerNamesake() {
        // Live 8/25: "tell me about yourself" answered as Hallie May McGill
        // (b. 1876) — the ancestor, not the archivist.
        for text in ["tell me about yourself", "Tell me about yourself, Hallie",
                     "describe yourself", "introduce yourself"] {
            #expect(ArchivistConversationCommand.detect(text) != nil, Comment(rawValue: text))
        }
        #expect(ArchivistConversationCommand.detect("tell me about Hallie May McGill") == nil)
    }

    @Test func conversationalAcknowledgementsMatchWhatThePersonSaid() {
        #expect(Command.smalltalkReply(.companionship)
            == "It's nice to talk with you too. What would you like to talk about?")
        #expect(Command.smalltalkReply(.userWelcome)
            == "Thank you. What would you like to talk about next?")
        #expect(Command.smalltalkReply(.understanding)
            == "Good. We can keep going whenever you're ready.")
    }

    @Test(arguments: [
        "start over", "Start over.", "new question", "forget that", "reset",
        "never mind", "nevermind", "clear", "let's start over", "scratch that",
        "start again", "forget it", "ok start over",
    ])
    func resetPhrasesClearTheConversation(text: String) {
        #expect(Command.detect(text) == .reset, Comment(rawValue: text))
    }

    @Test(arguments: [
        "help me find donna",
        "what do you know about donna",
        "what can you tell me about thankful pratt",
        "who is rick's dad?",
        "how old was timmy in 1998?",
        "how many videos of matt do we have?",
        "show me videos of donna down the cape in the 90s",
        "thanks, now show me rick",
        "hello donna",
        "good morning videos",
        "start over with rick",
        "playing guitar",
        "in westford",
        "around 2005",
        "with donna",
        "matt?",
        "play the first one",
        "show more",
        "can we change donna's biography?",
        "reset donna's birthday",
    ])
    func realContentIsNeverACommand(text: String) {
        #expect(Command.detect(text) == nil, Comment(rawValue: text))
    }

    @Test func helpCardListsFamilyLanguageExamplesByKind() {
        let card = Command.helpCard
        for example in [
            "show me videos of Donna down the Cape in the 90s",
            "Christmas videos from 2006",
            "show Timmy as a baby saying peekaboo",
            "how many videos of Matt do we have?",
            "who is Rick's dad?",
            "who was Donna's great grandmother on her maternal side?",
            "show Donna's family tree",
            "tell me about Thankful Pratt",
            "play the first one", "show more", "reveal that one",
            "show it in the catalog", "and in the 90s?", "start over",
            // Names and the tree (2026-08-29): the drill, teaching, asking,
            // kinship, centering, research.
            "let's practice names", "pronounce McGill like MahGill or MicGill", "how do you say Latta",
            "how is Tim related to Rick?", "how is Rick related to everyone in the People tab?",
            "center the family tree on Martha Lamson", "what do we know about David Latta from research?",
        ] {
            #expect(card.contains(example), Comment(rawValue: example))
        }
        for heading in ["Videos", "Family", "Names and the tree", "Follow-ups", "Housekeeping"] {
            #expect(card.contains(heading), Comment(rawValue: heading))
        }
        #expect(Command.helpExamples.count == 3)
    }

    // Topic-scoped help (Rick 2026-08-29 17:50): "help with pronunciation"
    // reached the social-lane model. Deterministic now: the matching
    // section only; an unknown topic gets the whole card; "help me find
    // donna" stays a search (realContentIsNeverACommand).
    @Test func helpWithATopicShowsThatSectionOnlyAndNeverTheModel() throws {
        #expect(Command.detect("help") == .help())
        #expect(Command.detect("help with pronunciation") == .help(topic: .names))
        #expect(Command.detect("help with names") == .help(topic: .names))
        #expect(Command.detect("Hallie, help me with pronunciations please") == .help(topic: .names))
        #expect(Command.detect("pronunciation help") == .help(topic: .names))
        #expect(Command.detect("how do I teach you names") == .help(topic: .names))
        #expect(Command.detect("how do i practice names") == .help(topic: .names))
        #expect(Command.detect("help with relationships") == .help(topic: .relationships))
        #expect(Command.detect("help with the family tree") == .help(topic: .tree))
        #expect(Command.detect("how do I research someone") == .help(topic: .research))
        #expect(Command.detect("help with cooking") == .help())
        // A pronunciation question about a name is not help.
        #expect(Command.detect("how do you pronounce Latta") == nil)
        #expect(Command.detect("how do you say Latta?") == nil)

        let names = Command.helpSection(.names)
        for line in ["let's practice names", "pronounce McGill like MahGill or MicGill", "how do you say Latta?",
                     "either MahGill or MicGill", "Latta should be pronounced with a short a on the La"] {
            #expect(names.contains(line), Comment(rawValue: line))
        }
        #expect(!names.contains("Christmas videos"))
        #expect(Command.helpSection(.relationships).contains("how is Tim related to Rick?"))
        #expect(Command.helpSection(.tree).contains("center the family tree on Martha Lamson"))
        #expect(Command.helpSection(.research).contains("what do we know about David Latta from research?"))

        guard case .answer(let scoped) = pre("help with pronunciation") else {
            Issue.record("help with pronunciation should answer locally"); return
        }
        #expect(scoped.route == .help)
        #expect(scoped.prose == Command.helpSection(.names))
        #expect(scoped.basisLine.contains("no model call"))
        #expect(scoped.offeredActions.map(HallieTurnExecutor.offerLabel) == ["Try: let's practice names", "Try: how do you say Latta?"])
        guard case .answer(let whole) = pre("help with names") else { Issue.record("help with names"); return }
        #expect(whole.prose == Command.helpSection(.names))
        guard case .answer(let full) = pre("help") else { Issue.record("help"); return }
        #expect(full.prose == Command.helpCard)
    }

    // MARK: Through the pre-translation step

    private func pre(_ text: String,
                     memory: HallieTurnExecutor.ConversationMemory = .init()
    ) -> HallieTurnExecutor.PreTranslation {
        HallieTurnExecutor.preTranslation(
            question: text, playAfterAnswer: false, memory: memory,
            isKnownPerson: { _ in false })
    }

    @Test func helpAnswersLocallyWithOfferChipsAndRoute() throws {
        guard case .answer(let result) = pre("help") else {
            Issue.record("help should answer locally"); return
        }
        #expect(result.route == .help)
        #expect(HallieTurnExecutor.label(result.route) == "help")
        #expect(result.outcome == .answered)
        #expect(result.prose == Command.helpCard)
        #expect(result.basisLine.contains("no model call"))
        #expect(result.offeredActions.map(HallieTurnExecutor.offerLabel) == [
            "Try: videos of Donna down the Cape in the 90s",
            "Try: who is Rick's dad?",
            "Try: show Donna's family tree",
        ])
        #expect(result.citations.isEmpty)
        #expect(result.mediaAction == nil)
    }

    @Test func smalltalkAndResetAnswerLocallyAndAreNeverDeclines() throws {
        guard case .answer(let thanks) = pre("thanks!") else {
            Issue.record("thanks should answer locally"); return
        }
        #expect(thanks.route == .smalltalk)
        #expect(thanks.outcome == .answered)
        #expect(HallieTurnExecutor.label(thanks.route) == "smalltalk")

        guard case .answer(let reset) = pre("start over") else {
            Issue.record("start over should answer locally"); return
        }
        #expect(reset.route == .reset)
        #expect(reset.outcome == .answered)
        #expect(HallieTurnExecutor.label(reset.route) == "reset")
        #expect(reset.prose == Command.resetReply)
    }

    @Test func compoundGreetingNeverReachesTheEvidencePipeline() throws {
        guard case .answer(let result) = pre("Hi Hallie, how are you today?") else {
            Issue.record("compound greeting must answer locally"); return
        }
        #expect(result.route == .smalltalk)
        #expect(result.outcome == .answered)
        #expect(result.citations.isEmpty)
        #expect(result.basisLine.contains("no model call"))
    }

    /// Live 8/25: "How hallie, how are you?" ("How" for "Hi") produced the
    /// 1876 Hallie's biography. Naming Hallie + an exact small-talk clause
    /// is a greeting; the same shapes without her name or without a
    /// small-talk clause stay on the query path.
    @Test func mistypedSalutationAddressedToHallieIsSmalltalk() {
        #expect(ArchivistConversationCommand.detect("How hallie, how are you?") == .smalltalk(.wellbeing))
        #expect(ArchivistConversationCommand.detect("Hallie! good morning") == .smalltalk(.greeting))
        #expect(ArchivistConversationCommand.detect("Hey Hallie, how are you doing?") == .smalltalk(.wellbeing))
        #expect(ArchivistConversationCommand.detect("Donna, how are you?") == nil)
        #expect(ArchivistConversationCommand.detect("Hallie, how old is Donna?") == nil)
        #expect(ArchivistConversationCommand.detect("tell me about hallie") == nil,
                "asking ABOUT Hallie by name is still the namesake question")
    }

    @Test func resetClearsConversationMemory() throws {
        var memory = HallieTurnExecutor.ConversationMemory()
        let ast = ArchivistQueryAST.presence(.init(people: ["donna"]))
        let intent = HallieTurnExecutor.Intent(originalQuestion: "donna", ast: ast)
        memory.record(intent: intent, result: .init(
            route: .presence, outcome: .answered, prose: "I found 1 catalog item matching that.",
            basisLine: "Basis: 1 cited of 1 matching catalog items.",
            queryDescription: nil, citations: [], catalogPersonName: nil, matchCount: 1))
        #expect(memory.lastAST == ast)
        #expect(memory.followUpSnapshot?.chain?.description == "donna")

        // Help and small talk leave memory alone.
        guard case .answer(let help) = pre("help", memory: memory) else {
            Issue.record("help"); return
        }
        memory.record(intent: nil, result: help)
        #expect(memory.lastAST == ast)

        guard case .answer(let reset) = pre("start over", memory: memory) else {
            Issue.record("start over"); return
        }
        memory.record(intent: nil, result: reset)
        #expect(memory.lastAST == nil)
        #expect(memory.followUpSnapshot == nil)
        #expect(memory == HallieTurnExecutor.ConversationMemory())
    }

    @Test func capabilityQuestionsWinOverHowToHelp() {
        // "how do i change …" is a capability question, not a how-to.
        guard case .answer(let result) = pre("how do i change donna's biography?") else {
            Issue.record("capability"); return
        }
        #expect(result.route == .capability)
    }
}
