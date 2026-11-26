// CatalogHeldBackRowsTests.swift — GH #339: the held-back reading and the one
// resolving door on a real catalog.sqlite, and the raw_row parser.
//   LOGIC     every quarantine row reads back whole (open and resolved); the
//             open count is the unresolved rows; a resolve writes ONLY the
//             resolution columns (`personDecided`, the file, the note);
//   ISOLATION a second resolve says `.alreadyResolved` and changes nothing; a
//             file id the catalog does not hold says `.fileMissing`; a row
//             with integrity findings is refused by the DDL (only
//             `resolvedByRule` closes those) and the write rolls back;
//             poisoned raw_row text (not JSON, not an object, wrong member
//             types, dates this app never writes) is said, never guessed;
//   SCALE     2,110 rows (today's count) read in well under a second.
// Invented fixtures only — no real path or name.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("Held back at import (#339) — the reading and the resolve door")
struct CatalogHeldBackRowsTests {

    private static let volume = "22222222-2222-2222-2222-222222222222"
    private static let digestA = String(repeating: "a", count: 64)
    private static let runID = "R-heldback"
    private static let fileID = "00000000-0000-4000-8000-0000000000F1"

    private func openFresh() async throws -> (StoreFixture, GRDBCatalogRepository) {
        let fixture = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        let repository = GRDBCatalogRepository(host: "heldback-host", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        return (fixture, repository)
    }

    private func query(_ fixture: StoreFixture, _ sql: String) throws -> String? {
        try DatabaseQueue(path: fixture.url.path).read { try String.fetchOne($0, sql: sql) }
    }

    private static func importRun() -> CatalogRow.ImportRun {
        CatalogRow.ImportRun(runID: runID, startedAt: 1_700_000_000, sourceSHA256: String(repeating: "d", count: 64),
                             sourceGeneration: 5, integrityRunID: "IR-1", auditRunStartedAt: 1_699_990_000,
                             auditRunFinishedAt: 1_699_990_500, auditGeneration: 5, integrityStartedAt: 1_699_995_000,
                             integrityGeneration: 5)
    }

    static func quarantine(_ ordinal: Int, digest: String? = nil, findings: [ImportGate.Finding] = [],
                           raw: [String: CatalogJSONValue] = [:]) -> CatalogRow.Quarantine {
        let id = String(format: "00000000-0000-4000-8000-%012d", ordinal)
        var row = raw
        row["id"] = .string(id)
        return CatalogRow.Quarantine(importRun: runID, sourceOrdinal: ordinal, jsonRowID: id,
                                     fullPath: "/Volumes/Invented/clip\(ordinal).mov", sizeBytes: 100, digest: digest,
                                     evidenceDigests: digest.map { [$0] } ?? [], sampledHash: "v1:" + String(repeating: "e", count: 64),
                                     reasonCode: findings.isEmpty ? .removedNoDigest : .tier5Finding, words: "invented words \(ordinal)",
                                     findings: findings, rawRow: row, quarantinedAt: 1_700_000_000)
    }

    private static func fileRow() -> CatalogRecordDTO.FileRow {
        let path = "/Volumes/Invented/moved/clip1.mov"
        return CatalogRecordDTO.FileRow(
            id: fileID, contentDigest: digestA, volumeUUID: volume, fullPath: path, pathFold: CatalogRecordDTO.pathFold(path),
            filename: "clip1.mov", ext: "mov", directory: "/Volumes/Invented/moved",
            sizeBytes: 100, fsCreatedAt: nil, fsModifiedAt: nil, stampDevice: nil, stampInode: nil, stampMtimeNs: nil,
            stampCtimeNs: nil, stampVolumeUUID: nil, digestComputedAt: 1_700_000_000, digestSource: .archiveFixity,
            sampledHash: nil, sampledHashAt: nil, partialMD5: nil, streamType: "Video+Audio", durationS: 1, container: "mov",
            videoCodec: "", audioCodec: "", embeddedCreatedAt: nil, embeddedCreatedSource: nil, probeExtra: [:],
            scanHost: "", scannedAt: nil, scanRootLabel: "", bundleContainer: "", sourceHost: "", originalFullPath: nil,
            originVolume: nil, machineNotes: "", lifecycle: "Cataloged", archiveStage: "None",
            masterLocation: "", setAsideReason: nil, needsReformat: false, workspaceActive: false,
            removalState: nil, removalSince: nil, removalReason: nil, removalTrashPath: nil,
            removalTrashEmptiedAt: nil, removalLastSeen: nil, removalRevision: 0,
            auditSeenVolumeUUID: nil, auditSeenMountFrom: nil, auditSeenDeviceKey: nil, auditSeenAt: nil, cataloguedAt: nil)
    }

    /// A run, one live file, and rows 1 (plain), 2 (with a finding).
    private func seeded() async throws -> (StoreFixture, GRDBCatalogRepository) {
        let (fixture, repository) = try await openFresh()
        let finding = ImportGate.Finding(tier: 5, rule: "referenceMovie", recordID: "X", words: "a reference movie", needsDecision: true)
        let outcome = await repository.write(as: .importRun) { tx in
            try tx.insertImportRun(Self.importRun())
            try tx.insertVolume(.init(volumeUUID: Self.volume, lastName: "Invented", mountType: "local", remoteServer: ""), caseSensitive: false)
            try tx.insertContent(.init(digest: Self.digestA, algorithm: "sha256", byteCount: 100, firstSeenAt: 1_700_000_000, firstSeenHow: .import))
            try tx.insertFile(Self.fileRow(), volumeCaseSensitive: false)
            _ = try tx.insertQuarantine(Self.quarantine(1, raw: ["mediaDisposition": .string("Important"), "userDate": .string("1992")]))
            _ = try tx.insertQuarantine(Self.quarantine(2, digest: Self.digestA, findings: [finding]))
        }
        try #require(outcome == .committed(generation: 1))
        return (fixture, repository)
    }

    private func rows(_ repository: GRDBCatalogRepository) async throws -> [CatalogRow.HeldBackRow] {
        try await repository.read { reader in
            var out: [CatalogRow.HeldBackRow] = []
            try reader.heldBackRows { out.append($0) }
            return out
        }
    }

    @Test func everyRowReadsBackWholeAndTheOpenCountIsTheUnresolvedRows() async throws {
        let (fixture, repository) = try await seeded()
        defer { fixture.remove() }
        let read = try await rows(repository)
        #expect(read.map(\.qid) == [1, 2])
        #expect(read[0].fullPath == "/Volumes/Invented/clip1.mov")
        #expect(read[0].reasonCode == "removedNoDigest")
        #expect(read[0].findingsCount == 0)
        #expect(read[1].findingsCount == 1)
        #expect(read[1].digest == Self.digestA)
        #expect(read[0].sampledHash?.hasPrefix("v1:") == true)
        guard case .read(let curated) = HeldBackCurated.parse(read[0].rawRowText) else { Issue.record("raw row not read"); return }
        #expect(curated.disposition == .important)
        #expect(curated.userDate == "1992")
        #expect(try await repository.read { try $0.heldBackOpenCount() } == 2)
        await repository.close()
    }

    @Test func aResolveWritesOnlyTheResolutionColumnsAndASecondSaysAlreadyResolved() async throws {
        let (fixture, repository) = try await seeded()
        defer { fixture.remove() }
        let evidenceBefore = try query(fixture, "SELECT raw_row || words || reason_code FROM quarantine WHERE qid = 1")
        let box = LandingsBox()
        let outcome = await repository.write(as: .importCarry) { tx in
            box.append(try tx.resolveHeldBack(.init(qid: 1, fileID: Self.fileID, note: "carried tag Important", resolvedAt: 1_800_000_000)))
            box.append(try tx.resolveHeldBack(.init(qid: 1, fileID: Self.fileID, note: "again", resolvedAt: 1_800_000_001)))
            box.append(try tx.resolveHeldBack(.init(qid: 99, fileID: Self.fileID, note: "none", resolvedAt: 1_800_000_001)))
        }
        #expect(outcome == .committed(generation: 2))
        #expect(box.landings == [.resolved, .alreadyResolved, .missing])
        #expect(try await repository.read { try $0.heldBackOpenCount() } == 1)
        let after = try await rows(repository)
        #expect(after[0].resolution == "personDecided")
        #expect(after[0].resolvedFileID == Self.fileID)
        #expect(after[0].resolutionNote == "carried tag Important")
        #expect(after[0].resolvedAt == 1_800_000_000)
        await repository.close()
        #expect(try query(fixture, "SELECT raw_row || words || reason_code FROM quarantine WHERE qid = 1") == evidenceBefore)
        #expect(try query(fixture, "SELECT writer FROM generation_history WHERE generation = 2") == "import carry")
    }

    @Test func ISOLATION_aFileTheCatalogDoesNotHoldIsRefusedAndNothingIsWritten() async throws {
        let (fixture, repository) = try await seeded()
        defer { fixture.remove() }
        let box = LandingsBox()
        _ = await repository.write(as: .importCarry) { tx in
            box.append(try tx.resolveHeldBack(.init(qid: 1, fileID: "00000000-0000-4000-8000-0000000000AA", note: "x", resolvedAt: 1)))
        }
        #expect(box.landings == [.fileMissing])
        #expect(try await repository.read { try $0.heldBackOpenCount() } == 2)
        await repository.close()
    }

    @Test func ISOLATION_aRowWithAnIntegrityFindingIsRefusedByTheDDLAndTheWriteRollsBack() async throws {
        let (fixture, repository) = try await seeded()
        defer { fixture.remove() }
        let outcome = await repository.write(as: .importCarry) { tx in
            _ = try tx.resolveHeldBack(.init(qid: 1, fileID: Self.fileID, note: "first", resolvedAt: 1))
            _ = try tx.resolveHeldBack(.init(qid: 2, fileID: Self.fileID, note: "has a finding", resolvedAt: 1))
        }
        guard case .refused = outcome else { Issue.record("expected the DDL to refuse, got \(outcome)"); return }
        #expect(try await repository.read { try $0.heldBackOpenCount() } == 2, "row 1's resolve rolled back with the refusal")
        await repository.close()
    }

    @Test(.tags(.quietMachine)) func SCALE_twoThousandRowsReadInUnderASecond() async throws {
        let (fixture, repository) = try await openFresh()
        defer { fixture.remove() }
        let outcome = await repository.write(as: .importRun) { tx in
            try tx.insertImportRun(Self.importRun())
            for i in 0..<2_110 {
                _ = try tx.insertQuarantine(Self.quarantine(i, raw: ["mediaDisposition": .string("Important"), "filename": .string("clip\(i).mov")]))
            }
        }
        try #require(outcome == .committed(generation: 1))
        let clock = ContinuousClock()
        let start = clock.now
        let read = try await rows(repository)
        var parsed = 0
        for row in read { if case .read = HeldBackCurated.parse(row.rawRowText) { parsed += 1 } }
        let elapsed = clock.now - start
        #expect(read.count == 2_110)
        #expect(parsed == 2_110)
        #expect(elapsed < .seconds(1), "read + parse took \(elapsed)")
        await repository.close()
    }
}

final class LandingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CatalogRow.HeldBackLanding] = []
    var landings: [CatalogRow.HeldBackLanding] { lock.withLock { stored } }
    func append(_ l: CatalogRow.HeldBackLanding) { lock.withLock { stored.append(l) } }
}

@Suite("Held back at import (#339) — the old record, poisoned or whole")
struct HeldBackCuratedTests {

    @Test func aWholeRecordReadsItsCuratedMembers() {
        let text = #"{"filename":"clip.mov","mediaDisposition":"Confirmed Junk","userDate":"1992-06","userDateConfidence":"known","userPlace":"Cape Cod","userPlaceConfidence":"estimated","starRating":2,"userNotes":"lake","tags":["a","b"]}"#
        guard case .read(let c) = HeldBackCurated.parse(text) else { Issue.record("not read"); return }
        #expect(c.filename == "clip.mov")
        #expect(c.disposition == .confirmedJunk)
        #expect(c.userDate == "1992-06")
        #expect(c.userDateConfidence == "known")
        #expect(c.userPlace == "Cape Cod")
        #expect(c.starRating == 2)
        #expect(c.hasUserNotes)
        #expect(c.tagCount == 2)
        #expect(c.problems.isEmpty)
        #expect(c.carriesCuratedValue)
    }

    @Test(arguments: ["{not json", "[1,2,3]", "\"a string\"", "null", "42"])
    func ISOLATION_textThatIsNotARecordIsUnreadableWithWords(_ text: String) {
        guard case .unreadable(let words) = HeldBackCurated.parse(text) else { Issue.record("\(text) was read as a record"); return }
        #expect(!words.isEmpty)
    }

    @Test func ISOLATION_noRawRowIsUnreadable() {
        #expect(HeldBackCurated.parse(nil) == .unreadable("the import kept no record for this row"))
    }

    @Test func ISOLATION_wrongTypesAndForeignValuesAreProblemsNeverValues() {
        let text = #"{"mediaDisposition":42,"userDate":"June-ish 92","userPlace":{"a":1},"starRating":"lots","userNotes":7,"tags":"x","filename":["no"]}"#
        guard case .read(let c) = HeldBackCurated.parse(text) else { Issue.record("not read"); return }
        #expect(c.disposition == nil)
        #expect(c.userDate == nil)
        #expect(c.userPlace == nil)
        #expect(c.starRating == 0)
        #expect(!c.hasUserNotes)
        #expect(c.tagCount == 0)
        #expect(c.filename == nil)
        #expect(c.problems.count == 7, "\(c.problems)")
        #expect(!c.carriesCuratedValue)
    }

    @Test func ISOLATION_anUnknownTagIsAProblem() {
        guard case .read(let c) = HeldBackCurated.parse(#"{"mediaDisposition":"Keeper"}"#) else { Issue.record("not read"); return }
        #expect(c.disposition == nil)
        #expect(c.problems == ["tag \"Keeper\" is not a tag this app knows"])
    }

    @Test func aDateConfidenceWithoutADateIsIgnored() {
        guard case .read(let c) = HeldBackCurated.parse(#"{"userDateConfidence":"known"}"#) else { Issue.record("not read"); return }
        #expect(c.userDateConfidence == nil)
    }
}
