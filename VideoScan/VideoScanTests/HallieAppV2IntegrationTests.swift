import Foundation
import Testing
@testable import VideoScan

@MainActor
@Suite("Hallie app QueryAST-v2 integration", .serialized)
struct HallieAppV2IntegrationTests {
    private enum FixtureError: Error {
        case translationFailed
    }

    private struct Invocation: Sendable {
        let ast: ArchivistQueryAST
        let presenceCount: Int
        let aggregateCount: Int
        let profiles: [HallieTurnExecutor.ProfileSnapshot]?
        let graphWasInjected: Bool
        let selectedDate: ArchivistTemporalSelectionDateSnapshot?
    }

    /// A mutex-backed recorder is the Swift equivalent of a small C++ test
    /// spy protected by `std::mutex`; coordinator dependencies run detached.
    private final class Recorder<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Value] = []

        func append(_ value: Value) {
            lock.withLock { storage.append(value) }
        }

        var values: [Value] {
            lock.withLock { storage }
        }
    }

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var started = false

        func pause() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started = true
            }
        }

        func waitUntilStarted() async {
            while !started { await Task.yield() }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func astCases() -> [ArchivistQueryAST] {
        [
            .presence(.init(people: ["Donna"])),
            .temporal(.init(subject: "Donna", operation: .age,
                            reference: .currentSelection)),
            .aggregate(.init(operation: .coOccurrence,
                             anchorPeople: ["Donna"])),
            .graph(.init(people: ["Hallie Mae"], operation: .biography)),
            .event(.init(keywords: ["birthday"])),
            .cross(.init(people: ["Donna"], keywords: ["birthday"])),
        ]
    }

    private nonisolated static func fixtureResult(
        for ast: ArchivistQueryAST,
        citations: [HallieTurnExecutor.Citation] = [],
        catalogPersonName: String? = nil
    ) -> HallieTurnExecutor.Result {
        HallieTurnExecutor.Result(
            route: HallieTurnExecutor.route(ast),
            outcome: .answered,
            prose: "fixture answer",
            basisLine: "fixture basis",
            queryDescription: HallieTurnExecutor.description(of: ast),
            citations: citations,
            catalogPersonName: catalogPersonName)
    }

    private func fixtureGraph() -> GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Hallie Mae /Breen/
        0 TRLR
        """)
    }

    private func dependencies(
        ast: ArchivistQueryAST,
        recorder: Recorder<Invocation>,
        result: HallieTurnExecutor.Result? = nil,
        photo: ArchivistBiographyPhoto? = nil,
        profiles: [HallieTurnExecutor.ProfileSnapshot]? = [
            .init(stableID: "donna", canonicalName: "Donna"),
        ],
        graph: GedcomFamilyGraph? = nil
    ) -> HallieAppTurnCoordinator.Dependencies {
        HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { hosts in hosts },
            translateAST: { question, hosts, modelName in
                #expect(question == "fixture question")
                #expect(hosts == ["fixture.invalid"])
                #expect(modelName == "fixture-model")
                return .init(ast: ast, responderHost: "fixture-host")
            },
            loadProfiles: { profiles },
            loadGraph: { graph },
            executeRequest: { request, context in
                let receivedAST = request.intent.ast
                recorder.append(Invocation(
                    ast: receivedAST,
                    presenceCount: context.presenceRecords.count,
                    aggregateCount: context.aggregateRecords.count,
                    profiles: context.profiles,
                    graphWasInjected: context.graph != nil,
                    selectedDate: context.selectedTemporalDate))
                return result ?? Self.fixtureResult(for: receivedAST)
            },
            continueTurn: { clarification, selectedID, context in
                try await HallieTurnExecutor.continue(
                    pending: clarification, selecting: selectedID,
                    context: context)
            },
            resolveBiographyPhoto: { _ in photo })
    }

    private func productionSource(_ filename: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let url = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("VideoScan")
            .appendingPathComponent(filename)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func slice(
        _ source: String,
        from start: String,
        through end: String
    ) throws -> String {
        let lower = try #require(source.range(of: start))
        let upper = try #require(
            source.range(of: end, range: lower.upperBound..<source.endIndex))
        return String(source[lower.lowerBound..<upper.lowerBound])
    }

    @Test func allSixASTRoutesPassThroughProductionCoordinatorSeam() async throws {
        let record = VideoRecord()
        record.fullPath = "/isolated/catalog/fixture.mov"
        record.filename = "fixture.mov"
        let selectedID = UUID()
        let selectedDate = ArchivistTemporalSelectionDateSnapshot.catalogCreation(
            recordID: selectedID,
            fullPath: "/isolated/catalog/selected.mov",
            date: Date(timeIntervalSince1970: 1_700_000_000))

        for ast in astCases() {
            let recorder = Recorder<Invocation>()
            let response = try await HallieAppTurnCoordinator.execute(
                question: "fixture question",
                records: [record],
                referent: .init(recordID: selectedID,
                                temporalDate: selectedDate),
                hosts: ["fixture.invalid"],
                modelName: "fixture-model",
                dependencies: dependencies(
                    ast: ast, recorder: recorder, graph: fixtureGraph()))

            #expect(recorder.values.count == 1)
            let invocation = try #require(recorder.values.first)
            #expect(invocation.ast == ast)
            #expect(response.result.route == HallieTurnExecutor.route(ast))
            #expect(response.responderHost == "fixture-host")
            #expect(response.capturedReferentID == selectedID)
            #expect(invocation.selectedDate == selectedDate)

            switch HallieTurnExecutor.route(ast) {
            case .presence:
                #expect(invocation.presenceCount == 1)
                #expect(invocation.aggregateCount == 0)
                #expect(invocation.profiles?.isEmpty == true)
                #expect(!invocation.graphWasInjected)
            case .aggregate:
                #expect(invocation.presenceCount == 0)
                #expect(invocation.aggregateCount == 1)
                #expect(invocation.profiles?.map(\.stableID) == ["donna"])
                #expect(!invocation.graphWasInjected)
            case .temporal:
                #expect(invocation.presenceCount == 0)
                #expect(invocation.aggregateCount == 0)
                #expect(invocation.profiles?.map(\.stableID) == ["donna"])
                #expect(!invocation.graphWasInjected)
            case .graph:
                #expect(invocation.presenceCount == 0)
                #expect(invocation.aggregateCount == 0)
                #expect(invocation.profiles?.map(\.stableID) == ["donna"])
                #expect(invocation.graphWasInjected)
            case .unsupportedEvent, .unsupportedCross:
                #expect(invocation.presenceCount == 0)
                #expect(invocation.aggregateCount == 0)
                #expect(invocation.profiles?.isEmpty == true)
                #expect(!invocation.graphWasInjected)
            }
        }
    }

    @Test func translationFailureNeverLoadsEvidenceOrExecutes() async {
        let calls = Recorder<String>()
        let dependencies = HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { hosts in
                calls.append("start")
                return hosts
            },
            translateAST: { _, _, _ in
                calls.append("translate")
                throw FixtureError.translationFailed
            },
            loadProfiles: {
                calls.append("profiles")
                return []
            },
            loadGraph: {
                calls.append("graph")
                return nil
            },
            executeRequest: { request, _ in
                calls.append("execute")
                return Self.fixtureResult(for: request.intent.ast)
            },
            continueTurn: { _, _, _ in
                calls.append("continue")
                throw FixtureError.translationFailed
            },
            resolveBiographyPhoto: { _ in
                calls.append("photo")
                return nil
            })

        do {
            _ = try await HallieAppTurnCoordinator.execute(
                question: "fixture question", records: [],
                referent: .init(recordID: nil, temporalDate: nil),
                hosts: ["fixture.invalid"], modelName: "fixture-model",
                dependencies: dependencies)
            Issue.record("invalid translation unexpectedly executed")
        } catch FixtureError.translationFailed {
            // Swift Testing's typed catch is analogous to EXPECT_THROW.
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(calls.values == ["start", "translate"])
    }

    @Test func coordinatorCapsEvidenceAtExactlyTwentyFiveAndAttachesBiographyPhoto() async throws {
        let ast = ArchivistQueryAST.graph(.init(
            people: ["Hallie Mae Breen"], operation: .biography))
        let citations = (0..<30).map { index in
            HallieTurnExecutor.Citation(
                recordID: UUID(),
                fullPath: "/isolated/evidence/\(index).mov",
                filename: "\(index).mov",
                playbackSeconds: Double(index),
                bases: [])
        }
        let result = Self.fixtureResult(
            for: ast, citations: citations,
            catalogPersonName: "Hallie Mae Breen")
        let photo = ArchivistBiographyPhoto(
            profileStableID: "hallie",
            profileCanonicalName: "Hallie Mae Breen",
            fileURL: URL(fileURLWithPath: "/isolated/photo/hallie.png"),
            cropOffsetX: 0, cropOffsetY: 0, cropScale: 1)
        let recorder = Recorder<Invocation>()

        let response = try await HallieAppTurnCoordinator.execute(
            question: "fixture question", records: [],
            referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            dependencies: dependencies(
                ast: ast, recorder: recorder, result: result,
                photo: photo, graph: fixtureGraph()))

        #expect(response.result.citations.count == 30)
        #expect(response.citations.count == 25)
        #expect(response.citations.map(\.recordID)
                == Array(citations.prefix(25)).map(\.recordID))
        #expect(response.biographyPhoto == photo)
    }

    @Test func coordinatorAttachesPhotoOnlyForBiographyOperation() async throws {
        let photo = ArchivistBiographyPhoto(
            profileStableID: "hallie",
            profileCanonicalName: "Hallie Mae Breen",
            fileURL: URL(fileURLWithPath: "/isolated/photo/hallie.png"),
            cropOffsetX: 0, cropOffsetY: 0, cropScale: 1)
        let cases: [(ArchivistQueryAST, Bool)] = [
            (.graph(.init(people: ["Hallie Mae Breen"],
                          operation: .biography)), true),
            (.graph(.init(people: ["Hallie Mae Breen"],
                          operation: .birth)), false),
            (.graph(.init(people: ["Hallie Mae Breen"],
                          operation: .death)), false),
            (.graph(.init(people: ["Hallie Mae Breen"],
                          operation: .kinship, relation: .children)), false),
        ]

        for (ast, expectsPhoto) in cases {
            let recorder = Recorder<Invocation>()
            let result = Self.fixtureResult(
                for: ast, catalogPersonName: "Hallie Mae Breen")
            let response = try await HallieAppTurnCoordinator.execute(
                question: "fixture question", records: [],
                referent: .init(recordID: nil, temporalDate: nil),
                hosts: ["fixture.invalid"], modelName: "fixture-model",
                dependencies: dependencies(
                    ast: ast, recorder: recorder, result: result,
                    photo: photo, graph: fixtureGraph()))

            if expectsPhoto {
                #expect(response.biographyPhoto == photo)
            } else {
                #expect(response.biographyPhoto == nil,
                        "birth/death/kinship must not attach biography art")
            }
        }
    }

    @Test func injectedStateIgnoresPoisonedDefaultsAndRealArchivePaths() async throws {
        let priorHosts = UserDefaults.standard.object(
            forKey: OllamaEndpoints.hostsKey)
        UserDefaults.standard.set("poison.invalid", forKey: OllamaEndpoints.hostsKey)
        defer {
            if let priorHosts {
                UserDefaults.standard.set(priorHosts,
                                          forKey: OllamaEndpoints.hostsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: OllamaEndpoints.hostsKey)
            }
        }

        let ast = ArchivistQueryAST.graph(.init(
            people: ["Fixture Person"], operation: .biography))
        let recorder = Recorder<Invocation>()
        let record = VideoRecord()
        record.fullPath = "/isolated/not-real-catalog/fixture.mxf"
        record.filename = "fixture.mxf"
        let injectedProfiles = [HallieTurnExecutor.ProfileSnapshot(
            stableID: "fixture-profile", canonicalName: "Fixture Person")]

        let response = try await HallieAppTurnCoordinator.execute(
            question: "fixture question", records: [record],
            referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            dependencies: dependencies(
                ast: ast, recorder: recorder,
                profiles: injectedProfiles, graph: fixtureGraph()))

        #expect(recorder.values.count == 1)
        let invocation = try #require(recorder.values.first)
        #expect(invocation.profiles == injectedProfiles)
        #expect(response.responderHost == "fixture-host")
        #expect(!response.result.prose.contains("poison.invalid"))
        #expect(!response.result.basisLine.contains("poison.invalid"))
    }

    @Test func capturedReferentSurvivesSelectionChangeDuringTranslation() async throws {
        let ast = ArchivistQueryAST.temporal(.init(
            subject: "Donna", operation: .age,
            reference: .currentSelection))
        let gate = Gate()
        let recorder = Recorder<Invocation>()
        let oldID = UUID()
        let newID = UUID()
        let oldDate = ArchivistTemporalSelectionDateSnapshot.catalogCreation(
            recordID: oldID, fullPath: "/isolated/old.mov",
            date: Date(timeIntervalSince1970: 1_600_000_000))
        let dependencies = HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { hosts in hosts },
            translateAST: { _, _, _ in
                await gate.pause()
                return .init(ast: ast, responderHost: "fixture-host")
            },
            loadProfiles: {
                [.init(stableID: "donna", canonicalName: "Donna")]
            },
            loadGraph: { nil },
            executeRequest: { request, context in
                let receivedAST = request.intent.ast
                recorder.append(Invocation(
                    ast: receivedAST,
                    presenceCount: context.presenceRecords.count,
                    aggregateCount: context.aggregateRecords.count,
                    profiles: context.profiles,
                    graphWasInjected: context.graph != nil,
                    selectedDate: context.selectedTemporalDate))
                return Self.fixtureResult(for: receivedAST)
            },
            continueTurn: { clarification, selectedID, context in
                try await HallieTurnExecutor.continue(
                    pending: clarification, selecting: selectedID,
                    context: context)
            },
            resolveBiographyPhoto: { _ in nil })

        var visibleSelectionID: UUID? = oldID
        let captured = HallieAppTurnCoordinator.CapturedReferent(
            recordID: visibleSelectionID,
            temporalDate: oldDate)
        let task = Task { @MainActor in
            try await HallieAppTurnCoordinator.execute(
                question: "fixture question", records: [],
                referent: captured, hosts: ["fixture.invalid"],
                modelName: "fixture-model", dependencies: dependencies)
        }
        await gate.waitUntilStarted()
        visibleSelectionID = newID
        await gate.open()

        let response = try await task.value
        let invocation = try #require(recorder.values.first)
        #expect(response.capturedReferentID == oldID)
        #expect(invocation.selectedDate == oldDate)
        #expect(visibleSelectionID == newID)
    }

    @Test func temporalClarificationTranslatesOnceAndPreservesIntentAndReferent() async throws {
        let translations = Recorder<String>()
        let selectedID = UUID()
        let selectedDate = ArchivistTemporalSelectionDateSnapshot.catalogCreation(
            recordID: selectedID, fullPath: "/isolated/original-selection.mov",
            date: Date(timeIntervalSince1970: 1_596_499_200)) // 2020-08-03 UTC
        let ast = ArchivistQueryAST.temporal(.init(
            subject: "Timmy", operation: .age,
            reference: .currentSelection))
        let profiles = [
            HallieTurnExecutor.ProfileSnapshot(
                stableID: "tim-senior", canonicalName: "Tim Breen",
                aliases: ["Timmy"],
                birthdate: Date(timeIntervalSince1970: 0)),
            HallieTurnExecutor.ProfileSnapshot(
                stableID: "tim-son", canonicalName: "Timothy Breen",
                aliases: ["Timmy"],
                birthdate: Date(timeIntervalSince1970: 965_779_200)),
        ]
        let dependencies = HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { hosts in hosts },
            translateAST: { question, _, _ in
                translations.append(question)
                return .init(ast: ast, responderHost: "fixture-host")
            },
            loadProfiles: { profiles },
            loadGraph: { nil },
            executeRequest: { request, context in
                try await HallieTurnExecutor.execute(request, context: context)
            },
            continueTurn: { clarification, selectedID, context in
                try await HallieTurnExecutor.continue(
                    pending: clarification, selecting: selectedID,
                    context: context)
            },
            resolveBiographyPhoto: { _ in nil })

        let first = try await HallieAppTurnCoordinator.execute(
            question: "How old was Timmy here?", records: [],
            referent: .init(recordID: selectedID,
                            temporalDate: selectedDate),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            playAfterAnswer: true, dependencies: dependencies)
        let pending = try #require(first.pendingClarification)
        #expect(first.result.outcome == .needsClarification)
        #expect(!first.playAfterAnswer)
        #expect(translations.values == ["How old was Timmy here?"])

        let answer = try await HallieAppTurnCoordinator.continue(
            pending: pending, selecting: .profileStableID("tim-son"),
            dependencies: dependencies)
        #expect(translations.values == ["How old was Timmy here?"])
        #expect(answer.result.outcome == .answered)
        #expect(answer.result.prose.contains("Timothy Breen"))
        #expect(answer.capturedReferentID == selectedID)
        #expect(answer.playAfterAnswer)
        #expect(answer.pendingClarification == nil)
    }

    @Test func graphTwoStageClarificationKeepsContextAndTranslatesOnce() async throws {
        let translations = Recorder<String>()
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Mary /Smith/
        1 BIRT
        2 DATE 1 JAN 1900
        0 @I2@ INDI
        1 NAME Mary /Smith/
        1 BIRT
        2 DATE 2 FEB 1920
        0 @I3@ INDI
        1 NAME Nancy /Jones/
        0 TRLR
        """)
        let ast = ArchivistQueryAST.graph(.init(
            people: ["Nan"], operation: .biography))
        let profiles = [
            HallieTurnExecutor.ProfileSnapshot(
                stableID: "mary", canonicalName: "Mary Smith",
                aliases: ["Nan"]),
            HallieTurnExecutor.ProfileSnapshot(
                stableID: "nancy", canonicalName: "Nancy Jones",
                aliases: ["Nan"]),
        ]
        let photo = ArchivistBiographyPhoto(
            profileStableID: "mary", profileCanonicalName: "Mary Smith",
            fileURL: URL(fileURLWithPath: "/isolated/mary.png"),
            cropOffsetX: 0, cropOffsetY: 0, cropScale: 1)
        let dependencies = HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { hosts in hosts },
            translateAST: { question, _, _ in
                translations.append(question)
                return .init(ast: ast, responderHost: "fixture-host")
            },
            loadProfiles: { profiles },
            loadGraph: { graph },
            executeRequest: { request, context in
                try await HallieTurnExecutor.execute(request, context: context)
            },
            continueTurn: { clarification, selectedID, context in
                try await HallieTurnExecutor.continue(
                    pending: clarification, selecting: selectedID,
                    context: context)
            },
            resolveBiographyPhoto: { canonical in
                canonical == "Mary Smith" ? photo : nil
            })

        let first = try await HallieAppTurnCoordinator.execute(
            question: "Who was Nan?", records: [],
            referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            dependencies: dependencies)
        let profilePending = try #require(first.pendingClarification)
        #expect(profilePending.clarification.stage == .profileIdentity)

        let second = try await HallieAppTurnCoordinator.continue(
            pending: profilePending, selecting: .profileStableID("mary"),
            dependencies: dependencies)
        let gedcomPending = try #require(second.pendingClarification)
        #expect(gedcomPending.clarification.stage == .gedcomPerson)
        #expect(second.biographyPhoto == nil)

        let answer = try await HallieAppTurnCoordinator.continue(
            pending: gedcomPending, selecting: .gedcomPersonID("@I2@"),
            dependencies: dependencies)
        #expect(translations.values == ["Who was Nan?"])
        #expect(answer.result.outcome == .answered)
        #expect(answer.result.prose.contains("2 FEB 1920"))
        #expect(answer.biographyPhoto == photo)
        #expect(answer.pendingClarification == nil)
        #expect(answer.responderHost == "fixture-host")
    }

    @Test func coordinatorCancellationStopsBeforeEvidenceExecution() async {
        let ast = ArchivistQueryAST.presence(.init(people: ["Donna"]))
        let gate = Gate()
        let calls = Recorder<String>()
        let dependencies = HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { hosts in
                calls.append("start")
                return hosts
            },
            translateAST: { _, _, _ in
                calls.append("translate")
                await gate.pause()
                return .init(ast: ast, responderHost: "fixture-host")
            },
            loadProfiles: {
                calls.append("profiles")
                return []
            },
            loadGraph: {
                calls.append("graph")
                return nil
            },
            executeRequest: { request, _ in
                calls.append("execute")
                return Self.fixtureResult(for: request.intent.ast)
            },
            continueTurn: { _, _, _ in
                calls.append("continue")
                throw FixtureError.translationFailed
            },
            resolveBiographyPhoto: { _ in nil })

        let task = Task { @MainActor in
            try await HallieAppTurnCoordinator.execute(
                question: "fixture question", records: [],
                referent: .init(recordID: nil, temporalDate: nil),
                hosts: ["fixture.invalid"], modelName: "fixture-model",
                dependencies: dependencies)
        }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            Issue.record("cancelled coordinator executed evidence")
        } catch is CancellationError {
            // Expected: cancellation is checked immediately after translation.
        } catch {
            Issue.record("unexpected cancellation error: \(error)")
        }
        #expect(calls.values == ["start", "translate"])
    }

    @Test func localBrainStartupFailureStillUsesConfiguredFleet() async throws {
        let calls = Recorder<String>()
        let dependencies = HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { hosts in
                calls.append("start:\(hosts.joined(separator: ","))")
                throw FixtureError.translationFailed
            },
            translateAST: { _, _, _ in
                calls.append("translate")
                return .init(
                    ast: .presence(.init(people: ["Donna"])),
                    responderHost: "fixture-host")
            },
            loadProfiles: { [] },
            loadGraph: { nil },
            executeRequest: { request, _ in
                calls.append("execute")
                return Self.fixtureResult(for: request.intent.ast)
            },
            continueTurn: { _, _, _ in throw FixtureError.translationFailed },
            resolveBiographyPhoto: { _ in nil })

        _ = try await HallieAppTurnCoordinator.execute(
            question: "Where is Donna?", records: [],
            referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["RicksM4.local", "ricksm5.local"],
            modelName: "fixture-model", dependencies: dependencies)

        #expect(calls.values == [
            "start:RicksM4.local,ricksm5.local", "translate", "execute",
        ])
    }

    @Test func oneHundredThousandRecordCoordinatorBudgetAndYieldSensor() async throws {
        let record = VideoRecord()
        record.fullPath = "/isolated/scale/repeated.mov"
        record.filename = "repeated.mov"
        record.confirmedByUserPeople = [ConfirmedTag(
            name: "Donna", confirmedAt: Date(timeIntervalSince1970: 1_700_000_000))]
        let records = Array(repeating: record, count: 100_000)
        let ast = ArchivistQueryAST.presence(.init(people: ["Donna"]))
        let recorder = Recorder<Invocation>()

        let started = ContinuousClock.now
        let response = try await HallieAppTurnCoordinator.execute(
            question: "fixture question", records: records,
            referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            dependencies: dependencies(ast: ast, recorder: recorder))
        let elapsed = ContinuousClock.now - started

        let invocation = try #require(recorder.values.first)
        #expect(response.result.route == .presence)
        #expect(invocation.presenceCount == 100_000)
        #expect(elapsed < .seconds(5),
                "app capture+execute took \(elapsed) for 100k records")

        let presence = try productionSource("ArchivistPresenceExecutor.swift")
        let aggregate = try productionSource("ArchivistAggregateExecutor.swift")
        #expect(presence.contains("if start < records.count { await Task.yield() }"))
        #expect(aggregate.contains("if start < records.count { await Task.yield() }"))
    }

    /// Production-path sensor: an ordinary factual turn has one path from
    /// strict QueryAST-v2 translation to the same executor used by the shell.
    /// This intentionally fails if v1 translation or literal filtering is
    /// reintroduced ahead of that path.
    @Test func ordinaryChatTurnUsesOnlySharedV2Coordinator() throws {
        let chat = try productionSource("ArchivistChatWindow.swift")
        let ask = try slice(chat, from: "private func ask(_ text: String)",
                            through: "// MARK: Play")
        let coordinator = try productionSource("HallieAppTurnCoordinator.swift")

        #expect(ask.contains("HallieAppTurnCoordinator.execute("))
        #expect(!ask.contains("translator.translate("))
        #expect(!ask.contains("NLQuerySpec"))
        #expect(!ask.contains("searchIndex.filter"))
        #expect(!ask.contains("finishSearch("))
        #expect(!ask.contains("literally"))
        #expect(ask.contains("activeRequestTask?.cancel()"))
        #expect(ask.contains("guard !Task.isCancelled,"))
        #expect(ask.contains("activeRequestID == requestID"))

        #expect(coordinator.contains("translator.translateAST(question)"))
        #expect(coordinator.contains("HallieTurnExecutor.route(translation.ast)"))
        #expect(coordinator.contains("HallieTurnExecutor.execute(request, context: context)"))
        #expect(coordinator.contains("dependencies.executeRequest(request, context)"))
        #expect(!coordinator.contains("translator.translate(question)"))
        #expect(!coordinator.contains("NLQueryComposer"))
        #expect(!coordinator.contains("searchIndex.filter"))
    }

    @Test func appClarificationChipsUseTypedContinuationNotAskText() throws {
        let chat = try productionSource("ArchivistChatWindow.swift")
        let ask = try slice(chat, from: "private func ask(_ text: String)",
                            through: "// MARK: Play")
        let commit = try slice(
            chat, from: "private func commitHallie(",
            through: "// MARK: Play")
        #expect(commit.contains("action: .hallieIdentityChoice($0.id)"))
        #expect(!commit.contains("action: .askText"))
        #expect(commit.contains("response.pendingClarification"))
        #expect(chat.contains("HallieAppTurnCoordinator.continue("))
        #expect(ask.contains("let number = Int(folded)"))
        #expect(ask.contains("exactCandidates.count == 1"))
        #expect(ask.contains("I need the name so I don't guess."))
        #expect(ask.contains("Okay — I won't guess which person you meant."))
    }

    @Test func interpretationFailureIsFailClosed() throws {
        let chat = try productionSource("ArchivistChatWindow.swift")
        let ask = try slice(chat, from: "private func ask(_ text: String)",
                            through: "// MARK: Play")
        let coordinator = try productionSource("HallieAppTurnCoordinator.swift")

        #expect(ask.contains("I couldn't safely interpret that question"))
        #expect(ask.contains("No catalog query or media action was performed."))
        #expect(ask.contains("lastMatches = []"))
        #expect(!ask.contains("archivistSearchRequest"))
        #expect(!ask.contains("applyQuery"))
        #expect(!coordinator.contains("try?"))
    }

    /// Exact selection means exactly one row. The captured UUID and temporal
    /// projection are created before translation, so a later table change
    /// cannot retarget the in-flight question.
    @Test func catalogPublishesExactSelectionAndTurnCapturesItBeforeAwait() throws {
        let content = try productionSource("ContentView.swift")
        let chat = try productionSource("ArchivistChatWindow.swift")
        let ask = try slice(chat, from: "private func ask(_ text: String)",
                            through: "// MARK: Play")

        #expect(content.contains("model.hallieCurrentSelectionID = selectedIDs.count == 1"))
        #expect(content.contains("model.hallieCurrentSelectionID = nil"))
        #expect(ask.contains("let selectedID = model.hallieCurrentSelectionID"))
        #expect(ask.contains("CapturedReferent("))
        #expect(ask.contains("recordID: selectedID"))
        #expect(ask.contains("temporalDate: selectedDate"))

        let capture = try #require(ask.range(of: "let referent ="))
        let awaitExecute = try #require(
            ask.range(of: "HallieAppTurnCoordinator.execute("))
        #expect(capture.lowerBound < awaitExecute.lowerBound)
    }

    /// Media-matrix execution is N/A for the metadata-only query executor.
    /// This pins the explicit terminal UI boundary: evidence must be shown
    /// before Play/Reveal can invoke media or Finder actions.
    @Test func boundedEvidenceHasExplicitPlayRevealBoundary() throws {
        let chat = try productionSource("ArchivistChatWindow.swift")
        let coordinator = try productionSource("HallieAppTurnCoordinator.swift")

        #expect(chat.contains("Evidence samples (up to 25; not all matches)"))
        #expect(chat.contains("Button(\"Play\")"))
        #expect(chat.contains("Button(\"Reveal\")"))
        #expect(chat.contains("let citations = response.citations"))
        #expect(coordinator.contains("citations: Array(result.citations.prefix(25))"))
        #expect(chat.contains("model.record(forID: citation.recordID)"))
        #expect(chat.contains("activateFileViewerSelecting"))
        #expect(!coordinator.contains("NSWorkspace"))
        #expect(!coordinator.contains("MediaOpener"))
        #expect(!coordinator.contains("AVPlayer"))
    }

    @Test func legacyPopoverIsClearlyQuickCatalogFilter() throws {
        let popover = try productionSource("ArchivistAskField.swift")
        #expect(popover.contains("Quick Catalog Filter"))
        #expect(!popover.contains("Text(\"Family Archivist\")"))
    }
}
