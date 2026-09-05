import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// THE 2026-09-05 DEMO BUG. Hours before the family demo, three questions
/// about HALLIE — the assistant — were answered with the birth and death
/// records of Hallie Mae McGill, the 1876 great-grandmother she is named
/// after (log: `~/Library/Logs/VideoScan/Hallie/hallie-conversation-2026-09-05.jsonl`,
/// sequences 124/150/167):
///
///     Do you ever get tired?
///     Are you a real person or a program?
///     who made you
///     did you serve in the military
///     → "Hallie Mae McGill was born March 1876 … and died 14 January 1908 …"
///        Basis: 'you' = Hallie Mae; imported family tree (GEDCOM).
///
/// Nothing claimed those shapes before translation, so the model made "you"
/// a person, `bindPronouns` bound it to the archivist's name, and the name
/// ladder found "Hallie" in the GEDCOM.
///
/// Three layers are pinned here:
///   1. the pure predicate (`HallieSelfReferenceQuestion`);
///   2. the two lanes it feeds — the existing personaPast boundary and the
///      existing help card — with nothing new written for either;
///   3. the graph SEAM: a `biography` lookup whose only subject came from a
///      bare "you" never returns a GEDCOM record, whatever the translator
///      decided. An explicit NAME still does.
@Suite("Hallie self-reference vs. her namesake")
struct HallieSelfReferenceIdentityTests {

    // MARK: 1. The predicate

    /// Nature, state, feeling, and a life she never had.
    static let natureQuestions = [
        "are you a real person", "Are you a real person or a program?",
        "are you a program", "are you an AI", "are you human",
        "do you ever get tired", "Do you ever get tired?", "do you sleep",
        "how old are you", "are you alive", "do you have feelings",
        "where do you live", "did you serve in the military",
        "are you a robot", "are you just software", "do you get bored",
        "do you dream", "are you a machine", "do you eat",
    ]

    /// Her name and her maker.
    static let originQuestions = [
        "who made you", "who built you", "who created you", "who wrote you",
        "who programmed you", "what should I call you", "what's your name",
        "what is your name", "do you have a name", "what are you called",
    ]

    /// Questions that mean her NAMESAKE, or somebody else entirely. None of
    /// these may ever be claimed as self-reference — the pronoun/name
    /// distinction is the whole point.
    static let notSelfReference = [
        "how am I related to you?", "how are you related to me",
        "tell me about Hallie Mae McGill", "who was Hallie Mae",
        "who is Hallie Mae McGill", "when were you born",
        "where were you born", "who were your parents", "when did you die",
        "who was your husband", "did you have children",
        "show me videos of Donna", "how many videos do we have",
        "who is Rick's dad", "how do you say Latta", "are you sure",
        "what was your mother's job", "were you in any videos from 1994",
    ]

    @Test(arguments: natureQuestions)
    func natureAsksWantTheNoPersonalLifeBoundary(question: String) {
        #expect(HallieSelfReferenceQuestion.detect(question) == .noPersonalLife,
                Comment(rawValue: question))
    }

    @Test(arguments: originQuestions)
    func originAsksWantTheIntroduction(question: String) {
        #expect(HallieSelfReferenceQuestion.detect(question) == .introduction,
                Comment(rawValue: question))
    }

    @Test(arguments: notSelfReference)
    func treeAndArchiveQuestionsAreNeverClaimed(question: String) {
        #expect(HallieSelfReferenceQuestion.detect(question) == nil,
                Comment(rawValue: question))
    }

    // MARK: 2a. Nature asks reach the EXISTING personaPast boundary

    @Test(arguments: natureQuestions)
    func natureAsksRouteToThePersonaPastLane(question: String) {
        let verdict = HallieConversationGuard.generalVerdict(
            question, isKnownPerson: { _ in false })
        #expect(verdict.kind == .personaPast, Comment(rawValue: "\(question) — \(verdict.reason)"))
        // …and the conversation guard must not bounce it back to the
        // archive translator, which is where the GEDCOM record came from.
        #expect(HallieConversationGuard.requiresArchive(
            question, kind: .personaPast, isKnownPerson: { _ in false }) == false,
                Comment(rawValue: question))
    }

    @Test func thePersonaPastLaneAnswersWithTheExistingWordsAndNoRecord() async {
        let reply = await HallieSocialConversation.reply(
            kind: .personaPast, question: "Are you a real person or a program?",
            modelCall: { _, _ in
                Issue.record("the personaPast boundary must never call a model")
                return ""
            })
        #expect(reply.composedByModel == false)
        #expect(reply.text == HallieSocialConversation.noMemoryReply)
        #expect(reply.text.contains("don't have personal memories"))
        let result = HallieSocialConversation.result(for: reply)
        #expect(result.route == .conversation)
        #expect(result.composedBy == .template)
        #expect(result.citations.isEmpty)
        #expect(!result.prose.contains("1908"))
        #expect(!result.prose.contains("McGill was born"))
    }

    // MARK: 2b. Origin asks reach the EXISTING help card

    @Test(arguments: originQuestions)
    func originAsksAnswerWithTheHelpCardBeforeAnyModel(question: String) {
        let pre = HallieTurnExecutor.preTranslation(
            question: question, playAfterAnswer: false, memory: .init(),
            isKnownPerson: { _ in
                Issue.record("a self-reference answer must not consult identity sources")
                return false
            })
        guard case .answer(let result) = pre else {
            Issue.record(Comment(rawValue: "expected a local answer for “\(question)”, got \(pre)"))
            return
        }
        #expect(result.route == .help, Comment(rawValue: question))
        #expect(result.prose == ArchivistConversationCommand.helpCard)
        #expect(result.prose.hasPrefix("Hi — I'm Hallie Mae, the family archivist."))
        #expect(result.citations.isEmpty)
        #expect(!result.prose.contains("1908"))
    }

    /// The answers that already worked on 2026-09-05 and must not move.
    @Test(arguments: [
        ("who are you", HallieTurnExecutor.Route.help),
        ("What can you do?", HallieTurnExecutor.Route.help),
        ("what are you", HallieTurnExecutor.Route.help),
        ("tell me about yourself", HallieTurnExecutor.Route.help),
        ("Can you play a video for me?", HallieTurnExecutor.Route.capability),
    ])
    func theAnswersThatAlreadyWorkedStillDo(question: String, route: HallieTurnExecutor.Route) {
        let pre = HallieTurnExecutor.preTranslation(
            question: question, playAfterAnswer: false, memory: .init(),
            isKnownPerson: { _ in false })
        guard case .answer(let result) = pre else {
            Issue.record(Comment(rawValue: "expected a local answer for “\(question)”, got \(pre)"))
            return
        }
        #expect(result.route == route, Comment(rawValue: question))
    }

    /// The reminiscence guard that ALREADY worked (coordinator's list,
    /// observed live 2026-09-05). The new sibling predicate runs after it
    /// and must not shadow or change it. Only the ones the deterministic
    /// guard claims are listed; the rest are classified by the model and
    /// are outside this unit's reach.
    @Test(arguments: [
        "did you have cars when you were young",
        "what was school like when you were my age",
        "did you have TV growing up",
        "what was your first job",
        "what did you do for fun",
        "were there computers back then",
        "how much did things cost when you were a kid",
        "what was your first car",
        "what was the happiest moment of your life",
        "what chores did you have to do",
    ])
    func theReminiscenceGuardStillClaimsItsOwn(question: String) {
        let verdict = HallieConversationGuard.generalVerdict(
            question, isKnownPerson: { _ in false })
        #expect(verdict.kind == .personaPast, Comment(rawValue: "\(question) — \(verdict.reason)"))
        // Still the reminiscence rule, not the new one.
        #expect(HallieSelfReferenceQuestion.detect(question) == nil, Comment(rawValue: question))
    }

    // MARK: 2c. DETERMINISM — the model is never asked

    /// The bug was intermittent, and this is why it must be: on 2026-09-05
    /// the ollama build on RicksM4.local answers HTTP 501 to structured
    /// output ("structured output is unavailable", 1,549 lines in
    /// videoscan.log), so the turn's SHAPE was decided by unconstrained
    /// generation. The identical question, twice from a cold `:reset`,
    /// classified as `graph` once and `conversation` the next time.
    ///
    /// So a fix that merely hopes the model says "conversation" is not a
    /// fix. This pins the property that makes it deterministic: for every
    /// trigger phrase the pure Swift verdict is non-nil, and both clients
    /// (HallieAppTurnCoordinator ~line 597, HallieShellCLI ~line 1044) read
    /// `if let kind = verdict.kind` and build the interpretation
    /// THEMSELVES — `interpretTurn` is never called. The composer then
    /// short-circuits before its own model call.
    @Test(arguments: natureQuestions)
    func theShapeDecisionNeverReachesTheModel(question: String) async {
        // 1. Swift decides the lane, with no I/O.
        let verdict = HallieConversationGuard.generalVerdict(
            question, isKnownPerson: { _ in false })
        #expect(verdict.kind != nil, Comment(rawValue: "\(question) would fall through to the model"))
        #expect(verdict.kind == .personaPast, Comment(rawValue: "\(question) — \(verdict.reason)"))

        // 2. The composer for that lane returns before any model call.
        let reply = await HallieSocialConversation.reply(
            kind: .personaPast, question: question,
            modelCall: { _, _ in
                Issue.record(Comment(rawValue: "“\(question)” reached the model"))
                return "Hallie Mae McGill was born March 1876 and died 14 January 1908."
            })
        #expect(reply.composedByModel == false, Comment(rawValue: question))
        #expect(reply.text == HallieSocialConversation.noMemoryReply, Comment(rawValue: question))

        // 3. Pure means repeatable: same answer every time, unlike the
        //    unconstrained generation this replaces.
        for _ in 0..<25 {
            #expect(HallieSelfReferenceQuestion.detect(question) == .noPersonalLife,
                    Comment(rawValue: question))
            #expect(HallieConversationGuard.generalVerdict(
                question, isKnownPerson: { _ in false }).kind == .personaPast,
                    Comment(rawValue: question))
        }
    }

    /// The same property for the introduction lane, which is settled even
    /// earlier — before translation, so neither `interpretTurn` nor
    /// `translateAST` is reached.
    @Test(arguments: originQuestions)
    func theIntroductionLaneIsSettledBeforeTranslation(question: String) {
        for _ in 0..<25 {
            guard case .answer(let result) = HallieTurnExecutor.preTranslation(
                question: question, playAfterAnswer: false, memory: .init(),
                isKnownPerson: { _ in false }) else {
                Issue.record(Comment(rawValue: "“\(question)” escaped to the model"))
                return
            }
            #expect(result.route == .help, Comment(rawValue: question))
        }
    }

    // MARK: 3. Isolation — a cold conversation and a warm one

    /// All three live failures happened immediately after `:reset`, so the
    /// cold case is the one that shipped. Both must hold.
    @Test(arguments: natureQuestions + originQuestions)
    func theVerdictIsTheSameWithAndWithoutConversationMemory(question: String) {
        // The poisoned state that matters: the previous answer WAS about
        // her namesake, so "you" has a tempting referent sitting in memory.
        var warm = HallieTurnExecutor.ConversationMemory()
        warm.record(
            intent: HallieTurnExecutor.Intent(
                originalQuestion: "tell me about Hallie Mae McGill",
                ast: .graph(.init(people: ["Hallie May McGill"], operation: .biography))),
            result: HallieTurnExecutor.Result(
                route: .graph, outcome: .answered,
                prose: "Hallie May McGill was born March 1876 and died 14 January 1908.",
                basisLine: "Basis: imported family tree (GEDCOM).",
                queryDescription: "shape=graph operation=biography person=Hallie May McGill",
                citations: [], catalogPersonName: "Hallie May McGill"),
            question: "tell me about Hallie Mae McGill")
        for memory in [HallieTurnExecutor.ConversationMemory(), warm] {
            let pre = HallieTurnExecutor.preTranslation(
                question: question, playAfterAnswer: false, memory: memory,
                isKnownPerson: { _ in true })
            switch HallieSelfReferenceQuestion.detect(question) {
            case .introduction:
                guard case .answer(let result) = pre else {
                    Issue.record(Comment(rawValue: "“\(question)” lost its help answer: \(pre)"))
                    continue
                }
                #expect(result.route == .help, Comment(rawValue: question))
            case .noPersonalLife:
                // Never answered from memory as a person, and never run as
                // a graph lookup on the remembered subject.
                if case .run(let intent) = pre, case .graph = intent.ast {
                    Issue.record(Comment(rawValue: "“\(question)” became a graph lookup: \(intent.ast)"))
                }
                #expect(HallieConversationGuard.generalVerdict(
                    question, isKnownPerson: { _ in true }).kind == .personaPast,
                        Comment(rawValue: question))
            case nil:
                Issue.record(Comment(rawValue: "“\(question)” is no longer self-reference"))
            }
        }
    }
}

/// The graph SEAM, over a synthetic tree (no real family data — 2026-08-03
/// privacy policy). Even if the translator insists a self-referential
/// question is a biography lookup, a bare "you" must not fetch her
/// namesake's record — while her NAME still must.
@MainActor
@Suite("Hallie self-reference — the graph seam", .serialized)
struct HallieSelfReferenceGraphSeamTests {

    /// Rick Breen's great-grandmother is "Hallie May McGill" — the display
    /// name "Hallie Mae" differs from the tree spelling on purpose, which
    /// is Rick's real situation and the reason the name ladder exists.
    private static let familyTree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Hallie May /McGill/
    1 SEX F
    1 BIRT
    2 DATE MAR 1876
    2 PLAC Louisville, Jefferson, Kentucky
    1 DEAT
    2 DATE 14 JAN 1908
    2 PLAC Jefferson, Kentucky
    1 FAMS @F1@
    0 @I2@ INDI
    1 NAME John /Latta/
    1 SEX M
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Grace /Latta/
    1 SEX F
    1 FAMC @F1@
    1 FAMS @F2@
    0 @I5@ INDI
    1 NAME Al /Breen/
    1 SEX M
    1 FAMC @F2@
    1 FAMS @F3@
    0 @I7@ INDI
    1 NAME Mae /Lake/
    1 SEX F
    1 FAMS @F3@
    0 @I8@ INDI
    1 NAME Rick /Breen/
    1 SEX M
    1 FAMC @F3@
    0 @F1@ FAM
    1 HUSB @I2@
    1 WIFE @I1@
    1 CHIL @I3@
    0 @F2@ FAM
    1 WIFE @I3@
    1 CHIL @I5@
    0 @F3@ FAM
    1 HUSB @I5@
    1 WIFE @I7@
    1 CHIL @I8@
    0 TRLR
    """

    private var context: HallieTurnExecutor.Context {
        HallieTurnExecutor.Context(
            profiles: [],
            graph: GedcomFamilyGraph(gedcomText: Self.familyTree),
            cyberBrain: nil,
            speakers: HallieTurnExecutor.Speakers(
                ownerName: "Rick Breen", archivistName: "Hallie Mae"))
    }

    private func biography(_ subject: String, question: String) async throws -> HallieTurnExecutor.Result {
        try await HallieTurnExecutor.execute(
            .init(intent: HallieTurnExecutor.Intent(
                originalQuestion: question,
                ast: .graph(.init(people: [subject], operation: .biography)))),
            context: context)
    }

    /// THE SENSOR. Named for the demo-day failure: "Are you a real person
    /// or a program?" must never come back as a GEDCOM biography, and must
    /// never emit a death date.
    @Test(arguments: ["you", "You", "your", "yourself"])
    func areYouARealPersonOrAProgramNeverReturnsAGedcomBiography(pronoun: String) async throws {
        let result = try await biography(
            pronoun, question: "Are you a real person or a program?")
        #expect(result.route == .conversation, Comment(rawValue: result.prose))
        #expect(result.prose == HallieSocialConversation.noMemoryReply)
        #expect(result.composedBy == .template)
        #expect(result.citations.isEmpty)
        // No record, no vital dates, no namesake.
        #expect(!result.prose.contains("1908"))
        #expect(!result.prose.contains("1876"))
        #expect(!result.prose.lowercased().contains("died"))
        #expect(!result.prose.contains("McGill"))
        #expect(!result.prose.contains("Louisville"))
        // The trail says which reading was taken.
        #expect(result.basisLine.contains("means me, the archivist"))
    }

    /// The other half of the crux: an EXPLICIT name still gets the record.
    @Test(arguments: ["Hallie May McGill", "Hallie Mae", "Hallie"])
    func namingHerNamesakeStillReturnsTheBiography(subject: String) async throws {
        let result = try await biography(
            subject, question: "tell me about \(subject)")
        #expect(result.route == .graph, Comment(rawValue: result.prose))
        #expect(result.outcome == .answered, Comment(rawValue: result.prose))
        #expect(result.prose.contains("1876"), Comment(rawValue: result.prose))
        #expect(result.prose.contains("1908"), Comment(rawValue: result.prose))
    }

    /// "how am I related to you?" is printed on Hallie's own help card.
    /// The seam guard is scoped to `biography`, so this keeps working.
    @Test func howAmIRelatedToYouStillAnswersFromTheTree() async throws {
        let result = try await HallieTurnExecutor.execute(
            .init(intent: HallieTurnExecutor.Intent(
                originalQuestion: "how am I related to you?",
                ast: .graph(.init(people: ["me", "you"], operation: .relationship)))),
            context: context)
        #expect(result.route == .graph, Comment(rawValue: result.prose))
        #expect(result.outcome == .answered, Comment(rawValue: result.prose))
        #expect(result.prose.contains("great-grandmother"), Comment(rawValue: result.prose))
        #expect(result.basisLine.contains("'you' = Hallie Mae"))
    }

    /// Vital-fact questions addressed to "you" are about the namesake and
    /// keep their tree answer — the guard is not a blanket ban on binding.
    @Test(arguments: [ArchivistQueryAST.Graph.Operation.birth,
                      ArchivistQueryAST.Graph.Operation.death])
    func vitalFactsAboutYouStillBindToTheNamesake(
        operation: ArchivistQueryAST.Graph.Operation
    ) async throws {
        let result = try await HallieTurnExecutor.execute(
            .init(intent: HallieTurnExecutor.Intent(
                originalQuestion: "when were you born?",
                ast: .graph(.init(people: ["you"], operation: operation)))),
            context: context)
        #expect(result.route == .graph, Comment(rawValue: result.prose))
        #expect(result.basisLine.contains("'you' = Hallie Mae"))
    }
}


/// The structural proof for the intermittency. The 2026-09-05 ollama build
/// answers HTTP 501 to structured output, so whenever the SHAPE decision
/// reaches the model it is made by unconstrained generation and the same
/// question can classify as `graph` one turn and `conversation` the next.
/// These drive the real coordinator with dependencies that fail the test if
/// the model classifier, the AST translator, or the executor is reached at
/// all — so the answer cannot depend on what any model decided.
@MainActor
@Suite("Hallie self-reference — no model in the loop", .serialized)
struct HallieSelfReferenceNoModelTests {

    private func trippedDependencies() -> HallieAppTurnCoordinator.Dependencies {
        HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { hosts in hosts },
            translateAST: { question, _, _ in
                Issue.record(Comment(rawValue: "translateAST reached for “\(question)”"))
                return .init(ast: .graph(.init(people: ["Hallie Mae"], operation: .biography)),
                             responderHost: "should-not-happen")
            },
            interpretTurn: { question, _, _ in
                Issue.record(Comment(rawValue: "interpretTurn reached for “\(question)”"))
                return .init(value: .archive(.graph(.init(
                    people: ["Hallie Mae"], operation: .biography))),
                    responderHost: "should-not-happen")
            },
            loadProfiles: { [] },
            loadGraph: { nil },
            executeRequest: { request, _ in
                Issue.record(Comment(rawValue: "executeRequest reached with \(request.intent.ast)"))
                return HallieTurnExecutor.Result(
                    route: .graph, outcome: .answered,
                    prose: "Hallie Mae McGill was born March 1876 and died 14 January 1908.",
                    basisLine: "should not happen", queryDescription: nil,
                    citations: [], catalogPersonName: nil)
            },
            continueTurn: { _, _, _ in
                Issue.record("continueTurn reached")
                throw CancellationError()
            },
            resolveBiographyPhoto: { _ in nil })
    }

    @Test(arguments: HallieSelfReferenceIdentityTests.natureQuestions
          + HallieSelfReferenceIdentityTests.originQuestions)
    func noSelfReferenceTurnConsultsAModel(question: String) async throws {
        let response = try await HallieAppTurnCoordinator.execute(
            question: question,
            records: [],
            referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["should-not-be-used.invalid"],
            modelName: "should-not-be-used",
            dependencies: trippedDependencies())
        // Whatever lane claimed it, the answer carries no GEDCOM record.
        #expect(response.result.route != .graph, Comment(rawValue: question))
        #expect(response.result.citations.isEmpty, Comment(rawValue: question))
        #expect(!response.result.prose.contains("1908"), Comment(rawValue: response.result.prose))
        #expect(!response.result.prose.contains("1876"), Comment(rawValue: response.result.prose))
        // (The help card legitimately mentions McGill as a PRONUNCIATION
        // example — "pronounce McGill like MahGill" — so the test looks for
        // the biography sentence and the vital dates, not the surname.)
        #expect(!response.result.prose.contains("McGill was born"),
                Comment(rawValue: response.result.prose))
        #expect(!response.result.prose.lowercased().contains(" died "),
                Comment(rawValue: response.result.prose))
        #expect(response.result.route == .help || response.result.route == .conversation,
                Comment(rawValue: "\(question) → \(response.result.route)"))
    }

    /// The contrast, on the same tripwires: a question that genuinely NEEDS
    /// the tree still goes to the model. If this ever stops reaching
    /// `interpretTurn`, the guard above has grown too wide.
    @Test(arguments: ["who was Hallie Mae", "tell me about Hallie Mae McGill"])
    func namingHerNamesakeStillGoesToTheArchiveLane(question: String) async throws {
        var reached = false
        let dependencies = HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { hosts in hosts },
            translateAST: { _, _, _ in
                .init(ast: .graph(.init(people: ["Hallie Mae"], operation: .biography)),
                      responderHost: "fixture-host")
            },
            loadProfiles: { [] },
            loadGraph: { nil },
            executeRequest: { request, _ in
                reached = true
                #expect(request.intent.ast == .graph(.init(
                    people: ["Hallie Mae"], operation: .biography)))
                return HallieTurnExecutor.Result(
                    route: .graph, outcome: .answered,
                    prose: "Hallie Mae McGill was born March 1876.",
                    basisLine: "fixture", queryDescription: nil,
                    citations: [], catalogPersonName: "Hallie Mae McGill")
            },
            continueTurn: { _, _, _ in throw CancellationError() },
            resolveBiographyPhoto: { _ in nil })
        _ = try await HallieAppTurnCoordinator.execute(
            question: question, records: [],
            referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            dependencies: dependencies)
        #expect(reached, Comment(rawValue: "“\(question)” never reached the archive lane"))
    }
}
