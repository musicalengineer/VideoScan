import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// The pronunciation drill (Rick 2026-08-29): the sheet's order, the reply
/// parser, the state machine through the chat coordinator, the read-back,
/// persistence, the manifest, the shell text loop, and scale.
@MainActor
@Suite("Hallie pronunciation drill", .serialized)
struct HalliePronunciationDrillTests {

    // MARK: - Fixtures

    private static func scratch(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-drill-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Two roots (Rick and Donna, `_VS_ROOT`), Rick's parents and a
    /// grandfather, Donna's mother; a far cousin line with many descendants.
    private static let gedcom = """
    0 HEAD
    1 _VS_ROOT @I1@
    1 _VS_ROOT @I2@
    0 @I1@ INDI
    1 NAME Richard Harding /Breen/ Jr
    1 SEX M
    1 FAMC @F1@
    1 FAMS @F0@
    0 @I2@ INDI
    1 NAME Donna /Latta/
    1 SEX F
    1 FAMC @F2@
    1 FAMS @F0@
    0 @I3@ INDI
    1 NAME Richard Harding /Breen/ Sr
    1 SEX M
    1 FAMS @F1@
    1 FAMC @F3@
    0 @I4@ INDI
    1 NAME Edith /McGill/
    1 SEX F
    1 FAMS @F1@
    0 @I5@ INDI
    1 NAME Bethiah /Latta/
    1 SEX F
    1 FAMS @F2@
    0 @I6@ INDI
    1 NAME Nathaniel /Breen/
    1 SEX M
    1 FAMS @F3@
    0 @I7@ INDI
    1 NAME Hendour /McLaughlin/
    1 SEX M
    1 FAMS @F4@
    0 @I8@ INDI
    1 NAME Ronan /McLaughlin/
    1 SEX M
    1 FAMC @F4@
    1 FAMS @F5@
    0 @I9@ INDI
    1 NAME Zephyr /McLaughlin/
    1 SEX M
    1 FAMC @F5@
    0 @I10@ INDI
    1 NAME Quill /Ashdown/
    1 SEX M
    0 @F0@ FAM
    1 HUSB @I1@
    1 WIFE @I2@
    0 @F1@ FAM
    1 HUSB @I3@
    1 WIFE @I4@
    1 CHIL @I1@
    0 @F2@ FAM
    1 WIFE @I5@
    1 CHIL @I2@
    0 @F3@ FAM
    1 HUSB @I6@
    1 CHIL @I3@
    0 @F4@ FAM
    1 HUSB @I7@
    1 CHIL @I8@
    0 @F5@ FAM
    1 HUSB @I8@
    1 CHIL @I9@
    0 TRLR
    """

    private static let graph = GedcomFamilyGraph(gedcomText: gedcom)

    private static let profiles: [HallieTurnExecutor.ProfileSnapshot] = [
        .init(stableID: "tim", canonicalName: "Timmy Breen",
              kinships: [Kinship(relation: .child, relativeTo: .profileName("Rick"))]),
        .init(stableID: "rick", canonicalName: "Rick Breen", aliases: ["Dicky"],
              kinships: [Kinship(relation: .spouse, relativeTo: .profileName("Donna"))]),
        .init(stableID: "wendy", canonicalName: "Wendy Foley"),
        .init(stableID: "donna", canonicalName: "Donna Breen"),
        .init(stableID: "mom", canonicalName: "Edith Breen",
              kinships: [Kinship(relation: .parent, relativeTo: .profileName("Rick"))]),
    ]

    private static let speakers = HallieTurnExecutor.Speakers(ownerName: "Rick Breen", archivistName: "Hallie Mae")

    /// The voice's table for these tests: only "Latta" already taught.
    private static let lexicon = HalliePronunciationLexicon(entries: [.init(written: "Latta", spoken: "LAT-uh")])

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [HallieAppTurnCoordinator.PronunciationWrite] = []
        private var stores: [PronunciationDrillStore] = []
        private var manifests: [PronunciationDrillManifest] = []
        var store = PronunciationDrillStore()
        var failWith: String?
        func append(_ value: HallieAppTurnCoordinator.PronunciationWrite) { lock.withLock { storage.append(value) } }
        var writes: [HallieAppTurnCoordinator.PronunciationWrite] { lock.withLock { storage } }
        func save(_ s: PronunciationDrillStore, _ m: PronunciationDrillManifest) {
            lock.withLock { store = s; stores.append(s); manifests.append(m) }
        }
        var savedStores: [PronunciationDrillStore] { lock.withLock { stores } }
        var lastManifest: PronunciationDrillManifest? { lock.withLock { manifests.last } }
        /// What the voice would have after every write so far — the layer
        /// the read-back is spoken through.
        var taughtLexicon: HalliePronunciationLexicon {
            .merged([HalliePronunciationLexicon(entries: writes.map { .init(written: $0.word, spoken: $0.saidAs) }),
                     HalliePronunciationDrillTests.lexicon])
        }
    }

    private func dependencies(_ recorder: Recorder) -> HallieAppTurnCoordinator.Dependencies {
        HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { $0 },
            translateAST: { _, _, _ in
                Issue.record("translation must not run during the drill")
                throw NLTranslatorError.unreachable("fixture")
            },
            loadProfiles: { Self.profiles },
            loadGraph: { Self.graph },
            loadCyberBrain: { nil },
            recordPronunciation: { write in
                if let failWith = recorder.failWith { throw CyberBrainWriter.WriteError.ioFailure(failWith) }
                recorder.append(write)
            },
            loadDrillStore: { recorder.store },
            saveDrillStore: { store, manifest in recorder.save(store, manifest) },
            loadLexicon: { recorder.taughtLexicon },
            loadSpeakers: { Self.speakers },
            executeRequest: { _, _ in
                Issue.record("no catalog query during the drill")
                throw NLTranslatorError.unreachable("fixture")
            },
            continueTurn: { _, _, _ in throw NLTranslatorError.unreachable("fixture") },
            resolveBiographyPhoto: { _ in nil })
    }

    private func turn(_ question: String, drill: HalliePronunciationDrillMode.Session?,
                      recorder: Recorder) async throws -> HallieAppTurnCoordinator.Response {
        try await HallieAppTurnCoordinator.execute(
            question: question, records: [],
            referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            drill: drill,
            dependencies: dependencies(recorder))
    }

    // MARK: - 1. List ordering

    @Test func sheetLeadsWithRicksHouseholdThenNearAncestryThenDescendantCount() {
        let list = PronunciationDrillList.build(
            graph: Self.graph, profiles: Self.profiles, speakers: Self.speakers,
            lexicon: Self.lexicon, store: PronunciationDrillStore())
        let names = list.items.map(\.name)
        // Owner first (matched through "Rick Breen" → profile "Rick Breen"),
        // then spouse (Donna), parent (Edith), child (Timmy), then the other
        // profile (Wendy Foley); given names before surnames.
        #expect(Array(names.prefix(8)) == ["Rick", "Breen", "Donna", "Edith", "Timmy", "Wendy", "Foley", "Richard"])
        // Latta is already taught → not on the sheet.
        #expect(!names.contains("Latta"))
        // Near ancestry (Harding, Nathaniel, McGill, Bethiah) comes before the
        // McLaughlin line, which comes before childless Quill Ashdown.
        let index = { (name: String) in names.firstIndex(of: name) ?? Int.max }
        #expect(index("McGill") < index("McLaughlin"))
        #expect(index("Nathaniel") < index("Hendour"))
        #expect(index("Hendour") < index("Ronan"))   // 2 descendants before 1
        #expect(index("Ronan") < index("Quill"))
        #expect(list.items.first { $0.name == "Rick" }?.source == .peopleTab)
        #expect(list.items.first { $0.name == "McGill" }?.source == .nearAncestry)
        #expect(list.items.first { $0.name == "McGill" }?.kind == .surname)
        #expect(list.items.first { $0.name == "Quill" }?.source == .tree)
        // Suffixes never appear; each name once.
        #expect(!names.contains("Jr") && !names.contains("Sr"))
        #expect(Set(names).count == names.count)
    }

    @Test func aTaughtNameStaysOnTheSheetOnlyWhileAlternativesArePending() {
        var store = PronunciationDrillStore()
        store.set(name: "McGill", status: .alternativesPending, alternatives: ["MahGill", "MicGill"], origin: .taught)
        let taught = HalliePronunciationLexicon(entries: [
            .init(written: "McGill", spoken: "MahGill | MicGill"), .init(written: "Latta", spoken: "LAT-uh"),
        ])
        let list = PronunciationDrillList.build(
            graph: Self.graph, profiles: [], speakers: .none, lexicon: taught, store: store)
        #expect(list.items.contains { $0.name == "McGill" })
        #expect(!list.items.contains { $0.name == "Latta" })
    }

    // MARK: - 2. Reply parser

    @Test func replyParserMatrix() {
        let list = PronunciationDrillList(items: [
            .init(key: "mcgill", name: "McGill", kind: .surname, source: .peopleTab, carriers: 2),
            .init(key: "edith", name: "Edith", kind: .given, source: .peopleTab, carriers: 1),
        ])
        let session = HalliePronunciationDrillMode.Session(list: list, index: 0)
        typealias M = HalliePronunciationDrillMode
        func c(_ text: String) -> M.Reply { M.classify(text, session: session) }
        func teach(_ word: String?, _ alternatives: [String]) -> M.Reply {
            .teach(.init(word: word, alternatives: alternatives))
        }

        #expect(M.detectStart("let's practice names"))
        #expect(M.detectStart("Hallie, let's practice names"))
        #expect(M.detectStart("practice pronunciations"))
        #expect(M.detectStart("Let's practice the names."))
        #expect(!M.detectStart("what names are in the tree?"))
        #expect(!M.detectStart("practice makes perfect"))

        #expect(c("next name") == .next)
        #expect(c("next") == .next)
        #expect(c("right") == .judgedOk)
        #expect(c("Correct.") == .judgedOk)
        #expect(c("yes") == .judgedOk)
        #expect(c("that's right, Hallie") == .judgedOk)
        #expect(c("skip") == .skip)
        #expect(c("skip it") == .skip)
        #expect(c("stop") == .stop)
        #expect(c("that's enough") == .stop)
        #expect(c("That's enough for now.") == .stop)

        #expect(c("no — MahGill") == teach(nil, ["MahGill"]))
        #expect(c("no, MahGill") == teach(nil, ["MahGill"]))
        #expect(c("no it's muh-GILL") == teach(nil, ["muh-GILL"]))
        #expect(c("say it like MahGill") == teach(nil, ["MahGill"]))
        #expect(c("pronounce it MahGill") == teach(nil, ["MahGill"]))
        #expect(c("either MahGill or MicGill") == teach(nil, ["MahGill", "MicGill"]))
        #expect(c("MahGill or MicGill") == teach(nil, ["MahGill", "MicGill"]))
        #expect(c("no — either MahGill or MicGill") == teach(nil, ["MahGill", "MicGill"]))
        // Rick's exact phrasings.
        #expect(c("pronounce McGill like MahGill or MicGill") == teach("McGill", ["MahGill", "MicGill"]))
        #expect(c("Edith is Ee-dith") == teach("Edith", ["Ee-dith"]))
        #expect(c("muh-GILL") == teach(nil, ["muh-GILL"]))

        // Not judgements: a question leaves; a sentence about someone not on
        // the sheet, or ordinary words, are unrecognized (the drill stays).
        #expect(c("who was Edith's father?") == .leave)
        #expect(c("let me tell you about Dad Breen") == .leave)
        #expect(c("Donna is lovely") == .unrecognized)
        #expect(c("it's fine") == .unrecognized)
        #expect(c("nothing") == .unrecognized)
        #expect(c("") == .unrecognized)
    }

    @Test func oneOffTeachAcceptsAlternativesAndKeepsSingleFormBehaviour() throws {
        let both = try #require(HallieTellingMode.detectPronunciation("pronounce McGill like MahGill or MicGill"))
        #expect(both.word == "McGill")
        #expect(both.saidAs == "MahGill | MicGill")
        #expect(both.alternatives == ["MahGill", "MicGill"])
        #expect(both.spoken == "MahGill")
        let one = try #require(HallieTellingMode.detectPronunciation("say Edith as EE-dith"))
        #expect(one == .init(word: "Edith", saidAs: "EE-dith"))
        #expect(HallieTellingMode.detectPronunciation("Donna is said to cook or to bake") == nil)
        // The reply opens with the read-back.
        #expect(HallieTellingMode.pronunciationReply(both, scope: .file)
                .hasPrefix("OK, noted — McGill. I'll say McGill as MahGill (or MicGill) from now on."))
    }

    // MARK: - 3. State machine through the coordinator

    @Test func drillRoundTripStartAdvanceTeachAlternativesSkipStopResume() async throws {
        let recorder = Recorder()
        // Start: Rick's own name is first on the sheet.
        let start = try await turn("let's practice names", drill: nil, recorder: recorder)
        let s1 = try #require(start.drill)
        #expect(start.result.prose == "Let's practice — 18 names on the sheet. Tell me \"right\", \"skip\", or how to say it. Next name: Rick.")
        #expect(start.result.route == .telling)
        #expect(start.responderHost == HallieAppTurnCoordinator.localResponder)
        #expect(s1.current?.name == "Rick")

        // "right" → judged-ok, advances to Breen.
        let ok = try await turn("right", drill: s1, recorder: recorder)
        let s2 = try #require(ok.drill)
        #expect(ok.result.prose == "Good. Next name: Breen.")
        #expect(recorder.store.status(for: "rick") == .judgedOk)
        #expect(s2.judgedOk == 1)

        // "skip" → skipped, advances to Donna.
        let skip = try await turn("skip", drill: s2, recorder: recorder)
        let s3 = try #require(skip.drill)
        #expect(skip.result.prose == "Skipped. Next name: Donna.")
        #expect(recorder.store.status(for: "breen") == .skipped)

        // "next name" → leaves Donna untested, moves to Edith.
        let next = try await turn("next name", drill: s3, recorder: recorder)
        let s4 = try #require(next.drill)
        #expect(next.result.prose == "We'll come back to that one. Next name: Edith.")
        #expect(recorder.store.status(for: "donna") == .untested)

        // Teach with Rick's exact phrasing: read-back first, then the next name.
        let teach = try await turn("Edith is Ee-dith", drill: s4, recorder: recorder)
        let s5 = try #require(teach.drill)
        #expect(teach.result.prose == "OK, noted — Edith. Next name: Timmy.")
        #expect(recorder.writes.last == .init(word: "Edith", saidAs: "Ee-dith", phonemes: "ˈidɪθ",
                                              target: .treePerson(name: "Edith McGill", gedcomID: "@I4@", aliases: [])))
        #expect(recorder.store.status(for: "edith") == .taught)
        #expect(recorder.store.record(for: "edith")?.respelling == "Ee-dith")
        #expect(s5.taught == 1)

        // Alternatives for a name that is NOT the current one: kept, the
        // drill stays on Timmy.
        let alt = try await turn("pronounce McGill like MahGill or MicGill", drill: s5, recorder: recorder)
        let s6 = try #require(alt.drill)
        #expect(alt.result.prose == "OK, noted — McGill. I'll say MahGill and keep MicGill too. Still on: Timmy.")
        #expect(recorder.writes.last?.saidAs == "MahGill | MicGill")
        #expect(recorder.store.status(for: "mcgill") == .alternativesPending)
        #expect(s6.current?.name == "Timmy")

        // Unrecognized words keep the name up.
        let huh = try await turn("hmm let me think", drill: s6, recorder: recorder)
        #expect(huh.drill == s6)
        #expect(huh.result.prose.hasSuffix("Still on: Timmy."))

        // Stop: counts and where we pick up.
        let stop = try await turn("that's enough", drill: s6, recorder: recorder)
        #expect(stop.drill == nil)
        #expect(stop.result.prose == "That's enough for now — taught 2, judged OK 1, skipped 1. We'll pick up at Timmy next time.")

        // Resume: the sheet skips judged/skipped/taught names; Donna
        // (untested, deferred) is the first pending again.
        let resume = try await turn("practice pronunciations", drill: nil, recorder: recorder)
        let s7 = try #require(resume.drill)
        #expect(resume.result.prose.hasPrefix("Picking up where we left off — "))
        #expect(s7.current?.name == "Donna")
        // McGill is taught now (in the lexicon) but alternatives-pending, so
        // it is still on the sheet; Edith is taught and gone.
        #expect(s7.list.items.contains { $0.name == "McGill" })
        #expect(!s7.list.items.contains { $0.name == "Edith" })

        // A question steps out of the drill; the turn is not the drill's.
        // (The fixture translator records an Issue if reached, so use the
        // deterministic help card.)
        let out = try await turn("let me tell you about Dad Breen", drill: s7, recorder: recorder)
        #expect(out.drill == nil)
        #expect(out.result.route == .telling)
        #expect(out.telling != nil)
    }

    @Test func aFailedTeachIsHonestAndStaysOnTheName() async throws {
        let recorder = Recorder()
        let start = try await turn("let's practice names", drill: nil, recorder: recorder)
        recorder.failWith = "read-only volume"
        let failed = try await turn("no — Rik", drill: start.drill, recorder: recorder)
        #expect(failed.result.outcome == .failed)
        #expect(failed.result.prose.contains("read-only volume"))
        #expect(failed.result.prose.hasSuffix("Saying Rick the new way won't stick, sorry. Still on: Rick."))
        #expect(!failed.result.prose.contains("OK, noted"))
        #expect(failed.drill?.current?.name == "Rick")
        #expect(recorder.store.status(for: "rick") == .untested)
    }

    // MARK: - 4. Read-back

    @Test func readBackIsSpokenWithTheTaughtPronunciation() async throws {
        let recorder = Recorder()
        let start = try await turn("let's practice names", drill: nil, recorder: recorder)
        let taught = try await turn("no — either Rik or Rick-ard", drill: start.drill, recorder: recorder)
        #expect(taught.result.prose == "OK, noted — Rick. I'll say Rik and keep Rick-ard too. Next name: Breen.")
        // The lexicon the voice re-reads on the next utterance now carries
        // the write; the read-back sentence is spoken the new way, first
        // alternative only. Visible text is untouched.
        let spoken = HallieSpeaker.spokenText(taught.result.prose, lexicon: recorder.taughtLexicon)
        #expect(spoken == "OK, noted — Rik. I'll say Rik and keep Rik-ard too. Next name: Breen.")
        #expect(HallieSpeaker.sentences(taught.result.prose, lexicon: recorder.taughtLexicon).first == "OK, noted, Rik.")
        // One-off outside the drill gets the same read-back.
        let oneOff = try await turn("pronounce McGill like MahGill or MicGill", drill: nil, recorder: recorder)
        #expect(oneOff.result.prose.hasPrefix("OK, noted — McGill."))
        #expect(HallieSpeaker.spokenText(oneOff.result.prose, lexicon: recorder.taughtLexicon).hasPrefix("OK, noted — MahGill."))
        #expect(recorder.store.status(for: "mcgill") == .alternativesPending)
    }

    @Test func lexiconSpeaksOnlyTheFirstAlternative() {
        let table = HalliePronunciationLexicon(entries: [.init(written: "McGill", spoken: "MahGill | MicGill")])
        #expect(table.apply(to: "Ann McGill's house").spoken == "Ann MahGill's house")
        #expect(HalliePronunciationLexicon.alternatives("MahGill | MicGill") == ["MahGill", "MicGill"])
        #expect(HalliePronunciationLexicon.alternatives("muh-GILL") == ["muh-GILL"])
        #expect(HalliePronunciationLexicon.joinedAlternatives([" a ", "", "b"]) == "a | b")
    }

    // MARK: - 5. Persistence + isolation

    @Test func storeRoundTripsAndAPoisonedFileIsNotClobberedUntilSaved() throws {
        let dir = Self.scratch("store")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(PronunciationDrillStore.fileName)
        let sink = InMemoryLogSink()

        #expect(PronunciationDrillStore.load(from: url, log: sink) == PronunciationDrillStore())

        var store = PronunciationDrillStore()
        let item = PronunciationDrillList.Item(key: "mcgill", name: "McGill", kind: .surname, source: .peopleTab, carriers: 2)
        store.set(item, status: .taught, alternatives: ["MahGill"], origin: .taught, at: Date(timeIntervalSince1970: 1_700_000_000))
        store.set(name: "Edith", status: .judgedOk, at: Date(timeIntervalSince1970: 1_700_000_001))
        let list = PronunciationDrillList(items: [item])
        try store.save(to: url, manifest: .build(list: list, lexicon: Self.lexicon, store: store))
        let back = PronunciationDrillStore.load(from: url, log: sink)
        #expect(back == store)
        #expect(back.record(for: "mcgill")?.listSource == .peopleTab)
        #expect(back.record(for: "mcgill")?.source == .taught)
        #expect(back.record(for: "mcgill")?.respelling == "MahGill")
        #expect(back.record(for: "mcgill")?.alternatives == ["MahGill"])
        #expect(back.record(for: "mcgill")?.phonemes == nil)
        #expect(back.tally.taught == 1 && back.tally.judgedOk == 1 && back.tally.skipped == 0)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(PronunciationDrillStore.manifestFileName).path))

        // Poisoned: unreadable JSON → empty sheet, logged, file left alone.
        try Data("{not json".utf8).write(to: url)
        #expect(PronunciationDrillStore.load(from: url, log: sink) == PronunciationDrillStore())
        #expect(sink.lines.contains { $0.contains("pronunciation-drill.json unreadable") })
        #expect(String(data: try Data(contentsOf: url), encoding: .utf8) == "{not json")

        // Isolation: the default path is under App Support, and nothing in
        // this suite used it.
        #expect(PronunciationDrillStore.defaultFileURL.path.hasSuffix("VideoScan/Hallie/pronunciation-drill.json"))
        #expect(PronunciationDrillStore.defaultFileURL.deletingLastPathComponent()
                == HalliePronunciationLexicon.defaultFileURL.deletingLastPathComponent())
    }

    // MARK: - 6. Manifest

    @Test func manifestCarriesNameRespellingStatusAndSource() throws {
        var store = PronunciationDrillStore()
        store.set(name: "McGill", status: .alternativesPending, alternatives: ["MahGill", "MicGill"], origin: .taught)
        store.set(name: "Rick", status: .judgedOk)
        let lexicon = HalliePronunciationLexicon.merged([
            HalliePronunciationLexicon(entries: [.init(written: "McGill", spoken: "MahGill | MicGill")]),
            Self.lexicon,
        ])
        let list = PronunciationDrillList.build(
            graph: Self.graph, profiles: Self.profiles, speakers: Self.speakers, lexicon: lexicon, store: store)
        let manifest = PronunciationDrillManifest.build(list: list, lexicon: lexicon, store: store,
                                                        at: Date(timeIntervalSince1970: 0))
        let byName = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.name, $0) })
        let mcgill = try #require(byName["McGill"])
        #expect(mcgill.respelling == "MahGill")
        #expect(mcgill.alternatives == ["MahGill", "MicGill"])
        #expect(mcgill.status == .alternativesPending)
        #expect(mcgill.source == "near-ancestry")
        #expect(mcgill.kind == .surname)
        let rick = try #require(byName["Rick"])
        #expect(rick.respelling == nil && rick.status == .judgedOk && rick.source == "people-tab")
        // Taught-but-off-sheet names are listed after the sheet.
        let latta = try #require(byName["Latta"])
        #expect(latta.status == .taught && latta.respelling == "LAT-uh" && latta.kind == nil)
        #expect(manifest.entries.firstIndex { $0.name == "Latta" }! > manifest.entries.firstIndex { $0.name == "Quill" }!)

        // Machine-readable: JSON with the keys codex's audit reads.
        let json = try #require(try JSONSerialization.jsonObject(with: manifest.jsonData()) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        let entries = try #require(json["entries"] as? [[String: Any]])
        let mcgillJSON = try #require(entries.first { $0["name"] as? String == "McGill" })
        #expect(Set(mcgillJSON.keys).isSuperset(of: ["name", "key", "status", "source", "alternatives", "carriers", "origin"]))
        #expect(mcgill.origin == .taught)
    }

    // MARK: - 7. Shell parity

    @Test func shellRunsTheSameTextLoopWithoutAudio() async {
        final class Harness: @unchecked Sendable {
            var inputs = ["let's practice names", "right", "no — MahGill"]
            var output: [String] = []
            var writes: [HallieAppTurnCoordinator.PronunciationWrite] = []
            var store = PronunciationDrillStore()
            func next() -> String? { inputs.isEmpty ? nil : inputs.removeFirst() }
        }
        let harness = Harness()
        let profiles = [POIProfile(name: "McGill Family", referencePath: "/synthetic/mcgill")]
        let dependencies = HallieShellCLI.Dependencies(
            loadCatalog: { _ in [] },
            loadProfiles: { .loaded(profiles) },
            loadGraph: { _ in nil },
            translateAST: { _, _ in
                Issue.record("translation must not run during the drill")
                throw NLTranslatorError.unreachable("fixture")
            },
            executeTurn: { _, _ in throw NLTranslatorError.unreachable("fixture") },
            performMediaAction: { _ in },
            recordPronunciation: { harness.writes.append($0) },
            loadDrillStore: { harness.store },
            saveDrillStore: { store, _ in harness.store = store },
            loadLexicon: { HalliePronunciationLexicon(entries: []) })
        var options = HallieShellCLI.Options()
        options.remember = true
        options.allowActions = false
        let code = await HallieShellCLI.run(
            options: options, input: harness.next,
            output: { harness.output.append($0) }, dependencies: dependencies)
        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        let text = harness.output.joined(separator: "\n")
        #expect(text.contains("Let's practice — 2 names on the sheet. Tell me \"right\", \"skip\", or how to say it. Next name: McGill."))
        #expect(text.contains("Good. Next name: Family."))
        #expect(text.contains("OK, noted — Family. That's every name on the sheet — taught 1, judged OK 1, skipped 0."))
        #expect(harness.writes == [.init(word: "Family", saidAs: "MahGill", phonemes: "mˈɑɡɪl", target: .file)])
        #expect(harness.store.status(for: "mcgill") == .judgedOk)
        #expect(harness.store.status(for: "family") == .taught)
        #expect(text.contains("interpreted: pronunciation drill (local)"))
    }

    @Test func shellWithoutRememberKeepsTeachingForTheSessionOnly() async {
        final class Harness: @unchecked Sendable {
            var inputs = ["practice names", "say it like MahGill"]
            var output: [String] = []
            var wrote = false
            var saved = false
            func next() -> String? { inputs.isEmpty ? nil : inputs.removeFirst() }
        }
        let harness = Harness()
        let dependencies = HallieShellCLI.Dependencies(
            loadCatalog: { _ in [] },
            loadProfiles: { .loaded([POIProfile(name: "McGill", referencePath: "/synthetic/mcgill")]) },
            loadGraph: { _ in nil },
            translateAST: { _, _ in throw NLTranslatorError.unreachable("fixture") },
            executeTurn: { _, _ in throw NLTranslatorError.unreachable("fixture") },
            performMediaAction: { _ in },
            recordPronunciation: { _ in harness.wrote = true },
            saveDrillStore: { _, _ in harness.saved = true },
            loadLexicon: { HalliePronunciationLexicon(entries: []) })
        _ = await HallieShellCLI.run(
            options: HallieShellCLI.Options(), input: harness.next,
            output: { harness.output.append($0) }, dependencies: dependencies)
        let text = harness.output.joined(separator: "\n")
        #expect(text.contains("OK, noted — McGill."))
        #expect(text.contains("run with --remember to save it"))
        #expect(!harness.wrote && !harness.saved)
    }

    // MARK: - 8. Scale

    @Test func thirtyNineThousandNamesOrderInUnder200Milliseconds() {
        // 39k people in a 13k-family chain: given names cycle through 3,900
        // spellings, surnames through 390, so the sheet has ~4.3k distinct
        // names and every person has a parent and up to three children.
        var people: [PronunciationDrillList.Person] = []
        people.reserveCapacity(39_000)
        for i in 0..<39_000 {
            let parent = i == 0 ? [] : ["p\((i - 1) / 3)"]
            let children = (1...3).map { "p\(i * 3 + $0)" }.filter { Int($0.dropFirst())! < 39_000 }
            people.append(.init(
                id: "p\(i)", words: ["Given\(i % 3_900)", "Surname\(i % 390)"], surname: "Surname\(i % 390)",
                parentIDs: parent, childIDs: children, spouseIDs: []))
        }
        let profiles = PronunciationDrillList.ProfileGroup(names: ["Rick Breen", "Donna Breen"])
        let lexicon = HalliePronunciationLexicon(entries: [.init(written: "Surname7", spoken: "SEVEN")])
        let clock = ContinuousClock()
        var list = PronunciationDrillList(items: [])
        let elapsed = clock.measure {
            list = PronunciationDrillList.build(
                people: people, rootIDs: ["p0"], profiles: profiles, lexicon: lexicon, store: PronunciationDrillStore())
        }
        #expect(elapsed < .milliseconds(200), "took \(elapsed)")
        #expect(list.items.count == 3 + 3_900 + 390 - 1)
        #expect(list.items.prefix(3).map(\.name) == ["Rick", "Breen", "Donna"])
        // The root's own name is next (near ancestry, generation 0).
        #expect(list.items[3].name == "Given0")
        #expect(!list.items.contains { $0.name == "Surname7" })
        // Finding the next pending name is cheap too.
        let hop = clock.measure { _ = list.nextPending(from: 0, store: PronunciationDrillStore()) }
        #expect(hop < .milliseconds(20))
    }

    // MARK: - 9. Descriptive hints (live miss #14) and questions (#15)

    @Test func ricksHintSentencesAreHintsNotSearches() throws {
        typealias H = HalliePronunciationHint
        let a = try #require(HallieTellingMode.detectPronunciationHint("Latta should be pronounced with a short a on the La"))
        #expect(a == .init(word: "Latta", hint: .vowel(letter: "a", length: .short, syllable: "La")))
        #expect(HalliePronunciationRespelling.respelling(for: "Latta", hint: a.hint) == "LAT-uh")

        let b = try #require(HallieTellingMode.detectPronunciationHint(
            "Latta should be pronounced La (as in Lag) and Tah, so short a on Latta"))
        #expect(b == .init(word: "Latta", hint: .syllables([.init(text: "La", exemplar: "Lag"), .init(text: "Tah", exemplar: nil)])))
        #expect(HalliePronunciationRespelling.respelling(for: "Latta", hint: b.hint) == "LA-tah")
        #expect(b.hint.description == "La (as in Lag) and Tah")

        // The rest of the vocabulary.
        #expect(HallieTellingMode.detectPronunciationHint("Nathaniel with the stress on the second syllable")?.hint == .stress(.second))
        #expect(HalliePronunciationRespelling.respelling(for: "Nathaniel", hint: .stress(.second)) == "na-THA-niel")
        #expect(HallieTellingMode.detectPronunciationHint("the a in Latta is like in father")?.hint == .vowelLike(letter: "a", exemplar: "father"))
        #expect(HalliePronunciationRespelling.respelling(for: "Latta", hint: .vowelLike(letter: "a", exemplar: "father")) == "LAHT-uh")
        #expect(HalliePronunciationRespelling.respelling(for: "Latta", hint: .vowel(letter: "a", length: .long, syllable: nil)) == "LAY-tuh")
        #expect(HallieTellingMode.detectPronunciationHint("McGill has a hard g")?.hint == .hardG)
        #expect(HallieTellingMode.detectPronunciationHint("the t in Latta is silent")?.hint == .silent("t"))
        #expect(HalliePronunciationRespelling.respelling(for: "Latta", hint: .silent("t")) == "LA-uh")
        #expect(HallieTellingMode.detectPronunciationHint("Latta rhymes with data")?.hint == .rhymes(with: "data"))
        #expect(HalliePronunciationRespelling.respelling(for: "Latta", hint: .rhymes(with: "data")) == nil)
        // A syllable the name does not have cannot be mapped.
        #expect(HalliePronunciationRespelling.respelling(for: "Edith", hint: .vowel(letter: "a", length: .short, syllable: "La")) == nil)
        #expect(HalliePronunciationRespelling.syllables("Latta") == ["lat", "ta"])
        #expect(HalliePronunciationRespelling.syllables("Edith") == ["e", "dith"])
        #expect(HalliePronunciationRespelling.syllables("McLaughlin") == ["mclaugh", "lin"])

        // Not hints: questions, ordinary sentences, plain respellings.
        #expect(HallieTellingMode.detectPronunciationHint("is Latta pronounced with a short a?") == nil)
        #expect(HallieTellingMode.detectPronunciationHint("Donna went home with a short nap") == nil)
        #expect(HallieTellingMode.detectPronunciationHint("Latta is pronounced LAT-uh") == nil)
    }

    @Test func hintsAreKeptAndReadBackOrAskedForASpellingNeverSearched() async throws {
        let recorder = Recorder()
        // Rick's first sentence: mapped, kept, read back.
        let a = try await turn("Latta should be pronounced with a short a on the La", drill: nil, recorder: recorder)
        #expect(a.result.prose == "OK, noted — Latta. From your hint (short a on La), I'll say Latta as LAT-uh from now on. I've kept that in the pronunciation list.")
        #expect(recorder.writes.last == .init(word: "Latta", saidAs: "LAT-uh", phonemes: "lˈætə", target: .file))
        #expect(a.result.route == .telling && a.result.queryDescription == "pronunciation hint")
        #expect(a.executedIntent == nil)
        #expect(recorder.store.record(for: "latta")?.source == .derived)
        #expect(recorder.store.record(for: "latta")?.hint == "short a on La")

        // Rick's second sentence: explicit syllables with an exemplar.
        let b = try await turn("Latta should be pronounced La (as in Lag) and Tah, so short a on Latta", drill: nil, recorder: recorder)
        #expect(b.result.prose.hasPrefix("OK, noted — Latta. From your hint (La (as in Lag) and Tah), I'll say Latta as LA-tah from now on."))
        #expect(recorder.writes.last?.saidAs == "LA-tah")
        let last = try #require(recorder.writes.last)
        let spoken = HallieSpeaker.spokenText(b.result.prose, lexicon: .init(entries: [.init(written: last.word, spoken: last.saidAs)]))
        #expect(spoken.hasPrefix("OK, noted — LA-tah."))

        // Not mappable: the hint is kept for the variations picker; ask.
        let c = try await turn("Latta rhymes with data", drill: nil, recorder: recorder)
        #expect(c.result.prose == "I've noted “rhymes with data” for Latta — I'll offer you a few ways to say it next; for now, spell it out for me like “LAT-uh”?")
        #expect(recorder.writes.count == 2)
        #expect(recorder.store.record(for: "latta")?.hint == "rhymes with data")
        #expect(recorder.store.record(for: "latta")?.respelling == "LA-tah")

        // An unknown subject is not a hint (nil → ordinary answering).
        #expect(HallieAppTurnCoordinator.isKnownName("Zorblax", dependencies: dependencies(recorder)) == false)
        #expect(HallieAppTurnCoordinator.knownSpelling("latta", dependencies: dependencies(recorder)) == "Latta")
        #expect(HallieAppTurnCoordinator.knownSpelling("timmy", dependencies: dependencies(recorder)) == "Timmy")
    }

    @Test func pronunciationQuestionsAreAnsweredFromTheLexicon() async throws {
        typealias Q = HalliePronunciationQuery
        #expect(Q.detect("tell me latta pronounciations") == .name("latta"))
        #expect(Q.detect("how do you say McGill?") == .name("McGill"))
        #expect(Q.detect("How is Edith pronounced") == .name("Edith"))
        #expect(Q.detect("what's the pronunciation of Latta?") == .name("Latta"))
        #expect(Q.detect("what pronunciations do you have?") == .list)
        #expect(Q.detect("list the pronunciations") == .list)
        #expect(Q.detect("which names have I taught you?") == .list)
        #expect(Q.detect("show me videos of Latta") == nil)
        #expect(Q.detect("tell me about Latta") == nil)

        let recorder = Recorder()
        // Taught in the fixture lexicon (file layer), not by Rick today.
        let known = try await turn("tell me latta pronounciations", drill: nil, recorder: recorder)
        #expect(known.result.prose == "I say Latta as LAT-uh — that's in the pronunciation list.")
        #expect(known.result.route == .telling && known.executedIntent == nil)
        // Untaught but known name.
        let untaught = try await turn("how do you say Timmy?", drill: nil, recorder: recorder)
        #expect(untaught.result.prose == "I don't have a note for Timmy; I'd say it as Kokoro does — tell me how (\"pronounce Timmy like LAT-uh\").")
        // After Rick teaches it, the answer says when.
        _ = try await turn("pronounce McGill like MahGill or MicGill", drill: nil, recorder: recorder)
        let today = try await turn("how do you say McGill?", drill: nil, recorder: recorder)
        let label = Q.whenLabel(Date(), now: Date())
        #expect(today.result.prose == "I say McGill as MahGill (or MicGill) — you taught me that \(label).")
        #expect(label.hasPrefix("today ("))
        #expect(HallieSpeaker.spokenText(today.result.prose, lexicon: recorder.taughtLexicon).hasPrefix("I say MahGill as MahGill"))
        // The list form.
        let list = try await turn("what pronunciations do you have?", drill: nil, recorder: recorder)
        #expect(list.result.prose == "I have 2 taught pronunciations: Latta as LAT-uh, McGill as MahGill.")
        #expect(Q.listAnswer(lexicon: .init(entries: [])).hasPrefix("I don't have any taught pronunciations yet"))
        #expect(Q.whenLabel(Date(timeIntervalSince1970: 86_400 * 200), now: Date()).hasPrefix("on "))
    }

    @Test func hintsWorkInsideTheDrillForTheNameThatIsUp() async throws {
        let recorder = Recorder()
        let start = try await turn("let's practice names", drill: nil, recorder: recorder)
        // Subject-less hint applies to the current name (Rick).
        let hinted = try await turn("stress on the first syllable", drill: start.drill, recorder: recorder)
        #expect(hinted.result.prose == "OK, noted — Rick. From your hint (stress on the first syllable), I'll say Rick as RICK. Next name: Breen.")
        #expect(recorder.writes.last == .init(word: "Rick", saidAs: "RICK", phonemes: "ɹˈɪk", target: .file))
        #expect(recorder.store.record(for: "rick")?.source == .derived)
        // Unmappable: stays on the name, keeps the hint.
        let ask = try await turn("Breen rhymes with green", drill: hinted.drill, recorder: recorder)
        #expect(ask.result.prose.hasSuffix("Still on: Breen."))
        #expect(ask.drill?.current?.name == "Breen")
        #expect(recorder.store.record(for: "breen")?.hint == "rhymes with green")
        #expect(recorder.store.status(for: "breen") == .untested)
    }

    @Test func shellAnswersPronunciationQuestionsAndHintsWithoutSearching() async {
        final class Harness: @unchecked Sendable {
            var inputs = ["tell me latta pronounciations", "Latta should be pronounced with a short a on the La",
                          "how do you say Latta?", "what pronunciations do you have?"]
            var output: [String] = []
            var writes: [HallieAppTurnCoordinator.PronunciationWrite] = []
            var store = PronunciationDrillStore()
            var lexicon = HalliePronunciationLexicon(entries: [.init(written: "Latta", spoken: "Lah-Tah")])
            func next() -> String? { inputs.isEmpty ? nil : inputs.removeFirst() }
        }
        let harness = Harness()
        let dependencies = HallieShellCLI.Dependencies(
            loadCatalog: { _ in [] },
            loadProfiles: { .loaded([]) },
            loadGraph: { _ in nil },
            translateAST: { _, _ in
                Issue.record("a pronunciation turn must never translate")
                throw NLTranslatorError.unreachable("fixture")
            },
            executeTurn: { _, _ in throw NLTranslatorError.unreachable("fixture") },
            performMediaAction: { _ in },
            recordPronunciation: { write in
                harness.writes.append(write)
                harness.lexicon = .init(entries: [.init(written: write.word, spoken: write.saidAs)])
            },
            loadDrillStore: { harness.store },
            saveDrillStore: { store, _ in harness.store = store },
            loadLexicon: { harness.lexicon })
        var options = HallieShellCLI.Options()
        options.remember = true
        _ = await HallieShellCLI.run(options: options, input: harness.next,
                                     output: { harness.output.append($0) }, dependencies: dependencies)
        let text = harness.output.joined(separator: "\n")
        #expect(text.contains("I say Latta as Lah-Tah — that's in the pronunciation list."))
        #expect(text.contains("OK, noted — Latta. From your hint (short a on La), I'll say Latta as LAT-uh from now on."))
        #expect(harness.writes == [.init(word: "Latta", saidAs: "LAT-uh", phonemes: "lˈætə", target: .file)])
        #expect(text.contains("I say Latta as LAT-uh — you taught me that today ("))
        #expect(text.contains("I have 1 taught pronunciation: Latta as LAT-uh."))
        #expect(text.contains("interpreted: pronunciation question (local)"))
    }

    // MARK: - 10. Phonemes (lexicon v2, docs/pronunciation_training_research.md)

    @Test func respellingsDeriveMisakiPhonemesDeterministically() {
        typealias P = HalliePhonemes
        #expect(P.derive(respelling: "LAT-uh") == "lˈætə")
        #expect(P.derive(respelling: "Lah-Tah") == "lˈɑtɑ")
        #expect(P.derive(respelling: "LA-tah") == "lˈætɑ")
        #expect(P.derive(respelling: "muh-GILL") == "məɡˈɪl")
        #expect(P.derive(respelling: "EE-dith") == "ˈidɪθ")
        #expect(P.derive(respelling: "nuh-THAN-yul") == "nəθˈænjəl")
        #expect(P.derive(respelling: "beh-THY-uh") == "bɛθˈIə")
        #expect(P.derive(respelling: "muh-GLOCK-lin") == "məɡlˈɑklɪn")
        #expect(P.derive(respelling: "muh-CAR-thee") == "məkˈɑɹθi")
        #expect(P.derive(respelling: "muh-DON-uld") == "mədˈɑnəld")
        #expect(P.derive(respelling: "ROW-nin") == "ɹˈOnɪn")
        #expect(P.derive(respelling: "HEN-door") == "hˈɛndɔɹ")
        #expect(P.derive(respelling: "MahGill") == "mˈɑɡɪl")
        // The "as in Lag" exemplar pins the vowel of that syllable.
        #expect(P.derive(respelling: "LA-tah", exemplarVowels: [0: "æ"]) == "lˈætɑ")
        #expect(P.derive(respelling: "LA-tah", exemplarVowels: [0: "ɑ"]) == "lˈɑtɑ")
        // Unreadable spellings never become phonemes.
        #expect(P.derive(respelling: "LAT-uh!") == nil)
        #expect(P.derive(respelling: "Lat7a") == nil)
        #expect(P.derive(respelling: "") == nil)
        #expect(P.stressedVowel(in: "lˈæɡ") == "æ")
        #expect(P.stressedVowel(in: "fˈɑðəɹ") == "ɑ")
        #expect(P.stressedVowel(in: "dˈAɾə") == "A")
        #expect(P.stressedVowel(in: "bɜɹd") == "ɜɹ")
        // No dots, ever (a `.` is a pause to misaki).
        for entry in HalliePronunciationLexicon.shipped.entries {
            #expect(entry.phonemes?.contains(".") != true, Comment(rawValue: entry.written))
        }
        #expect(HalliePronunciationLexicon.shipped.entries.first { $0.written == "Latta" }?.phonemes == "lˈætə")
        #expect(HalliePronunciationLexicon.shipped.entries.first { $0.written == "Breen" }?.phonemes == nil)
        // Gold exemplar lookup works when the helper bundle is installed and
        // is silent otherwise.
        let gold = MisakiGoldLexicon(url: nil)
        #expect(!gold.isAvailable && gold.phonemes(for: "lag") == nil)
        #expect(HalliePhonemes.exemplarVowel("lag", gold: gold) == nil)
        if MisakiGoldLexicon.shared.isAvailable {
            #expect(HalliePhonemes.exemplarVowel("lag") == "æ")
            #expect(HalliePhonemes.exemplarVowel("father") == "ɑ")
        }
    }

    @Test func kokoroGetsPhonemeLinksAndAppleSpeechGetsRespellings() throws {
        let table = HalliePronunciationLexicon(entries: [
            .init(written: "Latta", spoken: "LAT-uh", phonemes: "lˈætə"),
            .init(written: "McGill", spoken: "MahGill | MicGill"),
        ])
        let prose = "OK, noted — Latta. Edith Latta married a McGill."
        #expect(HallieSpeaker.spokenText(prose, lexicon: table) == "OK, noted — LAT-uh. Edith LAT-uh married a MahGill.")
        #expect(HallieSpeaker.spokenText(prose, lexicon: table, phonemeLinks: true)
                == "OK, noted — [Latta](/lˈætə/). Edith [Latta](/lˈætə/) married a MahGill.")
        #expect(HallieSpeaker.sentences(prose, lexicon: table, phonemeLinks: true)
                == ["OK, noted, [Latta](/lˈætə/).", "Edith [Latta](/lˈætə/) married a MahGill."])
        // The Apple fallback never reads brackets.
        #expect(table.strippingPhonemeLinks("OK, noted, [Latta](/lˈætə/).") == "OK, noted, LAT-uh.")
        #expect(HalliePronunciationLexicon.strippingPhonemeLinks("[Zed](/zˈɛd/) here") == "Zed here")
        #expect(HalliePronunciationLexicon.strippingPhonemeLinks("no links") == "no links")
        // An entry with phonemes but an identity respelling still overrides on Kokoro.
        let identity = HalliePronunciationLexicon(entries: [.init(written: "Breen", spoken: "Breen", phonemes: "bɹˈin")])
        #expect(identity.apply(to: "Rick Breen").spoken == "Rick Breen")
        #expect(identity.apply(to: "Rick Breen", style: .kokoro).spoken == "Rick [Breen](/bɹˈin/)")

        // v2 JSON round trip: objects for entries with phonemes, strings for
        // legacy ones; unknown fields survive a read-modify-write.
        let dir = Self.scratch("lexicon-v2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(HalliePronunciationLexicon.fileName)
        try Data("""
        {"Latta": {"respelling": "Lah-Tah", "phonemes": "lˈɑtɑ", "source": "picked", "confidence": 1.0,
                   "alternatives": ["lˈætə"], "attested": {"by": "rick", "at": "2026-08-30T15:02Z"}},
         "McGill": "muh-GILL"}
        """.utf8).write(to: url)
        let sink = InMemoryLogSink()
        let loaded = HalliePronunciationLexicon.load(from: url, log: sink)
        #expect(loaded.entries.map(\.written) == ["McGill", "Latta"])
        #expect(loaded.entries.first { $0.written == "Latta" } == .init(written: "Latta", spoken: "Lah-Tah", phonemes: "lˈɑtɑ"))
        #expect(loaded.entries.first { $0.written == "Latta" }?.origin == "picked")
        #expect(loaded.apply(to: "Latta", style: .kokoro).spoken == "[Latta](/lˈɑtɑ/)")
        try HalliePronunciationLexicon.setFileEntry(written: "Edith", spoken: "EE-dith", phonemes: "ˈidɪθ", origin: "told", url: url, log: sink)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["McGill"] as? String == "muh-GILL")
        let latta = try #require(json["Latta"] as? [String: Any])
        #expect(latta["phonemes"] as? String == "lˈɑtɑ")
        #expect(latta["confidence"] as? Double == 1.0)
        #expect((latta["alternatives"] as? [String]) == ["lˈætə"])
        #expect((latta["attested"] as? [String: Any])?["by"] as? String == "rick")
        let edith = try #require(json["Edith"] as? [String: Any])
        #expect(edith["respelling"] as? String == "EE-dith" && edith["phonemes"] as? String == "ˈidɪθ" && edith["source"] as? String == "told")
        #expect((edith["attested"] as? [String: Any])?["at"] != nil)

        // A person-level respelling (no phonemes) borrows the file's
        // phonemes for the same respelling.
        let person = HalliePronunciationLexicon(entries: [.init(written: "Latta", spoken: "Lah-Tah")])
        let merged = HalliePronunciationLexicon.merged([person, loaded])
        #expect(merged.entries.first { $0.written == "Latta" }?.phonemes == "lˈɑtɑ")
        let other = HalliePronunciationLexicon(entries: [.init(written: "Latta", spoken: "LAT-uh")])
        #expect(HalliePronunciationLexicon.merged([other, loaded]).entries.first { $0.written == "Latta" }?.phonemes == nil)
    }

    @Test func aTeachStoresPhonemesBesideTheRespellingAndTheReadBackUsesThem() async throws {
        let recorder = Recorder()
        let taught = try await turn("Latta should be pronounced La (as in Lag) and Tah, so short a on Latta", drill: nil, recorder: recorder)
        let write = try #require(recorder.writes.last)
        #expect(write == .init(word: "Latta", saidAs: "LA-tah", phonemes: "lˈætɑ", target: .file))
        #expect(write.phonemes == "lˈætɑ")
        #expect(recorder.store.record(for: "latta")?.phonemes == "lˈætɑ")
        #expect(recorder.store.record(for: "latta")?.source == .derived)
        let voice = HalliePronunciationLexicon(entries: [.init(written: write.word, spoken: write.saidAs, phonemes: write.phonemes)])
        #expect(HallieSpeaker.spokenText(taught.result.prose, lexicon: voice, phonemeLinks: true).hasPrefix("OK, noted — [Latta](/lˈætɑ/)."))
        #expect(HallieSpeaker.spokenText(taught.result.prose, lexicon: voice).hasPrefix("OK, noted — LA-tah."))
        // Plain typed respellings derive too; unreadable ones stay nil.
        _ = try await turn("pronounce McGill like MahGill or MicGill", drill: nil, recorder: recorder)
        #expect(recorder.writes.last?.phonemes == "mˈɑɡɪl")
        _ = try await turn("say Edith as EE-d1th", drill: nil, recorder: recorder)
        #expect(recorder.writes.last?.word == "Edith" && recorder.writes.last?.phonemes == nil)
        // The manifest carries phonemes for codex's audit.
        let manifest = try #require(recorder.lastManifest)
        #expect(manifest.entries.first { $0.name == "McGill" }?.phonemes == "mˈɑɡɪl")
    }

    // MARK: - 11. Free-form teaches (live misses #17/#18, 2026-08-29 17:35–17:58)

    /// Rick's exact sentences, as typed. None may reach translation.
    static let rickFreeformSentences: [String] = [
        "Latta is prounounced like Ladder but with Laddah or Lattah short a first ah second, like ladder but latt ah",
        "the family name \"Latta\" should be pronounced with a short a, like in Ladder, but it would be \"Latt uh\"",
        "you should pronounce \"Latta\" like \"Ladder\" but \"Latt ah\"",
    ]

    @Test func pronounceWordsAreReadTypoTolerantly() {
        typealias W = HalliePronounceWords
        #expect(W.canonicalForm("prounounced") == "pronounced")
        #expect(W.canonicalForm("pronunced") == "pronounced")
        #expect(W.canonicalForm("Pronounciation") == "pronunciation")
        #expect(W.canonicalForm("pronounciations") == "pronunciations")
        #expect(W.canonicalForm("pronounce") == "pronounce")
        #expect(W.canonicalForm("pronouncing") == "pronouncing")
        #expect(W.canonicalForm("pronoun") == nil)
        #expect(W.canonicalForm("pronouns") == nil)
        #expect(W.canonicalForm("produce") == nil)
        #expect(W.canonicalForm("province") == nil)
        #expect(W.canonicalForm("Latta") == nil)
        #expect(W.normalize("Latta is prounounced Lah-Tah") == "Latta is pronounced Lah-Tah")
        #expect(W.normalize("tell me latta pronounciations") == "tell me latta pronunciations")
        #expect(W.normalize("Prounounce it LAT-uh!") == "Pronounce it LAT-uh!")
        #expect(W.editDistance("kitten", "sitting") == 3)
        // The strict detectors read the corrected word.
        #expect(HallieTellingMode.detectPronunciation("Latta is prounounced Lah-Tah")
                == .init(word: "Latta", saidAs: "Lah-Tah"))
        #expect(HallieTellingMode.detectPronunciationHint("Latta should be prounounced with a short a on the La")?.hint
                == .vowel(letter: "a", length: .short, syllable: "La"))
        #expect(HalliePronunciationQuery.detect("how do you prounounce Latta?") == .name("Latta"))
    }

    @Test func ricksFreeformSentencesParseToTeaches() throws {
        typealias F = HalliePronunciationFreeform
        let known: (String) -> Bool = { ["latta", "mcgill", "edith"].contains(FamilyIdentityText.normalized($0)) }

        // #17: two respellings plus a description and an exemplar. Explicit
        // respellings win; both kept; the one the cues support best and
        // that sits nearest the written name is spoken.
        let a = try #require(F.detect(Self.rickFreeformSentences[0], isKnownName: known))
        #expect(a.word == "Latta" && a.kind == .teach && a.explicit)
        #expect(a.alternatives == ["LAT-tah", "LAD-dah"])
        #expect(a.cueSummary == "short a, then ah")
        #expect(a.uncertain)
        #expect(a.rawHint.contains("Laddah or Lattah"))

        // #18: "the family name", quoted, "Latt uh" as two words.
        let b = try #require(F.detect(Self.rickFreeformSentences[1], isKnownName: known))
        #expect(b.word == "Latta" && b.kind == .teach)
        #expect(b.alternatives == ["LAT-uh"])
        #expect(b.cueSummary == "short a")
        #expect(!b.uncertain)

        // 17:58: second-person imperative; "but <respelling>" beats the exemplar.
        let c = try #require(F.detect(Self.rickFreeformSentences[2], isKnownName: known))
        #expect(c.word == "Latta" && c.kind == .teach)
        #expect(c.alternatives == ["LAT-ah"])
        #expect(c.cueSummary == "like ladder")

        // Plain alternatives, no cues: as typed, first spoken.
        let d = try #require(F.detect("Latta is prounounced Laddah or Lattah, both are fine", isKnownName: known))
        #expect(d.alternatives == ["Laddah", "Lattah"] && !d.uncertain && d.cueSummary == nil)

        // Exemplar only: the vowel comes from the exemplar table / gold lexicon.
        let e = try #require(F.detect("Latta is prounounced like ladder", isKnownName: known))
        #expect(e.kind == .teach && e.alternatives == ["LAT-uh"] && !e.explicit)
        #expect(F.exemplarVowel("ladder") == "æ")
        #expect(F.exemplarVowel("father") == "ɑ")
        let f = try #require(F.detect("Latta is prounounced with a short a first and ah second", isKnownName: known))
        #expect(f.kind == .teach && f.alternatives == ["LAT-ah"] && !f.explicit)
        #expect(f.cueSummary == "short a, then ah")

        // Question shape → a query; nothing mappable → a kept hint.
        #expect(F.detect("is Latta prounounced with a short a?", isKnownName: known)?.kind == .query)
        #expect(F.detect("Latta is prounounced the Scottish way", isKnownName: known)?.kind == .hintOnly)

        // Not ours: no pronounce-word, or no name the archive knows.
        #expect(F.detect("Latta is said like Ladder", isKnownName: known) == nil)
        #expect(F.detect("Zorblax is prounounced ZOR-blax", isKnownName: known) == nil)
        #expect(F.detect("Donna's pronouns are she and her", isKnownName: { _ in true }) == nil)

        // Canonical forms and support scoring.
        #expect(F.canonicalRespelling("Lattah", cues: [.vowel(letter: "a", length: .short, position: 0)]) == "LAT-tah")
        #expect(F.canonicalRespelling("latt-uh", cues: [.exemplar("ladder")]) == "LAT-uh")
        #expect(F.canonicalRespelling("LAT-uh", cues: [.stress(1)]) == "LAT-uh")
        #expect(F.canonicalRespelling("MahGill", cues: [.stress(1)]) == "MahGill")
        #expect(F.support("LAT-tah", cues: [.vowel(letter: "a", length: .short, position: 0), .sound("ah", position: 1), .exemplar("ladder")]) == 3)
        #expect(F.support("LAY-tuh", cues: [.vowel(letter: "a", length: .short, position: 0)]) == 0)
        #expect(HalliePhonemes.derive(respelling: "LAT-tah") == "lˈætɑ")
        #expect(HalliePhonemes.derive(respelling: "LAD-dah") == "lˈædɑ")
    }

    @Test func ricksFreeformSentencesAreKeptAndReadBackNeverSearched() async throws {
        let recorder = Recorder()
        // #17 — uncertain: says what was chosen and the alternative, invites "no — …".
        let a = try await turn(Self.rickFreeformSentences[0], drill: nil, recorder: recorder)
        #expect(a.result.prose == "OK, noted — Latta. I'll say LAT-tah (short a, then ah) and keep LAD-dah too. Say 'no — …' if that's off. I've kept that in the pronunciation list.")
        #expect(a.result.route == .telling && a.result.queryDescription == "pronunciation" && a.executedIntent == nil)
        #expect(recorder.writes.last == .init(word: "Latta", saidAs: "LAT-tah | LAD-dah", phonemes: "lˈætɑ", target: .file))
        #expect(recorder.store.record(for: "latta")?.status == .alternativesPending)
        #expect(recorder.store.record(for: "latta")?.source == .taught)
        #expect(recorder.store.record(for: "latta")?.alternatives == ["LAT-tah", "LAD-dah"])
        #expect(recorder.store.record(for: "latta")?.hint?.contains("Laddah or Lattah") == true)
        // The read-back is spoken with the new entry in force.
        let spoken = HallieSpeaker.spokenText(a.result.prose, lexicon: recorder.taughtLexicon)
        #expect(spoken.hasPrefix("OK, noted — LAT-tah."))

        // #18 — one respelling, cues agree.
        let b = try await turn(Self.rickFreeformSentences[1], drill: nil, recorder: recorder)
        #expect(b.result.prose == "OK, noted — Latta. I'll say Latta as LAT-uh (short a) from now on. I've kept that in the pronunciation list.")
        #expect(recorder.writes.last == .init(word: "Latta", saidAs: "LAT-uh", phonemes: "lˈætə", target: .file))
        #expect(recorder.store.record(for: "latta")?.status == .taught)

        // 17:58 — second-person imperative.
        let c = try await turn(Self.rickFreeformSentences[2], drill: nil, recorder: recorder)
        #expect(c.result.prose.hasPrefix("OK, noted — Latta. I'll say Latta as LAT-ah (like ladder) from now on."))
        #expect(recorder.writes.last?.saidAs == "LAT-ah")

        // The earlier sentences still take their own paths.
        let d = try await turn("Latta is prounounced Lah-Tah", drill: nil, recorder: recorder)
        #expect(d.result.prose.hasPrefix("OK, noted — Latta. I'll say Latta as Lah-Tah from now on."))
        let e = try await turn("Latta should be prounounced with a short a on the La", drill: nil, recorder: recorder)
        #expect(e.result.prose.hasPrefix("OK, noted — Latta. From your hint (short a on La), I'll say Latta as LAT-uh from now on."))
        // (The fixture lexicon is first-write-wins, so the sheet still says LAT-tah.)
        let f = try await turn("tell me latta pronounciations", drill: nil, recorder: recorder)
        #expect(f.result.prose.hasPrefix("I say Latta as LAT-tah (or LAD-dah) — you taught me that today ("))

        // Question shape through the free-form path; unmappable → kept, asked.
        let g = try await turn("is Latta prounounced with a short a?", drill: nil, recorder: recorder)
        #expect(g.result.prose.hasPrefix("I say Latta as LAT-tah"))
        #expect(g.result.queryDescription == "pronunciation question")
        let h = try await turn("Latta is prounounced the Scottish way", drill: nil, recorder: recorder)
        #expect(h.result.prose == "I've noted what you said about Latta — spell it out for me like “LAT-uh” and I'll say it that way?")
        #expect(recorder.store.record(for: "latta")?.hint == "is the Scottish way")
        #expect(recorder.writes.count == 5)
    }

    @Test func freeformTeachesWorkInsideTheDrill() async throws {
        let recorder = Recorder()
        let start = try await turn("let's practice names", drill: nil, recorder: recorder)
        // A name off the sheet (Latta is already taught) but known to the archive.
        let taught = try await turn(Self.rickFreeformSentences[0], drill: start.drill, recorder: recorder)
        #expect(taught.result.prose == "OK, noted — Latta. I'll say LAT-tah and keep LAD-dah too. Still on: Rick.")
        #expect(recorder.writes.last?.saidAs == "LAT-tah | LAD-dah")
        #expect(taught.drill?.current?.name == "Rick")
        // The name that is up, with a typo'd verb.
        let rick = try await turn("Rick is prounounced RICK", drill: taught.drill, recorder: recorder)
        #expect(rick.result.prose.hasPrefix("OK, noted — Rick."))
        #expect(rick.drill?.current?.name == "Breen")
        // A free-form sentence about a name nobody carries is not a judgement.
        #expect(HalliePronunciationDrillMode.classify("Zorblax is prounounced like ladder but Zorblah", session: rick.drill!) == .unrecognized)
    }
}
