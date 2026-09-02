import Foundation
import Testing
@testable import VideoScan

@MainActor
@Suite("Hallie shared turn executor", .serialized)
struct HallieTurnExecutorTests {
    private let confirmedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: year, month: month, day: day,
            hour: 12))!
    }

    private func tag(_ name: String) -> ConfirmedTag {
        ConfirmedTag(name: name, confirmedAt: confirmedAt)
    }

    private func source(named filename: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let url = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("VideoScan")
            .appendingPathComponent(filename)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func allSixASTShapesHaveClosedRoutesAndUnsupportedShapesDecline() async throws {
        let cases: [(ArchivistQueryAST, HallieTurnExecutor.Route)] = [
            (.presence(.init(people: ["Donna"])), .presence),
            (.temporal(.init(subject: "Donna", operation: .age,
                             reference: .explicitYear(2000))), .temporal),
            (.aggregate(.init(operation: .coOccurrence,
                              anchorPeople: ["Donna"])), .aggregate),
            (.graph(.init(people: ["Donna"], operation: .biography)), .graph),
            (.event(.init(keywords: ["birthday"])), .unsupportedEvent),
            (.cross(.init(people: ["Donna"], keywords: ["birthday"])), .cross),
        ]

        for (ast, expectedRoute) in cases {
            #expect(HallieTurnExecutor.route(ast) == expectedRoute)
        }

        let event = try await HallieTurnExecutor.execute(cases[4].0, context: .init())
        #expect(event.outcome == .unsupported)
        #expect(event.citations.isEmpty)
        #expect(event.prose.contains("not supported"))
        #expect(event.prose.contains("did not"))

        // Cross is now executed deterministically (person AND keyword). With
        // no records it declines honestly on evidence, never "unsupported".
        let cross = try await HallieTurnExecutor.execute(cases[5].0, context: .init())
        #expect(cross.route == .cross)
        #expect(cross.outcome == .declined)
        #expect(cross.citations.isEmpty)
        #expect(cross.prose.hasPrefix("I looked for videos of "), Comment(rawValue: cross.prose))
        #expect(cross.prose.contains("found nothing in the catalog"))
    }

    @Test func crossAndsPersonWithSpokenWordAndCitesBothBases() async throws {
        let records = [
            ArchivistPresenceRecordSnapshot(
                fullPath: "/isolated/2006/timmy_playpen.mov",
                confirmedPeople: [tag("Timmy")],
                transcript: "peekaboo! there you are",
                transcriptModel: "fixture-whisper"),
            ArchivistPresenceRecordSnapshot(
                fullPath: "/isolated/2006/timmy_bath.mov",
                confirmedPeople: [tag("Timmy")],
                transcript: "splash splash"),
            ArchivistPresenceRecordSnapshot(
                fullPath: "/isolated/2006/donna_kitchen.mov",
                confirmedPeople: [tag("Donna")],
                transcript: "peekaboo"),
        ]
        let result = try await HallieTurnExecutor.execute(
            .cross(.init(people: ["Timmy"], transcript: ["peekaboo"])),
            context: .init(presenceRecords: records))
        #expect(result.route == .cross)
        #expect(result.outcome == .answered)
        #expect(result.citations.map(\.fullPath) == ["/isolated/2006/timmy_playpen.mov"])
        #expect(result.matchCount == 1)
        let bases = try #require(result.citations.first?.bases)
        #expect(bases.count == 2)
        guard case .humanPersonTag(let query, _, _) = bases[0],
              case .transcriptMention(let term, let model) = bases[1] else {
            Issue.record("expected person tag + transcript bases, got \(bases)")
            return
        }
        #expect(query == "Timmy")
        #expect(term == "peekaboo")
        #expect(model == "fixture-whisper")
    }

    /// "show ricks family tree": nobody is called "ricks", but "rick" is a
    /// People profile alias, so the possessive is read that way — visibly, in
    /// the basis line — and the family-tree summary comes back for Rick.
    @Test func missingApostrophePossessiveIsReadAsTheSingularAndSaidSo() async throws {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Richard /Breen/
        1 SEX M
        1 FAMS @F1@
        0 @I2@ INDI
        1 NAME Timothy /Breen/
        1 SEX M
        1 FAMC @F1@
        0 @F1@ FAM
        1 HUSB @I1@
        1 CHIL @I2@
        0 TRLR
        """)
        let context = HallieTurnExecutor.Context(
            profiles: [.init(stableID: "rick", canonicalName: "Richard Breen", aliases: ["Rick"])],
            graph: graph)
        let result = try await HallieTurnExecutor.execute(
            .graph(.init(people: ["ricks"], operation: .familyTree)), context: context)
        #expect(result.outcome == .answered)
        #expect(result.prose.hasPrefix("Richard Breen has 1 recorded child, Timothy Breen."))   // undated ⇒ living (LifeStatus)
        #expect(result.basisLine.hasPrefix("Basis: reading “ricks” as “rick’s”; "))
        #expect(result.offeredActions == [.openFamilyTree(personName: "Richard Breen")])

        // A genuinely unknown plural is NOT rewritten into someone else.
        let unknown = try await HallieTurnExecutor.execute(
            .graph(.init(people: ["chris"], operation: .familyTree)), context: context)
        #expect(unknown.outcome == .declined)
        #expect(!unknown.basisLine.contains("reading"))
    }

    @Test func presenceReturnsTypedContainerNeutralCitations() async throws {
        let paths = [
            "/isolated/archive/family.mp4", "/isolated/archive/family.mov",
            "/isolated/archive/family.mkv", "/isolated/archive/family.mxf",
            "/isolated/archive/family.avi",
        ]
        let records = paths.enumerated().map { index, path in
            ArchivistPresenceRecordSnapshot(
                fullPath: path,
                confirmedPeople: [tag("Donna")],
                captions: [.init(timestamp: Double(index) + 0.5,
                                 text: "Donna waves")],
                captionModel: "fixture-captioner")
        }
        let result = try await HallieTurnExecutor.execute(
            .presence(.init(people: ["Donna"], keywords: ["waves"])),
            context: .init(presenceRecords: records))

        #expect(result.route == .presence)
        #expect(result.outcome == .answered)
        #expect(result.citations.map(\.fullPath) == paths)
        #expect(result.citations.map(\.playbackSeconds)
                == [0.5, 1.5, 2.5, 3.5, 4.5])
        let first = try #require(result.citations.first)
        #expect(first.filename == "family.mp4")
        #expect(first.bases.count == 2)
        guard case .humanPersonTag(let query, let tagged, let stamp)
                = first.bases[0],
              case .caption(let term, let time, let text, let model)
                = first.bases[1] else {
            Issue.record("expected normalized typed identity and caption bases")
            return
        }
        #expect(query == "Donna")
        #expect(tagged == "Donna")
        #expect(stamp == confirmedAt)
        #expect(term == "waves")
        #expect(time == 0.5)
        #expect(text == "Donna waves")
        #expect(model == "fixture-captioner")

        let decline = try await HallieTurnExecutor.execute(
            .presence(.init(people: ["Nobody"])),
            context: .init(presenceRecords: records))
        #expect(decline.outcome == .declined)
        #expect(decline.citations.isEmpty)
    }

    @Test func presenceRecoversMisspelledFullNameToCatalogProfileTag() async throws {
        let profile = HallieTurnExecutor.ProfileSnapshot(
            stableID: "rick", canonicalName: "Rick", aliases: ["Dicky"])
        let cyberBrain = try CyberBrainIndex(archive: CyberBrainArchive(
            archiveID: "fixture", displayName: "Fixture",
            people: [CyberBrainPerson(
                id: "person.rick", gedcomPersonID: nil,
                canonicalName: "Rick Breen", aliases: ["Dicky"])],
            sources: []))
        let record = ArchivistPresenceRecordSnapshot(
            fullPath: "/isolated/rick.mov",
            confirmedPeople: [tag("Rick")])

        let result = try await HallieTurnExecutor.execute(
            .presence(.init(people: ["rick brren"], mediaKind: .video)),
            context: .init(
                presenceRecords: [record], profiles: [profile],
                cyberBrain: cyberBrain))

        #expect(result.outcome == .answered)
        #expect(result.prose.hasPrefix("I took “rick brren” to mean Rick."))
        #expect(result.citations.count == 1)
        #expect(result.basisLine.contains(
            "spelling recovery “rick brren” → People profile “Rick”"))
    }

    @Test func temporalUsesInjectedSelectedDateProvenanceAndDeclinesAmbiguity() async throws {
        let selectedID = UUID()
        let profile = HallieTurnExecutor.ProfileSnapshot(
            stableID: "timmy", canonicalName: "Timmy",
            aliases: ["Tim"], birthdate: date(2000, 8, 4))
        let selected = ArchivistTemporalSelectionDateSnapshot.dossierInferred(
            recordID: selectedID, fullPath: "/isolated/2020-08-03.mxf",
            date: date(2020, 8, 3), confidence: 0.95)
        let query = ArchivistQueryAST.temporal(.init(
            subject: "Tim", operation: .age, reference: .currentSelection))

        let result = try await HallieTurnExecutor.execute(
            query,
            context: .init(profiles: [profile], selectedTemporalDate: selected))

        #expect(result.route == .temporal)
        #expect(result.outcome == .answered)
        #expect(result.prose.contains("selected record's inferred date 2020-08-03"))
        #expect(result.prose.contains("calculated age is 19 years"))
        #expect(result.basisLine.contains("dossier inferred date"))
        #expect(result.basisLine.contains("confidence 0.95"))
        #expect(result.citations.isEmpty)

        let ambiguous = try await HallieTurnExecutor.execute(
            query,
            context: .init(profiles: [
                profile,
                .init(stableID: "other-tim", canonicalName: "Timothy",
                      aliases: ["Tim"], birthdate: date(1999, 1, 1)),
            ], selectedTemporalDate: selected))
        #expect(ambiguous.outcome == .needsClarification)
        #expect(ambiguous.prose == "Which Tim do you mean?")
        #expect(ambiguous.basisLine.contains("matched multiple People profiles"))
        #expect(ambiguous.citations.isEmpty)
        let clarification = try #require(ambiguous.clarification)
        #expect(clarification.stage == .profileIdentity)
        #expect(clarification.candidates.map(\.id) == [
            .profileStableID("timmy"),
            .profileStableID("other-tim"),
        ])
    }

    @Test func temporalTimAliasContinuationUsesStableIDAndPreservesReferent() async throws {
        let selectedID = UUID()
        let selected = ArchivistTemporalSelectionDateSnapshot.catalogCreation(
            recordID: selectedID, fullPath: "/isolated/2020-08-03.mov",
            date: date(2020, 8, 3))
        let profiles = [
            HallieTurnExecutor.ProfileSnapshot(
                stableID: "tim-senior", canonicalName: "Tim Breen",
                aliases: ["Tim", "Timmy"], birthdate: date(1970, 1, 1)),
            HallieTurnExecutor.ProfileSnapshot(
                stableID: "tim-son", canonicalName: "Timothy Breen",
                aliases: ["Tim", "Timmy"], birthdate: date(2000, 8, 4)),
        ]
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "How old was Timmy here?",
            ast: .temporal(.init(
                subject: "Timmy", operation: .age,
                reference: .currentSelection)),
            playAfterAnswer: true)
        let context = HallieTurnExecutor.Context(
            profiles: profiles, selectedTemporalDate: selected)

        let first = try await HallieTurnExecutor.execute(
            .init(intent: intent), context: context)
        let pending = try #require(first.clarification)
        #expect(first.outcome == .needsClarification)
        #expect(pending.intent == intent)
        #expect(pending.candidates.map(\.id) == [
            .profileStableID("tim-senior"),
            .profileStableID("tim-son"),
        ])

        let answer = try await HallieTurnExecutor.continue(
            pending: pending, selecting: .profileStableID("tim-son"),
            context: context)
        #expect(answer.outcome == .answered)
        #expect(answer.prose.contains("Timothy Breen"))
        #expect(answer.prose.contains("calculated age is 19 years"))
        #expect(answer.basisLine.contains("catalog creation date"))
        #expect(answer.clarification == nil)

        let forged = try await HallieTurnExecutor.continue(
            pending: pending, selecting: .profileStableID("forged"),
            context: context)
        #expect(forged.outcome == .declined)
        #expect(forged.prose.contains("no longer available"))

        let wrongSource = try await HallieTurnExecutor.continue(
            pending: pending, selecting: .gedcomPersonID("@I1@"),
            context: context)
        #expect(wrongSource.outcome == .declined)
        #expect(wrongSource.citations.isEmpty)

        let staleContext = HallieTurnExecutor.Context(
            profiles: [profiles[0]], selectedTemporalDate: selected)
        let stale = try await HallieTurnExecutor.continue(
            pending: pending, selecting: .profileStableID("tim-son"),
            context: staleContext)
        #expect(stale.outcome == .declined)
        #expect(stale.citations.isEmpty)

        let recycledIDContext = HallieTurnExecutor.Context(
            profiles: [
                .init(stableID: "tim-son", canonicalName: "Impostor Person",
                      birthdate: date(1900, 1, 1)),
            ], selectedTemporalDate: selected)
        let recycled = try await HallieTurnExecutor.continue(
            pending: pending, selecting: .profileStableID("tim-son"),
            context: recycledIDContext)
        #expect(recycled.outcome == .declined,
                "a stable ID recycled to another identity must fail closed")
        #expect(!recycled.prose.contains("Impostor Person"))

        let changedFactContext = HallieTurnExecutor.Context(
            profiles: [
                .init(stableID: "tim-son", canonicalName: "Timothy Breen",
                      aliases: ["A newly edited alias"],
                      birthdate: date(1900, 1, 1)),
            ], selectedTemporalDate: selected)
        let changedFact = try await HallieTurnExecutor.continue(
            pending: pending, selecting: .profileStableID("tim-son"),
            context: changedFactContext)
        #expect(changedFact.outcome == .declined,
                "same ID/name with edited aliases or birthdate is stale")
        #expect(!changedFact.prose.contains("120 years"))
    }

    @Test func graphContinuationHandlesProfileThenGEDCOMAmbiguityByStableID() async throws {
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
        let profiles = [
            HallieTurnExecutor.ProfileSnapshot(
                stableID: "mary-profile", canonicalName: "Mary Smith",
                aliases: ["Nan"]),
            HallieTurnExecutor.ProfileSnapshot(
                stableID: "nancy-profile", canonicalName: "Nancy Jones",
                aliases: ["Nan"]),
        ]
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "Who was Nan?",
            ast: .graph(.init(people: ["Nan"], operation: .biography)))
        let context = HallieTurnExecutor.Context(
            profiles: profiles, graph: graph)

        let first = try await HallieTurnExecutor.execute(
            .init(intent: intent), context: context)
        let profileChoice = try #require(first.clarification)
        #expect(first.outcome == .needsClarification)
        #expect(profileChoice.stage == .profileIdentity)
        #expect(profileChoice.candidates.map(\.id) == [
            .profileStableID("mary-profile"),
            .profileStableID("nancy-profile"),
        ])

        let recycledProfileContext = HallieTurnExecutor.Context(
            profiles: [
                .init(stableID: "mary-profile",
                      canonicalName: "Nancy Jones", aliases: ["Nan"]),
            ], graph: graph)
        let recycledProfile = try await HallieTurnExecutor.continue(
            pending: profileChoice,
            selecting: .profileStableID("mary-profile"),
            context: recycledProfileContext)
        #expect(recycledProfile.outcome == .declined,
                "a recycled profile ID must not switch graph identity")
        #expect(recycledProfile.catalogPersonName == nil)

        let second = try await HallieTurnExecutor.continue(
            pending: profileChoice,
            selecting: .profileStableID("mary-profile"), context: context)
        let gedcomChoice = try #require(second.clarification)
        #expect(second.outcome == .needsClarification)
        #expect(gedcomChoice.stage == .gedcomPerson)
        #expect(gedcomChoice.intent == intent)
        #expect(gedcomChoice.candidates.map(\.id) == [
            .gedcomPersonID("@I1@"),
            .gedcomPersonID("@I2@"),
        ])

        let answer = try await HallieTurnExecutor.continue(
            pending: gedcomChoice, selecting: .gedcomPersonID("@I2@"),
            context: context)
        #expect(answer.outcome == .answered)
        #expect(answer.prose.contains("2 February 1920"))
        #expect(answer.catalogPersonName == "Mary Smith")

        let wrongSource = try await HallieTurnExecutor.continue(
            pending: gedcomChoice,
            selecting: .profileStableID("mary-profile"), context: context)
        #expect(wrongSource.outcome == .declined)
        #expect(wrongSource.catalogPersonName == nil)

        let forged = try await HallieTurnExecutor.continue(
            pending: gedcomChoice, selecting: .gedcomPersonID("@FORGED@"),
            context: context)
        #expect(forged.outcome == .declined)
    }

    @Test func hundredThousandProfileClarificationStaysBoundedAndInjected() async throws {
        var profiles = (0..<100_000).map { index in
            HallieTurnExecutor.ProfileSnapshot(
                stableID: "unrelated-\(index)",
                canonicalName: "Unrelated Person \(index)")
        }
        profiles[0] = .init(
            stableID: "tim-a", canonicalName: "Tim Alpha",
            aliases: ["Timmy"], birthdate: date(1970, 1, 1))
        profiles[99_999] = .init(
            stableID: "tim-z", canonicalName: "Tim Zeta",
            aliases: ["Timmy"], birthdate: date(2000, 1, 1))
        let selected = ArchivistTemporalSelectionDateSnapshot.catalogCreation(
            recordID: UUID(), fullPath: "/isolated/scale/current.mov",
            date: date(2020, 1, 1))
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "How old was Timmy here?",
            ast: .temporal(.init(
                subject: "Timmy", operation: .age,
                reference: .currentSelection)))
        let context = HallieTurnExecutor.Context(
            profiles: profiles, selectedTemporalDate: selected)

        let started = ContinuousClock.now
        let first = try await HallieTurnExecutor.execute(
            .init(intent: intent), context: context)
        let pending = try #require(first.clarification)
        let answer = try await HallieTurnExecutor.continue(
            pending: pending, selecting: .profileStableID("tim-z"),
            context: context)
        let elapsed = ContinuousClock.now - started

        #expect(pending.candidates.map(\.id) == [
            .profileStableID("tim-a"), .profileStableID("tim-z"),
        ])
        #expect(answer.outcome == .answered)
        #expect(answer.prose.contains("Tim Zeta"))
        #expect(elapsed < .seconds(3),
                "100k injected-profile clarification took \(elapsed)")
    }

    @Test func duplicateDisplayNamesUseStableDeterministicLabels() async throws {
        let ast = ArchivistQueryAST.temporal(.init(
            subject: "Timmy", operation: .age,
            reference: .explicitYear(2020)))
        let result = try await HallieTurnExecutor.execute(
            ast,
            context: .init(profiles: [
                .init(stableID: "z-profile", canonicalName: "Tim Breen",
                      aliases: ["Timmy"]),
                .init(stableID: "a-profile", canonicalName: "Tim Breen",
                      aliases: ["Timmy"]),
            ]))
        let choices = try #require(result.clarification?.candidates)

        #expect(choices.map(\.id) == [
            .profileStableID("a-profile"),
            .profileStableID("z-profile"),
        ])
        #expect(choices.map(\.label) == [
            "Tim Breen (a-profile)",
            "Tim Breen (z-profile)",
        ])
    }

    @Test func aggregateReturnsRankedTypedCitationFromInjectedIdentities() async throws {
        let recordID = UUID()
        let records = [ArchivistAggregateRecordSnapshot(
            id: recordID, fullPath: "/isolated/archive/together.mxf",
            confirmedPeople: [tag("Mom"), tag("Dan")])]
        let profiles = [
            HallieTurnExecutor.ProfileSnapshot(
                stableID: "donna", canonicalName: "Donna", aliases: ["Mom"]),
            HallieTurnExecutor.ProfileSnapshot(
                stableID: "dan", canonicalName: "Dan Breen", aliases: ["Dan"]),
        ]
        let result = try await HallieTurnExecutor.execute(
            .aggregate(.init(operation: .coOccurrence,
                             anchorPeople: ["Donna"])),
            context: .init(aggregateRecords: records, profiles: profiles))

        #expect(result.route == .aggregate)
        #expect(result.outcome == .answered)
        #expect(result.prose.contains("Dan Breen"))
        let citation = try #require(result.citations.first)
        #expect(citation.recordID == recordID)
        #expect(citation.fullPath == "/isolated/archive/together.mxf")
        #expect(citation.playbackSeconds == nil)
        #expect(citation.bases.count == 2)
        guard case .humanPersonTag(let anchor, let anchorTag, _)
                = citation.bases[0],
              case .humanPersonTag(let peer, let peerTag, _)
                = citation.bases[1] else {
            Issue.record("aggregate citation lost typed tag provenance")
            return
        }
        #expect(anchor == "Donna")
        #expect(anchorTag == "Mom")
        #expect(peer == "Dan Breen")
        #expect(peerTag == "Dan")
    }

    @Test func graphAnswerAndMissingGraphRemainExplicit() async throws {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Alex /River/
        1 BIRT
        2 DATE 1 JAN 1900
        0 TRLR
        """)
        let ast = ArchivistQueryAST.graph(.init(
            people: ["Alex River"], operation: .biography))

        let answer = try await HallieTurnExecutor.execute(
            ast, context: .init(graph: graph))
        #expect(answer.route == .graph)
        #expect(answer.outcome == .answered)
        #expect(answer.catalogPersonName == "Alex River")
        #expect(answer.prose.contains("born 1 January 1900"))

        let decline = try await HallieTurnExecutor.execute(
            ast, context: .init(graph: nil))
        #expect(decline.outcome == .declined)
        #expect(decline.prose.contains("don't have an imported family tree"))
        #expect(decline.catalogPersonName == nil)
    }

    @Test func oneHundredThousandPrebuiltSnapshotsExecuteWithinBudget() async throws {
        let snapshot = ArchivistPresenceRecordSnapshot(
            fullPath: "/isolated/scale/repeated.mov",
            confirmedPeople: [tag("Donna")])
        let snapshots = Array(repeating: snapshot, count: 100_000)
        let context = HallieTurnExecutor.Context(presenceRecords: snapshots)

        let started = ContinuousClock.now
        let result = try await HallieTurnExecutor.execute(
            .presence(.init(people: ["Donna"])), context: context)
        let elapsed = ContinuousClock.now - started

        #expect(result.outcome == .answered)
        #expect(result.citations.count == ArchivistPresenceExecutor.maxCitations)
        #expect(elapsed < .seconds(2),
                "direct shared execution took \(elapsed) for 100k prebuilt snapshots")
    }

    @Test func hundredThousandRecordSnapshotBridgesStopAfterCancellation() async {
        let record = VideoRecord()
        record.fullPath = "/isolated/cancel/repeated.mov"
        record.filename = "repeated.mov"
        record.isPlayable = "Yes"
        record.confirmedByUserPeople = [tag("Donna")]
        let records = Array(repeating: record, count: 100_000)

        let presenceTask = Task { @MainActor in
            await ArchivistPresenceRecordSnapshot.capture(records, batchSize: 1)
        }
        await Task.yield()
        let presenceCancellation = ContinuousClock.now
        presenceTask.cancel()
        let partialPresence = await presenceTask.value
        let presenceElapsed = ContinuousClock.now - presenceCancellation

        #expect(partialPresence.count < records.count,
                "cancelled presence capture must not finish all 100k records")
        #expect(presenceElapsed < .seconds(3),
                "presence capture took \(presenceElapsed) to observe cancellation")

        let aggregateTask = Task { @MainActor in
            await ArchivistAggregateRecordSnapshot.capture(records, batchSize: 1)
        }
        await Task.yield()
        let aggregateCancellation = ContinuousClock.now
        aggregateTask.cancel()
        let partialAggregate = await aggregateTask.value
        let aggregateElapsed = ContinuousClock.now - aggregateCancellation

        #expect(partialAggregate.count < records.count,
                "cancelled aggregate capture must not finish all 100k records")
        #expect(aggregateElapsed < .seconds(3),
                "aggregate capture took \(aggregateElapsed) to observe cancellation")
    }

    @Test func productionPresenceExecutionThrowsPromptlyWhenCancelled() async {
        let snapshot = ArchivistPresenceRecordSnapshot(
            fullPath: "/isolated/cancel/presence.mov",
            confirmedPeople: [tag("Donna")],
            captions: [.init(timestamp: 1, text: "Donna waves at the camera")],
            captionModel: "fixture-captioner")
        let snapshots = Array(repeating: snapshot, count: 250_000)
        let context = HallieTurnExecutor.Context(presenceRecords: snapshots)
        let task = Task.detached {
            try await HallieTurnExecutor.execute(
                .presence(.init(people: ["Donna"], keywords: ["waves"])),
                context: context)
        }

        await Task.yield()
        let cancelledAt = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled production presence scan returned an answer")
        } catch is CancellationError {
            // Swift Testing uses a thrown-type branch here like EXPECT_THROW.
        } catch {
            Issue.record("presence cancellation threw \(error) instead")
        }
        let elapsed = ContinuousClock.now - cancelledAt
        #expect(elapsed < .seconds(3),
                "production presence cancellation took \(elapsed)")
    }

    @Test func productionAggregateExecutionThrowsPromptlyWhenCancelled() async {
        let snapshot = ArchivistAggregateRecordSnapshot(
            fullPath: "/isolated/cancel/aggregate.mxf",
            confirmedPeople: [tag("Donna"), tag("Dan")])
        let snapshots = Array(repeating: snapshot, count: 250_000)
        let context = HallieTurnExecutor.Context(
            aggregateRecords: snapshots,
            profiles: [
                .init(stableID: "donna", canonicalName: "Donna"),
                .init(stableID: "dan", canonicalName: "Dan"),
            ])
        let task = Task.detached {
            try await HallieTurnExecutor.execute(
                .aggregate(.init(operation: .coOccurrence,
                                 anchorPeople: ["Donna"])),
                context: context)
        }

        await Task.yield()
        let cancelledAt = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled production aggregate scan returned an answer")
        } catch is CancellationError {
            // Expected: the detached production scan propagates cancellation.
        } catch {
            Issue.record("aggregate cancellation threw \(error) instead")
        }
        let elapsed = ContinuousClock.now - cancelledAt
        #expect(elapsed < .seconds(3),
                "production aggregate cancellation took \(elapsed)")
    }

    @Test func injectedContextIgnoresPoisonedGlobalSettings() async throws {
        let key = OllamaEndpoints.hostsKey
        let prior = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set("poison.invalid", forKey: key)
        defer {
            if let prior {
                UserDefaults.standard.set(prior, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let path = "/isolated/not-the-real-catalog/family.avi"
        let result = try await HallieTurnExecutor.execute(
            .presence(.init(people: ["Fixture Person"])),
            context: .init(presenceRecords: [
                .init(fullPath: path,
                      confirmedPeople: [tag("Fixture Person")]),
            ]))

        #expect(result.outcome == .answered)
        #expect(result.citations.map(\.fullPath) == [path])
        #expect(!result.prose.contains("poison.invalid"))
        #expect(!result.basisLine.contains("poison.invalid"))
    }

    @Test func cyberBrainBiographyCarriesCuratedClaimsAndSources() async throws {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let source = CyberBrainSource(
            id: "source.donna-interview",
            type: .firstPerson,
            title: "Donna's Cape memories",
            attribution: "Donna Breen",
            locator: "sources/interviews/donna-cape.txt")
        let passage = CyberBrainItem(
            id: "bio.donna.cape",
            kind: .biography,
            text: "Donna remembers summers down the Cape as a defining family tradition.",
            subjectPersonIDs: ["person.donna"],
            sourceIDs: [source.id],
            confidence: .confirmed,
            privacy: .family,
            createdAt: instant,
            updatedAt: instant)
        let index = try CyberBrainIndex(archive: .init(
            archiveID: "breen-family",
            displayName: "Breen Family CyberBrain",
            people: [.init(
                id: "person.donna",
                canonicalName: "Donna Breen",
                aliases: ["Donna"],
                biographyPassages: [passage])],
            sources: [source]))
        let ast = ArchivistQueryAST.graph(.init(
            people: ["Donna"], operation: .biography))

        let result = try await HallieTurnExecutor.execute(
            ast,
            context: .init(graph: nil, cyberBrain: index))

        #expect(result.outcome == .answered)
        #expect(result.prose.contains("summers down the Cape"))
        #expect(result.catalogPersonName == "Donna Breen")
        #expect(result.citations.isEmpty)
        #expect(result.knowledgeCitations == [.init(
            id: source.id,
            title: source.title,
            attribution: source.attribution,
            locator: source.locator)])
    }

    @Test func cyberBrainAmbiguityContinuesByStableIDWithoutGuessing() async throws {
        let people = [
            CyberBrainPerson(
                id: "person.donna-a",
                canonicalName: "Donna A. Breen",
                aliases: ["Donna"]),
            CyberBrainPerson(
                id: "person.donna-b",
                canonicalName: "Donna B. Breen",
                aliases: ["Donna"]),
        ]
        let index = try CyberBrainIndex(archive: .init(
            archiveID: "ambiguity",
            displayName: "Ambiguity fixture",
            people: people,
            sources: []))
        let context = HallieTurnExecutor.Context(cyberBrain: index)
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "Tell me about Donna",
            ast: .graph(.init(people: ["Donna"], operation: .biography)))
        let first = try await HallieTurnExecutor.execute(
            .init(intent: intent), context: context)
        let pending = try #require(first.clarification)

        #expect(first.outcome == .needsClarification)
        #expect(pending.candidates.map(\.id) == [
            .cyberBrainPersonID("person.donna-a"),
            .cyberBrainPersonID("person.donna-b"),
        ])
        let continued = try await HallieTurnExecutor.continue(
            pending: pending,
            selecting: .cyberBrainPersonID("person.donna-b"),
            context: context)
        #expect(continued.outcome == .declined)
        #expect(continued.prose.contains("Donna B. Breen"))
        #expect(continued.clarification == nil)
    }

    /// Media-matrix execution is N/A: this seam consumes catalog metadata
    /// only. These source sensors keep media opening and UI frameworks in the
    /// terminal adapter, and keep the terminal adapter delegated to one core.
    @Test func sharedExecutorIsUIAndMediaNeutralAndShellDelegates() throws {
        let executor = try source(named: "HallieTurnExecutor.swift")
        let shell = try source(named: "HallieShellCLI.swift")
        let compactShell = shell.filter { !$0.isWhitespace }

        #expect(!executor.contains("import AppKit"))
        #expect(!executor.contains("import AVFoundation"))
        #expect(!executor.contains("NSWorkspace"))
        #expect(!executor.contains("AVPlayer"))
        #expect(!executor.contains("ffmpeg"))
        #expect(!executor.contains("Data(contentsOf:"))
        #expect(!executor.contains("performMediaAction"))
        #expect(!executor.contains("MediaOpener"))
        #expect(compactShell.contains("HallieTurnExecutor.execute("))
        #expect(compactShell.contains("dependencies.executeRequest("))
        #expect(compactShell.contains("dependencies.continueTurn("))
        #expect(!shell.contains("ArchivistPresenceExecutor"))
        #expect(!shell.contains("ArchivistTemporalExecutor"))
        #expect(!shell.contains("ArchivistAggregateExecutor"))
        #expect(!shell.contains("ArchivistGraphExecutor"))
    }

    @Test func aNameTypedExactlyAsAProfilesOwnNameIsNeverAmbiguous() async throws {
        // Cycle 4: "show me Timmy as a baby" asked "Did you mean Tim or
        // Timmy?" because Tim's profile lists "Timmy" as an alias.
        let context = HallieTurnExecutor.Context(
            presenceRecords: [],
            profiles: [
                .init(stableID: "tim", canonicalName: "Tim", aliases: ["Timmy", "Timothy"]),
                .init(stableID: "timmy", canonicalName: "Timmy", aliases: []),
            ])
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "show me Timmy",
            ast: .presence(.init(people: ["Timmy"])))
        let result = try await HallieTurnExecutor.execute(.init(intent: intent), context: context)
        #expect(!result.prose.contains("Did you mean"), Comment(rawValue: result.prose))
        #expect(result.clarification == nil)
    }

    @Test func aNameNobodyKnowsIsSearchedAsAPlaceOrWordAndSaysSo() async throws {
        // Cycle 9: "pull up anything from Franklin" — the translator made
        // Franklin a person; nobody by that name exists anywhere, but a
        // folder does.
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            ArchivistPresenceRecordSnapshot(
                fullPath: "/Volumes/X/Franklin/parade.mov",
                directory: "/Volumes/X/Franklin", volumeName: "X",
                inferredDate: nil,
                confirmedPeople: [ConfirmedTag(name: "Donna", confirmedAt: stamp)],
                transcript: nil),
            ArchivistPresenceRecordSnapshot(
                fullPath: "/Volumes/X/Cape/beach.mov",
                directory: "/Volumes/X/Cape", volumeName: "X",
                inferredDate: nil,
                confirmedPeople: [ConfirmedTag(name: "Donna", confirmedAt: stamp)],
                transcript: nil),
        ]
        let context = HallieTurnExecutor.Context(presenceRecords: records, profiles: [
            .init(stableID: "donna", canonicalName: "Donna"),
        ])
        let place = try await HallieTurnExecutor.execute(
            .init(intent: .init(originalQuestion: "pull up anything from Franklin",
                                ast: .presence(.init(people: ["Franklin"])))),
            context: context)
        #expect(place.outcome == .answered, Comment(rawValue: place.prose))
        #expect(place.citations.map(\.filename) == ["parade.mov"])
        #expect(place.basisLine.contains("“Franklin” isn't a person I know, so I searched it as a place or word"))

        // A real person stays a person — and a tagged name with no profile too.
        let person = try await HallieTurnExecutor.execute(
            .init(intent: .init(originalQuestion: "show me Donna",
                                ast: .presence(.init(people: ["Donna"])))),
            context: context)
        #expect(person.citations.count == 2)
        #expect(!person.basisLine.contains("isn't a person I know"))
    }


    @Test func speakerPronounsAreNeverSearchTerms() async throws {
        // Eval ic009 (2026-09-01): "Can you play a video for me?" reached the
        // presence executor as person "me", was demoted to a keyword, and
        // matched 24 directories containing the letters "me".
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            ArchivistPresenceRecordSnapshot(
                fullPath: "/Volumes/X/Media/home.mov",
                directory: "/Volumes/X/Media", volumeName: "X",
                confirmedPeople: [ConfirmedTag(name: "Donna", confirmedAt: stamp)]),
        ]
        let context = HallieTurnExecutor.Context(presenceRecords: records, profiles: [
            .init(stableID: "donna", canonicalName: "Donna"),
        ])
        let asPerson = try await HallieTurnExecutor.execute(
            .init(intent: .init(originalQuestion: "can you play a video for me?",
                                ast: .presence(.init(people: ["me"], mediaKind: .video)))),
            context: context)
        #expect(!asPerson.basisLine.contains("searched it as a place or word"), Comment(rawValue: asPerson.basisLine))
        #expect(asPerson.basisLine.contains("“me” means you or me, not a search word"), Comment(rawValue: asPerson.basisLine))
        #expect(!asPerson.citations.contains { $0.bases.contains { "\($0)".contains("contains me") } })

        let asKeyword = try await HallieTurnExecutor.execute(
            .init(intent: .init(originalQuestion: "show me something of my videos",
                                ast: .presence(.init(people: ["Donna"], keywords: ["my", "me"])))),
            context: context)
        #expect(asKeyword.outcome == .answered, Comment(rawValue: asKeyword.prose))
        #expect(asKeyword.citations.map(\.filename) == ["home.mov"])
        #expect(asKeyword.basisLine.contains("“my”, “me” means you or me"), Comment(rawValue: asKeyword.basisLine))

        var payload = ArchivistQueryAST.Presence(people: ["You", "Donna"], keywords: ["me", "cape"])
        #expect(HallieTurnExecutor.dropSpeakerPronouns(&payload) == ["You", "me"])
        #expect(payload.people == ["Donna"])
        #expect(payload.keywords == ["cape"])
    }


    /// A tiny tree with a Franklin surname and a Goushill — the two names
    /// the live tree used to keep "Franklin" a person and to fuzz "house".
    private func placeGuardTree() -> GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Benjamin /Franklin/
        1 SEX M
        1 BIRT
        2 DATE 1706
        0 @I2@ INDI
        1 NAME Robert /Goushill/
        1 SEX M
        1 BIRT
        2 DATE 1350
        0 TRLR
        """)
    }

    @Test func aNameTheTreeKnowsButNobodyIsTaggedWithFallsBackToPlaceAndFolder() async throws {
        // Eval cs018 (2026-09-01): with the real tree loaded, "Franklin" IS a
        // surname, so cycle 9's demotion never fired and the answer was
        // "no videos tagged with franklin" — while 24 files sat in a folder
        // named Franklin.
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            ArchivistPresenceRecordSnapshot(
                fullPath: "/Volumes/X/Franklin/Franklin_1990_p216.mkv",
                directory: "/Volumes/X/Franklin", volumeName: "X",
                confirmedPeople: [ConfirmedTag(name: "Donna", confirmedAt: stamp)]),
            ArchivistPresenceRecordSnapshot(
                fullPath: "/Volumes/X/Cape/beach.mov",
                directory: "/Volumes/X/Cape", volumeName: "X",
                confirmedPeople: [ConfirmedTag(name: "Donna", confirmedAt: stamp)]),
        ]
        let context = HallieTurnExecutor.Context(
            presenceRecords: records,
            profiles: [.init(stableID: "donna", canonicalName: "Donna")],
            graph: placeGuardTree())
        let place = try await HallieTurnExecutor.execute(
            .init(intent: .init(originalQuestion: "pull up anything from Franklin",
                                ast: .presence(.init(people: ["Franklin"])))),
            context: context)
        #expect(place.outcome == .answered, Comment(rawValue: place.prose))
        #expect(place.citations.map(\.filename) == ["Franklin_1990_p216.mkv"])
        #expect(place.basisLine.contains("no one in the catalog is tagged “Franklin”, so I searched it as a place or word"),
                Comment(rawValue: place.basisLine))

        // Both empty → the honest decline stands, unchanged.
        let nobody = try await HallieTurnExecutor.execute(
            .init(intent: .init(originalQuestion: "pull up anything from Goushill",
                                ast: .presence(.init(people: ["Goushill"])))),
            context: context)
        #expect(nobody.outcome == .declined)
        #expect(nobody.prose.lowercased().hasPrefix("i don't have any videos tagged with goushill yet"), Comment(rawValue: nobody.prose))
        #expect(!nobody.basisLine.contains("searched it as a place or word"))

        // A tagged person with a keyword alongside is never widened.
        let tagged = try await HallieTurnExecutor.execute(
            .init(intent: .init(originalQuestion: "Donna at the parade",
                                ast: .presence(.init(people: ["Donna"], keywords: ["parade"])))),
            context: context)
        #expect(tagged.outcome == .declined)
        #expect(!tagged.basisLine.contains("no one in the catalog is tagged"))
    }

    @Test func theStoryBehindThePlaceHouseIsACatalogSearchNotATreeLookup() async throws {
        // Eval bi013 (2026-09-01): "what's the story behind the Westford
        // house" → graph person "westford house" → "I don't know a
        // “Westford” Goushill" (three Goushills offered).
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            ArchivistPresenceRecordSnapshot(
                fullPath: "/Volumes/X/Christmas2010Westford/Christmas2010_In_Westford.mov",
                directory: "/Volumes/X/Christmas2010Westford", volumeName: "X",
                confirmedPeople: [ConfirmedTag(name: "Donna", confirmedAt: stamp)]),
            ArchivistPresenceRecordSnapshot(
                fullPath: "/Volumes/X/Cape/beach.mov",
                directory: "/Volumes/X/Cape", volumeName: "X",
                confirmedPeople: [ConfirmedTag(name: "Donna", confirmedAt: stamp)]),
        ]
        let context = HallieTurnExecutor.Context(
            presenceRecords: records,
            profiles: [.init(stableID: "donna", canonicalName: "Donna")],
            graph: placeGuardTree())
        let house = try await HallieTurnExecutor.execute(
            .init(intent: .init(originalQuestion: "what's the story behind the Westford house",
                                ast: .graph(.init(people: ["westford house"], operation: .biography)))),
            context: context)
        #expect(house.route == .cross, Comment(rawValue: house.prose))
        #expect(house.outcome == .answered, Comment(rawValue: house.prose))
        #expect(house.citations.map(\.filename) == ["Christmas2010_In_Westford.mov"])
        #expect(house.basisLine.contains("“westford house” is a place or a thing, not a person I know, so I searched the catalog for “westford”"),
                Comment(rawValue: house.basisLine))
        #expect(!house.prose.contains("Goushill"))

        // The same shape with a single token and a trip word.
        let trip = try await HallieTurnExecutor.execute(
            .init(intent: .init(originalQuestion: "tell me about the Westford trip",
                                ast: .graph(.init(people: ["Westford"], operation: .biography)))),
            context: context)
        #expect(trip.route == .cross)
        #expect(trip.citations.map(\.filename) == ["Christmas2010_In_Westford.mov"])

        // A real person's house is still a person question for the tree.
        let person = try await HallieTurnExecutor.execute(
            .init(intent: .init(originalQuestion: "what's the story of the Goushill house",
                                ast: .graph(.init(people: ["Goushill"], operation: .biography)))),
            context: context)
        #expect(person.route == .graph, Comment(rawValue: person.prose))

        // No place word → the guard stays out of the way entirely.
        let plain = try await HallieTurnExecutor.execute(
            .init(intent: .init(originalQuestion: "who is Westford",
                                ast: .graph(.init(people: ["Westford"], operation: .biography)))),
            context: context)
        #expect(plain.route == .graph)
    }
}
