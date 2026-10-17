// CatalogTransactionDoorsTests.swift
// The record doors of step C′ part 2b, one by one, read back with a plain
// GRDB queue (this folder may import GRDB): each door writes exactly its
// row; the DDL's refusals come back as a rolled-back write; the relation
// door answers `.alreadyPresent` for a byte-identical copy's edge and
// `.refused` with words where the DDL cannot hold the edge; the finish of
// an import run is refused on lying counters; every commit records the
// files counts in generation_history; the JSON store's reader refuses the
// record readings by name. One condition per #expect.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("CatalogTransaction doors (part 2b)")
struct CatalogTransactionDoorsTests {

    private static let volume = "11111111-1111-1111-1111-111111111111"
    private static let digestA = String(repeating: "a", count: 64)
    private static let digestB = String(repeating: "b", count: 64)
    private static let digestC = String(repeating: "c", count: 64)
    private static let runID = "R-doors"

    private func openFresh() async throws -> (StoreFixture, GRDBCatalogRepository) {
        let fixture = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        let repository = GRDBCatalogRepository(host: "doors-host", durability: .volatileForTests)
        let opened = await repository.open(at: fixture.url)
        try #require(opened == .readWrite)
        return (fixture, repository)
    }

    private func count(_ fixture: StoreFixture, _ sql: String) throws -> Int {
        try DatabaseQueue(path: fixture.url.path).read { try Int.fetchOne($0, sql: sql) ?? 0 }
    }

    private static func importRun() -> CatalogRow.ImportRun {
        CatalogRow.ImportRun(runID: runID, startedAt: 1_700_000_000, sourceSHA256: String(repeating: "d", count: 64),
                             sourceGeneration: 5, integrityRunID: "IR-1", auditRunStartedAt: 1_699_990_000,
                             auditRunFinishedAt: 1_699_990_500, auditGeneration: 5, integrityStartedAt: 1_699_995_000,
                             integrityGeneration: 5)
    }

    private static func content(_ digest: String) -> CatalogRecordDTO.ContentRow {
        CatalogRecordDTO.ContentRow(digest: digest, algorithm: "sha256", byteCount: 100, firstSeenAt: 1_700_000_000, firstSeenHow: .import)
    }

    private static func file(_ id: String, digest: String, path: String, marker: Bool = false) -> CatalogRecordDTO.FileRow {
        CatalogRecordDTO.FileRow(
            id: id, contentDigest: digest, volumeUUID: volume, fullPath: path, pathFold: CatalogRecordDTO.pathFold(path),
            filename: (path as NSString).lastPathComponent, ext: "mov", directory: (path as NSString).deletingLastPathComponent,
            sizeBytes: 100, fsCreatedAt: nil, fsModifiedAt: nil, stampDevice: nil, stampInode: nil, stampMtimeNs: nil,
            stampCtimeNs: nil, stampVolumeUUID: nil, digestComputedAt: 1_700_000_000, digestSource: .archiveFixity,
            sampledHash: nil, sampledHashAt: nil, partialMD5: nil, streamType: "Video+Audio", durationS: 1, container: "mov",
            videoCodec: "", audioCodec: "", embeddedCreatedAt: nil, embeddedCreatedSource: nil, probeExtra: [:],
            scanHost: "", scannedAt: nil, scanRootLabel: "", bundleContainer: "", sourceHost: "", originalFullPath: nil,
            originVolume: nil, machineNotes: "", lifecycle: marker ? "Trashed" : "Cataloged", archiveStage: "None",
            masterLocation: "", setAsideReason: nil, needsReformat: false, workspaceActive: false,
            removalState: marker ? "inTrash" : nil, removalSince: marker ? 1_700_000_100 : nil,
            removalReason: marker ? "catalogTrash" : nil, removalTrashPath: marker ? "/Volumes/A/.Trashes/501/x.mov" : nil,
            removalTrashEmptiedAt: nil, removalLastSeen: nil, removalRevision: marker ? 1 : 0,
            auditSeenVolumeUUID: nil, auditSeenMountFrom: nil, auditSeenDeviceKey: nil, auditSeenAt: nil, cataloguedAt: nil)
    }

    private static let volumeRow = CatalogRecordDTO.VolumeRowDTO(volumeUUID: volume, lastName: "A", mountType: "local", remoteServer: "")

    // MARK: - Files, content, volumes, tombstones, history counts

    @Test func fileContentAndVolumeDoorsWriteTheirRowsAndTheCommitCountsThem() async throws {
        let (fixture, repository) = try await openFresh()
        defer { fixture.remove() }
        let outcome = await repository.write(as: .importRun) { tx in
            try tx.insertVolume(Self.volumeRow, caseSensitive: false)
            try tx.insertContent(Self.content(Self.digestA))
            try tx.insertFile(Self.file("00000000-0000-4000-8000-000000000001", digest: Self.digestA, path: "/Volumes/A/one.mov"), volumeCaseSensitive: false)
            try tx.insertFile(Self.file("00000000-0000-4000-8000-000000000002", digest: Self.digestA, path: "/Volumes/A/two.mov", marker: true), volumeCaseSensitive: false)
        }
        #expect(outcome == .committed(generation: 1))
        await repository.close()
        #expect(try count(fixture, "SELECT count(*) FROM files") == 2)
        #expect(try count(fixture, "SELECT count(*) FROM tombstones WHERE door = 'import' AND revision = 1") == 1)
        #expect(try count(fixture, "SELECT files_live FROM generation_history WHERE generation = 1") == 1)
        #expect(try count(fixture, "SELECT files_total FROM generation_history WHERE generation = 1") == 2)
    }

    @Test func aRowTheDDLRefusesRollsTheWriteBack() async throws {
        let (fixture, repository) = try await openFresh()
        defer { fixture.remove() }
        let outcome = await repository.write(as: .importRun) { tx in
            try tx.insertVolume(Self.volumeRow, caseSensitive: false)
            try tx.insertContent(Self.content(Self.digestA))
            var bad = Self.file("00000000-0000-4000-8000-000000000001", digest: Self.digestA, path: "/Volumes/A/one.mov")
            bad.sizeBytes = 101                                            // files_size_matches_content_ins
            try tx.insertFile(bad, volumeCaseSensitive: false)
        }
        guard case .refused(let reason) = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        #expect(reason.contains("size_bytes differs from content.byte_count"))
        await repository.close()
        #expect(try count(fixture, "SELECT count(*) FROM content") == 0)
    }

    // MARK: - Import runs

    @Test func finishingARunWithLyingCountersIsRefusedByTheTrigger() async throws {
        let (fixture, repository) = try await openFresh()
        defer { fixture.remove() }
        let outcome = await repository.write(as: .importRun) { tx in
            try tx.insertImportRun(Self.importRun())
            try tx.finishImportRun(Self.runID, counters: .init(rowsBefore: 5, rowsMain: 3, rowsQuarantine: 2, digestsSeen: 0, knowledgeRows: 0),
                                   finishedAt: 1_700_000_100)
        }
        guard case .refused(let reason) = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        #expect(reason.contains("import run cannot finish"))
        await repository.close()
        #expect(try count(fixture, "SELECT count(*) FROM import_runs") == 0)
    }

    @Test func anEmptyRunFinishesWithTrueCountersAndTheItemsMap() async throws {
        let (fixture, repository) = try await openFresh()
        defer { fixture.remove() }
        let outcome = await repository.write(as: .importRun) { tx in
            try tx.insertImportRun(Self.importRun())
            try tx.insertJobMarker(CatalogRow.JobMarker(job: .fullHash, scope: "*", startedAt: 1, finishedAt: 2, outcome: .completed,
                                                        generation: 5, detail: .object(["hashedSoFar": .int(1)]), importRun: Self.runID,
                                                        sourceFile: .fullHashBackfill, sourceOrdinal: 0))
            try tx.insertImportItem(CatalogRow.ImportItem(importRun: Self.runID, sourceFile: .fullHashBackfill, sourceOrdinal: 0,
                                                          itemKind: .marker, sourceKey: nil, landedTable: .jobMarkers, landedRef: ""))
            try tx.finishImportRun(Self.runID, counters: .init(rowsBefore: 0, rowsMain: 0, rowsQuarantine: 0, digestsSeen: 0, knowledgeRows: 0),
                                   finishedAt: 1_700_000_100)
        }
        #expect(outcome == .committed(generation: 1))
        await repository.close()
        #expect(try count(fixture, "SELECT comparator_ok FROM import_runs WHERE run_id = 'R-doors'") == 1)
    }

    // MARK: - Quarantine, knowledge, derived, sound prints

    @Test func quarantineKnowledgeAndDerivedDoorsWriteOneRowEach() async throws {
        let (fixture, repository) = try await openFresh()
        defer { fixture.remove() }
        let finding = ImportGate.Finding(tier: 5, rule: "referenceMovie", recordID: "X", words: "a reference movie", needsDecision: true)
        let outcome = await repository.write(as: .importRun) { tx in
            try tx.insertImportRun(Self.importRun())
            try tx.insertContent(Self.content(Self.digestA))
            let qid = try tx.insertQuarantine(CatalogRow.Quarantine(
                importRun: Self.runID, sourceOrdinal: 0, jsonRowID: "00000000-0000-4000-8000-000000000009", fullPath: "/Volumes/A/q.mov",
                sizeBytes: 100, digest: Self.digestA, evidenceDigests: [Self.digestA], sampledHash: nil, reasonCode: .referenceMovie,
                words: finding.words, findings: [finding], rawRow: ["id": .string("00000000-0000-4000-8000-000000000009")],
                quarantinedAt: 1_700_000_000))
            guard qid == 1 else { throw FixtureFailure(words: "qid \(qid)") }
            try tx.insertKnowledgeSource(CatalogRow.KnowledgeSource(
                importRun: Self.runID, sourceOrdinal: 0, jsonRowID: "00000000-0000-4000-8000-000000000009", digest: Self.digestA,
                value: .init(field: .starRating, valueJSON: .int(3), setAt: nil)))
            let derived = CatalogRow.DerivedUnverified(digest: Self.digestA, sourceJSONRowID: "00000000-0000-4000-8000-000000000009",
                                                       importRun: Self.runID, sourceOrdinal: 0,
                                                       value: .init(kind: .scene, seq: 0, valueJSON: .string("a lake"), stampJSON: .object([:])))
            guard try tx.insertDerivedUnverified(derived) else { throw FixtureFailure(words: "first derived insert skipped") }
            guard try !tx.insertDerivedUnverified(derived) else { throw FixtureFailure(words: "second derived insert not skipped") }
            let print = CatalogRecordDTO.SoundPrintRow(digest: Self.digestA, engineVersion: 1, outcome: "noAudio", analyzedS: 0,
                                                       complete: true, landmarks: 0, blobBytes: 0, computedAt: 1)
            guard try tx.insertSoundPrint(print) else { throw FixtureFailure(words: "first print skipped") }
            guard try !tx.insertSoundPrint(print) else { throw FixtureFailure(words: "second print not skipped") }
        }
        #expect(outcome == .committed(generation: 1))
        await repository.close()
        #expect(try count(fixture, "SELECT count(*) FROM quarantine WHERE reason_class = 'finding' AND json_array_length(findings) = 1") == 1)
        #expect(try count(fixture, "SELECT count(*) FROM knowledge_sources WHERE field = 'starRating' AND value_json = '3'") == 1)
        #expect(try count(fixture, "SELECT count(*) FROM derived_unverified") == 1)
        #expect(try count(fixture, "SELECT count(*) FROM sound_prints") == 1)
    }

    // MARK: - Relations

    @Test func theRelationDoorAnswersLandedAlreadyPresentAndRefused() async throws {
        let (fixture, repository) = try await openFresh()
        defer { fixture.remove() }
        let box = LandingBox()
        let outcome = await repository.write(as: .importRun) { tx in
            try tx.insertContent(Self.content(Self.digestA))
            try tx.insertContent(Self.content(Self.digestB))
            try tx.insertContent(Self.content(Self.digestC))
            let trim = CatalogRecordDTO.LineageValue(derivedFrom: "X", derivationKind: "trim", cleanupRecipeID: nil,
                                                     cleanupRecipeVersion: nil, trimInSeconds: 1, trimOutSeconds: 2)
            box.append(try tx.insertRelation(.lineage(childDigest: Self.digestA, parentDigest: Self.digestB, value: trim, recordedAt: nil)))
            box.append(try tx.insertRelation(.lineage(childDigest: Self.digestA, parentDigest: Self.digestB, value: trim, recordedAt: nil)))
            let trimWithoutBounds = CatalogRecordDTO.LineageValue(derivedFrom: "X", derivationKind: "trim", cleanupRecipeID: nil,
                                                                  cleanupRecipeVersion: nil, trimInSeconds: nil, trimOutSeconds: nil)
            box.append(try tx.insertRelation(.lineage(childDigest: Self.digestC, parentDigest: Self.digestB, value: trimWithoutBounds, recordedAt: nil)))
            box.append(try tx.insertRelation(.supersession(retiredDigest: Self.digestA, byDigest: Self.digestB, confirmedAt: nil)))
            box.append(try tx.insertRelation(.supersession(retiredDigest: Self.digestB, byDigest: Self.digestA, confirmedAt: nil)))
            box.append(try tx.insertRelation(.supersession(retiredDigest: Self.digestA, byDigest: Self.digestB, confirmedAt: nil)))
        }
        #expect(outcome == .committed(generation: 1))
        #expect(box.landings == [
            .landed, .alreadyPresent, .refused("a trim edge carries both trim bounds, and only a trim edge does"),
            .landed, .refused("supersession would run in a circle"), .alreadyPresent,
        ])
        await repository.close()
        #expect(try count(fixture, "SELECT count(*) FROM lineage") == 1)
        #expect(try count(fixture, "SELECT count(*) FROM supersessions") == 1)
    }

    @Test func eventMembershipIsLandedOnceAndThenAlreadyPresent() async throws {
        let (fixture, repository) = try await openFresh()
        defer { fixture.remove() }
        let box = LandingBox()
        let outcome = await repository.write(as: .importRun) { tx in
            try tx.insertImportRun(Self.importRun())
            try tx.insertContent(Self.content(Self.digestA))
            try tx.insertEvent(CatalogRow.Event(eventID: "0A1B2C3D-0000-4000-8000-00000000EE01", name: "E", state: "confirmed", categories: [],
                                                note: nil, createdAt: 1, updatedAt: 1, importRun: Self.runID, sourceOrdinal: 0))
            let member = CatalogRow.Relation.eventMembership(eventID: "0A1B2C3D-0000-4000-8000-00000000EE01", digest: Self.digestA,
                                                             rangeStart: nil, rangeEnd: nil, importedKey: Self.digestA)
            box.append(try tx.insertRelation(member))
            box.append(try tx.insertRelation(member))
        }
        #expect(outcome == .committed(generation: 1))
        #expect(box.landings == [.landed, .alreadyPresent])
        await repository.close()
        #expect(try count(fixture, "SELECT count(*) FROM event_members") == 1)
    }

    // MARK: - The JSON store refuses the readings by name

    @Test func theJSONReaderRefusesRecordReadingsByName() async throws {
        let fixture = try await StoreFixture.make(.json, generation: 3)
        defer { fixture.remove() }
        let repository = JSONCatalogRepository()
        _ = await repository.open(at: fixture.url)
        await #expect(throws: CatalogRepositoryError.unsupported("\(JSONCatalogRepository.readOnlyReason); it has no record tables to read")) {
            try await repository.read { try $0.recordCounts() }
        }
        await repository.close()
    }
}

/// Collects relation landings out of a `@Sendable` write body.
private final class LandingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CatalogRow.RelationLanding] = []
    var landings: [CatalogRow.RelationLanding] { lock.withLock { stored } }
    func append(_ landing: CatalogRow.RelationLanding) { lock.withLock { stored.append(landing) } }
}
