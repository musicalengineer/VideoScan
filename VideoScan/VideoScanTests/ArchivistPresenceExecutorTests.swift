import Foundation
import Testing
@testable import VideoScan

@MainActor
@Suite("Family Archivist deterministic presence executor", .serialized)
struct ArchivistPresenceExecutorTests {
    private let confirmedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(
        _ path: String,
        detected: [String] = [],
        suspected: [String] = [],
        confirmed: [String] = [],
        captions: [(Double, String)] = [],
        transcript: String? = nil,
        streamType: StreamType = .videoAndAudio
    ) -> VideoRecord {
        let value = VideoRecord()
        value.fullPath = path
        value.directory = (path as NSString).deletingLastPathComponent
        value.filename = (path as NSString).lastPathComponent
        value.streamTypeRaw = streamType.rawValue
        value.detectedPeople = detected
        value.suspectedPeople = suspected
        value.confirmedByUserPeople = confirmed.map {
            ConfirmedTag(name: $0, confirmedAt: confirmedAt)
        }
        value.sceneCaptions = captions.map {
            SceneCaption(timestamp: $0.0, text: $0.1)
        }
        value.sceneCaptionModel = captions.isEmpty ? nil : "caption-model"
        value.audioTranscript = transcript
        value.audioTranscriptModel = transcript == nil ? nil : "whisper-model"
        return value
    }

    private func execute(
        _ payload: ArchivistQueryAST.Presence,
        records: [VideoRecord]
    ) async -> ArchivistPresenceResult {
        let snapshots = await ArchivistPresenceRecordSnapshot.capture(records)
        return ArchivistPresenceExecutor.execute(
            ArchivistPresenceQuery(payload),
            records: snapshots)
    }

    @Test func combinedConstraintsReturnCitedDeterministicFact() async throws {
        let matching = record(
            "/Archive/1995/donna.mov", confirmed: ["Donna"],
            captions: [(12.5, "Christmas morning beside the tree")])
        let wrongYear = record(
            "/Archive/2005/donna.mov", confirmed: ["Donna"],
            captions: [(4, "Christmas morning")])
        let wrongPerson = record(
            "/Archive/1995/dan.mov", confirmed: ["Dan"],
            captions: [(7, "Christmas morning")])

        let result = await execute(.init(
            people: ["Donna"], yearStart: 1990, yearEnd: 1999,
            mediaKind: .video, keywords: ["Christmas"]),
            records: [wrongYear, matching, wrongPerson])

        #expect(result.conclusion == .present)
        #expect(result.evidence.totalMatchCount == 1)
        let citation = try #require(result.evidence.citations.first)
        #expect(citation.recordID == matching.id)
        #expect(citation.fullPath == matching.fullPath)
        #expect(citation.playbackSeconds == 12.5)
        #expect(citation.bases.count == 4)
        guard case .humanPersonTag(let identity, let tagged, let date)
            = citation.bases[0] else {
            Issue.record("expected human-confirmed identity basis")
            return
        }
        #expect(identity == "Donna")
        #expect(tagged == "Donna")
        #expect(date == confirmedAt)
        guard case .caption(let term, let timestamp, let text, let model)
            = citation.bases[3] else {
            Issue.record("keyword must cite its actual caption source")
            return
        }
        #expect(term == "Christmas")
        #expect(timestamp == 12.5)
        #expect(text == "Christmas morning beside the tree")
        #expect(model == "caption-model")

        let answer = ArchivistPresenceAnswerComposer.compose(result)
        #expect(answer.prose == "I found 1 catalog item matching that.")
        #expect(answer.evidence == result.evidence)
    }

    @Test func multiwordIdentityCannotBeAssembledAcrossDifferentPeople() async {
        let falseCombination = record(
            "/Archive/false.mov", confirmed: ["Donna Smith", "Joe Breen"])
        let exactIdentity = record(
            "/Archive/true.mov", confirmed: ["Donna Breen"])
        let result = await execute(.init(people: ["Donna Breen"]),
                             records: [falseCombination, exactIdentity])

        #expect(result.evidence.totalMatchCount == 1)
        #expect(result.evidence.citations.map(\.recordID) == [exactIdentity.id])
    }

    @Test func oneConfirmedTagCannotProveTwoIdentities() async {
        let value = record("/Archive/mary-ann.mov", confirmed: ["Mary Ann"])

        let result = await execute(.init(people: ["Ann", "Mary Ann"]),
                                   records: [value])

        #expect(result.conclusion == .noEvidence)
        #expect(result.evidence.totalMatchCount == 0)
    }

    @Test func augmentingPathFindsValidTwoTagAssignment() async throws {
        // A greedy first-match implementation assigns Ann -> Mary Ann and
        // incorrectly strands Mary Ann. Maximum matching reassigns Ann -> Ann.
        let value = record(
            "/Archive/ann-and-mary-ann.mov", confirmed: ["Mary Ann", "Ann"])

        let result = await execute(.init(people: ["Ann", "Mary Ann"]),
                                   records: [value])

        #expect(result.conclusion == .present)
        let bases = try #require(result.evidence.citations.first?.bases)
        #expect(bases.count == 2)
        guard case .humanPersonTag(let firstQuery, let firstTag, _) = bases[0],
              case .humanPersonTag(let secondQuery, let secondTag, _) = bases[1]
        else {
            Issue.record("expected two human-confirmed identity bases")
            return
        }
        #expect(firstQuery == "Ann")
        #expect(firstTag == "Ann")
        #expect(secondQuery == "Mary Ann")
        #expect(secondTag == "Mary Ann")
    }

    @Test func machineNamesWithoutPersistedScoresCannotAssertPresence() async {
        let detected = record("/Archive/detected.mov", detected: ["Donna"])
        let suspected = record("/Archive/suspected.mov", suspected: ["Donna"])
        let result = await execute(.init(people: ["Donna"]),
                             records: [detected, suspected])

        #expect(result.conclusion == .noEvidence)
        #expect(result.evidence.totalMatchCount == 0)
        #expect(result.evidence.citations.isEmpty)
        #expect(ArchivistPresenceAnswerComposer.compose(result).prose
                == "I don't have any videos tagged with Donna yet. Try another spelling or a nickname — or tell me about Donna and I'll remember it.")
    }

    @Test func keywordCitationReportsTranscriptRatherThanGenericMetadata() async throws {
        let value = record(
            "/Archive/party.mov",
            transcript: "Then everybody shouted surprise together")
        let result = await execute(.init(keywords: ["surprise"]), records: [value])
        let basis = try #require(result.evidence.citations.first?.bases.first)
        guard case .transcriptMention(let term, let model) = basis else {
            Issue.record("expected exact transcript provenance")
            return
        }
        #expect(term == "surprise")
        #expect(model == "whisper-model")
    }

    @Test func emptyPayloadAndZeroMatchesDeclineExactly() async {
        let records = [record("/Archive/donna.mov", confirmed: ["Donna"])]

        let empty = await execute(.init(), records: records)
        #expect(empty.conclusion == .insufficientConstraints)
        #expect(ArchivistPresenceAnswerComposer.compose(empty).prose
                == "I need something to look for — a person, a year, a place, or a word. Try “show me Donna in the 90s”.")

        let absent = await execute(.init(people: ["Ellen"]), records: records)
        #expect(absent.conclusion == .noEvidence)
        #expect(absent.evidence.citations.isEmpty)
        #expect(ArchivistPresenceAnswerComposer.compose(absent).prose
                == "I don't have any videos tagged with Ellen yet. Try another spelling or a nickname — or tell me about Ellen and I'll remember it.")
    }

    /// Production sensor: snapshots extracted from real VideoRecord fields
    /// agree with CatalogSearchIndex for authoritative human-tagged records.
    @Test func snapshotExecutorAgreesWithProductionIndexForAuthoritativeData() async {
        let matching = record(
            "/Archive/CapeCod1997/donna.mov", confirmed: ["Donna"],
            captions: [(3, "A picnic on the beach")])
        let wrongKeyword = record(
            "/Archive/CapeCod1997/donna-inside.mov", confirmed: ["Donna"],
            captions: [(4, "Inside the cottage")])
        let records = [wrongKeyword, matching]
        let index = CatalogSearchIndex()
        index.rebuild(records: records)
        let indexedIDs = index.filter(
            records: records,
            query: "people:donna year:1997 beach").map(\.id)

        let query = ArchivistPresenceQuery(.init(
            people: ["Donna"], yearStart: 1997, yearEnd: 1997,
            keywords: ["beach"]))
        let snapshots = await ArchivistPresenceRecordSnapshot.capture(records)
        let result = ArchivistPresenceExecutor.execute(query, records: snapshots)

        #expect(result.evidence.citations.map(\.recordID) == indexedIDs)
        #expect(result.evidence.totalMatchCount == indexedIDs.count)
    }

    @Test func familySearchConvenienceDoesNotBecomePresenceEvidence() async {
        let family = record(
            "/Archive/CapeCod1997/family.mov", detected: ["Family"],
            captions: [(3, "A picnic on the beach")])
        let index = CatalogSearchIndex()
        index.rebuild(records: [family])
        #expect(index.filter(
            records: [family], query: "people:donna year:1997 beach").count == 1)

        let result = await execute(.init(
            people: ["Donna"], yearStart: 1997, yearEnd: 1997,
            keywords: ["beach"]), records: [family])
        #expect(result.conclusion == .noEvidence)
    }

    /// Keyword text is diacritic-folded in EVERY tier (phrase, token, alias),
    /// so an unaccented question still finds an accented file. This is a
    /// deliberate divergence from CatalogSearchIndex, which keeps accents:
    /// Hallie's questions are typed casually, the catalog box is not.
    @Test func keywordAccentsAreFoldedInEveryTier() async {
        let value = record("/Archive/caf\u{00E9}/party.mov")
        let records = [value]
        let index = CatalogSearchIndex()
        index.rebuild(records: records)
        let snapshots = await ArchivistPresenceRecordSnapshot.capture(records)

        let accentedResult = ArchivistPresenceExecutor.execute(
            ArchivistPresenceQuery(.init(keywords: ["caf\u{00E9}"])),
            records: snapshots)
        #expect(accentedResult.evidence.totalMatchCount == 1)
        #expect(index.filter(records: records, query: "caf\u{00E9}").count == 1)

        let plainResult = ArchivistPresenceExecutor.execute(
            ArchivistPresenceQuery(.init(keywords: ["cafe"])),
            records: snapshots)
        #expect(plainResult.evidence.totalMatchCount == 1)
        // The catalog index stays accent-sensitive; the divergence is known.
        #expect(index.filter(records: records, query: "cafe").isEmpty)
    }

    @Test func invertedInMemoryYearRangeFailsClosed() async {
        let value = record("/Archive/1995/party.mov")

        let result = await execute(
            .init(yearStart: 2000, yearEnd: 1990), records: [value])

        #expect(result.conclusion == .insufficientConstraints)
        #expect(result.evidence.totalMatchCount == 0)
        #expect(result.evidence.citations.isEmpty)
    }

    @Test func pathYearMustBeStandaloneFourDigitRun() async {
        let embedded = record("/Archive/reel19999/party.mov")
        let standalone = record("/Archive/reel-1999/party.mov")

        let result = await execute(
            .init(yearStart: 1999, yearEnd: 1999),
            records: [embedded, standalone])

        #expect(result.evidence.totalMatchCount == 1)
        #expect(result.evidence.citations.map(\.recordID) == [standalone.id])
    }

    @Test func bulkCaptureClampsBatchSizeAndPreservesOrder() async {
        let records = (0..<1_025).map { index in
            record("/Archive/capture/\(index).mov")
        }

        let snapshots = await ArchivistPresenceRecordSnapshot.capture(
            records, batchSize: .max)

        #expect(ArchivistPresenceRecordSnapshot.maxCaptureBatchSize == 512)
        #expect(snapshots.map(\.id) == records.map(\.id))
    }

    /// Production-scale responsiveness sensor. Repeating one reference keeps
    /// fixture setup lightweight while exercising all 100k real conversions.
    @Test func oneHundredThousandRecordCaptureYieldsAndIsBudgeted() async {
        let value = record("/Archive/capture/repeated.mov", confirmed: ["Donna"])
        let records = Array(repeating: value, count: 100_000)
        var competingTaskRan = false
        let competingTask = Task { @MainActor in
            competingTaskRan = true
        }

        let started = ContinuousClock.now
        let snapshots = await ArchivistPresenceRecordSnapshot.capture(records)
        let elapsed = ContinuousClock.now - started

        // This assertion fails if capture stops suspending between batches:
        // the already-queued actor task cannot run until capture returns.
        #expect(competingTaskRan)
        await competingTask.value
        #expect(snapshots.count == 100_000)
        #expect(snapshots.first?.id == value.id)
        #expect(snapshots.last?.id == value.id)
        #expect(snapshots.allSatisfy { $0.fullPath == value.fullPath })
        #expect(elapsed < .seconds(2),
                "main-actor snapshot capture took \(elapsed) for 100k records")
    }

    @Test func citationCapPreservesExactCountAndInputOrder() async {
        let records = (0..<40).map { index in
            record(String(format: "/Archive/%03d.mov", 39 - index),
                   confirmed: ["Donna"])
        }
        let result = await execute(.init(people: ["Donna"]), records: records)

        #expect(result.evidence.totalMatchCount == 40)
        #expect(result.evidence.citations.count
                == ArchivistPresenceExecutor.maxCitations)
        #expect(result.evidence.isCitationListTruncated)
        #expect(result.evidence.citations.map(\.recordID)
                == Array(records.prefix(ArchivistPresenceExecutor.maxCitations)).map(\.id))
    }

    @Test func oneHundredThousandRecordExecutionIsOffMainAndBudgeted() async {
        let stamp = ConfirmedTag(name: "Donna", confirmedAt: confirmedAt)
        var snapshots: [ArchivistPresenceRecordSnapshot] = []
        snapshots.reserveCapacity(100_000)
        for index in 0..<100_000 {
            snapshots.append(ArchivistPresenceRecordSnapshot(
                fullPath: "/Archive/scale/clip_\(index).mov",
                confirmedPeople: index.isMultiple(of: 2) ? [stamp] : []))
        }
        let query = ArchivistPresenceQuery(.init(people: ["Donna"]))

        let started = ContinuousClock.now
        let result = await Task.detached {
            ArchivistPresenceExecutor.execute(query, records: snapshots)
        }.value
        let elapsed = ContinuousClock.now - started

        #expect(result.evidence.totalMatchCount == 50_000)
        #expect(result.evidence.citations.count
                == ArchivistPresenceExecutor.maxCitations)
        #expect(elapsed < .seconds(2),
                "detached presence execution took \(elapsed) over 100k snapshots")
    }

    @Test func noEvidenceWordingKeepsMultiWordNamesAndYearSpans() {
        #expect(ArchivistPresenceAnswerComposer.noEvidenceAnswer(
            for: "shape=presence person=Richard Harding Breen Sr")
            == "I don't have any videos tagged with Richard Harding Breen Sr yet. Try another spelling or a nickname — or tell me about Richard Harding Breen Sr and I'll remember it.")
        #expect(ArchivistPresenceAnswerComposer.noEvidenceAnswer(
            for: "shape=presence person=Donna Breen years=1990...1995 keyword=cape cod")
            == "I looked for videos of Donna Breen from 1990–1995 with “cape cod” and found nothing in the catalog. Want me to try without the words, or with a different name?")
    }
}
