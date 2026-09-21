// HallieKindWordsTests.swift
// Rick's kind words (HallieKindWords, 2026-09-21). Fixtures only: every
// name and line here is invented — never Rick's real text, never the real
// file. Four dimensions: LOGIC (loader, rotation, once-per-subject, reset,
// UUID keying, greeting, the answers that get none), ISOLATION (test-host
// default is scratch; a real-looking file elsewhere is never read), and a
// SENSOR (a biography answer carries exactly one line, end to end through
// the shell, the coordinator and the app commit).

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Shared fixtures

private enum KindFixture {
    static let ellenUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    static let bethUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    static let ellenLines = [
        "Ellen could make a rainy Tuesday feel like a holiday.",
        "Nobody bakes a better blueberry pie than Ellen.",
    ]
    static let bethLine = "Beth has the steadiest hands and the kindest heart in the family."

    static let book = HallieKindWordsBook(people: [
        ellenUUID: .init(display: "Ellen", lines: ellenLines),
        bethUUID: .init(display: "Beth", lines: [bethLine]),
    ])

    static func json(people: [String: Any], schemaVersion: Int = 1) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": schemaVersion,
            "note": "fixture — invented lines",
            "people": people,
        ])
    }

    static var fileJSON: Data {
        json(people: [
            ellenUUID.uuidString: [
                "display": "Ellen",
                "lines": [
                    ["text": ellenLines[0], "addedAt": "2026-09-21T12:00:00Z", "by": "Fixture"],
                    ["text": ellenLines[1], "addedAt": "2026-09-21T12:00:00Z", "by": "Fixture",
                     "updatedAt": "2026-09-21T13:00:00Z"],
                ],
            ],
            bethUUID.uuidString: [
                "display": "Beth",
                "lines": [["text": bethLine, "addedAt": "2026-09-21T12:00:00Z", "by": "Fixture"]],
            ],
        ])
    }

    static func scratchDirectory(_ tag: String = #function) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VideoScan-tests/kind-words-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func ellenProfile(name: String = "Ellen", aliases: [String] = ["Ellie"],
                             treeIdentity: TreeIdentity? = nil) -> HallieTurnExecutor.ProfileSnapshot {
        .init(stableID: ellenUUID.uuidString, canonicalName: name, aliases: aliases,
              uuid: ellenUUID, treeIdentity: treeIdentity)
    }

    static func bethProfile() -> HallieTurnExecutor.ProfileSnapshot {
        .init(stableID: bethUUID.uuidString, canonicalName: "Elizabeth", aliases: ["Beth"],
              uuid: bethUUID)
    }

    static func biographyResult(name: String?, prose: String = "Ellen Fixture is in the People tab.",
                                route: HallieTurnExecutor.Route = .graph,
                                outcome: HallieTurnExecutor.Outcome = .answered) -> HallieTurnExecutor.Result {
        .init(route: route, outcome: outcome, prose: prose, basisLine: "Checked: fixture.",
              queryDescription: "shape=graph operation=biography", citations: [],
              catalogPersonName: name)
    }

    static func biographyAST(_ typed: String) -> ArchivistQueryAST {
        .graph(.init(people: [typed], operation: .biography))
    }

    static func greetingResult() -> HallieTurnExecutor.Result {
        HallieTurnExecutor.commandResult(.smalltalk(.greeting))
    }
}

/// A Sendable log sink for the store's injected logger.
private final class KindWordsLogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

// MARK: - LOGIC: the loader

@Suite("Hallie kind words — loader")
struct HallieKindWordsLoaderTests {
    @Test func decodesTheFileShapeIgnoringBookkeepingKeys() throws {
        let book = try HallieKindWordsBook.decode(KindFixture.fileJSON)
        #expect(book.people.count == 2)
        #expect(book.people[KindFixture.ellenUUID]?.display == "Ellen")
        #expect(book.people[KindFixture.ellenUUID]?.lines == KindFixture.ellenLines)
        #expect(book.people[KindFixture.bethUUID]?.lines == [KindFixture.bethLine])
    }

    @Test func skipsNonUUIDKeysAndEmptyLinesAndFinishesSentences() throws {
        let data = KindFixture.json(people: [
            "not-a-uuid": ["display": "Nobody", "lines": [["text": "Ignored line."]]],
            KindFixture.ellenUUID.uuidString: [
                "display": "Ellen",
                "lines": [["text": "   "], ["text": "Ellen  has a laugh you can hear\na block away"]],
            ],
            KindFixture.bethUUID.uuidString: ["display": "Beth", "lines": [["text": ""]]],
        ])
        let book = try HallieKindWordsBook.decode(data)
        #expect(book.people.count == 1)
        #expect(book.people[KindFixture.ellenUUID]?.lines == ["Ellen has a laugh you can hear a block away."])
    }

    @Test func refusesAnUnsupportedSchemaVersion() {
        #expect(throws: HallieKindWordsBook.DecodeError.unsupportedSchema(2)) {
            try HallieKindWordsBook.decode(KindFixture.json(people: [:], schemaVersion: 2))
        }
    }

    @Test func missingFileIsEmptyWithOneLogLine() {
        let log = KindWordsLogBox()
        let store = HallieKindWordsStore(directory: KindFixture.scratchDirectory(), log: { log.append($0) })
        #expect(store.book().isEmpty)
        #expect(store.book().isEmpty)
        #expect(store.book().isEmpty)
        #expect(log.lines.count == 1)
        #expect(log.lines.first?.hasPrefix("[hallie-kind]") == true)
    }

    @Test func malformedFileIsEmptyWithOneLogLineAndNoFileText() throws {
        let dir = KindFixture.scratchDirectory()
        let secret = "SECRET-FRAGMENT-never-logged"
        try Data("{\"schemaVersion\": 1, \"people\": [\"\(secret)\"".utf8)
            .write(to: dir.appendingPathComponent(HallieKindWordsStore.fileName))
        let log = KindWordsLogBox()
        let store = HallieKindWordsStore(directory: dir, log: { log.append($0) })
        #expect(store.book().isEmpty)
        #expect(store.book().isEmpty)
        #expect(log.lines.count == 1)
        #expect(!log.lines.joined().contains(secret))
    }

    @Test func loadsAndReloadsWhenTheFileChanges() throws {
        let dir = KindFixture.scratchDirectory()
        let url = dir.appendingPathComponent(HallieKindWordsStore.fileName)
        let log = KindWordsLogBox()
        let store = HallieKindWordsStore(directory: dir, log: { log.append($0) })
        #expect(store.book().isEmpty)
        try KindFixture.fileJSON.write(to: url)
        let first = store.book()
        #expect(first.people.count == 2)
        // Unchanged file → the cached book, no second "loaded" line.
        #expect(store.book() == first)
        let loadedLines = log.lines.filter { $0.contains("loaded") }
        #expect(loadedLines.count == 1)
        // Rewrite with one person and a different mtime → reloaded.
        try KindFixture.json(people: [
            KindFixture.bethUUID.uuidString: ["display": "Beth", "lines": [["text": KindFixture.bethLine]]],
        ]).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        #expect(store.book().people.count == 1)
        // No line of the file ever reached the log.
        let joined = log.lines.joined(separator: "\n")
        for line in KindFixture.ellenLines + [KindFixture.bethLine] { #expect(!joined.contains(line)) }
    }
}

// MARK: - LOGIC: decisions

@Suite("Hallie kind words — decisions")
struct HallieKindWordsDecisionTests {
    typealias Memory = HallieTurnExecutor.ConversationMemory

    private func offer(for result: HallieTurnExecutor.Result, typed: String = "Ellen",
                       profiles: [HallieTurnExecutor.ProfileSnapshot] = [KindFixture.ellenProfile()],
                       graph: GedcomFamilyGraph? = nil) -> HallieKindWords.Offer? {
        HallieKindWords.biographyOffer(
            result: result, ast: KindFixture.biographyAST(typed),
            profiles: profiles, graph: graph, loadBook: { KindFixture.book })
    }

    @Test func rotatesThroughAPersonsLines() {
        let rotation = HallieKindWordsRotation()
        let uuid = UUID()
        #expect([0, 1, 2, 3].map { _ in rotation.next(for: uuid, count: 3) } == [0, 1, 2, 0])
        #expect(rotation.next(for: UUID(), count: 3) == 0)
    }

    @Test func oncePerSubjectPerConversationAndResetClearsIt() throws {
        var memory = Memory()
        let rotation = HallieKindWordsRotation()
        let result = KindFixture.biographyResult(name: nil)
        let offer = try #require(offer(for: result))
        var logged: [String] = []

        let first = HallieKindWords.apply(offer, to: result, memory: &memory, rotation: rotation,
                                          log: { logged.append($0) })
        #expect(first.prose == result.prose + " " + KindFixture.ellenLines[0])
        let second = HallieKindWords.apply(offer, to: result, memory: &memory, rotation: rotation,
                                           log: { logged.append($0) })
        #expect(second == result)
        #expect(logged == ["[hallie-kind] added a kind word for Ellen (1 of 2)"])

        // A new conversation hears her again — the NEXT line.
        memory.reset()
        let third = HallieKindWords.apply(offer, to: result, memory: &memory, rotation: rotation,
                                          log: { logged.append($0) })
        #expect(third.prose.hasSuffix(KindFixture.ellenLines[1]))
        #expect(logged.last == "[hallie-kind] added a kind word for Ellen (2 of 2)")
    }

    @Test func aResetTurnRecordedIntoMemoryAlsoClearsIt() throws {
        var memory = Memory()
        memory.noteKindWord(about: KindFixture.ellenUUID)
        memory.noteGreetingKindWord()
        memory.record(intent: nil, result: HallieTurnExecutor.commandResult(.reset))
        #expect(memory.kindWordSubjects.isEmpty)
        #expect(!memory.kindWordGreetingSaid)
    }

    @Test func uuidKeyingSurvivesARenameOfNameAndAliases() throws {
        // Rick renames the profile "Ellen" → "Eleanor" with a new alias:
        // the book is keyed by UUID, so the line still follows her.
        let renamed = KindFixture.ellenProfile(name: "Eleanor", aliases: ["Nell"])
        let result = KindFixture.biographyResult(name: nil, prose: "Eleanor is in the People tab.")
        let offer = try #require(offer(for: result, typed: "Nell", profiles: [renamed]))
        #expect(offer.uuid == KindFixture.ellenUUID)
        #expect(offer.lines == KindFixture.ellenLines)
        // …and the old spelling no longer claims anyone.
        #expect(self.offer(for: result, typed: "Ellen", profiles: [renamed]) == nil)
    }

    @Test func answeredNameBeatsTheTypedSpelling() {
        // A tree biography about SOMEONE ELSE named Ellen: the answer's
        // name is not Ellen's profile, so the typed "ellen" is never used.
        let result = KindFixture.biographyResult(name: "Ellen Marsh Fixture")
        #expect(offer(for: result, typed: "ellen") == nil)
    }

    @Test func aPinnedTreeRecordReachesItsProfilesLine() throws {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Ellen Marie /Fixture/
        1 SEX F
        1 _FSFTID ZZZZ-111
        0 TRLR
        """)
        let pinned = KindFixture.ellenProfile(treeIdentity: .familySearchID("ZZZZ-111"))
        let result = KindFixture.biographyResult(name: "Ellen Marie Fixture",
                                                 prose: "Ellen Marie Fixture is in the family tree.")
        let offer = try #require(offer(for: result, typed: "ellen", profiles: [pinned], graph: graph))
        #expect(offer.uuid == KindFixture.ellenUUID)
        // The same name, unpinned and not a profile spelling → nothing.
        #expect(self.offer(for: result, typed: "ellen", profiles: [KindFixture.ellenProfile()], graph: graph) == nil)
    }

    @Test func twoTreeRecordsByTheAnsweredNameFailClosed() {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Ellen /Fixture/
        1 _FSFTID ZZZZ-111
        0 @I2@ INDI
        1 NAME Ellen /Fixture/
        0 TRLR
        """)
        let pinned = KindFixture.ellenProfile(treeIdentity: .familySearchID("ZZZZ-111"))
        #expect(offer(for: KindFixture.biographyResult(name: "Ellen Fixture"), typed: "ellen",
                      profiles: [pinned], graph: graph) == nil)
    }

    @Test func aWhichOneChipSelectionNamesTheProfile() throws {
        let twoEllens = [
            KindFixture.ellenProfile(),
            .init(stableID: UUID().uuidString, canonicalName: "Ellen", aliases: [], uuid: UUID()),
        ]
        let result = KindFixture.biographyResult(name: nil)
        // Typed "ellen" is ambiguous → nothing …
        #expect(offer(for: result, profiles: twoEllens) == nil)
        // … but the chip said which one.
        let chosen = HallieKindWords.biographyOffer(
            result: result, ast: KindFixture.biographyAST("ellen"),
            selected: .profileStableID(KindFixture.ellenUUID.uuidString),
            profiles: twoEllens, graph: nil, loadBook: { KindFixture.book })
        #expect(chosen?.uuid == KindFixture.ellenUUID)
    }

    @Test func greetingUsesTheSpeakersOwnLineOncePerConversation() throws {
        let speakers = HallieTurnExecutor.Speakers(ownerName: "Beth", archivistName: "Hallie")
        let profiles = [KindFixture.ellenProfile(), KindFixture.bethProfile()]
        let greeting = KindFixture.greetingResult()
        let offer = try #require(HallieKindWords.greetingOffer(
            result: greeting, speakers: speakers, profiles: profiles, loadBook: { KindFixture.book }))
        #expect(offer.uuid == KindFixture.bethUUID)
        var memory = Memory()
        let said = HallieKindWords.apply(offer, to: greeting, memory: &memory,
                                         rotation: HallieKindWordsRotation(), log: { _ in })
        #expect(said.prose == "Hello! It's good to see you. \(KindFixture.bethLine) How can I help?")
        let again = HallieKindWords.apply(offer, to: greeting, memory: &memory,
                                          rotation: HallieKindWordsRotation(), log: { _ in })
        #expect(again.prose == greeting.prose)
        // The greeting and a biography are separate: Beth can still hear
        // her line when someone asks about her.
        #expect(!memory.kindWordSubjects.contains(KindFixture.bethUUID))
    }

    @Test func greetingForAnUnknownSpeakerOrNotAGreetingSaysNothing() {
        let profiles = [KindFixture.bethProfile()]
        #expect(HallieKindWords.greetingOffer(
            result: KindFixture.greetingResult(),
            speakers: .init(ownerName: "Stranger", archivistName: "Hallie"),
            profiles: profiles, loadBook: { KindFixture.book }) == nil)
        #expect(HallieKindWords.greetingOffer(
            result: HallieTurnExecutor.commandResult(.smalltalk(.thanks)),
            speakers: .init(ownerName: "Beth", archivistName: "Hallie"),
            profiles: profiles, loadBook: { KindFixture.book }) == nil)
    }

    @Test func catalogCountSearchAgeDateAndKinshipAnswersGetNone() {
        let profiles = [KindFixture.ellenProfile()]
        let cases: [(HallieTurnExecutor.Route, ArchivistQueryAST)] = [
            (.presence, .presence(.init(people: ["Ellen"]))),
            (.aggregate, .aggregate(.init(operation: .coOccurrence, anchorPeople: ["Ellen"]))),
            (.temporal, .temporal(.init(subject: "Ellen", operation: .age, reference: .explicitYear(1990)))),
            (.graph, .graph(.init(people: ["Ellen"], operation: .birth))),
            (.graph, .graph(.init(people: ["Ellen"], operation: .kinship, relation: .sister))),
            (.graph, .graph(.init(people: ["Ellen", "Beth"], operation: .relationship))),
        ]
        var loads = 0
        for (route, ast) in cases {
            let result = KindFixture.biographyResult(name: "Ellen", route: route)
            #expect(HallieKindWords.biographyOffer(
                result: result, ast: ast, profiles: profiles, graph: nil,
                loadBook: { loads += 1; return KindFixture.book }) == nil)
        }
        // The file is never even consulted for those shapes.
        #expect(loads == 0)
        // Nor for a declined or still-asking biography.
        #expect(offer(for: KindFixture.biographyResult(name: nil, outcome: .declined)) == nil)
    }

    @Test func theLineGoesBeforeATrailingGalleryOffer() {
        let bio = "Ellen Fixture was born in 1950."
        let offerSentence = "I have 3 photos of her in the archive — want to see them all?"
        let result = KindFixture.biographyResult(name: nil, prose: bio + " " + offerSentence)
        let out = result.insertingKindWord("A kind line.", after: bio)
        #expect(out.prose == bio + " A kind line. " + offerSentence)
        // Facts untouched: basis, citations, plan.
        #expect(out.basisLine == result.basisLine)
        #expect(out.citations == result.citations)
        #expect(out.answerPlan == result.answerPlan)
        // Anchor no longer matches → appended.
        #expect(result.insertingKindWord("A kind line.", after: "Something else.").prose
                == result.prose + " A kind line.")
    }

    @Test func theLineIsNeverACitationOrClaim() throws {
        var memory = Memory()
        let result = KindFixture.biographyResult(name: nil)
        let said = HallieKindWords.apply(try #require(offer(for: result)), to: result,
                                         memory: &memory, rotation: HallieKindWordsRotation(), log: { _ in })
        #expect(!said.prose.contains("[c"))
        #expect(said.knowledgeCitations == result.knowledgeCitations)
        // Applied after composition: the plan the composer and verifier saw
        // is the one the answer keeps.
        #expect(said.answerPlan == result.answerPlan)
        #expect(said.basisLine == result.basisLine)
    }
}

// MARK: - ISOLATION

@Suite("Hallie kind words — isolation")
struct HallieKindWordsIsolationTests {
    @Test func testHostDefaultDirectoryIsScratch() {
        #expect(TestEnvironment.isTestHost)
        let dir = HallieKindWordsStore.defaultDirectory.path
        #expect(dir.hasPrefix(NSTemporaryDirectory()) || dir.contains("VideoScan-tests"))
        #expect(!dir.contains("Application Support"))
        #expect(HallieKindWordsStore.shared.directory.path == dir)
    }

    @Test func aPoisonedRealLookingFileElsewhereIsNeverRead() throws {
        // A file with the REAL layout (…/Application Support/VideoScan/
        // hallie/kind-words.json) under a temp root: nothing may read it.
        let root = KindFixture.scratchDirectory()
        let poisoned = root.appendingPathComponent("Library/Application Support/VideoScan/hallie", isDirectory: true)
        try FileManager.default.createDirectory(at: poisoned, withIntermediateDirectories: true)
        let poison = "POISON-LINE-must-never-be-said"
        try KindFixture.json(people: [
            KindFixture.ellenUUID.uuidString: ["display": "Ellen", "lines": [["text": poison]]],
        ]).write(to: poisoned.appendingPathComponent(HallieKindWordsStore.fileName))

        // The shared store looks only at its scratch dir.
        #expect(!HallieKindWordsStore.shared.book().people.values.contains { $0.lines.contains { $0.contains(poison) } })
        // A store pointed at an unrelated scratch dir sees nothing.
        #expect(HallieKindWordsStore(directory: KindFixture.scratchDirectory(), log: { _ in }).book().isEmpty)
        // Client defaults are inert: no kind words unless injected.
        let coordinator = HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { $0 },
            translateAST: { _, _, _ in throw CancellationError() },
            loadProfiles: { nil }, loadGraph: { nil },
            executeRequest: { _, _ in throw CancellationError() },
            continueTurn: { _, _, _ in throw CancellationError() },
            resolveBiographyPhoto: { _ in nil })
        #expect(coordinator.loadKindWords().isEmpty)
        let shell = HallieShellCLI.Dependencies(
            loadCatalog: { _ in [] }, loadProfiles: { .loaded([]) }, loadGraph: { _ in nil },
            translateAST: { _, _ in throw CancellationError() },
            executeTurn: { _, _ in throw CancellationError() },
            performMediaAction: { _ in })
        #expect(shell.loadKindWords().isEmpty)
    }
}

// MARK: - SENSOR: end to end

@MainActor
@Suite("Hallie kind words — sensor", .serialized)
struct HallieKindWordsSensorTests {
    private func profile(_ name: String, uuid: UUID, aliases: [String] = []) -> POIProfile {
        var p = POIProfile(name: name, referencePath: "/isolated/\(name.lowercased())", aliases: aliases)
        p.uuid = uuid
        return p
    }

    /// Beth (the web reader / shell owner) asks about Ellen, twice, then
    /// starts over and asks again; then says hello.
    @Test func shellBiographyCarriesExactlyOneLineOncePerConversation() async throws {
        var inputs = [
            "tell me about ellen", "tell me about ellen", ":reset", "tell me about ellen", ":quit",
        ]
        var output: [String] = []
        var transcript: [HallieTranscriptEvent] = []
        var dependencies = HallieShellCLI.Dependencies(
            loadCatalog: { _ in [] },
            loadProfiles: { [self] in
                .loaded([profile("Ellen", uuid: KindFixture.ellenUUID),
                         profile("Elizabeth", uuid: KindFixture.bethUUID, aliases: ["Beth"])])
            },
            loadGraph: { _ in nil },
            translateAST: { _, _ in .init(ast: KindFixture.biographyAST("Ellen"), responderHost: "fixture") },
            executeTurn: HallieTurnExecutor.execute,
            performMediaAction: { _ in },
            recordTranscript: { transcript.append(contentsOf: $0) },
            speakers: { .init(ownerName: "Beth", archivistName: "Hallie") })
        dependencies.loadKindWords = { KindFixture.book }

        _ = await HallieShellCLI.run(
            options: .init(), input: { inputs.isEmpty ? nil : inputs.removeFirst() },
            output: { output.append($0) }, dependencies: dependencies)

        let answers = transcript.filter { $0.kind == .assistant }.map(\.text)
        #expect(answers.count == 3)
        guard answers.count == 3 else { return }
        let all = KindFixture.ellenLines
        // First answer: exactly one line, as its own sentence at the end.
        #expect(all.map { occurrences(of: $0, in: answers[0]) }.reduce(0, +) == 1)
        #expect(answers[0].hasSuffix(all[0]))
        #expect(answers[0].contains("Ellen"))
        // Second, same conversation: none.
        #expect(all.allSatisfy { !answers[1].contains($0) })
        // After :reset: exactly one again (rotation is process-wide, so it
        // is whichever line is next — still exactly one).
        #expect(all.map { occurrences(of: $0, in: answers[2]) }.reduce(0, +) == 1)
        #expect(!answers.joined().contains(KindFixture.bethLine))
    }

    @Test func shellGreetingCarriesTheOwnersOwnLine() async throws {
        var inputs = ["hi hallie", "good morning", ":quit"]
        var transcript: [HallieTranscriptEvent] = []
        var dependencies = HallieShellCLI.Dependencies(
            loadCatalog: { _ in [] },
            loadProfiles: { [self] in
                .loaded([profile("Ellen", uuid: KindFixture.ellenUUID),
                         profile("Elizabeth", uuid: KindFixture.bethUUID, aliases: ["Beth"])])
            },
            loadGraph: { _ in nil },
            translateAST: { _, _ in throw CancellationError() },
            executeTurn: HallieTurnExecutor.execute,
            performMediaAction: { _ in },
            recordTranscript: { transcript.append(contentsOf: $0) },
            speakers: { .init(ownerName: "Beth", archivistName: "Hallie") })
        dependencies.loadKindWords = { KindFixture.book }

        _ = await HallieShellCLI.run(
            options: .init(), input: { inputs.isEmpty ? nil : inputs.removeFirst() },
            output: { _ in }, dependencies: dependencies)

        let answers = transcript.filter { $0.kind == .assistant }.map(\.text)
        #expect(answers.count == 2)
        guard answers.count == 2 else { return }
        #expect(occurrences(of: KindFixture.bethLine, in: answers[0]) == 1)
        #expect(answers[0].hasSuffix("How can I help?"))
        #expect(!answers[1].contains(KindFixture.bethLine))
        #expect(KindFixture.ellenLines.allSatisfy { !answers.joined().contains($0) })
    }

    @Test func coordinatorContinuationOffersAndAppCommitSaysItOnce() async throws {
        let profiles = [KindFixture.ellenProfile(),
                        HallieTurnExecutor.ProfileSnapshot(
                            stableID: UUID().uuidString, canonicalName: "Ellen", uuid: UUID())]
        let context = HallieTurnExecutor.Context(profiles: profiles)
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "tell me about ellen", ast: KindFixture.biographyAST("ellen"))
        let clarification = HallieTurnExecutor.makeClarification(
            intent: intent, stage: .profileIdentity,
            candidates: profiles.map {
                .init(id: .profileStableID($0.stableID), canonicalName: $0.canonicalName, label: $0.canonicalName)
            },
            context: context)
        let pending = HallieAppTurnCoordinator.PendingClarification(
            clarification: clarification, context: context, responderHost: "fixture",
            capturedReferentID: nil, composition: .off)
        let dependencies = HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { $0 },
            translateAST: { _, _, _ in throw CancellationError() },
            loadProfiles: { profiles }, loadGraph: { nil },
            executeRequest: { _, _ in throw CancellationError() },
            continueTurn: { _, _, _ in KindFixture.biographyResult(name: nil) },
            resolveBiographyPhoto: { _ in nil },
            loadKindWords: { KindFixture.book })

        let response = try await HallieAppTurnCoordinator.continue(
            pending: pending, selecting: .profileStableID(KindFixture.ellenUUID.uuidString),
            dependencies: dependencies)
        let offer = try #require(response.kindWord)
        #expect(offer.uuid == KindFixture.ellenUUID)
        // Resolved, not yet said: the prose is untouched until the client
        // applies it against its own conversation memory.
        #expect(response.result.prose == KindFixture.biographyResult(name: nil).prose)

        // The app commit says it once …
        var state = HallieResponseCommit.State()
        var messages: [ArchivistMessage] = []
        var spoken: [String] = []
        func commit(_ r: HallieAppTurnCoordinator.Response) {
            let id = UUID()
            HallieResponseCommit.apply(
                r, question: "tell me about ellen", modelName: "fixture", requestID: id,
                activeRequestID: id, isCancelled: false, state: state,
                sinks: .init(
                    isSpeechEnabled: { true }, speakPrepared: { _, _ in },
                    speak: { text, _ in spoken.append(text) }, recordForID: { _ in nil },
                    publishState: { state = $0 }, appendMessage: { messages.append($0) },
                    performMediaAction: { _ in }, play: { _ in },
                    openFamilyTreePerson: { _, _ in }, recompileFamilyTree: { _ in },
                    acceptImmediateOffer: { _ in }))
        }
        commit(response)
        commit(response)
        #expect(messages.count == 2)
        let said = KindFixture.ellenLines.map { occurrences(of: $0, in: messages[0].text) }.reduce(0, +)
        #expect(said == 1)
        #expect(spoken.first == messages.first?.text)
        #expect(KindFixture.ellenLines.allSatisfy { !messages[1].text.contains($0) })
    }

    @Test func coordinatorGreetingOffersTheSpeakersLine() async throws {
        let dependencies = HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { $0 },
            translateAST: { _, _, _ in throw CancellationError() },
            loadProfiles: { [KindFixture.ellenProfile(), KindFixture.bethProfile()] },
            loadGraph: { nil },
            loadSpeakers: { .init(ownerName: "Beth", archivistName: "Hallie") },
            executeRequest: { _, _ in throw CancellationError() },
            continueTurn: { _, _, _ in throw CancellationError() },
            resolveBiographyPhoto: { _ in nil },
            loadKindWords: { KindFixture.book })
        let response = try await HallieAppTurnCoordinator.execute(
            question: "hi hallie", records: [], referent: .init(recordID: nil, temporalDate: nil),
            hosts: [], modelName: "fixture", dependencies: dependencies)
        #expect(response.kindWord?.uuid == KindFixture.bethUUID)
        #expect(response.kindWord?.occasion == .greeting)
        var memory = HallieTurnExecutor.ConversationMemory()
        let said = response.applyingKindWord(memory: &memory, rotation: HallieKindWordsRotation())
        #expect(said.result.prose == "Hello! It's good to see you. \(KindFixture.bethLine) How can I help?")
        #expect(said.kindWord == nil)
    }
}
