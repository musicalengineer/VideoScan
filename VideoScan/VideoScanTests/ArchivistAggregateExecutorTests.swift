import Foundation
import Testing
@testable import VideoScan

@MainActor
@Suite("Family Archivist deterministic aggregate executor", .serialized)
struct ArchivistAggregateExecutorTests {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private var identities: ArchivistAggregateIdentityCatalog {
        ArchivistAggregateIdentityCatalog(identities: [
            .init(stableID: "donna", canonicalName: "Donna Breen",
                  aliases: ["Donna", "Mom"]),
            .init(stableID: "dan", canonicalName: "Dan Breen",
                  aliases: ["Dan"]),
            .init(stableID: "ellen", canonicalName: "Ellen Breen",
                  aliases: ["Ellen"]),
            .init(stableID: "matt", canonicalName: "Matt Breen",
                  aliases: ["Matt", "Matty", "shared"]),
            .init(stableID: "tim", canonicalName: "Tim Breen",
                  aliases: ["Tim", "shared"]),
            .init(stableID: "family", canonicalName: "Family"),
            .init(stableID: "pat-neighbor", canonicalName: "Pat (neighbor)",
                  source: .explicitConfirmedTag),
        ])
    }

    private func snapshot(
        _ path: String,
        _ names: [String],
        playable: Bool = true,
        id: UUID = UUID()
    ) -> ArchivistAggregateRecordSnapshot {
        ArchivistAggregateRecordSnapshot(
            id: id, fullPath: path, isPlayable: playable,
            confirmedPeople: names.map {
                ConfirmedTag(name: $0, confirmedAt: stamp)
            })
    }

    private func execute(
        anchors: [String] = ["Donna"],
        limit: Int? = nil,
        records: [ArchivistAggregateRecordSnapshot]
    ) -> ArchivistAggregateResult {
        ArchivistAggregateExecutor.execute(
            .init(.init(operation: .coOccurrence,
                        anchorPeople: anchors, limit: limit)),
            records: records,
            identities: identities)
    }

    @Test func authoritativeTagsOnlyAndDuplicateAliasesCountOneRecord() {
        let record = snapshot("/Archive/a.mov", [
            "Donna", "MOM", "Dan", "dan", "Family",
        ])
        let result = execute(records: [record])

        #expect(result.conclusion == .ranked)
        #expect(result.rankings.map(\.identity.stableID) == ["dan"])
        #expect(result.rankings.first?.recordCount == 1)
        #expect(result.rankings.first?.sampleCitations.first?.bases.count == 2)
    }

    @Test func aliasesCollapseToStableIdentityAndCaseIsFolded() {
        let result = execute(records: [
            snapshot("/Archive/a.mov", ["mom", "Matty"]),
            snapshot("/Archive/b.mov", ["DONNA", "Matt"]),
        ])

        #expect(result.rankings.count == 1)
        #expect(result.rankings[0].identity.stableID == "matt")
        #expect(result.rankings[0].identity.canonicalName == "Matt Breen")
        #expect(result.rankings[0].recordCount == 2)
    }

    @Test func ambiguousAliasMakesRelevantEvidenceIncomplete() {
        let result = execute(records: [
            snapshot("/Archive/a.mov", ["Donna", "shared", "Dan"]),
        ])

        #expect(result.conclusion == .incompleteIdentityEvidence(
            ambiguousAliases: ["shared"], unknownTagSamples: []))
        #expect(result.rankings.isEmpty)
        #expect(result.excludedAmbiguousAliases == ["shared"])
        #expect(result.factualAnswer.prose.contains("can't rank"))
    }

    @Test func ambiguousAnchorDeclinesRatherThanGuessing() {
        let result = execute(anchors: ["shared"], records: [
            snapshot("/Archive/a.mov", ["shared", "Dan"]),
        ])

        #expect(result.conclusion == .ambiguousAnchors([.init(
            queriedName: "shared",
            candidates: ["Matt Breen", "Tim Breen"])]))
        #expect(result.rankings.isEmpty)
        #expect(result.factualAnswer.prose
                == "Which person did you mean by shared: Matt Breen or Tim Breen?")
    }

    @Test func stableIdentityReuseCannotSatisfyTwoAnchorGroups() {
        let result = execute(anchors: ["Donna", "Mom"], records: [
            snapshot("/Archive/a.mov", ["Donna", "Mom", "Dan"]),
        ])

        #expect(result.conclusion == .noEvidence)
        #expect(result.rankings.isEmpty)
    }

    @Test func multipleDistinctAnchorsRequireOneTagForEachAndAreExcluded() {
        let result = execute(anchors: ["Donna", "Dan"], records: [
            snapshot("/Archive/only-donna.mov", ["Donna", "Ellen"]),
            snapshot("/Archive/all.mov", ["Donna", "Dan", "Ellen"]),
        ])

        #expect(result.rankings.map(\.identity.stableID) == ["ellen"])
        #expect(result.rankings.first?.recordCount == 1)
    }

    @Test func rankingUsesCountThenCanonicalNameAndHonorsLimit() {
        let result = execute(limit: 2, records: [
            snapshot("/Archive/1.mov", ["Donna", "Tim", "Matt", "Dan"]),
            snapshot("/Archive/2.mov", ["Donna", "Matt", "Dan"]),
            snapshot("/Archive/3.mov", ["Donna", "Tim"]),
        ])

        #expect(result.rankings.map(\.identity.canonicalName)
                == ["Dan Breen", "Matt Breen"])
        #expect(result.rankings.map(\.recordCount) == [2, 2])
        #expect(result.appliedLimit == 2)
        #expect(!result.usedDefaultLimit)
    }

    @Test func nilLimitUsesVisibleTopTenDefault() {
        let result = execute(records: [])

        #expect(ArchivistAggregateExecutor.defaultLimit == 10)
        #expect(result.appliedLimit == 10)
        #expect(result.usedDefaultLimit)
        #expect(result.interpretedQuery.contains("limit=10 (default)"))
    }

    @Test func directInvalidLimitFailsClosed() {
        let result = execute(limit: 101, records: [
            snapshot("/Archive/a.mov", ["Donna", "Dan"]),
        ])

        #expect(result.conclusion == .invalidLimit(101))
        #expect(result.rankings.isEmpty)
        #expect(result.factualAnswer.prose
                == "The requested result limit must be between 1 and 100.")
    }

    @Test func emptyAndUnresolvedAnchorsHaveSpecificDeclines() {
        let empty = execute(anchors: [], records: [])
        #expect(empty.conclusion == .emptyAnchors)
        #expect(empty.factualAnswer.prose
                == "I need at least one person to compare co-appearances.")

        let unknown = execute(anchors: ["Nobody Known"], records: [])
        #expect(unknown.conclusion == .unresolvedAnchors(["Nobody Known"]))
        #expect(unknown.factualAnswer.prose
                == "I couldn't resolve the anchor Nobody Known.")
    }

    @Test func oversizedInProcessQueryFailsBeforeScanningOneHundredThousandRecords() {
        let anchors = Array(repeating: "Donna", count: 100_000)
        let record = snapshot("/Archive/never-scanned.mov", ["Donna", "Dan"])
        let records = Array(repeating: record, count: 100_000)

        let started = ContinuousClock.now
        let result = execute(anchors: anchors, records: records)
        let elapsed = ContinuousClock.now - started

        #expect(result.conclusion == .tooManyAnchors(
            count: 100_000, limit: ArchivistQueryAST.maxListItems))
        #expect(result.rankings.isEmpty)
        #expect(result.factualAnswer.prose
                == "I can compare at most 6 anchor people at once.")
        #expect(elapsed < .milliseconds(100),
                "oversized aggregate query took \(elapsed) instead of failing fast")
    }

    @Test func unresolvedRelevantTagsSuppressAFalseMostWinner() {
        var records = (0..<100).map { index in
            snapshot("/Archive/unresolved-\(index).mov", [
                "Donna", index.isMultiple(of: 2) ? "shared" : "Mystery Person",
            ])
        }
        records.append(snapshot("/Archive/dan-once.mov", ["Donna", "Dan"]))
        // An unresolved tag outside the anchor evidence set is irrelevant.
        records.append(snapshot("/Archive/not-donna.mov", ["Other Unknown"]))

        let result = execute(records: records)

        #expect(result.conclusion == .incompleteIdentityEvidence(
            ambiguousAliases: ["shared"],
            unknownTagSamples: ["mystery person"]))
        #expect(result.rankings.isEmpty)
        #expect(result.excludedAmbiguousAliases == ["shared"])
        #expect(result.excludedUnknownTagSamples == ["mystery person"])
        #expect(result.factualAnswer.prose
                == "I can't rank co-appearances until the confirmed person tags "
                    + "with unresolved identities are clarified.")
    }

    @Test func unresolvedTagsOutsideAnchorMatchesDoNotSuppressRanking() {
        let result = execute(records: [
            snapshot("/Archive/relevant.mov", ["Donna", "Dan"]),
            snapshot("/Archive/irrelevant.mov", ["Other Unknown"]),
        ])

        #expect(result.conclusion == .ranked)
        #expect(result.rankings.map(\.identity.stableID) == ["dan"])
        #expect(result.excludedUnknownTagSamples.isEmpty)
    }

    @Test func noEvidenceReturnsExactFactualDecline() {
        let result = execute(records: [
            snapshot("/Archive/a.mov", ["Donna"]),
        ])

        #expect(result.conclusion == .noEvidence)
        #expect(result.factualAnswer.prose == "I don't have evidence for that.")
        #expect(result.factualAnswer.rankings.isEmpty)
    }

    @Test func citationsPreferPlayableThenPathAndCarryExactTagProvenance() throws {
        let laterID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let firstID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let result = execute(records: [
            snapshot("/Archive/z.mov", ["Donna", "Dan"],
                     playable: false),
            snapshot("/Archive/b.mov", ["Mom", "Dan"], id: laterID),
            snapshot("/Archive/a.mov", ["Donna", "Dan"], id: firstID),
            snapshot("/Archive/c.mov", ["Donna", "Dan"]),
        ])
        let rank = try #require(result.rankings.first)

        #expect(rank.recordCount == 4)
        #expect(rank.sampleCitations.count
                == ArchivistAggregateExecutor.maxSampleCitationsPerPerson)
        #expect(rank.sampleCitations.map(\.fullPath)
                == ["/Archive/a.mov", "/Archive/b.mov", "/Archive/c.mov"])
        #expect(rank.sampleCitations.allSatisfy { $0.isPlayable })
        let bases = try #require(rank.sampleCitations.first?.bases)
        guard case .humanPersonTag(let anchor, let anchorTag, let anchorDate)
                = bases[0],
              case .humanPersonTag(let coPerson, let coTag, let coDate)
                = bases[1] else {
            Issue.record("expected exact human-confirmed provenance")
            return
        }
        #expect(anchor == "Donna")
        #expect(anchorTag == "Donna")
        #expect(anchorDate == stamp)
        #expect(coPerson == "Dan Breen")
        #expect(coTag == "Dan")
        #expect(coDate == stamp)
    }

    @Test func explicitUnknownIdentityIsRepresentedHonestly() {
        let result = execute(records: [
            snapshot("/Archive/a.mov", ["Donna", "Pat (neighbor)"]),
        ])

        #expect(result.rankings.first?.identity.source == .explicitConfirmedTag)
        #expect(result.rankings.first?.identity.canonicalName == "Pat (neighbor)")
    }

    /// Isolation sensor: all identity state is injected. No profiles,
    /// UserDefaults, shared caches, or real catalog paths are consulted.
    @Test func injectedCatalogControlsResolution() {
        let isolated = ArchivistAggregateIdentityCatalog(identities: [
            .init(stableID: "x", canonicalName: "X", aliases: ["Donna"]),
            .init(stableID: "y", canonicalName: "Y", aliases: ["Dan"]),
        ])
        let result = ArchivistAggregateExecutor.execute(
            .init(.init(operation: .coOccurrence,
                        anchorPeople: ["Donna"])),
            records: [snapshot("/poisoned/path.mov", ["Donna", "Dan"])],
            identities: isolated)

        #expect(result.anchorIdentities.map(\.stableID) == ["x"])
        #expect(result.rankings.map(\.identity.stableID) == ["y"])
    }

    /// Production sensor: the detached snapshot reads the real VideoRecord
    /// confirmed-tag and playability fields, never detected/suspected names.
    @Test func productionVideoRecordSnapshotUsesConfirmedTagsOnly() async {
        let record = VideoRecord()
        record.fullPath = "/Archive/production.mov"
        record.filename = "production.mov"
        record.isPlayable = "Yes"
        record.detectedPeople = ["Ellen"]
        record.suspectedPeople = ["Tim"]
        record.confirmedByUserPeople = [
            ConfirmedTag(name: "Donna", confirmedAt: stamp),
            ConfirmedTag(name: "Dan", confirmedAt: stamp),
        ]

        let snapshots = await ArchivistAggregateRecordSnapshot.capture([record])
        let result = ArchivistAggregateExecutor.execute(
            .init(.init(operation: .coOccurrence,
                        anchorPeople: ["Donna"])),
            records: snapshots, identities: identities)

        #expect(result.rankings.map(\.identity.stableID) == ["dan"])
        #expect(result.rankings.first?.sampleCitations.first?.isPlayable == true)
    }

    /// Production-scale snapshot-bridge sensor. Reusing one lightweight
    /// VideoRecord keeps fixture setup bounded while exercising every one of
    /// the 100k real conversions and the bridge's MainActor yield points.
    @Test func oneHundredThousandRecordCaptureYieldsAndIsBudgeted() async {
        let record = VideoRecord()
        record.fullPath = "/Archive/capture/repeated.mov"
        record.filename = "repeated.mov"
        record.isPlayable = "Yes"
        record.confirmedByUserPeople = [
            ConfirmedTag(name: "Donna", confirmedAt: stamp),
        ]
        let records = Array(repeating: record, count: 100_000)
        var competingTaskRan = false
        let competingTask = Task { @MainActor in
            competingTaskRan = true
        }

        let started = ContinuousClock.now
        let snapshots = await ArchivistAggregateRecordSnapshot.capture(records)
        let elapsed = ContinuousClock.now - started

        // If capture stops yielding between bounded batches, this already-
        // queued actor task cannot run until after capture returns.
        #expect(competingTaskRan)
        await competingTask.value
        #expect(snapshots.count == 100_000)
        #expect(snapshots.first?.id == record.id)
        #expect(snapshots.last?.id == record.id)
        #expect(snapshots.allSatisfy { $0.fullPath == record.fullPath })
        #expect(elapsed < .seconds(2),
                "main-actor aggregate capture took \(elapsed) for 100k records")
    }

    @Test func oneHundredThousandDetachedRecordsFinishUnderTwoSeconds() async {
        let tags = [
            ConfirmedTag(name: "Donna", confirmedAt: stamp),
            ConfirmedTag(name: "Dan", confirmedAt: stamp),
            ConfirmedTag(name: "dan", confirmedAt: stamp),
        ]
        let repeated = ArchivistAggregateRecordSnapshot(
            fullPath: "/Archive/scale.mov", confirmedPeople: tags)
        let records = Array(repeating: repeated, count: 100_000)
        let query = ArchivistAggregateQuery(.init(
            operation: .coOccurrence, anchorPeople: ["Donna"]))
        let catalog = identities

        let started = ContinuousClock.now
        let result = await Task.detached {
            ArchivistAggregateExecutor.execute(
                query, records: records, identities: catalog)
        }.value
        let elapsed = ContinuousClock.now - started

        #expect(result.rankings.first?.recordCount == 100_000)
        #expect(result.rankings.first?.sampleCitations.count
                == ArchivistAggregateExecutor.maxSampleCitationsPerPerson)
        #expect(elapsed < .seconds(2),
                "detached aggregate execution took \(elapsed) for 100k records")
    }
}
