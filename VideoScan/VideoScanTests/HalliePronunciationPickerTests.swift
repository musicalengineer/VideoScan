import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// The variations picker (Rick 2026-08-29): the reply classifier, the
/// request detector, the chip flow through the chat coordinator (offer →
/// hear → pick by click / number → stored → read-back; none → next page →
/// exhausted), the drill's bare "no", an unmappable hint, shell parity by
/// number, and persistence through the lexicon file and the drill store.
@MainActor
@Suite("Hallie pronunciation picker", .serialized)
struct HalliePronunciationPickerTests {

    // MARK: - Fixtures

    private static let profiles: [HallieTurnExecutor.ProfileSnapshot] = [
        .init(stableID: "rick", canonicalName: "Rick Breen"),
        .init(stableID: "donna", canonicalName: "Donna Foley"),
    ]
    private static let speakers = HallieTurnExecutor.Speakers(ownerName: "Rick Breen", archivistName: "Hallie Mae")
    /// The voice's table: Latta already has the shipped respelling.
    private static let lexicon = HalliePronunciationLexicon(entries: [.init(written: "Latta", spoken: "LAT-uh")])

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [HallieAppTurnCoordinator.PronunciationWrite] = []
        private var manifests: [PronunciationDrillManifest] = []
        var store = PronunciationDrillStore()
        var failWith: String?
        var gold = MisakiGoldLexicon(url: nil)
        func append(_ value: HallieAppTurnCoordinator.PronunciationWrite) { lock.withLock { storage.append(value) } }
        var writes: [HallieAppTurnCoordinator.PronunciationWrite] { lock.withLock { storage } }
        func save(_ s: PronunciationDrillStore, _ m: PronunciationDrillManifest) { lock.withLock { store = s; manifests.append(m) } }
        var lastManifest: PronunciationDrillManifest? { lock.withLock { manifests.last } }
        var taughtLexicon: HalliePronunciationLexicon {
            .merged([HalliePronunciationLexicon(entries: writes.map { .init(written: $0.word, spoken: $0.saidAs, phonemes: $0.phonemes, origin: $0.origin) }),
                     HalliePronunciationPickerTests.lexicon])
        }
    }

    private final class DependencyProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Set<String> = []
        func hit(_ name: String) { lock.withLock { _ = storage.insert(name) } }
        var hits: Set<String> { lock.withLock { storage } }
    }

    private func dependencies(_ recorder: Recorder) -> HallieAppTurnCoordinator.Dependencies {
        HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { $0 },
            translateAST: { _, _, _ in
                Issue.record("translation must not run in the picker")
                throw NLTranslatorError.unreachable("fixture")
            },
            loadProfiles: { Self.profiles },
            loadGraph: { nil },
            loadCyberBrain: { nil },
            recordPronunciation: { write in
                if let failWith = recorder.failWith { throw CyberBrainWriter.WriteError.ioFailure(failWith) }
                recorder.append(write)
            },
            loadDrillStore: { recorder.store },
            saveDrillStore: { store, manifest in recorder.save(store, manifest) },
            loadLexicon: { recorder.taughtLexicon },
            loadPronunciationGold: { recorder.gold },
            loadSpeakers: { Self.speakers },
            executeRequest: { _, _ in
                Issue.record("no catalog query in the picker")
                throw NLTranslatorError.unreachable("fixture")
            },
            continueTurn: { _, _, _ in throw NLTranslatorError.unreachable("fixture") },
            resolveBiographyPhoto: { _ in nil })
    }

    private func turn(_ question: String, picker: HalliePronunciationPicker.Offer?,
                      drill: HalliePronunciationDrillMode.Session? = nil,
                      recorder: Recorder) async throws -> HallieAppTurnCoordinator.Response {
        try await HallieAppTurnCoordinator.execute(
            question: question, records: [],
            referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            drill: drill, picker: picker,
            dependencies: dependencies(recorder))
    }

    private static let noGold = MisakiGoldLexicon(url: nil)

    private func goldFixture(_ table: [String: String]) throws -> (MisakiGoldLexicon, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("picker-gold-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: table).write(to: url)
        return (MisakiGoldLexicon(url: url), url)
    }

    private func preservationDependencies(
        _ probe: DependencyProbe,
        gold: MisakiGoldLexicon,
        ast: ArchivistQueryAST,
        result: HallieTurnExecutor.Result
    ) -> HallieAppTurnCoordinator.Dependencies {
        HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { _ in probe.hit("startLocalBrain"); return ["brain"] },
            translateAST: { _, _, _ in
                probe.hit("translateAST")
                return .init(ast: ast, responderHost: "translation")
            },
            interpretTurn: { _, _, _ in
                probe.hit("interpretTurn")
                return .init(value: .archive(ast), responderHost: "interpretation")
            },
            composeConversation: { _, _, _, _, _ in
                probe.hit("composeConversation")
                return .init(
                    value: .init(text: "social", composedByModel: false, note: "probe"),
                    responderHost: "conversation")
            },
            loadProfiles: {
                probe.hit("loadProfiles")
                return [.init(stableID: "probe", canonicalName: "Probe Person")]
            },
            loadGraph: { probe.hit("loadGraph"); return nil },
            loadNeedsRecompile: {
                probe.hit("loadNeedsRecompile")
                return [URL(fileURLWithPath: "/probe/needs-recompile")]
            },
            loadCyberBrain: { probe.hit("loadCyberBrain"); return nil },
            recordTestimony: { _ in probe.hit("recordTestimony") },
            recordPhotoCaption: { _ in probe.hit("recordPhotoCaption") },
            recordPronunciation: { _ in probe.hit("recordPronunciation") },
            loadDrillStore: { probe.hit("loadDrillStore"); return .init() },
            saveDrillStore: { _, _ in probe.hit("saveDrillStore") },
            loadLexicon: {
                probe.hit("loadLexicon")
                return .init(entries: [.init(written: "Probe", spoken: "PROBE")])
            },
            loadPronunciationGold: { probe.hit("loadPronunciationGold"); return gold },
            excludePhoto: { _, _, _, _ in probe.hit("excludePhoto") },
            loadSpeakers: {
                probe.hit("originalSpeakers")
                return .init(ownerName: "Wrong", archivistName: "Wrong")
            },
            executeRequest: { _, _ in probe.hit("executeRequest"); return result },
            continueTurn: { _, _, _ in probe.hit("continueTurn"); return result },
            resolveBiographyPhoto: { _ in probe.hit("resolveBiographyPhoto"); return nil },
            composeAnswer: { plan, _, _, _ in
                probe.hit("composeAnswer")
                return .template(plan, note: "probe")
            })
    }

    private static var lattaOffer: HalliePronunciationPicker.Offer {
        HalliePronunciationPicker.makeOffer(word: "Latta", gold: noGold)!
    }

    // MARK: - 1. Classifier and detectors

    @Test func replyClassifierMatrix() {
        typealias P = HalliePronunciationPicker
        let offer = Self.lattaOffer
        #expect(offer.candidates.count == 5)
        for (text, expected) in [
            ("2", P.Reply.pick(2)), ("number 3", .pick(3)), ("#4", .pick(4)), ("the second one", .pick(2)),
            ("three", .pick(3)), ("the first", .pick(1)), ("the last one", .pick(5)), ("it's 5", .pick(5)),
            ("2 is right", .pick(2)), ("I'll take number two", .pick(2)), ("go with 1", .pick(1)), ("ok, 3", .pick(3)),
            ("7", .outOfRange(7)), ("number 9", .outOfRange(9)),
            ("say 2 again", .hear(2)), ("play 3", .hear(3)), ("2 again", .hear(2)), ("let me hear the third one again", .hear(3)),
            ("none of these", .none), ("none", .none), ("no", .none), ("nope", .none), ("give me more", .none), ("neither", .none),
            ("that's it", .needsNumber), ("yes", .needsNumber), ("right", .needsNumber),
            ("skip", .leave), ("how do you say McGill?", .leave), ("LAT-uh", .leave), ("Latta rhymes with data", .leave),
            ("who is Donna?", .leave), ("", .leave), ("stop", .leave),
        ] {
            #expect(P.classify(text, offer: offer) == expected, "\(text)")
        }
        var heard = offer
        heard.heard = 2
        #expect(P.classify("that's it", offer: heard) == .confirmHeard)
        #expect(P.classify("yes, that one", offer: heard) == .confirmHeard)
        #expect(P.classify("Hallie, that's it!", offer: heard) == .confirmHeard)
    }

    @Test func requestDetectorMatrix() {
        typealias P = HalliePronunciationPicker
        #expect(P.detectRequest("say Latta a few different ways until I pick one") == .init(word: "Latta"))
        #expect(P.detectRequest("say Latta a few ways") == .init(word: "Latta"))
        #expect(P.detectRequest("Hallie, pronounce McGill several ways") == .init(word: "McGill"))
        #expect(P.detectRequest("say it a few ways") == .init(word: nil))
        #expect(P.detectRequest("let me pick") == .init(word: nil))
        #expect(P.detectRequest("let me pick Latta") == .init(word: "Latta"))
        #expect(P.detectRequest("let me choose how to say Latta") == .init(word: "Latta"))
        #expect(P.detectRequest("I want to pick how to pronounce McGill") == .init(word: "McGill"))
        #expect(P.detectRequest("which sounds right?") == .init(word: nil))
        #expect(P.detectRequest("which one sounds right for Edith") == .init(word: "Edith"))
        #expect(P.detectRequest("give me a few ways to say Latta") == .init(word: "Latta"))
        #expect(P.detectRequest("show me the options") == .init(word: nil))
        #expect(P.detectRequest("how else could you say Latta?") == .init(word: "Latta"))
        #expect(P.detectRequest("say Latta") == nil)
        #expect(P.detectRequest("pronounce Latta like LAT-uh") == nil)
        #expect(P.detectRequest("who is Latta?") == nil)
        #expect(P.detectRequest("play the first one") == nil)
        for text in ["no", "No.", "nope", "not right", "wrong", "that's not it", "not quite",
                     "no, that's wrong", "no, that's not right"] {
            #expect(P.isBareNo(text), "\(text)")
        }
        for text in ["no — MahGill", "not LAT-uh", "no it's Lah-Tah", "skip", "right"] {
            #expect(!P.isBareNo(text), "\(text)")
        }
    }

    @Test func wordingAndChipLabels() {
        typealias P = HalliePronunciationPicker
        let offer = Self.lattaOffer
        #expect(P.offerReply(offer) == "Here are a few ways to say Latta — click the one that's right:")
        #expect(P.spokenOffer(offer) == "Here are a few ways to say Latta. One: [Latta](/lˈætə/). Two: [Latta](/lˈæɾə/). Three: [Latta](/lˈɑtɑ/). Four: [Latta](/lətˈɑ/). Five: [Latta](/lˈætɑ/). Click the one that's right.")
        #expect(P.spokenOfferFallback(offer) == "Here are a few ways to say Latta. One: LAT-uh. Two: LAD-uh. Three: LAH-tah. Four: la-TAH. Five: LAT-ah. Click the one that's right.")
        #expect(P.shellOfferReply(offer).hasPrefix("Here are a few ways to say Latta — reply with the number that's right, or \"none of these\":\n1. LAT-uh /lˈætə/ — short a, stress on the 1st\n2. LAD-uh /lˈæɾə/ — short a, stress on the 1st, flapped t, like ladder\n"))
        #expect(P.chipLabel(number: 2, candidate: offer.candidates[1], heard: false) == "2 LAD-uh")
        #expect(P.chipLabel(number: 2, candidate: offer.candidates[1], heard: true) == "\u{25B6}\u{FE0E} 2 LAD-uh")
        #expect(P.thatsItLabel(number: 2) == "That's it (2)")
        #expect(P.hearReply(offer, number: 2) == "Number 2 — LAD-uh.")
        #expect(P.hearSpeech(offer, number: 2) == "Number 2: [Latta](/lˈæɾə/).")
        #expect(P.pickedReply(word: "Latta", candidate: offer.candidates[1], number: 2, scope: .file)
                == "OK, noted — Latta. I'll say Latta as LAD-uh (number 2) from now on. I've kept that in the pronunciation list for that name.")
        #expect(P.transientPickedReply(
            word: "Latta", candidate: offer.candidates[1], number: 2)
            == "OK, noted — Latta. I'll say Latta as LAD-uh (number 2) from now on. I'll use that for this session only; run with --remember to save it.")
        // The chat window's chips: five to hear, "That's it" only once one was heard, "None of these".
        #expect(ArchivistMessage.pickerChips(for: offer).map(\.label) == ["1 LAT-uh", "2 LAD-uh", "3 LAH-tah", "4 la-TAH", "5 LAT-ah", "None of these"])
        var heard = offer
        heard.heard = 2
        #expect(ArchivistMessage.pickerChips(for: heard).map(\.label) == ["1 LAT-uh", "\u{25B6}\u{FE0E} 2 LAD-uh", "3 LAH-tah", "4 la-TAH", "5 LAT-ah", "That's it (2)", "None of these"])
    }

    // MARK: - 2. The chip flow through the coordinator

    @Test func offerHearPickByNumberStoresAndReadsBack() async throws {
        let recorder = Recorder()
        // Rick's ask.
        let offered = try await turn("say Latta a few different ways until I pick one", picker: nil, recorder: recorder)
        let offer = try #require(offered.picker)
        #expect(offered.result.prose == "Here are a few ways to say Latta — click the one that's right:")
        #expect(offer.candidates.map(\.respelling) == ["LAT-uh", "LAD-uh", "LAH-tah", "la-TAH", "LAT-ah"])
        #expect(offered.pickerSpeech?.contains("Two: [Latta](/lˈæɾə/).") == true)
        #expect(offered.result.queryDescription == "pronunciation picker")
        #expect(offered.result.basisLine == HalliePronunciationPicker.basisLine)
        #expect(recorder.writes.isEmpty)

        // "say 2 again" marks it heard (a chip click does the same in the window).
        let heard = try await turn("say 2 again", picker: offer, recorder: recorder)
        #expect(heard.result.prose == "Number 2 — LAD-uh.")
        #expect(heard.pickerSpeech == "Number 2: [Latta](/lˈæɾə/).")
        #expect(heard.picker?.heard == 2)

        // "that's it" picks the one heard.
        let picked = try await turn("that's it", picker: heard.picker, recorder: recorder)
        #expect(picked.picker == nil)
        #expect(picked.result.prose == "OK, noted — Latta. I'll say Latta as LAD-uh (number 2) from now on. I've kept that in the pronunciation list for that name.")
        #expect(picked.pickerSpeech == nil)   // the read-back goes through the lexicon, which now has the phonemes
        #expect(recorder.writes == [.init(word: "Latta", saidAs: "LAD-uh", phonemes: "lˈæɾə", target: .file, origin: "picked")])
        let record = try #require(recorder.store.record(for: "latta"))
        #expect(record.status == .taught && record.source == .picked && record.phonemes == "lˈæɾə" && record.respelling == "LAD-uh")
        let entry = try #require(recorder.lastManifest?.entries.first { $0.key == "latta" })
        #expect(entry.origin == .picked && entry.phonemes == "lˈæɾə" && entry.respelling == "LAD-uh")
        // The voice's next utterance carries the override.
        let spoken = HallieSpeaker.spokenText("OK, noted — Latta.", lexicon: recorder.taughtLexicon, phonemeLinks: true)
        #expect(spoken == "OK, noted — [Latta](/lˈæɾə/).")
        #expect(recorder.taughtLexicon.strippingPhonemeLinks(spoken) == "OK, noted — LAD-uh.")
    }

    @Test func pickByNumberDirectlyAndOutOfRangeAndNeedsNumber() async throws {
        let recorder = Recorder()
        let offer = Self.lattaOffer
        let tooBig = try await turn("number 8", picker: offer, recorder: recorder)
        #expect(tooBig.result.prose == "I offered 5 ways to say Latta — tell me a number from 1 to 5, or \"none of these\".")
        #expect(tooBig.picker == offer)
        let which = try await turn("that's it", picker: offer, recorder: recorder)
        #expect(which.result.prose == "Which one? Click it, or tell me the number (1 to 5).")
        #expect(which.picker == offer)
        let picked = try await turn("the third one", picker: offer, recorder: recorder)
        #expect(picked.picker == nil)
        #expect(picked.result.prose.hasPrefix("OK, noted — Latta. I'll say Latta as LAH-tah (number 3) from now on."))
        #expect(recorder.writes.last?.phonemes == "lˈɑtɑ")
    }

    @Test func noneTurnsThePagesThenAsksForASpelling() async throws {
        let recorder = Recorder()
        let first = try #require(try await turn("let me pick Latta", picker: nil, recorder: recorder).picker)
        let second = try await turn("none of these", picker: first, recorder: recorder)
        let page2 = try #require(second.picker)
        #expect(second.result.prose == "None of those — here are a few more ways to say Latta; click the one that's right:")
        #expect(page2.round == 1 && page2.candidates.count == 5)
        #expect(Set(page2.candidates.map(\.phonemes)).isDisjoint(with: first.candidates.map(\.phonemes)))
        let third = try await turn("none", picker: page2, recorder: recorder)
        let page3 = try #require(third.picker)
        #expect(page3.round == 2 && page3.candidates.count == 1)
        let done = try await turn("nope", picker: page3, recorder: recorder)
        #expect(done.picker == nil)
        #expect(done.result.prose == HalliePronunciationPicker.exhaustedReply(word: "Latta"))
        #expect(recorder.writes.isEmpty)
        // After that, a typed respelling is an ordinary teach (the offer is gone).
        let taught = try await turn("pronounce Latta like LAT-uh", picker: nil, recorder: recorder)
        #expect(taught.result.prose.hasPrefix("OK, noted — Latta."))
        #expect(recorder.writes.last?.origin == "told")
    }

    @Test func aQuestionStepsOutOfTheOfferAndAnUnknownNameIsNotOurs() async throws {
        let recorder = Recorder()
        // "who is Donna" would go to translation (the fixture throws) — the
        // offer is dropped first, so the picker returns nil.
        let response = HallieAppTurnCoordinator.pickerResponse(
            question: "who is Donna?", picker: Self.lattaOffer, drill: nil, telling: nil,
            referent: .init(recordID: nil, temporalDate: nil), dependencies: dependencies(recorder))
        #expect(response == nil)
        // "say hello a few ways": nobody carries "hello".
        let unknown = HallieAppTurnCoordinator.pickerResponse(
            question: "say hello a few ways", picker: nil, drill: nil, telling: nil,
            referent: .init(recordID: nil, temporalDate: nil), dependencies: dependencies(recorder))
        #expect(unknown == nil)
        let which = try await turn("let me pick", picker: nil, recorder: recorder)
        #expect(which.result.prose == HalliePronunciationPicker.whichNameReply())
        #expect(which.picker == nil)
    }

    @Test func aFailedWriteIsHonestAndKeepsTheOfferUp() async throws {
        let recorder = Recorder()
        recorder.failWith = "disk full"
        let offer = Self.lattaOffer
        let failed = try await turn("2", picker: offer, recorder: recorder)
        #expect(failed.result.outcome == .failed)
        #expect(failed.result.prose == "I couldn't save that — disk full. Saying Latta as LAD-uh won't stick past this answer, sorry.")
        #expect(failed.picker == offer)
        #expect(recorder.store.record(for: "latta") == nil)
    }

    // MARK: - 3. The drill: bare "no" and an unmappable hint

    @Test func bareNoInTheDrillOffersVariationsAndAPickAdvancesTheSheet() async throws {
        let recorder = Recorder()
        let start = try await turn("let's practice names", picker: nil, recorder: recorder)
        let drill = try #require(start.drill)
        #expect(drill.current?.name == "Rick")
        let offered = try await turn("no", picker: nil, drill: drill, recorder: recorder)
        let offer = try #require(offered.picker)
        #expect(offer.word == "Rick" && offer.fromDrill)
        #expect(offered.drill == drill)   // still on Rick
        #expect(offered.result.prose == "Here are a few ways to say Rick — click the one that's right:")
        #expect(offer.candidates.map(\.respelling) == ["RICK", "REEK", "REYEK"])
        let picked = try await turn("1", picker: offer, drill: offered.drill, recorder: recorder)
        #expect(picked.picker == nil)
        #expect(picked.result.prose == "OK, noted — Rick. I'll say Rick as RICK (number 1) from now on. I've kept that in the pronunciation list for that name. Next name: Breen.")
        #expect(picked.drill?.current?.name == "Breen")
        #expect(picked.drill?.taught == 1)
        #expect(recorder.writes == [.init(word: "Rick", saidAs: "RICK", phonemes: "ɹˈɪk", target: .file, origin: "picked")])
        #expect(recorder.store.status(for: "rick") == .taught)
        #expect(recorder.store.record(for: "rick")?.source == .picked)
        #expect(recorder.store.record(for: "rick")?.listSource == .peopleTab)
        // A drill word while the offer is up steps out of the picker and into the drill.
        let skipped = try await turn("skip", picker: offer, drill: picked.drill, recorder: recorder)
        #expect(skipped.picker == nil && skipped.drill?.current?.name == "Donna")
    }

    @Test func anUnmappableHintOffersVariationsBuiltFromIt() async throws {
        let recorder = Recorder()
        let (gold, goldURL) = try goldFixture(["data": "dˈAɾə", "brick": "bɹˈɪk"])
        defer { try? FileManager.default.removeItem(at: goldURL) }
        recorder.gold = gold
        // One-off: "rhymes with" is never mapped to a spelling on its own.
        let offered = try await turn("Latta rhymes with data", picker: nil, recorder: recorder)
        let offer = try #require(offered.picker)
        #expect(offered.result.prose == "I've noted \u{201C}rhymes with data\u{201D} for Latta. Here are a few ways to say Latta — click the one that's right:")
        #expect(offer.hint == .rhymes(with: "data"))
        #expect(offer.candidates.map(\.respelling) == ["LAY-duh", "LAT-uh", "LAD-uh", "LAH-tah", "la-TAH"])
        #expect(recorder.store.record(for: "latta")?.hint == "rhymes with data")
        let picked = try await turn("1", picker: offer, recorder: recorder)
        #expect(picked.result.prose.hasPrefix("OK, noted — Latta. I'll say Latta as LAY-duh (number 1) from now on."))
        #expect(recorder.store.record(for: "latta")?.hint == "rhymes with data")
        #expect(recorder.store.record(for: "latta")?.source == .picked)

        // In the drill, the same hint about the name that is up.
        let start = try await turn("practice names", picker: nil, recorder: recorder)
        let drill = try #require(start.drill)
        let inDrill = try await turn("Rick rhymes with brick", picker: nil, drill: drill, recorder: recorder)
        #expect(inDrill.picker?.word == "Rick" && inDrill.picker?.fromDrill == true)
        #expect(inDrill.drill?.current?.name == "Rick")
        #expect(inDrill.result.prose.hasPrefix("I've noted \u{201C}rhymes with brick\u{201D} for Rick. Here are a few ways to say Rick"))
    }

    @Test func coordinatorGoldIsInjectedAndNeverFallsThroughToTheInstalledGlobal() async throws {
        let recorder = Recorder()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-gold-\(UUID().uuidString).json")
        recorder.gold = MisakiGoldLexicon(url: missing)
        let withoutGold = try await turn(
            "Latta rhymes with data", picker: nil, recorder: recorder)
        #expect(withoutGold.picker?.candidates.first?.respelling == "LAT-uh")
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        let (fixture, fixtureURL) = try goldFixture(["data": "dˈAɾə"])
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        recorder.gold = fixture
        let withGold = try await turn(
            "Latta rhymes with data", picker: nil, recorder: recorder)
        #expect(withGold.picker?.candidates.first?.respelling == "LAY-duh")
    }

    @Test func replacingWebSpeakersPreservesEveryInjectedDependency() async throws {
        let probe = DependencyProbe()
        let (gold, goldURL) = try goldFixture(["data": "dˈAɾə"])
        defer { try? FileManager.default.removeItem(at: goldURL) }
        let ast = ArchivistQueryAST.temporal(.init(
            subject: "Tim", operation: .age, reference: .currentSelection))
        let result = HallieTurnExecutor.Result(
            route: .temporal, outcome: .answered, prose: "executed",
            basisLine: "probe", queryDescription: nil, citations: [],
            catalogPersonName: nil)
        let plan = HallieAnswerPlan(
            route: .help, shape: .fixed, fallbackText: "composed")
        let source = preservationDependencies(
            probe, gold: gold, ast: ast, result: result)
        let replaced = source.replacingSpeakers(
            .init(ownerName: "Donna Breen", archivistName: "Hallie Mae"))

        #expect(try await replaced.startLocalBrain([]) == ["brain"])
        #expect(try await replaced.translateAST("", [], "").responderHost == "translation")
        #expect(try await replaced.interpretTurn("", [], "").responderHost == "interpretation")
        #expect(await replaced.composeConversation(.casual, "", [], [], "").responderHost == "conversation")
        #expect(replaced.loadProfiles()?.first?.stableID == "probe")
        #expect(replaced.loadGraph() == nil)
        #expect(replaced.loadNeedsRecompile().first?.path == "/probe/needs-recompile")
        #expect(replaced.loadCyberBrain() == nil)
        try replaced.recordTestimony(.init(
            subjectName: "Probe", speakerName: "Tester", text: "test", date: .distantPast))
        try replaced.recordPhotoCaption(.init(
            subjects: [.init(name: "Probe")], speakerName: "Tester",
            text: "test", photoPath: "/probe.jpg", date: .distantPast))
        try replaced.recordPronunciation(.init(
            word: "Probe", saidAs: "PROBE", phonemes: nil, target: .file))
        let store = replaced.loadDrillStore()
        try replaced.saveDrillStore(
            store,
            .build(list: .init(items: []), lexicon: .shipped, store: store))
        #expect(replaced.loadLexicon().entries.first?.written == "Probe")
        #expect(replaced.loadPronunciationGold().phonemes(for: "data") == "dˈAɾə")
        try replaced.excludePhoto(URL(fileURLWithPath: "/probe.jpg"), "@I1@", nil, nil)
        #expect(replaced.loadSpeakers().ownerName == "Donna Breen")
        // Two profiles genuinely NAMED Tim — real ambiguity, so the turn
        // still needs a clarification (exact name wins since 2026-09-03,
        // so a name-versus-alias pair no longer ties).
        let context = HallieTurnExecutor.Context(profiles: [
            .init(stableID: "tim-a", canonicalName: "Tim"),
            .init(stableID: "tim-b", canonicalName: "Tim"),
        ])
        let request = HallieTurnExecutor.Request(intent: .init(
            originalQuestion: "How old was Tim?", ast: ast, playAfterAnswer: false))
        #expect(try await replaced.executeRequest(request, context).prose == "executed")
        let ambiguous = try await HallieTurnExecutor.execute(request, context: context)
        let clarification = try #require(ambiguous.clarification)
        #expect(try await replaced.continueTurn(
            clarification, .profileStableID("tim-a"), context).prose == "executed")
        #expect(replaced.resolveBiographyPhoto("Probe") == nil)
        #expect(await replaced.composeAnswer(plan, [], [], "").displayText == "composed")

        #expect(probe.hits == [
            "startLocalBrain", "translateAST", "interpretTurn", "composeConversation",
            "loadProfiles", "loadGraph", "loadNeedsRecompile", "loadCyberBrain",
            "recordTestimony", "recordPhotoCaption", "recordPronunciation",
            "loadDrillStore", "saveDrillStore", "loadLexicon", "loadPronunciationGold",
            "excludePhoto", "executeRequest", "continueTurn", "resolveBiographyPhoto",
            "composeAnswer",
        ])
    }

    // MARK: - 4. Shell parity

    @Test func shellOffersANumberedListAndTakesTheNumber() async {
        final class Harness: @unchecked Sendable {
            var inputs = ["say Latta a few ways", "say 2 again", "2"]
            var output: [String] = []
            var writes: [HallieAppTurnCoordinator.PronunciationWrite] = []
            var store = PronunciationDrillStore()
            func next() -> String? { inputs.isEmpty ? nil : inputs.removeFirst() }
        }
        let harness = Harness()
        let dependencies = HallieShellCLI.Dependencies(
            loadCatalog: { _ in [] },
            loadProfiles: { .loaded([]) },
            loadGraph: { _ in nil },
            translateAST: { _, _ in
                Issue.record("translation must not run in the picker")
                throw NLTranslatorError.unreachable("fixture")
            },
            executeTurn: { _, _ in throw NLTranslatorError.unreachable("fixture") },
            performMediaAction: { _ in },
            recordPronunciation: { harness.writes.append($0) },
            loadDrillStore: { harness.store },
            saveDrillStore: { store, _ in harness.store = store },
            loadLexicon: { Self.lexicon })
        var options = HallieShellCLI.Options()
        options.remember = true
        options.allowActions = false
        let code = await HallieShellCLI.run(
            options: options, input: harness.next,
            output: { harness.output.append($0) }, dependencies: dependencies)
        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        let text = harness.output.joined(separator: "\n")
        #expect(text.contains("Here are a few ways to say Latta — reply with the number that's right, or \"none of these\":"))
        #expect(text.contains("1. LAT-uh /lˈætə/ — short a, stress on the 1st"))
        #expect(text.contains("5. LAT-ah /lˈætɑ/ — short a, stress on the 1st, ends in ah"))
        #expect(text.contains("Number 2 — LAD-uh. /lˈæɾə/"))
        #expect(text.contains("OK, noted — Latta. I'll say Latta as LAD-uh (number 2) from now on."))
        #expect(text.contains("interpreted: pronunciation picker (local)"))
        #expect(harness.writes == [.init(word: "Latta", saidAs: "LAD-uh", phonemes: "lˈæɾə", target: .file, origin: "picked")])
        #expect(harness.store.record(for: "latta")?.source == .picked)
    }

    @Test func shellWithoutRememberKeepsThePickForTheSessionOnly() async {
        final class Harness: @unchecked Sendable {
            var inputs = ["let me pick Latta", "the first one"]
            var output: [String] = []
            var wrote = false
            var saved = false
            func next() -> String? { inputs.isEmpty ? nil : inputs.removeFirst() }
        }
        let harness = Harness()
        let dependencies = HallieShellCLI.Dependencies(
            loadCatalog: { _ in [] },
            loadProfiles: { .loaded([]) },
            loadGraph: { _ in nil },
            translateAST: { _, _ in throw NLTranslatorError.unreachable("fixture") },
            executeTurn: { _, _ in throw NLTranslatorError.unreachable("fixture") },
            performMediaAction: { _ in },
            recordPronunciation: { _ in harness.wrote = true },
            saveDrillStore: { _, _ in harness.saved = true },
            loadLexicon: { Self.lexicon })
        _ = await HallieShellCLI.run(
            options: HallieShellCLI.Options(), input: harness.next,
            output: { harness.output.append($0) }, dependencies: dependencies)
        let text = harness.output.joined(separator: "\n")
        #expect(text.contains(
            "OK, noted — Latta. I'll say Latta as LAT-uh (number 1) from now on. "
                + "I'll use that for this session only; run with --remember to save it."))
        #expect(!text.contains("I've kept that in the pronunciation list"))
        #expect(!text.contains("I've kept that on Latta's record"))
        #expect(!harness.wrote && !harness.saved)
    }

    @Test func shellNoRememberPronunciationsLiveUntilResetAndNeverWrite() async {
        final class Harness: @unchecked Sendable {
            var inputs: [String]
            var output: [String] = []
            var recorded = 0
            var saved = 0
            init(_ inputs: [String]) { self.inputs = inputs }
            func next() -> String? { inputs.isEmpty ? nil : inputs.removeFirst() }
        }
        func dependencies(_ harness: Harness) -> HallieShellCLI.Dependencies {
            HallieShellCLI.Dependencies(
                loadCatalog: { _ in [] },
                loadProfiles: { .loaded([]) },
                loadGraph: { _ in nil },
                translateAST: { _, _ in throw NLTranslatorError.unreachable("fixture") },
                executeTurn: { _, _ in throw NLTranslatorError.unreachable("fixture") },
                performMediaAction: { _ in },
                recordPronunciation: { _ in harness.recorded += 1 },
                saveDrillStore: { _, _ in harness.saved += 1 },
                loadLexicon: { Self.lexicon })
        }

        let harness = Harness([
            "pronounce Latta like LAH-tah or LAY-tuh",
            "how do you say Latta?",
            "what pronunciations do you have?",
            "say Latta a few ways",
            ":reset",
            "how do you say Latta?",
        ])
        _ = await HallieShellCLI.run(
            options: HallieShellCLI.Options(), input: harness.next,
            output: { harness.output.append($0) }, dependencies: dependencies(harness))
        let text = harness.output.joined(separator: "\n")
        #expect(text.contains(
            "OK, noted — Latta. I'll say Latta as LAH-tah (or LAY-tuh) from now on. "
                + "I'll use that for this session only; run with --remember to save it."))
        #expect(!text.contains("I've kept that in the pronunciation list for that name"))
        #expect(text.contains("I say Latta as LAH-tah (or LAY-tuh)"))
        #expect(text.contains("Latta as LAH-tah"))
        #expect(text.contains("1. LAH-tah /lˈɑtɑ/ — as you spelled it"))
        #expect(text.contains("reset: conversation forgotten"))
        #expect(text.contains("I say Latta as LAT-uh — that's in the pronunciation list."))
        #expect(harness.recorded == 0)
        #expect(harness.saved == 0)

        let fresh = Harness(["how do you say Latta?"])
        _ = await HallieShellCLI.run(
            options: HallieShellCLI.Options(), input: fresh.next,
            output: { fresh.output.append($0) }, dependencies: dependencies(fresh))
        let freshText = fresh.output.joined(separator: "\n")
        #expect(freshText.contains("I say Latta as LAT-uh"))
        #expect(!freshText.contains("LAH-tah"))
        #expect(fresh.recorded == 0 && fresh.saved == 0)
    }

    @Test func shellPickerUsesOnlyItsInjectedGoldSource() async throws {
        final class Harness: @unchecked Sendable {
            var inputs = ["Latta rhymes with data"]
            var output: [String] = []
            func next() -> String? { inputs.isEmpty ? nil : inputs.removeFirst() }
        }
        func run(gold: MisakiGoldLexicon) async -> String {
            let harness = Harness()
            let dependencies = HallieShellCLI.Dependencies(
                loadCatalog: { _ in [] },
                loadProfiles: { .loaded([]) },
                loadGraph: { _ in nil },
                translateAST: { _, _ in throw NLTranslatorError.unreachable("fixture") },
                executeTurn: { _, _ in throw NLTranslatorError.unreachable("fixture") },
                performMediaAction: { _ in },
                loadLexicon: { Self.lexicon },
                loadPronunciationGold: { gold })
            _ = await HallieShellCLI.run(
                options: HallieShellCLI.Options(), input: harness.next,
                output: { harness.output.append($0) }, dependencies: dependencies)
            return harness.output.joined(separator: "\n")
        }

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-shell-gold-\(UUID().uuidString).json")
        let withoutGold = await run(gold: MisakiGoldLexicon(url: missing))
        #expect(withoutGold.contains("1. LAT-uh /lˈætə/"))
        #expect(!withoutGold.contains("1. LAY-duh /lˈAɾə/"))
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        let (fixture, fixtureURL) = try goldFixture(["data": "dˈAɾə"])
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let withGold = await run(gold: fixture)
        #expect(withGold.contains("1. LAY-duh /lˈAɾə/"))
    }

    // MARK: - 5. Persistence and isolation

    @Test func pickedEntriesRoundTripThroughTheLexiconFileAndTheDrillStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("pronunciations.json")
        // The lexicon file: v2 object with source "picked" and the phonemes.
        try HalliePronunciationLexicon.setFileEntry(written: "Latta", spoken: "LAD-uh", phonemes: "lˈæɾə", origin: "picked", url: file, log: nil)
        let json = try #require(String(data: Data(contentsOf: file), encoding: .utf8))
        #expect(json.contains("\"source\" : \"picked\"") && json.contains("\"phonemes\" : \"lˈæɾə\"") && json.contains("\"attested\""))
        let loaded = HalliePronunciationLexicon.load(from: file, log: nil)
        let entry = try #require(loaded.entries.first { $0.written == "Latta" })
        #expect(entry.spoken == "LAD-uh" && entry.phonemes == "lˈæɾə" && entry.origin == "picked")
        #expect(loaded.apply(to: "Tell me about Latta.", style: .kokoro).spoken == "Tell me about [Latta](/lˈæɾə/).")
        // The drill store: origin picked survives a save/load.
        var store = PronunciationDrillStore()
        store.set(name: "Latta", status: .taught, alternatives: ["LAD-uh"], phonemes: "lˈæɾə", origin: .picked, hint: "short a on La")
        let storeURL = directory.appendingPathComponent("pronunciation-drill.json")
        let manifest = PronunciationDrillManifest.build(list: PronunciationDrillList(items: []), lexicon: loaded, store: store)
        try store.save(to: storeURL, manifest: manifest)
        let reloaded = PronunciationDrillStore.load(from: storeURL, log: nil)
        let record = try #require(reloaded.record(for: "latta"))
        #expect(record.source == .picked && record.phonemes == "lˈæɾə" && record.hint == "short a on La" && record.status == .taught)
        let manifestData = try Data(contentsOf: directory.appendingPathComponent(PronunciationDrillStore.manifestFileName))
        let manifestJSON = try #require(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let entries = try #require(manifestJSON["entries"] as? [[String: Any]])
        let latta = try #require(entries.first { $0["key"] as? String == "latta" })
        #expect(latta["origin"] as? String == "picked" && latta["phonemes"] as? String == "lˈæɾə")
        // Isolation: nothing above touched the real files.
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Hallie").path))
    }

    @Test func theOfferIsAValueTheClientsCarryUnchanged() {
        var offer = Self.lattaOffer
        let copy = offer
        offer.heard = 3
        #expect(copy.heard == nil && offer.heard == 3)
        #expect(offer.candidate(0) == nil && offer.candidate(6) == nil && offer.candidate(5)?.respelling == "LAT-ah")
        #expect(HalliePronunciationPicker.logLine(offered: offer) == "[hallie-voice] picker: offered 5 (page 1)")
    }
}
