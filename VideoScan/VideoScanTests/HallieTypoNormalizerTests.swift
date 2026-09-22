// HallieTypoNormalizerTests.swift
// The typo front door (Rick 2026-09-21: "Hallie gets unnerved when I have
// typos which I frequently do… My users will be making typos and we
// can't have Hallie freaking out").
//
// LIVE MISS 2026-09-21 18:52 (app): "Hi Hallie how areyou?" → mode
// unknown → translator → `catalog shape=presence keyword=hi keyword=how
// are you` → "687 videos matched: 25 shown where someone says “hi”…".
//
// Five dimensions:
//   LOGIC     — the rewrite table, names untouched, quotes untouched, the
//               log line; ≥40 typo'd sentences route like their clean
//               forms; the live miss end-to-end through the coordinator
//               AND the shell.
//   SCALE     — 10k sentences inside a time budget.
//   ISOLATION — the name oracle is injected; a clean sentence never asks
//               it; a poisoned oracle (everything is a name) rewrites
//               nothing.
//   SENSOR    — the live-miss sentence, and "a name is never corrected"
//               over every one-slip neighbour of the vocabulary.
// The typo-variant generator is in HallieTypoVariantGeneratorTests.swift.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Shared fixtures

/// The fixture family: first names one slip from a vocabulary word or a
/// split part, plus two tree surnames that ARE one slip from vocabulary
/// words ("Moher" ← "mother", "Wen" ← "when"). Injected; nothing is read
/// from App Support.
enum HallieTypoFixture {
    static let people: Set<String> = [
        "donna", "tim", "dan", "ma", "libby", "anna", "mark", "matt", "rick",
        "latta", "moher", "wen", "breen", "donna breen", "rick breen",
    ]
    static let isKnownPerson: (String) -> Bool = { people.contains($0.lowercased()) }
    static let nobody: (String) -> Bool = { _ in false }

    /// The routing decision a turn gets BEFORE any model: the front door,
    /// the request-opener repair, the pre-translation lanes with the mode
    /// verdict, and — for a turn that would be translated — the general
    /// lane's deterministic verdict. `frontDoor: false` is the pre-fix
    /// pipeline, for the before/after pass rate.
    static func route(_ question: String, frontDoor: Bool = true,
                      isKnownPerson: @escaping (String) -> Bool = isKnownPerson) -> String {
        let routed = frontDoor
            ? HallieFrontDoor.prepare(question, isProtectedName: isKnownPerson).routingText
            : question
        let text = HallieSpellingRecovery.repairRequestOpener(routed).text
        let classified = HallieTurnExecutor.preTranslationClassified(
            question: text, playAfterAnswer: false, memory: .init(),
            isKnownPerson: isKnownPerson, isInnerCircleName: isKnownPerson)
        let mode = classified.verdict.mode.rawValue
        switch classified.decision {
        case .answer(let result):
            // The fixed replies (small talk, help, capability, reset) must
            // match word for word — digits out, the clock is in the date
            // and time replies. Other local answers echo the typed words
            // ("I don't find Napoleon…"), so only their route counts.
            let fixed: Set<HallieTurnExecutor.Route> = [.smalltalk, .help, .capability, .reset]
            let prose = fixed.contains(result.route)
                ? String(result.prose.filter { !$0.isNumber }.prefix(48)) : ""
            return "answer:\(HallieTurnExecutor.label(result.route)):\(prose)"
        case .run(let intent):
            var label = "run:\(HallieTurnExecutor.description(of: intent.ast))"
            if case .graph(let graph) = intent.ast {
                label += ":\(graph.operation.rawValue):\(graph.people.map { $0.lowercased() }.sorted())"
            }
            return label + ":mode=\(mode)"
        case .translate(let effective, let play):
            let verdict = HallieConversationGuard.generalVerdict(
                effective, isKnownPerson: isKnownPerson, isInnerCircleName: isKnownPerson)
            let lane = verdict.kind.map { "general:\($0.rawValue)" } ?? "model"
            return "translate:\(lane):play=\(play):mode=\(mode)"
        }
    }
}

// MARK: - LOGIC: the normalizer itself

@Suite("Hallie typo normalizer: what it reads")
struct HallieTypoNormalizerTests {
    typealias Norm = HallieTypoNormalizer

    private func read(_ text: String, names: (String) -> Bool = HallieTypoFixture.isKnownPerson) -> String {
        Norm.normalize(text, isProtectedName: names).text
    }

    @Test(arguments: [
        ("Hi Hallie how areyou?", "Hi Hallie how are you?"),
        ("howare u", "how are you"),
        ("how r u", "how are you"),
        ("thankyou hallie", "thank you hallie"),
        ("Thankyou!", "Thank you!"),
        ("helllo", "hello"),
        ("hiii", "hi"),
        ("sooo cool", "so cool"),
        ("whos donnas mom", "who's donna's mom"),
        ("who is Tims brother", "who is Tim's brother"),
        ("when was Donnaborn", "when was Donna born"),
        ("who isDonna", "who is Donna"),
        ("wehre was donna born", "where was donna born"),
        ("Thansk, that's helpful", "Thanks, that's helpful"),
        ("sho me donna", "show me donna"),
        ("the Breens family", "the Breens family"),
        ("shwo me vidoes of donna", "show me videos of donna"),
        ("wat year was ma born", "what year was ma born"),
        ("tel me about ma", "tell me about ma"),
        ("im good", "I'm good"),
        ("ur welcome", "you're welcome"),
        ("whats ur name", "what's your name"),
        ("pls show me vids of tim", "please show me videos of tim"),
        ("thx", "thanks"),
        ("whowas donna's father", "who was donna's father"),
        ("tellme about libby", "tell me about libby"),
        ("dont know", "don't know"),
        ("AREYOU there", "ARE YOU there"),
        ("whn was tim brn", "when was tim born"),
        ("who maried donna", "who married donna"),
        ("merry Chrismas", "merry Christmas"),
    ] as [(String, String)])
    func readsTheTypoAsItsWords(typed: String, expected: String) {
        #expect(read(typed) == expected, Comment(rawValue: typed))
    }

    /// Clean sentences pass through byte for byte — punctuation, case,
    /// curly quotes and all.
    @Test(arguments: [
        "Hi Hallie how are you?",
        "show me Donna down the cape in the early 90s",
        "who was Donna’s mother?",
        "I'm fine, thanks.",
        "Tell me about Thankful Pratt",
        "what happened when someone said surprise?",
        "It's pouring rain here in the Berkshires today.",
        "how is Tim related to Rick?",
        "videos from 1994",
        "",
        "?",
    ])
    func aCleanSentenceIsUntouched(text: String) {
        let result = Norm.normalize(text, isProtectedName: HallieTypoFixture.isKnownPerson)
        #expect(result.text == text)
        #expect(!result.changed)
        #expect(result.logLine == nil)
    }

    /// Everyday words one slip from a command word are real words, not
    /// slips: "fine" is not "find", "hour" is not "your", "snow" is not
    /// "show", "now" is not "how".
    @Test(arguments: ["I'm fine", "an hour ago", "snow at the cape", "now what", "the shoe box",
                      "four years", "a cold day", "dear Donna", "we were there", "tall trees",
                      "my kind of day", "it was free", "the lost tape"])
    func aRealWordIsNotASlip(text: String) {
        #expect(read(text) == text, Comment(rawValue: text))
    }

    /// Names are never corrected, lower-case or not, even one slip from a
    /// vocabulary word — the built-in given names and the injected tree
    /// surnames alike.
    @Test(arguments: [
        "videos of dan and tim", "tell me about ma", "show libby", "anna at the beach",
        "mark and matt", "donna", "Dan", "Tim", "Ma", "Libby", "Anna", "Mark", "Matt",
        "the moher family", "who was wen", "harry at christmas", "barry and larry",
        "tell me about rick breen", "the breen family", "edward iii", "who is in Christmas.mov",
    ])
    func aNameIsNeverCorrected(text: String) {
        #expect(read(text) == text, Comment(rawValue: text))
    }

    /// The injected oracle is what protects a tree surname: with nobody
    /// known, "moher" IS read as "mother".
    @Test func theInjectedOracleProtectsTreeSurnames() {
        #expect(read("the moher family", names: HallieTypoFixture.nobody) == "the mother family")
        #expect(read("the moher family") == "the moher family")
        #expect(read("wen was tim born", names: HallieTypoFixture.nobody) == "when was tim born")
        #expect(read("wen was tim born") == "wen was tim born")
    }

    /// A capitalised word mid-sentence is a typed name; a quoted phrase is
    /// the person's own words; digits and apostrophes are left alone.
    @Test func typedNamesQuotesAndDigitsAreLeftAlone() {
        #expect(read("videos of Shwo") == "videos of Shwo")
        #expect(read("videos where someone says \"shwo me\"") == "videos where someone says \"shwo me\"")
        #expect(read("videos where someone says “areyou”") == "videos where someone says “areyou”")
        #expect(read("vidoes from 199o") == "videos from 199o")
        #expect(read("John R Smith") == "John R Smith")
        #expect(read("Hi8 tapes") == "Hi8 tapes")
    }

    /// Two-letter tokens are never slip-corrected; "hwo" (how or who?) is
    /// ambiguous and left alone.
    @Test func shortAndAmbiguousTokensAreLeftAlone() {
        #expect(read("hw old is donna") == "hw old is donna")
        #expect(read("hwo is donna") == "hwo is donna")
    }

    @Test func theLogLineNamesOnlyTheCorrections() {
        let result = Norm.normalize("Hi Hallie how areyou?")
        #expect(result.logLine == "[hallie-typo] read “areyou” as “are you”")
        let two = Norm.normalize("shwo me vidoes")
        #expect(two.logLine == "[hallie-typo] read “shwo” as “show”, “vidoes” as “videos”")
    }

    @Test func keyboardNeighbours() {
        #expect(Norm.areKeyboardNeighbours("e", "d"))
        #expect(Norm.areKeyboardNeighbours("n", "m"))
        #expect(Norm.areKeyboardNeighbours("h", "y"))
        #expect(!Norm.areKeyboardNeighbours("h", "m"))
        #expect(!Norm.areKeyboardNeighbours("a", "o"))
        #expect(Norm.isOneSlip("shwo", "show"))
        #expect(Norm.isOneSlip("fnd", "find"))
        #expect(Norm.isOneSlip("vidoes", "videos"))
        #expect(!Norm.isOneSlip("harry", "marry"))
    }
}

// MARK: - LOGIC: the greeting peel

@Suite("Hallie greeting peel")
struct HallieGreetingPeelTests {
    @Test(arguments: [
        ("Hi Hallie, who was Donna's mother?", "who was Donna's mother?", "Hi Hallie,"),
        ("hello hallie mae what year was ma born", "what year was ma born", "hello hallie mae"),
        ("good morning! show me videos of tim", "show me videos of tim", "good morning!"),
        ("hey, how old is donna", "how old is donna", "hey,"),
        ("Hi there. when was rick born?", "when was rick born?", "Hi there."),
    ] as [(String, String, String)])
    func aLeadingGreetingIsSetAside(text: String, rest: String, greeting: String) {
        let peeled = HallieGreetingPeel.peel(text)
        #expect(peeled?.rest == rest, Comment(rawValue: text))
        #expect(peeled?.greeting == greeting, Comment(rawValue: text))
    }

    /// Whole small talk stays whole (the table answers it); one word left
    /// is not a request; a greeting word glued to another is not a greeting.
    @Test(arguments: ["hi hallie", "Hi Hallie how are you?", "hello", "good morning hallie",
                      "hello Donna", "hi-8 tapes of donna", "morning at the cape",
                      "show me hi", "who said hello to donna"])
    func notAGreetingPlusRequest(text: String) {
        #expect(HallieGreetingPeel.peel(text) == nil, Comment(rawValue: text))
    }

    @Test func theFrontDoorLogsBothPasses() {
        let door = HallieFrontDoor.prepare("helllo hallie, shwo me donna")
        #expect(door.routingText == "show me donna")
        #expect(door.logLines == [
            "[hallie-typo] read “helllo” as “hello”, “shwo” as “show”",
            "[hallie-greeting] set aside “hello hallie,”",
        ])
        #expect(door.original == "helllo hallie, shwo me donna")
    }
}

// MARK: - LOGIC: the social shape backstop

@Suite("Hallie social shape guard: nothing left to search for")
struct HallieSocialShapeEmptyKeywordTests {
    typealias Guard = HallieSocialShapeGuard
    private let nobody = HallieTypoFixture.nobody

    @Test(arguments: [
        ("hi, how are you", ArchivistQueryAST.presence(.init(keywords: ["hi", "how are you"]))),
        ("hi how are you doing today", .presence(.init(keywords: ["how are you doing today"]))),
        ("hello there how is it going", .event(.init(keywords: ["hello"], transcript: ["how is it going"]))),
        ("whats up", .presence(.init(keywords: ["what's up"]))),
    ] as [(String, ArchivistQueryAST)])
    func onlySmallTalkToSearchForIsConversation(question: String, ast: ArchivistQueryAST) {
        let verdict = Guard.verdict(question: question, ast: ast, isKnownPerson: nobody, isInnerCircleName: nobody)
        #expect(verdict?.kind == .casual, Comment(rawValue: question))
    }

    /// A sentence with a word of its own stays a search.
    @Test(arguments: [
        ("when did someone say hi", ArchivistQueryAST.presence(.init(keywords: ["hi"]))),
        ("hi at the cape", .presence(.init(keywords: ["hi", "cape"]))),
        ("hello dolly", .presence(.init(keywords: ["hello dolly"]))),
    ] as [(String, ArchivistQueryAST)])
    func aWordOfItsOwnStaysASearch(question: String, ast: ArchivistQueryAST) {
        #expect(Guard.verdict(question: question, ast: ast, isKnownPerson: nobody, isInnerCircleName: nobody) == nil,
                Comment(rawValue: question))
    }
}

// MARK: - LOGIC: typo'd sentences route like their clean forms

/// ≥40 pairs: a clean sentence and the way a retiree might type it.
let hallieTypoRoutingPairs: [(clean: String, typed: String)] = [
    ("Hi Hallie how are you?", "Hi Hallie how areyou?"),
    ("how are you", "howare u"),
    ("how are you", "how r u"),
    ("how are you", "howru"),
    ("thank you hallie", "thankyou hallie"),
    ("thank you", "thanku"),
    ("hello", "helllo"),
    ("hi", "hiii"),
    ("hi hallie", "hii hallie"),
    ("thanks", "thx"),
    ("thanks", "thanksss"),
    ("thanks hallie", "thnks hallie"),
    ("good morning", "goodmorning"),
    ("hello there", "hellothere"),
    ("I'm good", "im good"),
    ("I'm doing well thanks", "im doing well thx"),
    ("you're welcome", "ur welcome"),
    ("you're the best", "youre the best"),
    ("how's your day going", "hows ur day going"),
    ("bye", "byee"),
    ("what's the date", "whats the date"),
    ("what time is it", "wat time is it"),
    ("what can you do", "wat can u do"),
    ("who are you", "who r u"),
    ("who's donna's mom", "whos donnas mom"),
    ("show me videos of donna", "shwo me vidoes of donna"),
    ("please show me videos of tim", "pls show me vids of tim"),
    ("find videos of matt", "fnid videos of matt"),
    ("show me pictures of anna", "show me picutres of anna"),
    ("what year was ma born", "wat year was ma born"),
    ("tell me about ma", "tel me about ma"),
    ("tell me about libby", "tellme about libby"),
    ("who was donna's mother", "who was donna's mohter"),
    ("who was donna's father", "who was donna's fahter"),
    ("who was mark's grandfather", "who was mark's grandfahter"),
    ("how old is donna", "howold is donna"),
    ("how many videos are there", "howmany vidoes are there"),
    ("who is rick's brother", "whois rick's brother"),
    ("where was donna born", "wehre was donna born"),
    ("when was tim born", "when was tim brn"),
    ("who married donna", "who maried donna"),
    ("show me the family tree", "show me the famly tree"),
    ("show donna's family tree", "show donna's famliy tree"),
    ("tell me about the latta family", "tell me abot the latta family"),
    ("who was donna's mother", "Hi Hallie, who was donna's mother"),
    ("what year was ma born", "hello hallie what year was ma born"),
]

@Suite("Hallie typo routing: a typo'd sentence routes like its clean form")
struct HallieTypoRoutingTests {
    @Test func thereAreAtLeastFortyPairs() {
        #expect(hallieTypoRoutingPairs.count >= 40)
    }

    @Test(arguments: hallieTypoRoutingPairs.map { [$0.clean, $0.typed] })
    func routesLikeTheCleanForm(pair: [String]) {
        let clean = HallieTypoFixture.route(pair[0])
        let typed = HallieTypoFixture.route(pair[1])
        #expect(typed == clean, Comment(rawValue: "“\(pair[1])” → \(typed)\n“\(pair[0])” → \(clean)"))
    }

    /// The social ones are answered before any model, whatever was typed.
    @Test(arguments: ["Hi Hallie how areyou?", "howare u", "thankyou hallie", "helllo", "hiii", "im good"])
    func socialTyposAreAnsweredBeforeTheModel(typed: String) {
        #expect(HallieTypoFixture.route(typed).hasPrefix("answer:smalltalk"),
                Comment(rawValue: HallieTypoFixture.route(typed)))
    }
}

// MARK: - LOGIC + SENSOR: the live miss end-to-end

/// The AST the translator returned in the live miss.
let hallieLiveMissAST = ArchivistQueryAST.presence(.init(keywords: ["hi", "how are you"]))
let hallieLiveMissSentence = "Hi Hallie how areyou?"

@Suite("Hallie typo live miss: coordinator", .serialized)
struct HallieTypoLiveMissCoordinatorTests {
    typealias Exec = HallieTurnExecutor

    private final class Recorder: @unchecked Sendable {
        var asts: [ArchivistQueryAST] = []
        var translated: [String] = []
    }

    private func dependencies(_ recorder: Recorder, ast: ArchivistQueryAST = hallieLiveMissAST)
        -> HallieAppTurnCoordinator.Dependencies {
        HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { hosts in hosts },
            translateAST: { question, _, _ in
                recorder.translated.append(question)
                return .init(ast: ast, responderHost: "fixture-host")
            },
            loadProfiles: { [] },
            loadGraph: { nil },
            loadCyberBrain: { nil },
            loadSpeakers: { .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil) },
            executeRequest: { request, context in
                recorder.asts.append(request.intent.ast)
                return try await Exec.execute(request, context: context)
            },
            continueTurn: { clarification, selectedID, context in
                try await Exec.continue(pending: clarification, selecting: selectedID, context: context)
            },
            resolveBiographyPhoto: { _ in nil })
    }

    private func run(_ question: String, _ recorder: Recorder, ast: ArchivistQueryAST = hallieLiveMissAST)
        async throws -> (HallieAppTurnCoordinator.Response, [String]) {
        let sink = InMemoryLogSink(name: "hallie-typo")
        let previous = appLog
        appLog = sink
        defer { appLog = previous }
        let response = try await HallieAppTurnCoordinator.execute(
            question: question, records: [],
            referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            dependencies: dependencies(recorder, ast: ast))
        return (response, sink.lines)
    }

    /// THE SENSOR: the live-miss sentence is small talk, answered before
    /// any model; nothing is searched; one `[hallie-typo]` line is logged.
    @Test func theLiveMissIsSmallTalkNotASearch() async throws {
        let recorder = Recorder()
        let (response, lines) = try await run(hallieLiveMissSentence, recorder)
        #expect(recorder.asts.isEmpty, Comment(rawValue: "\(recorder.asts)"))
        #expect(recorder.translated.isEmpty, Comment(rawValue: "\(recorder.translated)"))
        #expect(response.result.route == .smalltalk, Comment(rawValue: response.result.prose))
        #expect(response.result.prose.hasPrefix("I'm doing well"), Comment(rawValue: response.result.prose))
        #expect(!response.result.prose.contains("where someone says"))
        #expect(lines.contains("[hallie-typo] read “areyou” as “are you”"), Comment(rawValue: lines.joined(separator: "\n")))
    }

    /// Even if a typo got past the front door, the social backstop keeps a
    /// greeting-and-small-talk search out of the catalog.
    @Test func theBackstopCatchesGreetingOnlyKeywords() async throws {
        let recorder = Recorder()
        let (response, lines) = try await run("hi hallie how is it going", recorder,
                                              ast: .presence(.init(keywords: ["hi", "how is it going"])))
        #expect(recorder.asts.isEmpty, Comment(rawValue: "\(recorder.asts) \(lines)"))
        #expect(response.result.route == .conversation || response.result.route == .smalltalk,
                Comment(rawValue: "\(response.result.route) \(response.result.prose)"))
        #expect(!response.result.prose.contains("where someone says"))
    }

    /// A greeting leading a real question is never a search keyword: the
    /// translator sees the question without it.
    @Test func aLeadingGreetingNeverReachesTheTranslator() async throws {
        let recorder = Recorder()
        let ast = ArchivistQueryAST.presence(.init(keywords: ["cape"]))
        let (_, lines) = try await run("Hi Hallie, show me the cape at sunset", recorder, ast: ast)
        #expect(recorder.translated == ["show me the cape at sunset"], Comment(rawValue: "\(recorder.translated)"))
        #expect(lines.contains("[hallie-greeting] set aside “Hi Hallie,”"), Comment(rawValue: lines.joined(separator: "\n")))
        #expect(!recorder.asts.contains { HallieSocialShapeGuard.searchTerms($0).contains("hi") })
    }

}

// MARK: - ISOLATION

@Suite("Hallie typo isolation: the name oracle is injected and asked lazily")
struct HallieTypoIsolationTests {
    private final class Asked: @unchecked Sendable { var names: [String] = [] }

    /// A clean sentence never asks the oracle — the app loads identity
    /// files behind it, so a clean turn reads nothing for the front door.
    @Test(arguments: ["Hi Hallie how are you?", "show me Donna down the cape in the early 90s",
                      "who was Donna's mother?", "thanks"])
    func aCleanSentenceNeverAsksTheOracle(text: String) {
        let asked = Asked()
        _ = HallieFrontDoor.prepare(text) { asked.names.append($0); return false }
        #expect(asked.names.isEmpty, Comment(rawValue: "\(asked.names)"))
    }

    /// The oracle is asked about exactly the tokens it might protect.
    @Test func theOracleIsAskedOnlyAboutRewriteCandidates() {
        let asked = Asked()
        _ = HallieFrontDoor.prepare("shwo me vidoes of Donna") { asked.names.append($0); return false }
        #expect(asked.names == ["shwo", "vidoes"])
    }
}

@Suite("Hallie typo live miss: shell")
struct HallieTypoLiveMissShellTests {
    @Test func theLiveMissIsSmallTalkInTheShell() async throws {
        let harness = HallieShellCLITests.Harness(translations: [hallieLiveMissAST])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", hallieLiveMissSentence, "--diagnostics",
        ])
        let code = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())
        let output = harness.output.joined(separator: "\n")
        #expect(harness.translatedQuestions.isEmpty, Comment(rawValue: output))
        #expect(!output.contains("shape=presence"), Comment(rawValue: output))
        #expect(!output.contains("where someone says"), Comment(rawValue: output))
        #expect(output.contains("I'm doing well"), Comment(rawValue: output))
        #expect(output.contains("[hallie-typo] read “areyou” as “are you”"), Comment(rawValue: output))
        // The transcript keeps what was typed.
        #expect(harness.transcriptEvents.contains { $0.kind == .user && $0.text == hallieLiveMissSentence },
                Comment(rawValue: "\(harness.transcriptEvents.map(\.text))"))
        #expect(code == 0)
    }

    @Test func aLeadingGreetingNeverReachesTheShellTranslator() async throws {
        let harness = HallieShellCLITests.Harness(translations: [.presence(.init(keywords: ["cape"]))])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", "hello hallie, shwo me the cape at sunset",
        ])
        _ = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())
        #expect(harness.translatedQuestions == ["show me the cape at sunset"],
                Comment(rawValue: "\(harness.translatedQuestions)"))
    }
}

// MARK: - SENSOR: names are never corrected

@Suite("Hallie typo sensor: names are never corrected")
struct HallieTypoNameSensorTests {
    typealias Norm = HallieTypoNormalizer

    /// Every one-slip neighbour of every vocabulary word that is a
    /// built-in protected name stays exactly as typed — with NO oracle.
    @Test func noBuiltinNameIsEverRewritten() {
        var rewritten: [String] = []
        for name in Norm.builtinProtectedNames {
            for form in [name, name.capitalized] {
                for sentence in [form, "videos of \(form)", "tell me about \(form)", "\(form) at the cape"] {
                    let result = Norm.normalize(sentence)
                    if result.changed { rewritten.append("\(sentence) → \(result.text)") }
                }
            }
        }
        #expect(rewritten.isEmpty, Comment(rawValue: rewritten.joined(separator: "\n")))
    }

    /// Any word the oracle calls a name is left alone, whatever table it
    /// would otherwise match — a poisoned oracle (everything is a name)
    /// makes the normalizer a no-op.
    @Test(arguments: ["areyou", "shwo me vidoes", "helllo", "whowas donna", "pls thx", "how r u"])
    func whatTheOracleCallsANameIsNeverRewritten(text: String) {
        let result = Norm.normalize(text, isProtectedName: { _ in true })
        // "u" / "r" are single letters and not names in any tree, but a
        // poisoned oracle still wins.
        #expect(!result.changed, Comment(rawValue: result.text))
    }

    @Test func theLiveMissSentenceIsPinned() {
        #expect(HallieTypoNormalizer.normalize(hallieLiveMissSentence).text == "Hi Hallie how are you?")
        #expect(ArchivistConversationCommand.detect(
            HallieFrontDoor.prepare(hallieLiveMissSentence).routingText) == .smalltalk(.wellbeing))
    }
}

// MARK: - SCALE

@Suite("Hallie typo scale: 10k sentences")
struct HallieTypoScaleTests {
    @Test func tenThousandSentencesInsideTheBudget() {
        let base = hallieTypoRoutingPairs.flatMap { [$0.clean, $0.typed] }
        let sentences = (0..<10_000).map { base[$0 % base.count] + (($0 % 7 == 0) ? " please" : "") }
        let clock = ContinuousClock()
        var changed = 0
        let elapsed = clock.measure {
            for sentence in sentences where HallieTypoNormalizer.normalize(
                sentence, isProtectedName: HallieTypoFixture.isKnownPerson).changed {
                changed += 1
            }
        }
        #expect(changed > 0)
        // Debug build; measured well under a second on the M4 Max. The
        // budget leaves room for a loaded CI machine.
        #expect(elapsed < .seconds(5), Comment(rawValue: "\(elapsed)"))
    }
}
