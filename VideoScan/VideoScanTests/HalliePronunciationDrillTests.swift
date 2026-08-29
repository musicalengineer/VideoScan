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
        store.set(name: "McGill", status: .alternativesPending, respelling: "MahGill | MicGill")
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
        #expect(recorder.writes.last == .init(word: "Edith", saidAs: "Ee-dith",
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
        #expect(failed.result.prose == "I couldn't save that — read-only volume. Saying Rick the new way won't stick, sorry. Still on: Rick.")
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
        store.set(item, status: .taught, respelling: "MahGill", at: Date(timeIntervalSince1970: 1_700_000_000))
        store.set(name: "Edith", status: .judgedOk, respelling: nil, at: Date(timeIntervalSince1970: 1_700_000_001))
        let list = PronunciationDrillList(items: [item])
        try store.save(to: url, manifest: .build(list: list, lexicon: Self.lexicon, store: store))
        let back = PronunciationDrillStore.load(from: url, log: sink)
        #expect(back == store)
        #expect(back.record(for: "mcgill")?.source == .peopleTab)
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
        store.set(name: "McGill", status: .alternativesPending, respelling: "MahGill | MicGill")
        store.set(name: "Rick", status: .judgedOk, respelling: nil)
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
        let first = try #require(entries.first)
        #expect(Set(first.keys).isSuperset(of: ["name", "key", "status", "source", "alternatives", "carriers"]))
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
        #expect(harness.writes == [.init(word: "Family", saidAs: "MahGill", target: .file)])
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
        #expect(list.items.count == 2 + 3_900 + 390 - 1)
        #expect(list.items.prefix(2).map(\.name) == ["Rick", "Breen"])
        // The root's own name is next (near ancestry, generation 0).
        #expect(list.items[2].name == "Given0")
        #expect(!list.items.contains { $0.name == "Surname7" })
        // Finding the next pending name is cheap too.
        let hop = clock.measure { _ = list.nextPending(from: 0, store: PronunciationDrillStore()) }
        #expect(hop < .milliseconds(20))
    }
}
