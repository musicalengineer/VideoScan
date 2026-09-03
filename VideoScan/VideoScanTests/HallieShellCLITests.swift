import AppKit
import Foundation
import Testing
@testable import VideoScan

@MainActor
@Suite("Hallie standalone shell", .serialized)
struct HallieShellCLITests {
    private final class Harness {
        var inputs: [String]
        var output: [String] = []
        var loadedURLs: [URL] = []
        var translatedQuestions: [String] = []
        var translationOptions: [HallieShellCLI.Options] = []
        var mediaActions: [HallieShellCLI.MediaAction] = []
        var transcriptEvents: [HallieTranscriptEvent] = []
        var composedPlans: [HallieAnswerPlan] = []
        var compositionReply: (@Sendable (HallieAnswerPlan) -> String)?
        var readCount = 0
        var records: [VideoRecord]
        var profiles: [POIProfile]
        var profileLoadResult: HallieShellCLI.ProfileLoadResult?
        var graph: GedcomFamilyGraph?
        var cyberBrain: CyberBrainIndex?
        var translations: [ArchivistQueryAST]
        var translationError: Error?
        /// Who "I" is; injected so no test reads the real preferences.
        var speakers = HallieTurnExecutor.Speakers(ownerName: "Rick Breen", archivistName: "Hallie")
        var unavailableMediaPaths: Set<String> = []
        var mediaActionShouldSucceed = true
        var executeTurn: @Sendable (
            ArchivistQueryAST,
            HallieTurnExecutor.Context
        ) async throws -> HallieTurnExecutor.Result = HallieTurnExecutor.execute
        var executeRequest: (@Sendable (
            HallieTurnExecutor.Request,
            HallieTurnExecutor.Context
        ) async throws -> HallieTurnExecutor.Result)?
        var continueTurn: (@Sendable (
            HallieTurnExecutor.Clarification,
            HallieTurnExecutor.CandidateID,
            HallieTurnExecutor.Context
        ) async throws -> HallieTurnExecutor.Result)?

        init(
            inputs: [String] = [], records: [VideoRecord] = [],
            profiles: [POIProfile] = [], graph: GedcomFamilyGraph? = nil,
            translations: [ArchivistQueryAST] = []
        ) {
            self.inputs = inputs
            self.records = records
            self.profiles = profiles
            self.graph = graph
            self.translations = translations
        }

        func dependencies() -> HallieShellCLI.Dependencies {
            HallieShellCLI.Dependencies(
                loadCatalog: { [self] url in
                    loadedURLs.append(url)
                    return records
                },
                loadProfiles: { [self] in
                    profileLoadResult ?? .loaded(profiles)
                },
                loadGraph: { [self] _ in graph },
                loadCyberBrain: { [self] in cyberBrain },
                translateAST: { [self] question, options in
                    translatedQuestions.append(question)
                    translationOptions.append(options)
                    if let translationError { throw translationError }
                    guard !translations.isEmpty else {
                        throw HarnessError.missingTranslation
                    }
                    return .init(ast: translations.removeFirst(),
                                 responderHost: "fixture-translator")
                },
                executeTurn: executeTurn,
                executeRequest: executeRequest,
                continueTurn: continueTurn,
                mediaURLIsAvailable: { [self] url in
                    !unavailableMediaPaths.contains(url.path)
                },
                tryPerformMediaAction: { [self] action in
                    mediaActions.append(action)
                    return mediaActionShouldSucceed
                },
                performMediaAction: { _ in },
                recordTranscript: { [self] events in
                    transcriptEvents.append(contentsOf: events)
                },
                composeAnswer: { [self] plan, history, _ in
                    composedPlans.append(plan)
                    guard let compositionReply else {
                        return .template(plan, note: "template: no composer configured")
                    }
                    return await HallieGroundedComposer(
                        personaName: "Hallie Mae",
                        modelCall: { _, _ in compositionReply(plan) })
                        .compose(plan: plan, history: history)
                },
                speakers: { [self] in speakers })
        }

        func nextInput() -> String? {
            readCount += 1
            return inputs.isEmpty ? nil : inputs.removeFirst()
        }
    }

    private enum HarnessError: LocalizedError {
        case missingTranslation
        case refusedByTranslator

        var errorDescription: String? {
            switch self {
            case .missingTranslation: "test did not supply a translation"
            case .refusedByTranslator: "translator refused unsupported evidence"
            }
        }
    }

    private enum ActiveResetMode: CaseIterable {
        case telling
        case drill
        case picker
    }

    private final class CancellationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var isCancelled = false
        private var blockingContinuation: CheckedContinuation<Void, Never>?
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var hasStarted = false

        func waitUntilStarted() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if hasStarted {
                    lock.unlock()
                    continuation.resume()
                } else {
                    startWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        func blockUntilCancelled() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    hasStarted = true
                    let waiters = startWaiters
                    startWaiters.removeAll()
                    if isCancelled {
                        lock.unlock()
                        waiters.forEach { $0.resume() }
                        continuation.resume()
                    } else {
                        blockingContinuation = continuation
                        lock.unlock()
                        waiters.forEach { $0.resume() }
                    }
                }
            } onCancel: {
                lock.lock()
                isCancelled = true
                let continuation = blockingContinuation
                blockingContinuation = nil
                lock.unlock()
                continuation?.resume()
            }
        }

        var observedCancellation: Bool {
            lock.withLock { isCancelled }
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        func increment() { lock.withLock { storage += 1 } }
        var value: Int { lock.withLock { storage } }
    }

    private func record(
        _ path: String, confirmed: [String] = [],
        caption: (Double, String)? = nil
    ) -> VideoRecord {
        let value = VideoRecord()
        value.fullPath = path
        value.directory = (path as NSString).deletingLastPathComponent
        value.filename = (path as NSString).lastPathComponent
        value.streamTypeRaw = StreamType.videoAndAudio.rawValue
        value.confirmedByUserPeople = confirmed.map {
            ConfirmedTag(name: $0, confirmedAt: Date(timeIntervalSince1970: 1))
        }
        if let caption {
            value.sceneCaptions = [
                SceneCaption(timestamp: caption.0, text: caption.1),
            ]
            value.sceneCaptionModel = "fixture-captioner"
        }
        return value
    }

    private func citedAnswer(path: String) -> HallieTurnExecutor.Result {
        HallieTurnExecutor.Result(
            route: .presence,
            outcome: .answered,
            prose: "fixture answer",
            basisLine: "fixture basis",
            queryDescription: "shape=presence",
            citations: [
                .init(
                    recordID: UUID(), fullPath: path,
                    filename: (path as NSString).lastPathComponent,
                    playbackSeconds: nil, bases: []),
            ],
            catalogPersonName: nil)
    }

    private func conversationState(
        with mode: ActiveResetMode
    ) -> HallieShellCLI.Session {
        var state = HallieShellCLI.Session(
            records: [], profiles: [], graph: nil, cyberBrain: nil,
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae"),
            model: "fixture-model", runID: "reset-run")
        state.transcriptSequence = 41
        let prior = citedAnswer(path: "/isolated/Donna/Cape.mov")
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "Was Donna there?",
            ast: .presence(.init(people: ["Donna"])))
        state.memory.record(
            intent: intent, result: prior, question: "Was Donna there?")
        state.citations = prior.citations
        state.selectedRecordID = prior.citations.first?.recordID
        state.remember(question: "Was Donna there?", answer: prior.prose)
        state.rememberSocial(question: "Hello", answer: "Hello, Rick.")
        let context = state.identityContext
        state.pendingClarification = .init(
            value: HallieTurnExecutor.makeClarification(
                intent: intent,
                stage: .profileIdentity,
                candidates: [
                    .init(
                        id: .profileStableID("donna"),
                        canonicalName: "Donna", label: "Donna"),
                ],
                context: context),
            context: context)
        switch mode {
        case .telling:
            state.telling = HallieTellingMode.Session(opening: .init(
                subject: "Dad Breen", relation: "Rick's dad", pronoun: .he,
                firstStatement: nil))
        case .drill:
            state.drill = HalliePronunciationDrillMode.Session(
                list: PronunciationDrillList(items: []), index: nil)
        case .picker:
            state.picker = HalliePronunciationPicker.Offer(
                word: "Latta", candidates: [])
        }
        return state
    }

    private func source(named filename: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let url = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("VideoScan")
            .appendingPathComponent(filename)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private var onePixelPNG: Data {
        // Real decoded 1x1 PNG, not merely a filename-shaped byte blob.
        Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }

    // MARK: - Option grammar

    @Test func parsesDefaultsAndEverySupportedOption() throws {
        let defaults = try HallieShellCLI.parse(arguments: ["--hallie"])
        #expect(defaults.once == nil)
        #expect(!defaults.hosts.isEmpty)

        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--catalog", "/tmp/hallie-catalog.json",
            "--host", "ollama-one.local,ollama-two.local",
            "--model", "fixture-model", "--gedcom", "/tmp/family.ged",
            "--once", "Was Donna there?", "--no-actions",
            "--log-run-id", "fixture-run", "--diagnostics",
        ])

        #expect(options.catalogURL.path == "/tmp/hallie-catalog.json")
        #expect(options.hosts.count == 2)
        #expect(options.hosts[0].contains("ollama-one.local"))
        #expect(options.hosts[1].contains("ollama-two.local"))
        #expect(options.model == "fixture-model")
        #expect(options.gedcomURL?.path == "/tmp/family.ged")
        #expect(options.once == "Was Donna there?")
        #expect(!options.allowActions)
        #expect(options.diagnostics)
        #expect(options.logRunID == "fixture-run")
    }

    @Test func rejectsUnknownMissingAndEmptyOptions() {
        #expect(throws: HallieShellCLI.ParseError.self) {
            _ = try HallieShellCLI.parse(arguments: ["--catalog"])
        }
        #expect(throws: HallieShellCLI.ParseError.self) {
            _ = try HallieShellCLI.parse(arguments: ["--model", "   "])
        }
        #expect(throws: HallieShellCLI.ParseError.self) {
            _ = try HallieShellCLI.parse(arguments: ["--host", ",,"])
        }
        #expect(throws: HallieShellCLI.ParseError.self) {
            _ = try HallieShellCLI.parse(arguments: ["--write-catalog"])
        }
    }

    @Test func onlyDeployedGEDCOMLayoutConfersPhotoAuthority() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("HallieGEDCOMAuthority-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let master = base.appendingPathComponent("Breen_Family_Archive", isDirectory: true)
        let gedcom = master
            .appendingPathComponent("40_Family_Tree/GEDCOM", isDirectory: true)
        try FileManager.default.createDirectory(
            at: gedcom, withIntermediateDirectories: true)
        let file = gedcom.appendingPathComponent("family.ged")
        try Data("0 HEAD\n0 TRLR\n".utf8).write(to: file)

        #expect(HallieShellCLI.masterArchiveRoot(containingGEDCOM: file) == master)
        #expect(HallieShellCLI.masterArchiveRoot(containingGEDCOM: gedcom) == master)
        #expect(HallieShellCLI.masterArchiveRoot(containingGEDCOM:
            base.appendingPathComponent("unrelated/family.ged")) == nil)
    }

    @Test func catalogHeaderProbeReadsMasterWithoutDecodingRecords() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("HallieCatalogHeader-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let catalog = base.appendingPathComponent("catalog.json")
        let json = """
        {"version":6,"generation":12,"savedAt":"2026-08-23T01:31:09Z","savedFromHost":"fixture","masterArchive":{"targetPath":"/Volumes/FamilyArchive","rootPath":"/Volumes/FamilyArchive/Breen_Family_Archive","volumeUUID":"fixture-uuid","designatedAt":"2026-08-21T00:28:35Z"},"records":[{"intentionally":"not a VideoRecord"}]}
        """
        try Data(json.utf8).write(to: catalog)

        let designation = try #require(
            HallieShellCLI.masterArchiveDesignation(catalogURL: catalog))
        #expect(designation.targetPath == "/Volumes/FamilyArchive")
        #expect(designation.rootPath
            == "/Volumes/FamilyArchive/Breen_Family_Archive")
        #expect(designation.volumeUUID == "fixture-uuid")

        let missingMarker = base.appendingPathComponent("missing.json")
        try Data("{}".utf8).write(to: missingMarker)
        #expect(HallieShellCLI.masterArchiveDesignation(
            catalogURL: missingMarker) == nil)
    }

    // MARK: - Interactive and once modes

    @Test func helpSessionAndQuitCommandsDoNotTranslateOrOpenMedia() async throws {
        let harness = Harness(inputs: [":help", ":session", ":quit"])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--catalog", "/isolated/catalog.json",
        ])
        let code = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.readCount == 3)
        #expect(harness.translatedQuestions.isEmpty)
        #expect(harness.mediaActions.isEmpty)
        #expect(harness.output.contains(HallieShellCLI.help))
        #expect(harness.output.contains { $0.hasPrefix("session: ")
            && $0.contains("· 0 citations") })
        #expect(harness.output.contains("Goodbye."))
        #expect(harness.output.contains { $0.contains("standalone family librarian") })
        #expect(harness.output.contains {
            $0 == "Archive ready — 0 catalog items, read-only."
        })
        #expect(!harness.output.contains { $0.contains("/isolated/catalog.json") })
    }

    @Test func onceTranslatesExactlyOnceAndNeverReadsInteractiveInput() async throws {
        let harness = Harness(
            inputs: ["this must remain unread"],
            translations: [.presence(.init(people: ["Donna"]))])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", "Was Donna there?",
        ])

        let code = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.noEvidence.rawValue)
        #expect(harness.translatedQuestions == ["Was Donna there?"])
        #expect(harness.readCount == 0)
        #expect(harness.inputs == ["this must remain unread"])
        #expect(harness.mediaActions.isEmpty)
        #expect(harness.output.contains("Hallie is thinking…"))
    }

    /// Sensor for the live catalog-roster miss: the real shell pipeline must
    /// answer from People profiles before translation and must not enumerate
    /// tree-only or family-told people.
    @Test func catalogPeopleRosterIsLocalBoundedAndSourceScoped() async throws {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Tree Only /Secret/
        0 TRLR
        """)
        let profiles = [
            POIProfile(name: "Rick", referencePath: "/isolated/rick"),
            POIProfile(name: "Donna", referencePath: "/isolated/donna"),
        ]
        let harness = Harness(profiles: profiles, graph: graph)
        harness.cyberBrain = try CyberBrainIndex(archive: .init(
            archiveID: "fixture", displayName: "Fixture",
            people: [.init(id: "private", canonicalName: "Told Only Secret")],
            sources: []))
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", "tell me about the people in the catalog",
        ])

        let code = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.translatedQuestions.isEmpty)
        #expect(harness.output.contains {
            $0.contains("The People-tab catalog roster has 2 people: Donna; Rick.")
        })
        #expect(!harness.output.contains { $0.contains("Tree Only Secret") })
        #expect(!harness.output.contains { $0.contains("Told Only Secret") })
        #expect(harness.transcriptEvents.contains {
            $0.queryDescription == "shape=roster" && $0.responder == "local"
        })
    }

    /// Live 2026-09-02 (lv260902-001): after a Thankful Pratt biography,
    /// the photo question's trailing "if" clause was swallowed into the
    /// name. Exercise the real shell state so both the photo turn and the
    /// next ordinary pronoun follow-up prove that Thankful remains the
    /// remembered subject.
    @Test func photoPronounWithTrailingClauseKeepsThePreviousSubject() async throws {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Thankful /Pratt/
        1 SEX F
        1 BIRT
        2 DATE 6 OCT 1761
        1 DEAT
        2 DATE 1 NOV 1849
        0 TRLR
        """)
        let biography = ArchivistQueryAST.graph(.init(
            people: ["Thankful Pratt"], operation: .biography))
        let harness = Harness(
            inputs: [
                "tell me about thankful pratt",
                "would there be a photo of her if she born so long ago?",
                "tell me about her again",
                ":quit",
            ],
            graph: graph,
            translations: [biography, biography])

        let code = await HallieShellCLI.run(
            options: .init(), input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.translatedQuestions == [
            "tell me about thankful pratt",
            "tell me about Thankful Pratt again",
        ])
        #expect(harness.output.contains("I don’t have a photo of Thankful Pratt yet."))
        #expect(!harness.output.contains { $0.contains("Her If She Born So Long Ago") })
        #expect(harness.transcriptEvents.contains {
            $0.queryDescription == "photo: Thankful Pratt"
        })
    }

    /// Rick (the shell's owner) married to Donna; Rick's maternal line
    /// reaches Scotland at generation 2, Donna's maternal line leaves the
    /// US in Canada at generation 2 (2026-09-02, the birthplace trail).
    private static let trailTree = GedcomFamilyGraph(gedcomText: """
    0 HEAD
    0 @I20@ INDI
    1 NAME Rick /Breen/
    1 SEX M
    1 BIRT
    2 DATE 1959
    2 PLAC Boston, Massachusetts, USA
    1 FAMC @F20@
    1 FAMS @F0@
    0 @I21@ INDI
    1 NAME Richard /Breen/ Sr
    1 SEX M
    1 BIRT
    2 DATE 1929
    2 PLAC Boston, Massachusetts, USA
    1 FAMS @F20@
    0 @I22@ INDI
    1 NAME Eileen /Latta/
    1 SEX F
    1 BIRT
    2 DATE 1930
    2 PLAC Lowell, Massachusetts, USA
    1 FAMC @F22@
    1 FAMS @F20@
    0 @I23@ INDI
    1 NAME Mary /McGill/
    1 SEX F
    1 BIRT
    2 DATE 1904
    2 PLAC Glasgow, Scotland
    1 FAMS @F22@
    0 @I1@ INDI
    1 NAME Donna /Hudson/
    1 SEX F
    1 BIRT
    2 DATE 4 APR 1958
    2 PLAC Brockton, Massachusetts, USA
    1 FAMC @F1@
    1 FAMS @F0@
    0 @I2@ INDI
    1 NAME Elaine /Bowser/
    1 SEX F
    1 BIRT
    2 DATE 3 MAR 1934
    2 PLAC Stoughton, Massachusetts, USA
    1 FAMC @F2@
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Ethel /Cote/
    1 SEX F
    1 BIRT
    2 DATE 2 FEB 1908
    2 PLAC Quebec, Canada
    1 FAMS @F2@
    0 @F0@ FAM
    1 HUSB @I20@
    1 WIFE @I1@
    0 @F20@ FAM
    1 HUSB @I21@
    1 WIFE @I22@
    1 CHIL @I20@
    0 @F22@ FAM
    1 WIFE @I23@
    1 CHIL @I22@
    0 @F1@ FAM
    1 WIFE @I2@
    1 CHIL @I1@
    0 @F2@ FAM
    1 WIFE @I3@
    1 CHIL @I2@
    0 TRLR
    """)

    /// Live 2026-09-02 (lv260902-010, then Rick's demo ask): the requested-
    /// output phrase before Donna's possessive is not part of her name, and
    /// the sentence is the birthplace TRAIL — the maternal line read out,
    /// stopping at the first birth outside the United States — pinned
    /// through the real shell boundary, route and prose.
    @Test func maternalBirthLocationTrailReadsDonnaOutThroughTheShell() async throws {
        let question = "can you trace the birth locations of donna's maternal line and read them out until you get outside the USA"
        let harness = Harness(graph: Self.trailTree)
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", question,
        ])

        let code = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.translatedQuestions.isEmpty)
        #expect(harness.output.contains {
            $0 == "Here are the birthplaces on Donna Hudson’s maternal line, 2 generations back: "
                + "1. Donna Hudson — 1958, Brockton, Massachusetts, USA. "
                + "2. Elaine Bowser — 1934, Stoughton, Massachusetts, USA. "
                + "3. Ethel Cote — 1908, Quebec, Canada (first born outside the United States). "
                + "Ethel Cote is the first on that line born outside the United States, so I stopped there."
        }, Comment(rawValue: harness.output.joined(separator: " | ")))
        #expect(!harness.output.contains { $0.contains("The Birth Locations Of Donna") })
        #expect(!harness.output.contains { $0.contains("don't find") })
        #expect(harness.transcriptEvents.contains {
            $0.queryDescription == "birthplace trail maternal stop=outside:United_States list: Donna Hudson [@I1@] tree=\(HallieLineageAnswer.trailTreeToken(Self.trailTree)) shown 1-3 of 3"
        })
    }

    /// Rick's second demo ask (2026-09-02): the subject defaults to the
    /// owner, every ancestor is walked one generation at a time, and the
    /// answer counts the generations, names the person and the path, and
    /// offers the Family Tree centered on that ancestor.
    @Test func generationsToEuropeAnswersForTheOwnerThroughTheShell() async throws {
        let question = "Tell me how many generations you need to go back to find someone born in europe then tell me who and where."
        let harness = Harness(graph: Self.trailTree)
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", question,
        ])

        let code = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.translatedQuestions.isEmpty)
        #expect(harness.output.contains {
            $0 == "Two generations. Mary McGill, born 1904 in Glasgow, Scotland, is the first ancestor born in Europe on any line: you → Eileen Latta → Mary McGill."
        }, Comment(rawValue: harness.output.joined(separator: " | ")))
        #expect(harness.transcriptEvents.contains {
            $0.queryDescription == "birthplace trail allAncestors stop=continent:Europe firstMatch: Rick Breen [@I20@] tree=\(HallieLineageAnswer.trailTreeToken(Self.trailTree)) shown 1-3 of 3"
        })
        #expect(!harness.output.contains { $0.contains("people and") })
    }

    /// A trail longer than a page (16 lines) pages in the shell: "show
    /// more" continues the SAME walk from conversation memory.
    @Test func longTrailPagesWithShowMoreInTheShell() async throws {
        var lines = ["0 HEAD"]
        for g in 0...15 {
            lines.append("0 @I\(g)@ INDI")
            lines.append("1 NAME \(g == 0 ? "Anna" : "Gen\(g)") /Chain/")
            lines.append("1 SEX F")
            lines.append("1 BIRT")
            lines.append("2 DATE \(2000 - 25 * g)")
            lines.append("2 PLAC Town\(g), Massachusetts, USA")
            if g < 15 { lines.append("1 FAMC @F\(g)@") }
            if g > 0 { lines.append("1 FAMS @F\(g - 1)@") }
        }
        for g in 0..<15 {
            lines.append("0 @F\(g)@ FAM")
            lines.append("1 WIFE @I\(g + 1)@")
            lines.append("1 CHIL @I\(g)@")
        }
        lines.append("0 TRLR")
        let graph = GedcomFamilyGraph(gedcomText: lines.joined(separator: "\n"))
        let harness = Harness(
            inputs: ["trace the birth locations of anna chain's maternal line", "show more", "show more", ":quit"],
            graph: graph)
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])

        let code = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.translatedQuestions.isEmpty)
        #expect(harness.output.contains { $0.contains("12. Gen11 Chain — 1725, Town11, Massachusetts, USA.")
            && $0.hasSuffix("4 more generations further back — say “show more” to continue.") })
        #expect(harness.output.contains { $0.hasPrefix("Continuing Anna Chain’s maternal line birthplaces, 13 to 16 of 16:")
            && $0.hasSuffix("The tree records no mother for Gen15 Chain, so that is where the line ends.") })
        #expect(harness.output.contains { $0.hasPrefix("That was the whole trail — 15 generations back from Anna Chain.") })
        #expect(harness.transcriptEvents.contains {
            $0.queryDescription == "birthplace trail maternal stop=top list: Anna Chain [@I0@] tree=\(HallieLineageAnswer.trailTreeToken(graph)) shown 13-16 of 16"
        })
    }

    /// A 15-generation maternal chain (16 lines, so the read-out pages);
    /// @I0@ is `anchor`, the rest Gen1 … Gen15 Chain.
    private static func pagedChain(anchor: String, depth: Int = 15) -> GedcomFamilyGraph {
        var lines = ["0 HEAD"]
        for g in 0...depth {
            lines.append("0 @I\(g)@ INDI")
            lines.append("1 NAME \(g == 0 ? anchor : "Gen\(g)") /Chain/")
            lines.append("1 SEX F")
            lines.append("1 BIRT")
            lines.append("2 DATE \(2000 - 25 * g)")
            lines.append("2 PLAC Town\(g), Massachusetts, USA")
            if g < depth { lines.append("1 FAMC @F\(g)@") }
            if g > 0 { lines.append("1 FAMS @F\(g - 1)@") }
        }
        for g in 0..<depth {
            lines.append("0 @F\(g)@ FAM")
            lines.append("1 WIFE @I\(g + 1)@")
            lines.append("1 CHIL @I\(g)@")
        }
        lines.append("0 TRLR")
        return GedcomFamilyGraph(gedcomText: lines.joined(separator: "\n"))
    }

    /// codex #1014 item 4: the shell's "show more" is bound to the tree the
    /// read-out came from. A session whose tree was reloaded so that @I0@
    /// names someone else — or the same names in a changed tree — refuses
    /// the page instead of reading another person's line.
    @Test func showMoreAfterTheTreeChangedIsRefusedThroughTheShell() async throws {
        let first = Self.pagedChain(anchor: "Anna")
        let harness = Harness(graph: first)
        var output: [String] = []
        var state = HallieShellCLI.Session(
            records: [], profiles: [], graph: first, cyberBrain: nil,
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae"),
            model: "fixture-model", runID: "trail-run")
        _ = await HallieShellCLI.answer(
            "trace the birth locations of anna chain's maternal line",
            options: HallieShellCLI.Options(), state: &state,
            output: { output.append($0) }, dependencies: harness.dependencies())
        #expect(output.contains { $0.hasSuffix("4 more generations further back — say “show more” to continue.") })
        #expect(state.memory.lastExchange?.queryDescription?.contains("tree=\(HallieLineageAnswer.trailTreeToken(first))") == true)

        // Reloaded: @I0@ is now Zed Chain.
        let reloaded = Self.pagedChain(anchor: "Zed")
        var reloadedState = HallieShellCLI.Session(
            records: [], profiles: [], graph: reloaded, cyberBrain: nil,
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae"),
            model: "fixture-model", runID: "trail-run")
        reloadedState.memory = state.memory
        output = []
        _ = await HallieShellCLI.answer(
            "show more", options: HallieShellCLI.Options(), state: &reloadedState,
            output: { output.append($0) }, dependencies: Harness(graph: reloaded).dependencies())
        #expect(output.contains("That list is from an earlier tree; ask again."), Comment(rawValue: output.joined(separator: " | ")))
        #expect(!output.contains { $0.contains("Zed Chain") })
        #expect(!output.contains { $0.contains("Continuing") })

        // Same names, one generation more: a different tree, refused too.
        let grown = Self.pagedChain(anchor: "Anna", depth: 16)
        var grownState = HallieShellCLI.Session(
            records: [], profiles: [], graph: grown, cyberBrain: nil,
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae"),
            model: "fixture-model", runID: "trail-run")
        grownState.memory = state.memory
        output = []
        _ = await HallieShellCLI.answer(
            "show more", options: HallieShellCLI.Options(), state: &grownState,
            output: { output.append($0) }, dependencies: Harness(graph: grown).dependencies())
        #expect(output.contains("That list is from an earlier tree; ask again."), Comment(rawValue: output.joined(separator: " | ")))

        // The same tree: the page continues.
        output = []
        _ = await HallieShellCLI.answer(
            "show more", options: HallieShellCLI.Options(), state: &state,
            output: { output.append($0) }, dependencies: harness.dependencies())
        #expect(output.contains { $0.hasPrefix("Continuing Anna Chain’s maternal line birthplaces, 13 to 16 of 16:") },
                Comment(rawValue: output.joined(separator: " | ")))
    }

    /// codex #1014 item 4: a two-question turn ("…? what is gedcom") joins
    /// the trail with another answer; "show more" still continues the
    /// trail, whichever half it was.
    @Test func joinedTwoQuestionTurnKeepsShowMoreForItsTrailThroughTheShell() async throws {
        for question in ["trace the birth locations of anna chain's maternal line? what is gedcom",
                         "what is gedcom? trace the birth locations of anna chain's maternal line"] {
            let graph = Self.pagedChain(anchor: "Anna")
            let harness = Harness(inputs: [question, "show more", ":quit"], graph: graph)
            let options = try HallieShellCLI.parse(arguments: ["--hallie"])

            let code = await HallieShellCLI.run(
                options: options, input: harness.nextInput,
                output: { harness.output.append($0) },
                dependencies: harness.dependencies())

            #expect(code == HallieShellCLI.ExitCode.success.rawValue)
            #expect(harness.translatedQuestions.isEmpty, Comment(rawValue: question))
            let joined = harness.output.joined(separator: " | ")
            #expect(harness.output.contains { $0.contains("12. Gen11 Chain — 1725, Town11, Massachusetts, USA.") && $0.lowercased().contains("gedcom") },
                    Comment(rawValue: joined))
            #expect(harness.output.contains { $0.hasPrefix("Continuing Anna Chain’s maternal line birthplaces, 13 to 16 of 16:") },
                    Comment(rawValue: joined))
            #expect(harness.transcriptEvents.contains {
                $0.queryDescription?.hasPrefix("two questions: ") == true
                    && $0.queryDescription?.contains("birthplace trail maternal stop=top list: Anna Chain [@I0@] tree=\(HallieLineageAnswer.trailTreeToken(graph)) shown 1-12 of 16") == true
            }, Comment(rawValue: question))
        }
    }

    @Test func normalConversationHidesDiagnosticsButLogRetainsThem() async throws {
        for diagnostics in [false, true] {
            let path = "/isolated/archive/Donna-Cape.mov"
            let harness = Harness(
                translations: [.presence(.init(people: ["Donna"]))])
            let answer = citedAnswer(path: path)
            harness.executeTurn = { _, _ in answer }
            var arguments = ["--hallie", "--once", "Show me Donna"]
            if diagnostics { arguments.append("--diagnostics") }
            let options = try HallieShellCLI.parse(arguments: arguments)

            _ = await HallieShellCLI.run(
                options: options, output: { harness.output.append($0) },
                dependencies: harness.dependencies())

            #expect(harness.output.contains("fixture answer"))
            #expect(harness.output.contains("fixture basis") == diagnostics)
            #expect(harness.output.contains("query: shape=presence") == diagnostics)
            #expect(harness.output.contains { $0.contains(path) } == diagnostics)
            let transcriptAnswer = try #require(harness.transcriptEvents.last)
            #expect(transcriptAnswer.basisLine == "fixture basis")
            #expect(transcriptAnswer.queryDescription == "shape=presence")
            #expect(transcriptAnswer.mediaEvidence.first?.fullPath == path)
        }
    }

    @Test func noActionsBlocksRequestedPlaybackAndStampsTheRunID() async throws {
        let item = record("/isolated/Donna/Cape.mov", confirmed: ["Donna"])
        let harness = Harness(
            records: [item],
            translations: [.presence(.init(people: ["Donna"]))])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", "play videos of Donna", "--no-actions",
            "--log-run-id", "safe-eval-run",
        ])

        let code = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.mediaActions.isEmpty)
        #expect(harness.output.contains("Media actions are off."))
        #expect(harness.transcriptEvents.allSatisfy {
            $0.runID == "safe-eval-run"
        })
    }

    @Test func colonResetStartsANewLoggedSessionAndClearsSequence() async throws {
        let item = record("/isolated/Donna/Cape.mov", confirmed: ["Donna"])
        let harness = Harness(
            inputs: ["Was Donna there?", ":reset", ":quit"],
            records: [item],
            translations: [.presence(.init(people: ["Donna"]))])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--log-run-id", "reset-run",
        ])

        let code = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.transcriptEvents.count == 3)
        let firstSession = harness.transcriptEvents[0].sessionID
        let reset = harness.transcriptEvents[2]
        #expect(reset.kind == .system)
        #expect(reset.text == ":reset")
        #expect(reset.sessionID != firstSession)
        #expect(reset.sequence == 1)
        #expect(reset.runID == "reset-run")
        #expect(reset.basisLine
            == "Conversation memory, citations, history, and active modes cleared.")
    }

    @Test func resetSessionClearsEveryActiveConversationMode() {
        var state = HallieShellCLI.Session(
            records: [], profiles: [], graph: nil, cyberBrain: nil,
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae"),
            model: "fixture-model", runID: "reset-run")
        let previousSessionID = state.transcriptSessionID
        state.transcriptSequence = 41
        state.telling = HallieTellingMode.Session(opening: .init(
            subject: "Dad Breen", relation: "Rick's dad", pronoun: .he,
            firstStatement: nil))
        state.drill = HalliePronunciationDrillMode.Session(
            list: PronunciationDrillList(items: []), index: nil)
        state.picker = HalliePronunciationPicker.Offer(
            word: "Latta", candidates: [])

        let reset = HallieShellCLI.resetSession(&state)

        #expect(state.telling == nil)
        #expect(state.drill == nil)
        #expect(state.picker == nil)
        #expect(state.transcriptSessionID != previousSessionID)
        #expect(state.transcriptSequence == 1)
        #expect(reset.sessionID == state.transcriptSessionID)
        #expect(reset.sequence == 1)
        #expect(reset.runID == "reset-run")
        #expect(reset.basisLine
            == "Conversation memory, citations, history, and active modes cleared.")
    }

    @Test func naturalResetPreemptsEveryActiveConversationMode() async {
        for mode in ActiveResetMode.allCases {
            let harness = Harness()
            var state = conversationState(with: mode)
            let sessionID = state.transcriptSessionID
            var output: [String] = []

            let outcome = await HallieShellCLI.answer(
                "start over",
                options: HallieShellCLI.Options(),
                state: &state,
                output: { output.append($0) },
                dependencies: harness.dependencies())

            #expect(outcome.exitCode == HallieShellCLI.ExitCode.success.rawValue)
            #expect(state.telling == nil, "\(mode)")
            #expect(state.drill == nil, "\(mode)")
            #expect(state.picker == nil, "\(mode)")
            #expect(state.pendingClarification == nil, "\(mode)")
            #expect(state.citations.isEmpty, "\(mode)")
            #expect(state.selectedRecordID == nil, "\(mode)")
            #expect(state.memory == HallieTurnExecutor.ConversationMemory(), "\(mode)")
            #expect(state.history.isEmpty, "\(mode)")
            #expect(state.socialHistory.isEmpty, "\(mode)")
            #expect(state.lastResponder == "none", "\(mode)")
            // Natural reset stays in the logged session; only `:reset`
            // renews the ID and restarts its sequence.
            #expect(state.transcriptSessionID == sessionID, "\(mode)")
            #expect(state.transcriptSequence == 43, "\(mode)")
            #expect(harness.transcriptEvents.map(\.sequence) == [42, 43], "\(mode)")
            #expect(harness.transcriptEvents.allSatisfy {
                $0.sessionID == sessionID
            }, "\(mode)")
            #expect(harness.transcriptEvents.last?.route == "reset", "\(mode)")
            #expect(output == [ArchivistConversationCommand.resetReply], "\(mode)")
            #expect(harness.translatedQuestions.isEmpty, "\(mode)")
        }
    }

    @Test func onceRecordsExactQuestionAndBoundedAnswerEvidence() async throws {
        let item = record("/isolated/Donna/Cape.mov", confirmed: ["Donna"])
        let harness = Harness(
            records: [item],
            translations: [.presence(.init(people: ["Donna"]))])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--model", "fixture-model",
            "--once", "Was Donna there?",
        ])

        let code = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.transcriptEvents.count == 2)
        let user = harness.transcriptEvents[0]
        let answer = harness.transcriptEvents[1]
        #expect(user.kind == .user)
        #expect(user.text == "Was Donna there?")
        #expect(user.sequence == 1)
        #expect(answer.kind == .assistant)
        #expect(answer.sequence == 2)
        #expect(answer.sessionID == user.sessionID)
        #expect(answer.model == "fixture-model")
        #expect(answer.responder == "fixture-translator")
        #expect(answer.route == "presence")
        #expect(answer.outcome == "answered")
        #expect(answer.mediaEvidence.map(\.recordID) == [item.id])
    }

    /// Eval sm022 on main d3725558: "It's pouring rain here in the
    /// Berkshires today." ran a presence search for "berkshires" (5 videos).
    /// The lane order is capability › help/small-talk › record › knowledge
    /// › catalog › translator, and the sentence is small talk — so it is
    /// answered by the deterministic table with NO translation call and no
    /// media evidence, even with "Berkshires" files in the catalog.
    @Test func aWeatherAsideIsSmallTalkBeforeAnyCatalogLaneOrTheTranslator() async throws {
        let berkshires = VideoRecord()
        berkshires.fullPath = "/isolated/Movies/New Home in the Berkshires.mp4"
        berkshires.filename = "New Home in the Berkshires.mp4"
        berkshires.directory = "/isolated/Movies"
        let harness = Harness(records: [berkshires])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--model", "fixture-model",
            "--once", "It's pouring rain here in the Berkshires today.",
        ])

        let code = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.translatedQuestions.isEmpty, "small talk must never reach the translator")
        let answer = try #require(harness.transcriptEvents.last)
        #expect(answer.kind == .assistant)
        #expect(answer.route == "smalltalk")
        #expect(answer.outcome == "answered")
        #expect(answer.mediaEvidence.isEmpty)
        #expect(answer.text == ArchivistConversationCommand.smalltalkReply(.weather))
        #expect(!harness.output.contains { $0.contains("berkshires") || $0.contains("Berkshires.mp4") })
    }

    @Test func translatorFailureAssertsNoFactAndPerformsNoMediaAction() async throws {
        let harness = Harness()
        harness.translationError = HarnessError.refusedByTranslator
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", "Invent something",
        ])

        let code = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.output.contains {
            $0.contains("I didn't search the archive or open anything")
        })
        #expect(!harness.output.contains { $0.contains("I found") })
        #expect(harness.mediaActions.isEmpty)
        #expect(code == HallieShellCLI.ExitCode.interpretationFailed.rawValue)
    }

    @Test func clarificationNumberAndExactNameDoNotRetranslate() async throws {
        for reply in ["2", "Timothy Breen"] {
            let profiles = [
                POIProfile(
                    name: "Tim Breen", referencePath: "/isolated/tim-a",
                    aliases: ["Timmy"],
                    birthdate: Date(timeIntervalSince1970: 0)),
                POIProfile(
                    name: "Timothy Breen", referencePath: "/isolated/tim-z",
                    aliases: ["Timmy"],
                    birthdate: Date(timeIntervalSince1970: 946_684_800)),
            ]
            let ast = ArchivistQueryAST.temporal(.init(
                subject: "Timmy", operation: .age,
                reference: .explicitYear(2020)))
            let harness = Harness(
                inputs: ["How old was Timmy in 2020?", reply, ":quit"],
                profiles: profiles, translations: [ast])
            let continuations = LockedCounter()
            harness.executeRequest = { request, context in
                try await HallieTurnExecutor.execute(request, context: context)
            }
            harness.continueTurn = { pending, selectedID, context in
                continuations.increment()
                return try await HallieTurnExecutor.continue(
                    pending: pending, selecting: selectedID, context: context)
            }
            let options = try HallieShellCLI.parse(arguments: [
                "--hallie", "--catalog", "/isolated/catalog.json",
            ])

            let code = await HallieShellCLI.run(
                options: options, input: harness.nextInput,
                output: { harness.output.append($0) },
                dependencies: harness.dependencies())

            #expect(code == HallieShellCLI.ExitCode.success.rawValue)
            #expect(harness.translatedQuestions
                    == ["How old was Timmy in 2020?"])
            #expect(continuations.value == 1)
            #expect(harness.output.contains { $0 == "choices:" })
            #expect(harness.output.contains("  1. Tim Breen"))
            #expect(harness.output.contains("  2. Timothy Breen"))
            #expect(harness.output.contains { $0.contains("Timothy Breen") })
            #expect(harness.output.contains { $0.contains("years old") })
            #expect(harness.mediaActions.isEmpty)
        }
    }

    /// lv260902-013 is intentionally synthetic: Rick's live "yes" came
    /// after he had already corrected the name and received a biography.
    /// The useful contract is immediate adjacency — one offered identity,
    /// then an ordinary affirmative, resumes the exact original ask.
    @Test func immediateThatOneAfterALoneDidYouMeanResumesTheOriginalAsk() async throws {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME William Love /Latta Sr./
        1 BIRT
        2 DATE 3 FEB 1875
        2 PLAC Wilmington, North Carolina
        0 TRLR
        """)
        let ast = ArchivistQueryAST.graph(.init(
            people: ["william love latter"], operation: .biography))
        let harness = Harness(
            inputs: ["research william love latter", "that one", ":quit"],
            graph: graph, translations: [ast])
        let continuations = LockedCounter()
        harness.continueTurn = { pending, selectedID, context in
            continuations.increment()
            return try await HallieTurnExecutor.continue(
                pending: pending, selecting: selectedID, context: context)
        }
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])

        _ = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        let transcript = harness.output.joined(separator: "\n")
        #expect(harness.translatedQuestions == ["research william love latter"])
        #expect(continuations.value == 1)
        #expect(transcript.contains("did you mean William Love Latta Sr.?"),
                Comment(rawValue: transcript))
        #expect(transcript.contains("William Love Latta Sr. was born"),
                Comment(rawValue: transcript))
        let answers = harness.transcriptEvents.filter { $0.kind == .assistant }
        #expect(answers.map(\.route) == ["graph", "graph"])
        #expect(answers.map(\.outcome) == ["needs-clarification", "answered"])
    }

    /// Isolation sensor: an answered intervening turn expires the old
    /// clarification. A later "yes" may be handled or declined as its own
    /// turn, but it must never resurrect William from poisoned old state.
    @Test func answeredInterveningTurnExpiresTheOldDidYouMean() async throws {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME William Love /Latta Sr./
        1 BIRT
        2 DATE 1875
        0 @I2@ INDI
        1 NAME Donna /Breen/
        1 BIRT
        2 DATE 1959
        0 TRLR
        """)
        let william = ArchivistQueryAST.graph(.init(
            people: ["william love latter"], operation: .biography))
        let donna = ArchivistQueryAST.graph(.init(
            people: ["Donna Breen"], operation: .biography))
        let harness = Harness(
            inputs: [
                "research william love latter",
                "tell me about Donna Breen",
                "yes",
                ":quit",
            ],
            graph: graph, translations: [william, donna])
        let continuations = LockedCounter()
        harness.continueTurn = { pending, selectedID, context in
            continuations.increment()
            return try await HallieTurnExecutor.continue(
                pending: pending, selecting: selectedID, context: context)
        }
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])

        _ = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        let answers = harness.transcriptEvents.filter { $0.kind == .assistant }
        #expect(continuations.value == 0, "stale William offer must not resume")
        #expect(answers.filter { $0.text.contains("William Love Latta Sr. was born") }.isEmpty)
        #expect(answers.contains { $0.text.contains("Donna Breen") && $0.outcome == "answered" })
        #expect(answers.last?.route != "graph" || answers.last?.text.contains("Donna Breen") == true,
                "bare yes must not become the stale William biography")
    }

    @Test func cancelAbandonsPendingClarificationWithoutContinuation() async throws {
        let profiles = [
            POIProfile(name: "Tim Breen", referencePath: "/isolated/tim-a",
                       aliases: ["Timmy"]),
            POIProfile(name: "Timothy Breen", referencePath: "/isolated/tim-z",
                       aliases: ["Timmy"]),
        ]
        let ast = ArchivistQueryAST.temporal(.init(
            subject: "Timmy", operation: .age,
            reference: .explicitYear(2020)))
        let harness = Harness(
            inputs: ["How old was Timmy?", ":cancel", ":session", ":quit"],
            profiles: profiles, translations: [ast])
        let continuations = LockedCounter()
        harness.executeRequest = { request, context in
            try await HallieTurnExecutor.execute(request, context: context)
        }
        harness.continueTurn = { pending, selectedID, context in
            continuations.increment()
            return try await HallieTurnExecutor.continue(
                pending: pending, selecting: selectedID, context: context)
        }
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--catalog", "/isolated/catalog.json",
        ])

        _ = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.translatedQuestions == ["How old was Timmy?"])
        #expect(continuations.value == 0)
        #expect(harness.output.contains(
            "Clarification cancelled; I won't guess."))
        #expect(harness.output.contains { $0.contains("pending none") })
    }

    // MARK: - Typed routing boundary

    @Test func allSixASTShapesHaveClosedExplicitRoutes() {
        let cases: [(ArchivistQueryAST, HallieShellCLI.Route)] = [
            (.presence(.init(people: ["Donna"])), .presence),
            (.temporal(.init(subject: "Donna", operation: .age,
                             reference: .explicitYear(2000))), .temporal),
            (.aggregate(.init(operation: .coOccurrence,
                              anchorPeople: ["Donna"])), .aggregate),
            (.graph(.init(people: ["Donna"], operation: .biography)), .graph),
            (.event(.init(keywords: ["birthday"])), .unsupportedEvent),
            (.cross(.init(people: ["Donna"], transcript: ["birthday"])), .cross),
        ]
        for (ast, expected) in cases {
            #expect(HallieShellCLI.route(ast) == expected)
        }
    }

    @Test func fourSupportedShapesExecuteThroughOnceMode() async throws {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Alex /River/
        0 TRLR
        """)
        let cases: [(ArchivistQueryAST, String)] = [
            (.presence(.init(people: ["Donna"])), "shape=presence"),
            (.temporal(.init(subject: "Donna", operation: .age,
                             reference: .explicitYear(2000))), "shape=temporal"),
            (.aggregate(.init(operation: .coOccurrence,
                              anchorPeople: ["Donna"])), "shape=aggregate"),
            (.graph(.init(people: ["Alex River"], operation: .biography)),
             "shape=graph"),
        ]

        for (ast, shape) in cases {
            let harness = Harness(graph: graph, translations: [ast])
            let options = try HallieShellCLI.parse(arguments: [
                "--hallie", "--once", "fixture question", "--diagnostics",
            ])
            _ = await HallieShellCLI.run(
                options: options, output: { harness.output.append($0) },
                dependencies: harness.dependencies())

            #expect(harness.translatedQuestions == ["fixture question"])
            #expect(harness.output.contains { $0.contains(shape) })
            #expect(!harness.output.contains { $0.contains("not supported") })
            #expect(harness.output.contains("interpreted by fixture-translator"))
        }
    }

    @Test func eventIsDeclinedBySharedTurnWithoutMediaAction() async throws {
        let ast = ArchivistQueryAST.event(.init(keywords: ["first birthday"]))
        let harness = Harness(translations: [ast])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", "fixture question", "--diagnostics",
        ])
        let code = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.output.contains { $0.contains("not supported") })
        #expect(harness.output.contains { $0.contains("did not run a broader search") })
        #expect(harness.output.contains { $0.contains("QueryAST shape=") })
        #expect(harness.mediaActions.isEmpty)
        #expect(code == HallieShellCLI.ExitCode.unsupportedShape.rawValue)
    }

    /// Cross now runs on the deterministic presence executor: with no
    /// matching evidence it declines on evidence (exit 3), never as an
    /// unsupported shape, and never opens media.
    @Test func crossExecutesDeterministicallyAndDeclinesOnNoEvidence() async throws {
        let ast = ArchivistQueryAST.cross(.init(people: ["Donna"], keywords: ["red bike"]))
        let harness = Harness(translations: [ast])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", "fixture question", "--diagnostics",
        ])
        let code = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.output.contains { $0.contains("shape=cross") })
        #expect(!harness.output.contains { $0.contains("not supported") })
        #expect(harness.mediaActions.isEmpty)
        #expect(code == HallieShellCLI.ExitCode.noEvidence.rawValue)
    }

    @Test func unsupportedRoutesRenderSharedResultWithoutShellOverride() async throws {
        for (ast, route) in [
            (ArchivistQueryAST.event(.init(keywords: ["birthday"])),
             HallieTurnExecutor.Route.unsupportedEvent),
        ] {
            let harness = Harness(translations: [ast])
            harness.executeTurn = { _, _ in
                HallieTurnExecutor.Result(
                    route: route,
                    outcome: .unsupported,
                    prose: "SENTINEL shared unsupported prose",
                    basisLine: "SENTINEL shared unsupported basis",
                    queryDescription: nil,
                    citations: [],
                    catalogPersonName: nil)
            }
            let options = try HallieShellCLI.parse(arguments: [
                "--hallie", "--once", "fixture question", "--diagnostics",
            ])

            let code = await HallieShellCLI.run(
                options: options, output: { harness.output.append($0) },
                dependencies: harness.dependencies())

            #expect(code == HallieShellCLI.ExitCode.unsupportedShape.rawValue)
            #expect(harness.output.contains("SENTINEL shared unsupported prose"))
            #expect(harness.output.contains("SENTINEL shared unsupported basis"))
            #expect(!harness.output.contains {
                $0.contains("not supported by the headless shell")
            })
            #expect(!harness.output.contains {
                $0.contains("no deterministic shell executor")
            })
            #expect(harness.mediaActions.isEmpty)
        }
    }

    // MARK: - Citation and media safety

    @Test func citationsAreBoundedAndRetainPlaybackCoordinates() async throws {
        let records = (0..<40).map { index in
            record("/isolated/archive/clip-\(index).mov", confirmed: ["Donna"],
                   caption: (Double(index) + 0.25, "Donna waves"))
        }
        let harness = Harness(
            records: records,
            translations: [.presence(.init(people: ["Donna"], keywords: ["waves"]))])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--diagnostics", "--once", "Where is Donna waving?",
        ])

        _ = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        let citationRows = harness.output.filter {
            $0.hasPrefix("  ") && $0.contains(". clip-")
        }
        #expect(citationRows.count == ArchivistPresenceExecutor.maxCitations)
        #expect(citationRows.first?.contains("clip-0.mov @ 0.2s") == true)
        #expect(citationRows.first?.contains("/isolated/archive/clip-0.mov") == true)
    }

    @Test func invalidIndexesNeverOpenMediaAndValidCommandsAreExplicit() async throws {
        let value = record("/isolated/archive/donna.mov", confirmed: ["Donna"])
        let harness = Harness(
            inputs: ["Was Donna there?", ":play 0", ":play 2", ":select 1",
                     ":play 1", ":reveal 1", ":quit"],
            records: [value],
            translations: [.presence(.init(people: ["Donna"]))])
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])

        _ = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.mediaActions == [
            .play(URL(fileURLWithPath: value.fullPath)),
            .reveal(URL(fileURLWithPath: value.fullPath)),
        ])
        #expect(harness.output.filter { $0.hasPrefix("No such citation") }.count == 2)
        #expect(harness.output.contains("selected 1: donna.mov"))
    }

    @Test func askingSelectingAndListingNeverImplicitlyOpenMedia() async throws {
        let harness = Harness(
            inputs: ["Was Donna there?", ":select 1", ":list", ":quit"],
            records: [record("/isolated/archive/donna.mov", confirmed: ["Donna"])],
            translations: [.presence(.init(people: ["Donna"]))])
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])

        _ = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.mediaActions.isEmpty)
    }

    @Test func selectByFilenameFragmentSetsTheSameSelectionAsSelectN() async throws {
        // Eval enabler (2026-09-01): ":select Christmas_1994_etc.mkv" before
        // "when was this filmed" — no prior answer, no citation list.
        let christmas = record("/isolated/archive/Christmas_1994_etc.mkv", confirmed: ["Donna"])
        christmas.embeddedCreationDate = Date(timeIntervalSince1970: 788_000_000) // 1994-12-21 UTC
        // A 2026 transcode stamp must not become the file's year.
        christmas.dateCreatedRaw = Date(timeIntervalSince1970: 1_784_000_000) // 2026-07
        let undated = record("/isolated/archive/Cape tape.mov")
        let harness = Harness(
            inputs: [":select christmas_1994", ":session",
                     ":select Cape tape", ":select nothing-like-this", ":quit"],
            records: [undated, christmas])
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])

        _ = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.output.contains("selected Christmas_1994_etc.mkv (1994)"))
        #expect(harness.output.contains {
            $0.hasPrefix("session:") && $0.contains("selected \(christmas.id.uuidString)")
        })
        // Spaces in the fragment survive the command split; no date → "undated".
        #expect(harness.output.contains("selected Cape tape.mov (undated)"))
        #expect(harness.output.contains("no file matches “nothing-like-this”"))
        #expect(harness.mediaActions.isEmpty)
        #expect(harness.output.filter { $0.hasPrefix("No such citation") }.isEmpty)
    }

    /// The eval's five phrasings (2026-09-01), asked of the real record
    /// shape: Rick's userDate "1994", a 2026 transcode stamp, no embedded
    /// date. All answered locally from the resolved date — no translation.
    @Test func selectionDateQuestionsAnswerFromTheResolvedDateWithoutTheModel() async throws {
        let christmas = record("/isolated/Christmas1994/Christmas_1994_etc.mkv", confirmed: ["Donna"])
        christmas.userDate = "1994"
        christmas.userDateConfidence = UserDateConfidence.known.rawValue
        christmas.dateCreatedRaw = Date(timeIntervalSince1970: 1_784_000_000) // 2026-07
        let harness = Harness(
            inputs: [":select Christmas_1994_etc.mkv",
                     "when was this filmed",
                     "what year is that from",
                     "how old is this tape",
                     "what season was this filmed in",
                     "how long ago was that",
                     ":quit"],
            records: [christmas])
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])

        let code = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.output.contains("selected Christmas_1994_etc.mkv (1994)"))
        #expect(harness.translatedQuestions.isEmpty)
        #expect(harness.output.contains { $0.contains("This was filmed in 1994.") })
        #expect(harness.output.contains { $0.contains("This is from 1994.") })
        let thisYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        #expect(harness.output.contains { $0.contains("About \(thisYear - 1994) years old — filmed in 1994.") })
        #expect(harness.output.contains { $0.contains("I only know the year — 1994 — so I can't say the season") })
        #expect(harness.output.contains { $0.contains("About \(thisYear - 1994) years ago (1994).") })
        #expect(!harness.output.contains { $0.contains("I need to know who you mean") })
        #expect(!harness.output.contains { $0.contains("2026") && $0.contains("filmed") })
    }

    /// Day precision through the shell: an embedded camera date gives the
    /// full date, the season, and a real elapsed-years count.
    @Test func selectionDateQuestionsUseTheEmbeddedDateAtDayPrecision() async throws {
        let tape = record("/isolated/tapes/xmas.mov")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        tape.embeddedCreationDate = utc.date(from: DateComponents(year: 1994, month: 12, day: 25, hour: 15))!
        tape.originMake = "Sony"
        tape.dateCreatedRaw = Date(timeIntervalSince1970: 1_784_000_000) // 2026-07
        let harness = Harness(
            inputs: [":select xmas", "when was this filmed", "what season was this filmed in", ":quit"],
            records: [tape])
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])

        _ = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.translatedQuestions.isEmpty)
        #expect(harness.output.contains { $0.contains("This was filmed on 25 December 1994.") })
        #expect(harness.output.contains { $0.contains("This was filmed in winter, on 25 December 1994.") })
    }

    /// Nothing selected: the words still go to the translator and the
    /// temporal route asks for a selection, exactly as before.
    @Test func selectionDateQuestionsWithoutASelectionStillTranslate() async throws {
        let ast = ArchivistQueryAST.temporal(.init(
            subject: "this", operation: .age, reference: .currentSelection))
        let harness = Harness(
            inputs: ["when was this filmed", ":quit"],
            records: [record("/isolated/Christmas1994/Christmas_1994_etc.mkv")],
            translations: [ast])
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])

        _ = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.translatedQuestions == ["when was this filmed"])
        #expect(!harness.output.contains { $0.contains("This was filmed") })
    }

    /// Bug A through the shell: "how old is Donna" with the 1994 tape
    /// selected counts from Rick's year, not from the 2026 transcode stamp.
    @Test func personAgeWithSelectionCountsFromTheResolvedDateNotTheTranscodeStamp() async throws {
        let christmas = record("/isolated/Christmas1994/Christmas_1994_etc.mkv", confirmed: ["Donna"])
        christmas.userDate = "1994"
        christmas.userDateConfidence = UserDateConfidence.known.rawValue
        christmas.dateCreatedRaw = Date(timeIntervalSince1970: 1_784_000_000) // 2026-07
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let born = utc.date(from: DateComponents(year: 1959, month: 6, day: 15, hour: 12))!
        let ast = ArchivistQueryAST.temporal(.init(
            subject: "Donna", operation: .age, reference: .currentSelection))
        let harness = Harness(
            inputs: [":select christmas_1994", "how old is Donna", ":quit"],
            records: [christmas],
            profiles: [POIProfile(name: "Donna", referencePath: "/isolated/donna", birthdate: born)],
            translations: [ast])
        harness.executeRequest = { request, context in
            try await HallieTurnExecutor.execute(request, context: context)
        }
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])

        _ = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.translatedQuestions == ["how old is Donna"])
        #expect(harness.output.contains { $0.contains("34\u{2013}35 years old during 1994") })
        #expect(!harness.output.contains { $0.contains("66") })
        #expect(!harness.output.contains { $0.contains("catalog creation date") })
    }

    @Test func selectByFilenameTakesTheFirstCatalogMatchCaseInsensitively() {
        let a = record("/isolated/one/XMAS_1994.mkv")
        let b = record("/isolated/two/xmas_1995.mkv")
        #expect(HallieShellCLI.selectRecord(matchingFilename: "xmas", in: [a, b])?.id == a.id)
        #expect(HallieShellCLI.selectRecord(matchingFilename: "1995", in: [a, b])?.id == b.id)
        #expect(HallieShellCLI.selectRecord(matchingFilename: "  ", in: [a, b]) == nil)
        #expect(HallieShellCLI.selectRecord(matchingFilename: "/isolated/one", in: [a, b]) == nil)
    }

    @Test func unavailableCitationNeverClaimsPlayOrRevealAndReturnsMediaFailure() async throws {
        for command in [":play 1", ":reveal 1"] {
            let path = "/offline/archive/missing.mov"
            let harness = Harness(
                inputs: ["Was Donna there?", command],
                translations: [.presence(.init(people: ["Donna"]))])
            harness.unavailableMediaPaths = [path]
            let answer = citedAnswer(path: path)
            harness.executeTurn = { _, _ in answer }
            let options = try HallieShellCLI.parse(arguments: ["--hallie"])

            let code = await HallieShellCLI.run(
                options: options, input: harness.nextInput,
                output: { harness.output.append($0) },
                dependencies: harness.dependencies())

            #expect(code == HallieShellCLI.ExitCode.mediaUnavailable.rawValue)
            #expect(harness.mediaActions.isEmpty)
            #expect(harness.output.contains {
                $0.contains("unavailable or unreadable")
            })
            #expect(!harness.output.contains("opening missing.mov"))
            #expect(!harness.output.contains("revealing missing.mov"))
        }
    }

    @Test func refusedMediaActionNeverClaimsSuccessAndReturnsMediaFailure() async throws {
        for command in [":play 1", ":reveal 1"] {
            let path = "/isolated/available.mov"
            let harness = Harness(
                inputs: ["Was Donna there?", command],
                translations: [.presence(.init(people: ["Donna"]))])
            harness.mediaActionShouldSucceed = false
            let answer = citedAnswer(path: path)
            harness.executeTurn = { _, _ in answer }
            let options = try HallieShellCLI.parse(arguments: ["--hallie"])

            let code = await HallieShellCLI.run(
                options: options, input: harness.nextInput,
                output: { harness.output.append($0) },
                dependencies: harness.dependencies())

            #expect(code == HallieShellCLI.ExitCode.mediaUnavailable.rawValue)
            #expect(harness.mediaActions.count == 1)
            #expect(harness.output.contains {
                $0.contains("system refused")
                    && $0.contains("no media action was completed")
            })
            #expect(!harness.output.contains("opening available.mov"))
            #expect(!harness.output.contains("revealing available.mov"))
        }
    }

    @Test func availableCitationReportsSuccessOnlyAfterMediaActionSucceeds() async throws {
        for (command, expectedAction, successLine) in [
            (":play 1",
             HallieShellCLI.MediaAction.play(
                URL(fileURLWithPath: "/isolated/available.mov")),
             "opening available.mov"),
            (":reveal 1",
             HallieShellCLI.MediaAction.reveal(
                URL(fileURLWithPath: "/isolated/available.mov")),
             "revealing available.mov"),
        ] {
            let path = "/isolated/available.mov"
            let harness = Harness(
                inputs: ["Was Donna there?", command, ":quit"],
                translations: [.presence(.init(people: ["Donna"]))])
            let answer = citedAnswer(path: path)
            harness.executeTurn = { _, _ in answer }
            let options = try HallieShellCLI.parse(arguments: ["--hallie"])

            let code = await HallieShellCLI.run(
                options: options, input: harness.nextInput,
                output: { harness.output.append($0) },
                dependencies: harness.dependencies())

            #expect(code == HallieShellCLI.ExitCode.success.rawValue)
            #expect(harness.mediaActions == [expectedAction])
            #expect(harness.output.contains(successLine))
        }
    }

    @Test func biographyPrintsCyberBrainClaimAndRelativeSource() async throws {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let source = CyberBrainSource(
            id: "source.cape",
            type: .firstPerson,
            title: "Cape memories",
            attribution: "Donna Breen",
            locator: "sources/donna-cape.txt")
        let item = CyberBrainItem(
            id: "bio.cape",
            kind: .biography,
            text: "Donna remembers the Cape as a central family gathering place.",
            subjectPersonIDs: ["person.donna"],
            sourceIDs: [source.id],
            confidence: .confirmed,
            privacy: .family,
            createdAt: instant,
            updatedAt: instant)
        let harness = Harness(translations: [.graph(.init(
            people: ["Donna"], operation: .biography))])
        harness.cyberBrain = try CyberBrainIndex(archive: .init(
            archiveID: "breen",
            displayName: "Breen Family CyberBrain",
            people: [.init(
                id: "person.donna",
                canonicalName: "Donna Breen",
                aliases: ["Donna"],
                biographyPassages: [item])],
            sources: [source]))

        let code = await HallieShellCLI.run(
            options: .init(once: "Tell me about Donna", diagnostics: true),
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.output.contains(where: {
            $0.contains("central family gathering place")
        }))
        #expect(harness.output.contains("knowledge sources:"))
        #expect(harness.output.contains(
            "  1. Cape memories — Donna Breen [sources/donna-cape.txt]"))
    }

    @Test func biographyPrintsVerifiedPhotoButOpensOnlyOnExplicitCommand() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-biography-photo-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("portrait.png")
        try onePixelPNG.write(to: photo)

        var profile = POIProfile(name: "Alex River", referencePath: root.path)
        profile.coverImageFilename = photo.lastPathComponent
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Alex /River/
        1 BIRT
        2 DATE 1 JAN 1900
        0 TRLR
        """)
        let harness = Harness(
            inputs: ["Tell me about Alex River", ":photo", ":open-photo",
                     ":reveal-photo", ":quit"],
            profiles: [profile], graph: graph,
            translations: [.graph(.init(
                people: ["Alex River"], operation: .biography))])
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])

        _ = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.output.filter { $0 == "photo: \(photo.path)" }.count == 1,
                "the attachment path appears only after the explicit :photo command")
        #expect(harness.mediaActions == [.play(photo), .reveal(photo)],
                "answering and :photo are presentation-only; only explicit open commands act")
    }

    @Test func biographyPhotoRejectsTraversalAbsoluteSymlinkAmbiguityAndNoCover() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-photo-safety-\(UUID().uuidString)",
                                    isDirectory: true)
        let references = root.appendingPathComponent("references", isDirectory: true)
        try FileManager.default.createDirectory(
            at: references, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let regular = references.appendingPathComponent("regular.png")
        try onePixelPNG.write(to: regular)
        let symlink = references.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(
            at: symlink, withDestinationURL: regular)

        func profile(_ name: String = "Alex River", cover: String?) -> POIProfile {
            var value = POIProfile(name: name, referencePath: references.path)
            value.coverImageFilename = cover
            return value
        }

        #expect(ArchivistBiographyPhoto.resolve(
            personName: "Alex River",
            profiles: [profile(cover: regular.lastPathComponent)])?.fileURL == regular)
        #expect(ArchivistBiographyPhoto.resolve(
            personName: "Alex River", profiles: [profile(cover: "../regular.png")]) == nil)
        #expect(ArchivistBiographyPhoto.resolve(
            personName: "Alex River", profiles: [profile(cover: regular.path)]) == nil)
        #expect(ArchivistBiographyPhoto.resolve(
            personName: "Alex River", profiles: [profile(cover: symlink.lastPathComponent)]) == nil)
        #expect(ArchivistBiographyPhoto.resolve(
            personName: "Alex River",
            profiles: [profile(cover: regular.lastPathComponent),
                       profile(cover: regular.lastPathComponent)]) == nil)
        #expect(ArchivistBiographyPhoto.resolve(
            personName: "Alex River", profiles: [profile(cover: nil)]) == nil)

        let corrupt = references.appendingPathComponent("corrupt.png")
        try Data("not an image".utf8).write(to: corrupt)
        #expect(ArchivistBiographyPhoto.resolve(
            personName: "Alex River",
            profiles: [profile(cover: corrupt.lastPathComponent)]) == nil)
    }

    @Test func biographyPhotoDownsamplesAndRevalidatesBeforeUse() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-photo-downsample-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2048, pixelsHigh: 1024,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let formats: [(String, NSBitmapImageRep.FileType)] = [
            ("large.png", .png), ("large.jpg", .jpeg),
        ]
        for (filename, format) in formats {
            let url = root.appendingPathComponent(filename)
            let data = try #require(bitmap.representation(
                using: format, properties: [:]))
            try data.write(to: url)
            var profile = POIProfile(name: "Alex River", referencePath: root.path)
            profile.coverImageFilename = filename
            let attachment = try #require(ArchivistBiographyPhoto.resolve(
                personName: "Alex River", profiles: [profile]))
            let thumbnail = try #require(attachment.makeThumbnail(maxPixelSize: 64))
            #expect(max(thumbnail.width, thumbnail.height) <= 64)
        }

        var profile = POIProfile(name: "Alex River", referencePath: root.path)
        profile.coverImageFilename = "replace.png"
        let replace = root.appendingPathComponent("replace.png")
        try onePixelPNG.write(to: replace)
        let attachment = try #require(ArchivistBiographyPhoto.resolve(
            personName: "Alex River", profiles: [profile]))
        try FileManager.default.removeItem(at: replace)
        try FileManager.default.createSymbolicLink(
            at: replace, withDestinationURL: root.appendingPathComponent("large.png"))
        #expect(attachment.revalidatedURL() == nil)
        #expect(attachment.makeThumbnail(maxPixelSize: 64) == nil)
    }

    // MARK: - Scale, isolation, and production wiring sensors

    @Test func oneHundredThousandRecordOnceModeSnapshotsAndDispatchesWithinBudget() async throws {
        let repeated = record("/isolated/scale/repeated.mov", confirmed: ["Donna"])
        let harness = Harness(
            records: Array(repeating: repeated, count: 100_000),
            translations: [.presence(.init(people: ["Nobody"]))])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", "Was Nobody there?",
        ])

        let started = ContinuousClock.now
        let code = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())
        let elapsed = ContinuousClock.now - started

        #expect(code == HallieShellCLI.ExitCode.noEvidence.rawValue)
        #expect(harness.output.contains("Archive ready — 100000 catalog items, read-only."))
        #expect(elapsed < .seconds(4),
                "shell snapshot + typed dispatch took \(elapsed) for 100k records")
    }

    @Test func injectedFilesAndPoisonedDefaultsCannotRedirectReadOnlySession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("catalog.json")
        let sentinel = Data("READ-ONLY-SENTINEL".utf8)
        try sentinel.write(to: catalog)

        let poisonKey = OllamaEndpoints.hostsKey
        let priorHosts = UserDefaults.standard.object(forKey: poisonKey)
        UserDefaults.standard.set("poison.invalid", forKey: poisonKey)
        defer {
            if let priorHosts {
                UserDefaults.standard.set(priorHosts, forKey: poisonKey)
            } else {
                UserDefaults.standard.removeObject(forKey: poisonKey)
            }
        }

        let harness = Harness(
            records: [record("/isolated/media/test.mov")],
            profiles: [POIProfile(name: "Fixture Person", referencePath: root.path)],
            graph: GedcomFamilyGraph(gedcomText: "0 HEAD\n0 TRLR"),
            translations: [.presence(.init(people: ["Nobody"]))])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--catalog", catalog.path,
            "--host", "isolated-translator.local",
            "--gedcom", root.appendingPathComponent("fixture.ged").path,
            "--once", "Was Nobody there?",
        ])
        _ = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.loadedURLs == [catalog])
        #expect(harness.translationOptions.first?.hosts
                == ["isolated-translator.local"])
        #expect(try Data(contentsOf: catalog) == sentinel,
                "the shell must never rewrite even its explicitly loaded catalog")
        #expect(harness.mediaActions.isEmpty)
    }

    @Test func cancellationReachesInjectedTurnSeamAndPerformsNoMediaAction() async throws {
        let probe = CancellationProbe()
        let harness = Harness(
            translations: [.presence(.init(people: ["Donna"]))])
        harness.executeTurn = { _, _ in
            await probe.blockUntilCancelled()
            try Task.checkCancellation()
            throw CancellationError()
        }
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", "Was Donna there?",
        ])

        let task = Task {
            await HallieShellCLI.run(
                options: options, output: { harness.output.append($0) },
                dependencies: harness.dependencies())
        }
        await probe.waitUntilStarted()
        task.cancel()
        let code = await task.value

        #expect(probe.observedCancellation)
        #expect(code == HallieShellCLI.ExitCode.interpretationFailed.rawValue)
        #expect(harness.mediaActions.isEmpty)
        #expect(!harness.output.contains { $0.contains("I found") })
    }

    @Test func productionProfileLoaderFailsClosedForUnreadableAndCorruptProfiles() async throws {
        func profileURL(in root: URL) throws -> URL {
            let folder = root.appendingPathComponent("VideoScan/POI/Fixture",
                                                      isDirectory: true)
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
            return folder.appendingPathComponent("profile.json")
        }

        let corruptRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-corrupt-profile-\(UUID().uuidString)",
                                    isDirectory: true)
        let unreadableRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-unreadable-profile-\(UUID().uuidString)",
                                    isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: corruptRoot)
            try? FileManager.default.removeItem(at: unreadableRoot)
        }

        let corruptURL = try profileURL(in: corruptRoot)
        try Data("not valid profile JSON".utf8).write(to: corruptURL)
        let corrupt = HallieShellCLI.loadProfilesReadOnly(
            applicationSupportURL: corruptRoot)
        guard case .unavailable(.profileCorrupt(let reportedCorruptPath))
                = corrupt else {
            Issue.record("corrupt production profile must make evidence unavailable")
            return
        }
        #expect(reportedCorruptPath == corruptURL.path)

        let missingURL = try profileURL(in: unreadableRoot)
        let unreadable = HallieShellCLI.loadProfilesReadOnly(
            applicationSupportURL: unreadableRoot)
        guard case .unavailable(.profileUnreadable(let reportedUnreadablePath))
                = unreadable else {
            Issue.record("unreadable production profile must make evidence unavailable")
            return
        }
        #expect(reportedUnreadablePath == missingURL.path)

        let harness = Harness(translations: [.temporal(.init(
            subject: "Donna", operation: .age,
            reference: .explicitYear(2000)))])
        harness.profileLoadResult = corrupt
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--diagnostics", "--once", "How old was Donna in 2000?",
        ])
        let code = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.noEvidence.rawValue)
        #expect(harness.output.contains {
            $0.contains("People profiles are unavailable")
        })
        #expect(harness.output.contains {
            $0 == "Basis: profile evidence could not be read."
        })
        #expect(harness.mediaActions.isEmpty)
    }

    /// Media matrix is intentionally N/A for ordinary shell questions: the
    /// shell handles catalog metadata only. The command tests pin that media
    /// reaches AppKit solely through explicit :play or :reveal commands.
    @Test func productionSourceHasNoCatalogWriterOrImplicitMediaPath() throws {
        let shell = try source(named: "HallieShellCLI.swift")
        let compactShell = shell.filter { !$0.isWhitespace }
        #expect(!shell.contains("CatalogStore("))
        #expect(!shell.contains("saveNow("))
        #expect(!shell.contains("scheduleSave("))
        #expect(shell.contains("case \":select\", \":play\", \":reveal\":"))
        #expect(compactShell.contains("dependencies.mediaURLIsAvailable(url)"))
        #expect(compactShell.contains("dependencies.tryPerformMediaAction(action)"))
        #expect(shell.contains("case mediaFailure"))
        #expect(shell.contains("case mediaUnavailable = 6"))
    }

    @Test func mainRoutesHallieBeforeSwiftUIAndShellUsesTypedTranslator() throws {
        let main = try source(named: "main.swift")
        // The shell's rendering lives in a sibling extension file; the
        // source sensors below cover both.
        let shell = try source(named: "HallieShellCLI.swift")
            + source(named: "HallieShellCLI+Render.swift")
        let hallieBranch = try #require(main.range(of: "if isHallieShell"))
        let appMain = try #require(main.range(of: "VideoScanApp.main()",
                                             options: .backwards))

        #expect(hallieBranch.lowerBound < appMain.lowerBound,
                "--hallie must route before the normal SwiftUI app entry")
        #expect(main.contains("HallieShellCLI.parse("))
        #expect(main.contains("HallieShellCLI.run(options:"))
        #expect(shell.contains("translator.translateAST(question)"))
        #expect(!shell.contains("translator.translate(question)"),
                "the shell must not fall back to the v1 translator")
        #expect(shell.contains("if let pending = state.pendingClarification"))
        #expect(shell.contains("dependencies.continueTurn("))
        #expect(shell.contains("case \":cancel\":"))
        #expect(shell.contains("Reply with a number or exact name"))
    }

    /// "the boys" / "my dad" through the shell (eval tm008, tm014, tm019,
    /// 2026-09-01): the owner's household children and father come from the
    /// People-tab relationships in the fixture profiles; the age arithmetic
    /// counts from the selected record's resolved year; and "and the most
    /// recent one?" afterwards is the boys' newest video.
    @Test func theBoysAndMyDadResolveThroughThePeopleTabInTheShell() async throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
        }
        func profile(_ name: String, born: Date, died: Date? = nil, sex: PersonSex = .male,
                     kinships: [Kinship] = []) -> POIProfile {
            var value = POIProfile(name: name, referencePath: "/isolated/\(name.lowercased())",
                                   birthdate: born, deathdate: died, sex: sex)
            value.kinships = kinships
            return value
        }
        let profiles = [
            profile("Rick", born: day(1958, 3, 1), kinships: [
                Kinship(relation: .spouse, relativeTo: .profile(name: "Donna")),
                Kinship(relation: .parent, relativeTo: .profile(name: "Dan")),
                Kinship(relation: .parent, relativeTo: .profile(name: "Mark")),
                Kinship(relation: .child, relativeTo: .profile(name: "Dad")),
            ]),
            profile("Donna", born: day(1959, 8, 4), sex: .female, kinships: [
                Kinship(relation: .parent, relativeTo: .profile(name: "Matt")),
                Kinship(relation: .parent, relativeTo: .profile(name: "Timmy")),
            ]),
            profile("Dan", born: day(1984, 6, 1)),
            profile("Mark", born: day(1986, 11, 15)),
            profile("Matt", born: day(1996, 5, 10)),
            profile("Timmy", born: day(1999, 4, 22)),
            profile("Dad", born: day(1936, 5, 10), died: day(1977, 6, 25)),
        ]
        let christmas = record("/isolated/Christmas1994/Christmas_1994_etc.mkv", confirmed: ["Dan", "Mark"])
        christmas.userDate = "1994"
        christmas.userDateConfidence = UserDateConfidence.known.rawValue
        christmas.dateCreatedRaw = Date(timeIntervalSince1970: 1_784_000_000) // 2026-07 transcode
        let cape = record("/isolated/2003/Cape_2003.mov", confirmed: ["Matt", "Timmy"])
        let wedding = record("/isolated/2011/Dan_wedding_2011.mov", confirmed: ["Dan"])
        func temporal(_ subject: String) -> ArchivistQueryAST {
            .temporal(.init(subject: subject, operation: .age, reference: .currentSelection))
        }
        let harness = Harness(
            inputs: [":select Christmas_1994_etc.mkv",
                     "were the boys born yet when this was shot",
                     "how old would my dad have been in this video",
                     "how old were the boys then",
                     "and the most recent one?",
                     ":quit"],
            records: [christmas, cape, wedding],
            profiles: profiles,
            translations: [temporal("the boys"), temporal("my dad"), temporal("the boys")])
        // The full request (original question, date-order intent) must
        // reach the executor; the AST-only seam drops both.
        harness.executeRequest = { request, context in
            try await HallieTurnExecutor.execute(request, context: context)
        }
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])

        let code = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.translatedQuestions == [
            "were the boys born yet when this was shot",
            "how old would my dad have been in this video",
            "how old were the boys then",
        ])
        let transcript = harness.output.joined(separator: "\n")
        #expect(harness.output.contains { $0.contains("Dan and Mark were born by 1994; Matt and Timmy were not (Matt was born in 1996, Timmy in 1999).") }, Comment(rawValue: transcript))
        #expect(harness.output.contains { $0.contains("Dad would have been 57 or 58 in 1994 — he passed on in 1977.") }, Comment(rawValue: transcript))
        #expect(harness.output.contains { $0.contains("In 1994 Dan was 9 or 10 and Mark 7 or 8. Matt and Timmy weren't born yet (Matt was born in 1996, Timmy in 1999).") }, Comment(rawValue: transcript))
        // The boys' newest video: any of the four counts; the 2011 wedding wins.
        #expect(harness.output.contains { $0.contains("The newest of the 3 matches for Dan, Mark, Matt or Timmy is Dan_wedding_2011.mov (2011).") }, Comment(rawValue: transcript))
        #expect(!harness.output.contains { $0.contains("I need to know who you mean") })
    }

    // MARK: - Record scope: one video (2026-09-02 sensors)

    private static let newHampshirePath =
        "/Volumes/SanDiskWorkspace/FromCheesegrater/QuicktimeMovies_AndOtherFormats/New Hampshire.mov"

    /// The 2026-09-02 catalog neighbourhood: the file Rick asked about, the
    /// two longer names that contain it, a Westford tape whose transcript
    /// says "new hampshire" (what the keyword sweep used to cite), and the
    /// eval's Christmas tape.
    private func newHampshireCatalog() -> [VideoRecord] {
        let nh = record(Self.newHampshirePath, confirmed: ["Donna", "Rick"])
        nh.userDate = "1994"
        nh.userDateConfidence = UserDateConfidence.known.rawValue
        nh.dateCreatedRaw = Date(timeIntervalSince1970: 1_784_000_000) // 2026-07 transcode
        nh.container = "mov"
        nh.videoCodec = "h264"
        nh.audioCodec = "aac"
        nh.durationSeconds = 754
        nh.sizeBytes = 1_200_000_000
        nh.detectedPeople = ["Tim"]
        nh.audioTranscript = "Okay everybody wave. Nancy, get in the picture."
        nh.audioTranscriptModel = "fixture-whisper"
        let long = record("/Volumes/SanDiskWorkspace/FromCheesegrater/QuicktimeMovies_AndOtherFormats/Long Sequence - New Hampshire Christmas .mov")
        let photos = record("/Volumes/SanDiskWorkspace/FromCheesegrater/QuicktimeMovies_AndOtherFormats/ChristmasNewHampshirePhotos.mov")
        let westford = record("/Volumes/LaCie/1994-xx-xx_Westford_1994-1995.mkv", confirmed: ["Donna"])
        westford.audioTranscript = "we drove up to new hampshire"
        let christmas = record("/isolated/Christmas1994/Christmas_1994_etc.mkv", confirmed: ["Donna", "Dan"])
        return [westford, long, photos, nh, christmas]
    }

    private func assistantRoutes(_ harness: Harness) -> [String?] {
        harness.transcriptEvents.filter { $0.kind == .assistant }.map(\.route)
    }

    /// cs003 through the shell: `:select New Hampshire.mov` + "who else is
    /// in it" is answered from THAT record, model-free — no aggregate, no
    /// "couldn't resolve the anchor currentSelection".
    @Test func whoElseIsInItAnswersFromTheSelectedRecordWithoutTheModel() async throws {
        let harness = Harness(
            inputs: [":select New Hampshire.mov", "who else is in it", ":quit"],
            records: newHampshireCatalog())
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])

        let code = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.output.contains("selected New Hampshire.mov (1994)"))
        #expect(harness.translatedQuestions.isEmpty)
        #expect(assistantRoutes(harness) == ["record"])
        #expect(harness.output.contains("In New Hampshire.mov, Donna and Rick are tagged (confirmed by a person). The face matcher thinks Tim is in it too — not confirmed."),
                Comment(rawValue: harness.output.joined(separator: "\n")))
        #expect(!harness.output.contains { $0.contains("resolve the anchor") })
        #expect(!harness.output.contains { $0.contains("videos") })
    }

    /// The four live 2026-09-02 questions, by filename / path, nothing
    /// selected: every one is a record turn about New Hampshire.mov, none
    /// becomes the keyword sweep ("29 videos…", "Setting aside …").
    @Test func theFourLiveNewHampshireQuestionsAreRecordTurnsByName() async throws {
        let questions = [
            "can you examine this video New Hampshire and see if it has a date and who is in it?",
            "can you search the text of the file New Hampshire.mov for people's names, like tim, nancy, rick, donna, and a date?",
            "tell me all about this video, including the metadata whether it has rick in it: \(Self.newHampshirePath)",
            "Examine the video New Hampshire.mov and see if it has my name in it?",
        ]
        let harness = Harness(inputs: questions + [":quit"], records: newHampshireCatalog())
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])

        let code = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        let transcript = harness.output.joined(separator: "\n")
        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.translatedQuestions.isEmpty, Comment(rawValue: transcript))
        #expect(assistantRoutes(harness) == ["record", "record", "record", "record"], Comment(rawValue: transcript))
        #expect(harness.transcriptEvents.filter { $0.kind == .assistant }.allSatisfy { $0.outcome == "answered" })
        // Q1: date + people from the stem "New Hampshire".
        #expect(harness.output.contains("This was filmed in 1994. In New Hampshire.mov, Donna and Rick are tagged (confirmed by a person). The face matcher thinks Tim is in it too — not confirmed."),
                Comment(rawValue: transcript))
        // Q2: one verdict per asked name, then the date.
        #expect(harness.output.contains { line in
            line.hasPrefix("This was filmed in 1994. In New Hampshire.mov, the face matcher thinks Tim is in it — not confirmed. Nancy isn't tagged, but someone says the name “Nancy” in the transcript. Rick is tagged (confirmed by a person). Donna is tagged (confirmed by a person).")
        }, Comment(rawValue: transcript))
        // Q3: the dossier by full path, with Rick's verdict.
        #expect(harness.output.contains("New Hampshire.mov is a mov video with sound, h264 with aac audio, 12:34 long, 1.2 GB, on SanDiskWorkspace — not yet archived. This was filmed in 1994. In New Hampshire.mov, Rick is tagged (confirmed by a person). The transcript opens: “Okay everybody wave.”"),
                Comment(rawValue: transcript))
        // Q4: "my name" is the owner (harness speakers: Rick Breen → tag Rick).
        #expect(harness.output.contains("In New Hampshire.mov, Rick is tagged (confirmed by a person)."), Comment(rawValue: transcript))
        for forbidden in ["29 videos", "9 videos", "3 videos", "Setting aside", "resolve the anchor", "Westford"] {
            #expect(!transcript.contains(forbidden), Comment(rawValue: "must not contain \(forbidden)"))
        }
    }

    /// Isolation: poisoned Ollama host preferences and an injected catalog
    /// path cannot make a record turn reach a model or another catalog —
    /// the four live questions answer with no translation at all.
    @Test func recordTurnsIgnorePoisonedTranslatorPreferences() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("catalog.json")
        let sentinel = Data("READ-ONLY-SENTINEL".utf8)
        try sentinel.write(to: catalog)

        let poisonKey = OllamaEndpoints.hostsKey
        let priorHosts = UserDefaults.standard.object(forKey: poisonKey)
        UserDefaults.standard.set("poison.invalid", forKey: poisonKey)
        defer {
            if let priorHosts {
                UserDefaults.standard.set(priorHosts, forKey: poisonKey)
            } else {
                UserDefaults.standard.removeObject(forKey: poisonKey)
            }
        }

        let harness = Harness(
            inputs: [
                "can you examine this video New Hampshire and see if it has a date and who is in it?",
                "can you search the text of the file New Hampshire.mov for people's names, like tim, nancy, rick, donna, and a date?",
                "tell me all about this video, including the metadata whether it has rick in it: \(Self.newHampshirePath)",
                "Examine the video New Hampshire.mov and see if it has my name in it?",
                ":quit",
            ],
            records: newHampshireCatalog())
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--catalog", catalog.path, "--host", "isolated-translator.local",
        ])

        _ = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.loadedURLs == [catalog])
        #expect(harness.translatedQuestions.isEmpty)
        #expect(harness.translationOptions.isEmpty)
        #expect(assistantRoutes(harness) == ["record", "record", "record", "record"])
        #expect(try Data(contentsOf: catalog) == sentinel)
    }

    /// A name several files fit is a which-one with one chip per file, and
    /// the chip's question (by full path) answers about that file alone.
    @Test func ambiguousFileNameListsCandidatesAndAChipResolvesOne() async throws {
        let harness = Harness(
            inputs: [
                "who is in Christmas.mov",
                "who is in /isolated/Christmas1994/Christmas_1994_etc.mkv",
                ":quit",
            ],
            records: newHampshireCatalog())
        let options = try HallieShellCLI.parse(arguments: ["--hallie", "--diagnostics"])

        _ = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        let transcript = harness.output.joined(separator: "\n")
        #expect(harness.translatedQuestions.isEmpty)
        #expect(harness.output.contains("I found 3 files that could be “Christmas.mov”: Long Sequence - New Hampshire Christmas .mov, ChristmasNewHampshirePhotos.mov, Christmas_1994_etc.mkv. Which one do you mean?"),
                Comment(rawValue: transcript))
        #expect(harness.output.contains("offer: ask “who is in /isolated/Christmas1994/Christmas_1994_etc.mkv”"))
        let events = harness.transcriptEvents.filter { $0.kind == .assistant }
        #expect(events.map(\.route) == ["record", "record"])
        #expect(events.map(\.outcome) == ["declined", "answered"])
        #expect(events.first?.offeredActions == [
            "Long Sequence - New Hampshire Christmas .mov", "ChristmasNewHampshirePhotos.mov", "Christmas_1994_etc.mkv",
        ])
        #expect(harness.output.contains("In Christmas_1994_etc.mkv, Donna and Dan are tagged (confirmed by a person)."),
                Comment(rawValue: transcript))
    }

    @Test func selectionQuestionsWithNothingSelectedAskForASelectionOrAName() async throws {
        let harness = Harness(
            inputs: ["who is in this video", "who is in Nowhere.mov", ":quit"],
            records: newHampshireCatalog())
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])

        _ = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.translatedQuestions.isEmpty)
        #expect(harness.output.contains("Which video? Select one in the Catalog, or name the file, and ask me again."))
        #expect(harness.output.contains { $0.hasPrefix("I couldn't find a file called “Nowhere.mov” in the catalog.") })
        #expect(assistantRoutes(harness) == ["record", "record"])
    }

    /// codex #976 item 2: search → a record turn that cannot settle its
    /// file → "play it" must NOT play the search's item; it names the gap.
    /// The same after an ambiguous name and after "this video" with
    /// nothing selected.
    @Test func playItAfterADeclinedRecordTurnPlaysNothingAndSaysSo() async throws {
        let presence = ArchivistQueryAST.presence(.init(people: ["Donna"]))
        let harness = Harness(
            inputs: [
                "videos of Donna", "who is in Nowhere.mov", "play it",
                "videos of Donna", "who is in Christmas.mov", "play it",
                "videos of Donna", "who is in this video", "play it",
                ":quit",
            ],
            records: newHampshireCatalog(),
            translations: [presence, presence, presence])
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])

        _ = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        let transcript = harness.output.joined(separator: "\n")
        #expect(harness.translatedQuestions == ["videos of Donna", "videos of Donna", "videos of Donna"], Comment(rawValue: transcript))
        #expect(harness.mediaActions.isEmpty, Comment(rawValue: "nothing may play: \(harness.mediaActions)"))
        #expect(!transcript.contains("Playing item"), Comment(rawValue: transcript))
        #expect(harness.output.filter {
            $0.hasPrefix("Nothing to play — I couldn't settle which file “Nowhere.mov” is.")
        }.count == 1, Comment(rawValue: transcript))
        #expect(harness.output.filter {
            $0.hasPrefix("Nothing to play — I couldn't settle which file “Christmas.mov” is.")
        }.count == 1, Comment(rawValue: transcript))
        #expect(harness.output.filter {
            $0.hasPrefix("Nothing to play — nothing was selected for my last answer.")
        }.count == 1, Comment(rawValue: transcript))
        #expect(assistantRoutes(harness) == [
            "presence", "record", "follow-up",
            "presence", "record", "follow-up",
            "presence", "record", "follow-up",
        ], Comment(rawValue: transcript))
    }

    /// codex #976 item 3: an explicit path nobody has never answers from a
    /// same-named file elsewhere; the decline offers that file by exact
    /// path and the chip answers about it.
    @Test func aMissingPathDeclinesAndOffersTheSameNamedFileAsAChip() async throws {
        let harness = Harness(
            inputs: [
                "who is in /Volumes/Nowhere/New Hampshire.mov",
                "who is in \(Self.newHampshirePath)",
                "who is in /Volumes/Nowhere/nothing.mov",
                ":quit",
            ],
            records: newHampshireCatalog())
        let options = try HallieShellCLI.parse(arguments: ["--hallie", "--diagnostics"])

        _ = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        let transcript = harness.output.joined(separator: "\n")
        #expect(harness.translatedQuestions.isEmpty, Comment(rawValue: transcript))
        #expect(harness.output.contains("I don't have /Volumes/Nowhere/New Hampshire.mov. I do have \(Self.newHampshirePath) — that one?"),
                Comment(rawValue: transcript))
        #expect(harness.output.contains("offer: ask “who is in \(Self.newHampshirePath)”"), Comment(rawValue: transcript))
        #expect(harness.output.contains("In New Hampshire.mov, Donna and Rick are tagged (confirmed by a person). The face matcher thinks Tim is in it too — not confirmed."),
                Comment(rawValue: transcript))
        #expect(harness.output.contains { $0.hasPrefix("I don't have /Volumes/Nowhere/nothing.mov, and nothing in the catalog is called “nothing.mov”.") },
                Comment(rawValue: transcript))
        let events = harness.transcriptEvents.filter { $0.kind == .assistant }
        #expect(events.map(\.route) == ["record", "record", "record"])
        #expect(events.map(\.outcome) == ["declined", "answered", "declined"])
        // The first decline's ONLY answer-bearing line is the offer: the
        // wrong volume's people were never reported.
        let firstAnswer = try #require(harness.output.firstIndex { $0.hasPrefix("I don't have /Volumes/Nowhere/New Hampshire.mov") })
        let realAnswer = try #require(harness.output.firstIndex { $0.hasPrefix("In New Hampshire.mov, Donna and Rick are tagged") })
        #expect(firstAnswer < realAnswer)
    }

    /// Scale: a record turn over 100k records resolves the named file once
    /// and never captures a catalog-wide snapshot — the whole session,
    /// including the 100k-record catalog open, stays within the same budget
    /// as the one-shot presence sensor above.
    @Test func recordTurnOverOneHundredThousandRecordsStaysWithinBudget() async throws {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for index in 0..<100_000 {
            records.append(record("/isolated/scale/vol\(index % 5)/clip_\(index).mov",
                                  confirmed: index == 73_421 ? ["Donna"] : []))
        }
        let harness = Harness(
            inputs: ["who is in clip_73421.mov", ":select clip_73421.mov", "tell me about this video", ":quit"],
            records: records)
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])

        let started = ContinuousClock.now
        let code = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())
        let elapsed = ContinuousClock.now - started

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.translatedQuestions.isEmpty)
        #expect(assistantRoutes(harness) == ["record", "record"])
        #expect(harness.output.contains("In clip_73421.mov, Donna is tagged (confirmed by a person)."))
        #expect(harness.output.contains { $0.hasPrefix("clip_73421.mov is a video with sound") })
        #expect(elapsed < .seconds(4), "two record turns over 100k records took \(elapsed)")
    }

    // MARK: - Full siblings share parents (Rick's ruling 2026-09-02) — sensor

    /// Rick's card as it stands today (child of Ma and Dad, sibling of
    /// Tim, Ellen and Beth; the siblings' cards empty), Ma and Dad pinned
    /// to Eileen Latta and Richard Sr in a three-person tree. Through the
    /// shell, with the REAL detectors (codex #984: the earlier sensor fed
    /// prepared translations for every turn):
    ///   • "eileen's children" and "tim's parents" are the bare possessive
    ///     fragments HallieLineageQuestion.kinFragmentQuestion owns — they
    ///     reach the graph kinship route with no translator at all;
    ///   • "tell me about ma" has no deterministic shape in the shell (the
    ///     biography is the translator's, as "tell me about thankful pratt"
    ///     is above), so that ONE turn carries a prepared translation and
    ///     the sensor pins that it is the only one.
    /// Eileen's children are all four, her biography says so with the
    /// derived note in the basis, and Tim's parents come back from the
    /// tree with their names. Read-time only — the fixture profiles are
    /// never written.
    @Test func eileensChildrenAndTimsParentsComeThroughRicksSiblingRows() async throws {
        let tree = """
        0 HEAD
        0 @I1@ INDI
        1 NAME Richard Harding /Breen/ Jr
        1 SEX M
        1 BIRT
        2 DATE 4 MAR 1959
        1 FAMC @F1@
        1 _FSFTID GVQV-NW3
        0 @I2@ INDI
        1 NAME Richard Harding /Breen/ Sr
        1 SEX M
        1 FAMS @F1@
        1 _FSFTID G2S4-JF4
        0 @I3@ INDI
        1 NAME Eileen /Latta/
        1 SEX F
        1 BIRT
        2 DATE 31 AUG 1930
        1 FAMS @F1@
        1 _FSFTID G2CR-R4H
        0 @F1@ FAM
        1 HUSB @I2@
        1 WIFE @I3@
        1 CHIL @I1@
        0 TRLR
        """
        func profile(_ name: String, aliases: [String] = [], sex: PersonSex,
                     kinships: [Kinship] = [], pin: String? = nil) -> POIProfile {
            POIProfile(name: name, referencePath: "/isolated/people/\(name.lowercased())",
                       aliases: aliases, sex: sex, kinships: kinships,
                       treeIdentity: pin.map { .familySearchID($0) })
        }
        func row(_ relation: KinshipRelation, _ name: String) -> Kinship {
            Kinship(relation: relation, relativeTo: .profile(name: name))
        }
        let profiles = [
            profile("Rick", aliases: ["Richard Harding Breen Jr"], sex: .male, kinships: [
                row(.sibling, "Tim"), row(.sibling, "Ellen"), row(.sibling, "Beth"),
                row(.child, "Ma"), row(.child, "Dad"),
                row(.parent, "Dan"), row(.parent, "Mark"), row(.parent, "Matt"), row(.parent, "Timmy"),
                row(.childInLaw, "Anna"), row(.grandparent, "Libby"),
            ], pin: "GVQV-NW3"),
            profile("Tim", sex: .male), profile("Ellen", sex: .female), profile("Beth", sex: .female),
            profile("Ma", aliases: ["Eileen"], sex: .female, pin: "G2CR-R4H"),
            profile("Dad", aliases: ["Richard Harding Breen Sr"], sex: .male, pin: "G2S4-JF4"),
            profile("Dan", sex: .male), profile("Mark", sex: .male),
            profile("Matt", sex: .male), profile("Timmy", sex: .male),
            profile("Anna", sex: .female), profile("Libby", sex: .female),
        ]
        // The two kinship fragments are detected locally (asserted below);
        // only the biography sentence needs the translator.
        #expect(HallieLineageQuestion.detect("eileen's children")
                == .kinship(person: "Eileen", relation: .children, side: nil))
        #expect(HallieLineageQuestion.detect("tim's parents")
                == .kinship(person: "Tim", relation: .parents, side: nil))
        #expect(HallieLineageQuestion.detect("tell me about ma") == nil)
        let harness = Harness(
            // Natural fragments through the real detector (codex #984) plus
            // the one sentence that needs a translation for the two-parent
            // fallback check (codex #973).
            inputs: [
                "eileen's children", "tell me about ma",
                "tim's parents", "tell me about rick's parents", ":quit",
            ],
            profiles: profiles,
            graph: GedcomFamilyGraph(gedcomText: tree),
            translations: [
                .graph(.init(people: ["Ma"], operation: .biography)),
                .graph(.init(people: ["Rick"], operation: .kinship, relation: .parents)),
            ])
        // Feed valid claim-for-claim prose except for the two-parent plans:
        // there the model cites c1 but repeats only Eileen, reproducing the
        // live 9/02 omission. Required-person verification must select the
        // deterministic two-parent fallback on the shell surface.
        harness.compositionReply = { plan in
            if Set(plan.requiredPersonNames) == Set([
                "Eileen Latta", "Richard Harding Breen Sr",
            ]) {
                return "Eileen Latta was one of them [c1]."
            }
            return plan.claims.map { "\($0.text) [\($0.id)]" }
                .joined(separator: " ")
        }
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--diagnostics", "--compose",
        ])

        let code = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        let transcript = harness.output.joined(separator: "\n")
        // The real detectors carried the two kinship fragments; the
        // translator saw exactly the two sentences that need it (the
        // biography, and the two-parent fallback check from codex #973).
        #expect(harness.translatedQuestions == ["tell me about ma", "tell me about rick's parents"], Comment(rawValue: transcript))
        let answers = harness.transcriptEvents.filter { $0.kind == .assistant }
        #expect(answers.count == 4, Comment(rawValue: transcript))
        let rule = "derived from Rick's rows: full siblings share parents"

        // 1. "eileen's children" — all four, three marked derived.
        let children = try #require(answers.first)
        for name in ["Rick", "Tim", "Ellen", "Beth"] {
            #expect(children.text.contains(name), Comment(rawValue: children.text))
        }
        #expect((children.basisLine ?? "").contains("(stored on Rick's profile; Beth, Ellen and Tim \(rule));"),
                Comment(rawValue: children.basisLine ?? ""))
        #expect(!(children.basisLine ?? "").contains("Relationship warning"), Comment(rawValue: children.basisLine ?? ""))

        // 2. "tell me about ma" — the tree's Rick, then the three from the
        //    People tab, with the derived note in the basis.
        let biography = answers[1]
        #expect(biography.text.contains("1 recorded child, Richard Harding Breen Jr."), Comment(rawValue: biography.text))
        #expect(biography.text.contains("In the People tab: Beth — daughter, Ellen — daughter and Tim — son."),
                Comment(rawValue: biography.text))
        #expect((biography.basisLine ?? "").contains("People tab relationships (stored on Rick's profile; Beth, Ellen and Tim \(rule)); local only, not from the family tree."),
                Comment(rawValue: biography.basisLine ?? ""))

        // 3. "tim's parents" — Eileen and Richard Sr by their tree names.
        let parents = answers[2]
        #expect(parents.text.contains("Eileen Latta"), Comment(rawValue: parents.text))
        #expect(parents.text.contains("Richard Harding Breen Sr"), Comment(rawValue: parents.text))
        #expect((parents.basisLine ?? "").contains("; Dad and Ma \(rule));"), Comment(rawValue: parents.basisLine ?? ""))
        // Diagnostics mode prints the basis, so the marker is visible in the shell too.
        #expect(harness.output.contains { $0.contains(rule) }, Comment(rawValue: transcript))
        #expect(harness.mediaActions.isEmpty)

        // 4. Exact live sensor: both are answer obligations even though a
        // single c1 carries them. The partial model answer is never shown.
        let ricksParents = answers[3]
        #expect(ricksParents.composedBy == "template")
        #expect(ricksParents.text.contains("Eileen Latta"), Comment(rawValue: ricksParents.text))
        #expect(ricksParents.text.contains("Richard Harding Breen Sr"),
                Comment(rawValue: ricksParents.text))
        #expect(!ricksParents.text.contains("Eileen Latta was one of them"),
                Comment(rawValue: ricksParents.text))
        #expect(Set(harness.composedPlans.last?.requiredPersonNames ?? []) == Set([
            "Eileen Latta", "Richard Harding Breen Sr",
        ]))
    }

    // MARK: - One primary parent family (Rick's ruling 2026-09-02 19:55) — sensor

    /// LIVE MISS (shell, 2026-09-02T23:40): Eileen Latta carries two FAMC
    /// lines on FamilySearch — F3 (David Latta Sr + Mary Catherine
    /// O'Connor, family MT64-4HP) and F4 (wife-only "Mary O'Connor" b.
    /// 1905, the same woman, both daughters of F6) — and Hallie read out
    /// two mothers, five grandparents and a forked maternal line. Through
    /// the shell, with the real shape of the records: one mother, one
    /// biography mother, two parents, an unforked maternal line, and the
    /// fold note in the basis. Read-time only.
    @Test func eileenHasOneMotherThroughTheShell() async throws {
        let tree = """
        0 HEAD
        0 @I1@ INDI
        1 NAME Richard Harding /Breen/ Jr
        1 SEX M
        1 BIRT
        2 DATE 4 MAR 1959
        1 FAMC @F1@
        1 _FSFTID GVQV-NW3
        0 @I3@ INDI
        1 NAME Eileen /Latta/
        1 SEX F
        1 BIRT
        2 DATE 31 AUG 1930
        2 PLAC Chelsea, Suffolk, Massachusetts, United States
        1 DEAT
        2 DATE 2023
        1 FAMS @F1@
        1 FAMC @F3@
        1 FAMC @F4@
        1 _FSFTID G2CR-R4H
        0 @I5@ INDI
        1 NAME Mary /O'Connor/
        1 SEX F
        1 BIRT
        2 DATE 1905
        2 PLAC Ireland
        1 FAMS @F4@
        1 FAMC @F6@
        1 _FSFTID GNZ5-428
        0 @I6@ INDI
        1 NAME David McGill /Latta/ Sr
        1 SEX M
        1 BIRT
        2 DATE 1902
        2 PLAC Wilmington, New Hanover, North Carolina, United States
        1 DEAT
        2 DATE 1983
        1 FAMS @F3@
        1 _FSFTID LX9M-WJG
        0 @I7@ INDI
        1 NAME Mary Catherine /O'Connor/
        1 SEX F
        1 BIRT
        2 DATE 23 DEC 1904
        2 PLAC Ireland
        1 DEAT
        2 DATE 16 JUL 1985
        2 PLAC Brockton, Plymouth, Massachusetts, United States
        1 FAMS @F3@
        1 FAMC @F6@
        1 _FSFTID G89Q-34N
        0 @I14@ INDI
        1 NAME Christopher Dennis /O'Connor/
        1 SEX M
        1 BIRT
        2 DATE 1883
        2 PLAC Ireland
        1 FAMS @F6@
        0 @I15@ INDI
        1 NAME Ellen /Ronan/
        1 SEX F
        1 BIRT
        2 DATE 1883
        2 PLAC Ireland
        1 FAMS @F6@
        0 @F1@ FAM
        1 WIFE @I3@
        1 CHIL @I1@
        0 @F3@ FAM
        1 HUSB @I6@
        1 WIFE @I7@
        1 CHIL @I3@
        1 _FSFTID MT64-4HP
        0 @F4@ FAM
        1 WIFE @I5@
        1 CHIL @I3@
        0 @F6@ FAM
        1 HUSB @I14@
        1 WIFE @I15@
        1 CHIL @I5@
        1 CHIL @I7@
        0 TRLR
        """
        let harness = Harness(
            inputs: ["who is eileen latta's mother", "tell me about eileen latta",
                     "who are eileen's parents", "show eileen latta's maternal line back 3 generations", ":quit"],
            graph: GedcomFamilyGraph(gedcomText: tree),
            translations: [
                .graph(.init(people: ["Eileen Latta"], operation: .kinship, relation: .mother)),
                .graph(.init(people: ["Eileen Latta"], operation: .biography)),
                .graph(.init(people: ["Eileen"], operation: .kinship, relation: .parents)),
            ])
        let options = try HallieShellCLI.parse(arguments: ["--hallie", "--diagnostics"])

        let code = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        let transcript = harness.output.joined(separator: "\n")
        let answers = harness.transcriptEvents.filter { $0.kind == .assistant }
        #expect(answers.count == 4, Comment(rawValue: transcript))
        let note = "(another record for her mother, Mary O'Connor b. 1905, exists in the tree — same parents; treated as the same person)"

        // 1. One mother, the note in the basis.
        let mother = try #require(answers.first)
        #expect(mother.text == "Eileen Latta's mother: Mary Catherine O'Connor.", Comment(rawValue: mother.text))
        #expect((mother.basisLine ?? "").hasSuffix(" \(note)"), Comment(rawValue: mother.basisLine ?? ""))

        // 2. Biography: child of two people; no "two mothers" sentence.
        let biography = answers[1]
        #expect(biography.text.contains("child of David McGill Latta Sr and Mary Catherine O'Connor"), Comment(rawValue: biography.text))
        #expect(!biography.text.contains("Mary O'Connor,"), Comment(rawValue: biography.text))
        #expect(!biography.text.contains("two mothers"), Comment(rawValue: biography.text))
        #expect((biography.basisLine ?? "").contains(note), Comment(rawValue: biography.basisLine ?? ""))

        // 3. Parents: two people, not three.
        let parents = answers[2]
        #expect(parents.text == "Eileen Latta's parents: David McGill Latta Sr, Mary Catherine O'Connor.", Comment(rawValue: parents.text))

        // 4. The maternal line does not fork at the duplicate.
        let line = answers[3]
        #expect(line.text.contains("Mother: Mary Catherine O'Connor"), Comment(rawValue: line.text))
        #expect(line.text.contains("Grandmother: Ellen Ronan"), Comment(rawValue: line.text))
        #expect(!line.text.contains("Mary O'Connor (b. 1905)"), Comment(rawValue: line.text))
        #expect(harness.transcriptEvents.contains { $0.queryDescription == "lineage maternal ×3: Eileen Latta" },
                Comment(rawValue: transcript))
        // Every answer that named a parent carries the note; nothing else prints "Mary O'Connor" alone.
        #expect(!harness.output.contains { $0.contains("Mary O'Connor,") || $0.contains("Mary O'Connor (b.") }, Comment(rawValue: transcript))
        #expect(harness.mediaActions.isEmpty)
    }

    /// The same shell, with Tim's card saying "child of Other": the sibling
    /// set fails closed (three parents), Eileen's children are the tree's
    /// Rick alone, and the warning reaches the shell's basis for both the
    /// kinship turn and the biography — through the real detector for the
    /// fragment, the translator for the biography sentence.
    @Test func aContradictingTimReachesTheShellBasisAsAWarning() async throws {
        let tree = """
        0 HEAD
        0 @I1@ INDI
        1 NAME Richard Harding /Breen/ Jr
        1 SEX M
        1 FAMC @F1@
        1 _FSFTID GVQV-NW3
        0 @I2@ INDI
        1 NAME Richard Harding /Breen/ Sr
        1 SEX M
        1 FAMS @F1@
        1 _FSFTID G2S4-JF4
        0 @I3@ INDI
        1 NAME Eileen /Latta/
        1 SEX F
        1 FAMS @F1@
        1 _FSFTID G2CR-R4H
        0 @F1@ FAM
        1 HUSB @I2@
        1 WIFE @I3@
        1 CHIL @I1@
        0 TRLR
        """
        func profile(_ name: String, aliases: [String] = [], sex: PersonSex,
                     kinships: [Kinship] = [], pin: String? = nil) -> POIProfile {
            POIProfile(name: name, referencePath: "/isolated/people/\(name.lowercased())",
                       aliases: aliases, sex: sex, kinships: kinships,
                       treeIdentity: pin.map { .familySearchID($0) })
        }
        func row(_ relation: KinshipRelation, _ name: String) -> Kinship {
            Kinship(relation: relation, relativeTo: .profile(name: name))
        }
        let profiles = [
            profile("Rick", sex: .male, kinships: [
                row(.sibling, "Tim"), row(.sibling, "Ellen"), row(.child, "Ma"), row(.child, "Dad"),
            ], pin: "GVQV-NW3"),
            profile("Tim", sex: .male, kinships: [row(.child, "Other")]),
            profile("Ellen", sex: .female),
            profile("Ma", aliases: ["Eileen"], sex: .female, pin: "G2CR-R4H"),
            profile("Dad", sex: .male, pin: "G2S4-JF4"),
            profile("Other", sex: .male),
        ]
        let harness = Harness(
            inputs: ["eileen's children", "tell me about ma", ":quit"],
            profiles: profiles,
            graph: GedcomFamilyGraph(gedcomText: tree),
            translations: [.graph(.init(people: ["Ma"], operation: .biography))])
        let options = try HallieShellCLI.parse(arguments: ["--hallie", "--diagnostics"])

        let code = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        let transcript = harness.output.joined(separator: "\n")
        #expect(harness.translatedQuestions == ["tell me about ma"], Comment(rawValue: transcript))
        let answers = harness.transcriptEvents.filter { $0.kind == .assistant }
        #expect(answers.count == 2, Comment(rawValue: transcript))
        let warning = "Relationship warning: Sibling rows on Ellen, Rick and Tim imply more than two parents (Dad, Ma, Other) — nothing derived until one is corrected."
        let children = try #require(answers.first)
        #expect(children.text.contains("Richard Harding Breen Jr"), Comment(rawValue: children.text))
        #expect(!children.text.contains("Tim"), Comment(rawValue: children.text))
        #expect(!children.text.contains("Ellen"), Comment(rawValue: children.text))
        #expect((children.basisLine ?? "").contains(warning), Comment(rawValue: children.basisLine ?? ""))
        let biography = answers[1]
        #expect(!biography.text.contains("In the People tab"), Comment(rawValue: biography.text))
        #expect((biography.basisLine ?? "").contains(warning), Comment(rawValue: biography.basisLine ?? ""))
        #expect(harness.output.contains { $0.contains("Relationship warning") }, Comment(rawValue: transcript))
    }
}
