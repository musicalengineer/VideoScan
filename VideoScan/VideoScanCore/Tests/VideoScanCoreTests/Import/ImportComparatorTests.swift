// ImportComparatorTests.swift
// The comparator (contract §f "Comparator", brief deliverable 3): a clean pair
// passes, and each miss class is caught and named — a dropped row, a dropped
// digest, a dropped curated value, a dropped event member, a duplicate
// landing — plus the sidecar classes. Codex D′ #1 (2026-10-17): IDENTITY
// too — a landing on another row's id or digest, a value bound to another
// row or digest, a cleared or padded membership, a sidecar row whose payload
// differs. Built on the poisoned fixture, so the clean pair is what a
// correct importer would write for it. One condition per #expect.

import Foundation
import Testing
@testable import VideoScanCore

/// A "correct importer" in miniature: what SQLite would hold for the fixture
/// if every occurrence landed where the gate says.
private enum Clean {

    static let run = "R-compare"
    static let healthyDigest = PoisonedCatalogFixture.digest("healthy")
    static let resolved = ImportComparator.ResolvedMember(eventID: PoisonedCatalogFixture.eventOneID, digest: healthyDigest)
    static let listed = ImportComparator.EventMember(eventID: PoisonedCatalogFixture.eventOneID, key: "id:" + PoisonedCatalogFixture.id(.sampledOnly))
    static let marker = ImportComparator.MarkerKey(sourceFile: .catalogAudit, ordinal: 0, fileSHA256: "h")

    static func ledger(_ ordinal: Int) -> CatalogRow.Ledger {
        CatalogRow.Ledger(at: 0, kind: "dateSet", actor: "rick", recordID: "", contentKey: "", digest: nil, path: "",
                          payload: .object(["event": .string("dateSet"), "n": .int(Int64(ordinal))]), importRun: run, sourceOrdinal: ordinal)
    }

    static func decision(_ ordinal: Int) -> CatalogRow.EventDecision {
        CatalogRow.EventDecision(kind: "member", payload: .object(["kind": .string("member"), "n": .int(Int64(ordinal))]),
                                 importRun: run, sourceOrdinal: ordinal)
    }

    static func event(_ ordinal: Int) -> CatalogRow.Event {
        CatalogRow.Event(eventID: PoisonedCatalogFixture.eventOneID, name: "Matt's birthday", state: "confirmed", categories: [],
                         note: nil, createdAt: 1, updatedAt: 1, importRun: run, sourceOrdinal: ordinal)
    }

    static func ignored(_ ordinal: Int) -> CatalogRow.Ignored {
        CatalogRow.Ignored(entryID: "0A1B2C3D-0000-4000-8000-00000000CC01", importRun: run, sourceOrdinal: ordinal, partialMD5: "",
                           sizeBytes: 1, filename: "junk.mov", reason: "junk", addedAt: 0, samplePath: "/j")
    }

    static func audit(_ ordinal: Int, accepted: Bool = true) -> CatalogRow.AuditResult {
        CatalogRow.AuditResult(importRun: run, sourceOrdinal: ordinal, jsonRowID: PoisonedCatalogFixture.id(.healthy), result: .gone,
                               detail: .object([:]), judgedPath: "/V/a.mov", rowFullPath: "/V/a.mov", rowAuditSeenAt: nil, accepted: accepted)
    }

    static func pair() throws -> (json: ImportComparator.JSONSide, sqlite: ImportComparator.SQLiteSide) {
        let fixture = try ImportTestSupport.fixtureRun()
        // The JSON side is re-decoded independently, from the bytes.
        var rows = ImportComparator.JSONSide.occurrences(from: try CatalogFileJSON.decode(fixture.fixture.catalogData))
        ImportComparator.JSONSide.expectLandings(&rows, evidence: fixture.audit.evidenceByID(), window: fixture.audit.window,
                                                 findings: fixture.report.findingsByRecord())
        var files: [ImportComparator.FileLanding] = []
        var quarantine: [ImportComparator.QuarantineLanding] = []
        var raws: [Int: [String: CatalogJSONValue]] = [:]
        var knowledge: [ImportComparator.KnowledgeKey] = []
        var derived = Set<ImportComparator.DerivedKey>()
        for row in rows {
            let dto = fixture.dtos[row.ordinal]
            if row.expected?.table == .files {
                files.append(.init(ordinal: row.ordinal, fileID: dto.file.id, digest: dto.digestState.digest))
            } else {
                quarantine.append(.init(ordinal: row.ordinal, jsonRowID: dto.file.id, digest: dto.digestState.digest))
                raws[row.ordinal] = dto.raw
            }
            for k in dto.knowledgeSources {
                knowledge.append(.init(ordinal: row.ordinal, field: k.field, valueJSON: k.valueJSON, jsonRowID: dto.file.id,
                                       digest: row.boundDigest))
            }
            if let digest = row.boundDigest {
                for d in dto.derivedUnverified {
                    derived.insert(.init(digest: digest, kind: d.kind, seq: d.seq, sourceJSONRowID: dto.file.id))
                }
            }
        }
        let digests = Set(rows.compactMap(\.boundDigest))
        let json = ImportComparator.JSONSide(
            rows: rows, events: [event(0)], eventDecisions: [decision(1), decision(2)], resolvedMembers: [resolved],
            listedMembers: [listed], ledgerLines: [ledger(0), ledger(1), ledger(2)], ignoredEntries: [ignored(0)],
            markers: [marker], auditResults: [audit(1)], personSearchOrdinals: [0])
        let sqlite = ImportComparator.SQLiteSide(
            fileLandings: files, quarantineLandings: quarantine, quarantineRawRows: raws, contentDigests: digests,
            knowledgeSources: knowledge, derivedUnverified: derived, soundPrintDigests: [],
            events: [event(0)], eventDecisions: [decision(1), decision(2)], eventMembers: [resolved],
            listedMemberKeys: [listed.key], ledgerLines: [ledger(0), ledger(1), ledger(2)], ignoredEntries: [ignored(0)],
            markers: [marker], auditResults: [audit(1)], personSearchOrdinals: [0])
        return (json, sqlite)
    }

    static func ordinal(_ shape: PoisonedCatalogFixture.Shape) throws -> Int {
        try #require(PoisonedCatalogFixture().ordinals(of: shape).first)
    }
}

@Suite("Import comparator — clean pair and every miss class")
struct ImportComparatorTests {

    @Test func aCleanPairPasses() throws {
        let (json, sqlite) = try Clean.pair()
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .ok)
    }

    @Test func theCleanPairExpectsTheFixturesLandings() throws {
        let (json, _) = try Clean.pair()
        let files = json.rows.filter { $0.expected?.table == .files }.count
        #expect(files == 5)
        #expect(json.rows.allSatisfy { $0.expected != nil })
    }

    @Test func aDroppedRowIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        let dropped = try #require(sqlite.fileLandings.first)
        sqlite.fileLandings.removeFirst()
        let id = try #require(json.rows.first { $0.ordinal == dropped.ordinal }?.jsonRowID)
        #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                == .misses([.rowMissing(ordinal: dropped.ordinal, jsonRowID: id)]))
    }

    @Test func aDroppedDigestIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.contentDigests.remove(Clean.healthyDigest)
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.digestMissing(Clean.healthyDigest)]))
    }

    @Test func aDroppedCuratedValueIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        let ordinal = try Clean.ordinal(.curatedConflictA)
        sqlite.knowledgeSources.removeAll { $0.ordinal == ordinal && $0.field == .starRating }
        #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                == .misses([.curatedValueMissing(ordinal: ordinal, field: .starRating)]))
    }

    @Test func aCuratedValueKeptWithAnotherValueIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        let ordinal = try Clean.ordinal(.curatedConflictA)
        let i = try #require(sqlite.knowledgeSources.firstIndex { $0.ordinal == ordinal && $0.field == .starRating })
        sqlite.knowledgeSources[i].valueJSON = .int(1)
        #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                == .misses([.curatedValueDiffers(ordinal: ordinal, field: .starRating)]))
    }

    @Test func aQuarantinedRowsCuratedValueMayLiveInItsRawRow() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        let ordinal = try Clean.ordinal(.supersessionCycleA)
        sqlite.knowledgeSources.removeAll { $0.ordinal == ordinal }
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .ok)
    }

    @Test func aDuplicateLandingInFilesAndQuarantineIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        let landing = try #require(sqlite.fileLandings.first)
        sqlite.quarantineLandings.append(.init(ordinal: landing.ordinal, jsonRowID: landing.fileID, digest: landing.digest))
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.rowLandedTwice(ordinal: landing.ordinal)]))
    }

    @Test func twoOccurrencesOnOneFilesRowAreNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        let a = try Clean.ordinal(.curatedConflictA)
        let b = try Clean.ordinal(.curatedConflictB)
        let target = try #require(sqlite.fileLandings.first { $0.ordinal == a }?.fileID)
        let i = try #require(sqlite.fileLandings.firstIndex { $0.ordinal == b })
        sqlite.fileLandings[i].fileID = target
        let misses = ImportComparator.compare(json: json, sqlite: sqlite)
        #expect(misses == .misses([.rowIdentityWrong(ordinal: b, jsonRowID: PoisonedCatalogFixture.id(.curatedConflictB), landedOn: target),
                                   .fileRowShared(fileID: target, ordinals: [a, b].sorted())]))
    }

    @Test func aLandingForARowTheFileDoesNotHaveIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.quarantineLandings.append(.init(ordinal: 999, jsonRowID: "x", digest: nil))
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.rowNotInSource(ordinal: 999)]))
    }

    @Test func aDroppedDerivedValueIsNamed() throws {
        let pair = try Clean.pair()
        var json = pair.json
        let sqlite = pair.sqlite
        let ordinal = try Clean.ordinal(.healthy)
        // The healthy row carries no derived values; give the JSON side one the SQLite side lacks.
        let i = try #require(json.rows.firstIndex { $0.ordinal == ordinal })
        json.rows[i].derived = [CatalogRecordDTO.DerivedValueRow(kind: .transcript, seq: 0, valueJSON: .string("hi"),
                                                                 stampJSON: .object([:]))]
        #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                == .misses([.derivedValueMissing(ordinal: ordinal, kind: .transcript, seq: 0)]))
    }

    // MARK: - Identity and binding (codex D′ #1)

    @Test func twoLandingsWithSwappedFileIdsAreNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        let a = try Clean.ordinal(.healthy)
        let b = try Clean.ordinal(.curatedConflictA)
        let ia = try #require(sqlite.fileLandings.firstIndex { $0.ordinal == a })
        let ib = try #require(sqlite.fileLandings.firstIndex { $0.ordinal == b })
        let swapped = sqlite.fileLandings[ia].fileID
        sqlite.fileLandings[ia].fileID = sqlite.fileLandings[ib].fileID
        sqlite.fileLandings[ib].fileID = swapped
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([
            .rowIdentityWrong(ordinal: a, jsonRowID: PoisonedCatalogFixture.id(.healthy), landedOn: PoisonedCatalogFixture.id(.curatedConflictA)),
            .rowIdentityWrong(ordinal: b, jsonRowID: PoisonedCatalogFixture.id(.curatedConflictA), landedOn: PoisonedCatalogFixture.id(.healthy)),
        ]))
    }

    @Test func aRowLandedInTheOtherTableIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        let a = try Clean.ordinal(.healthy)
        let i = try #require(sqlite.fileLandings.firstIndex { $0.ordinal == a })
        let moved = sqlite.fileLandings.remove(at: i)
        sqlite.quarantineLandings.append(.init(ordinal: a, jsonRowID: moved.fileID, digest: moved.digest))
        #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                == .misses([.rowLandedElsewhere(ordinal: a, expected: .files, actual: .quarantine)]))
    }

    @Test func aLandingOnAnotherDigestIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        let a = try Clean.ordinal(.healthy)
        let i = try #require(sqlite.fileLandings.firstIndex { $0.ordinal == a })
        sqlite.fileLandings[i].digest = PoisonedCatalogFixture.digest("other")
        #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                == .misses([.rowDigestWrong(ordinal: a, expected: Clean.healthyDigest, actual: PoisonedCatalogFixture.digest("other"))]))
    }

    @Test func aQuarantineLandingOnAnotherRowIdIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        let a = try Clean.ordinal(.deadLink)
        let i = try #require(sqlite.quarantineLandings.firstIndex { $0.ordinal == a })
        sqlite.quarantineLandings[i].jsonRowID = PoisonedCatalogFixture.id(.neverSeen)
        #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                == .misses([.rowIdentityWrong(ordinal: a, jsonRowID: PoisonedCatalogFixture.id(.deadLink), landedOn: PoisonedCatalogFixture.id(.neverSeen))]))
    }

    @Test func aCuratedValueBoundToAnotherDigestIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        let ordinal = try Clean.ordinal(.curatedConflictA)
        let i = try #require(sqlite.knowledgeSources.firstIndex { $0.ordinal == ordinal && $0.field == .starRating })
        sqlite.knowledgeSources[i].digest = PoisonedCatalogFixture.digest("deadLink")
        #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                == .misses([.curatedBindingWrong(ordinal: ordinal, field: .starRating)]))
    }

    @Test func aCuratedValueBoundToAnotherRowIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        let ordinal = try Clean.ordinal(.curatedConflictA)
        let i = try #require(sqlite.knowledgeSources.firstIndex { $0.ordinal == ordinal && $0.field == .starRating })
        sqlite.knowledgeSources[i].jsonRowID = PoisonedCatalogFixture.id(.curatedConflictB)
        #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                == .misses([.curatedBindingWrong(ordinal: ordinal, field: .starRating)]))
    }

    @Test func anUnrepresentableRowExpectsNoContentAndNoDerivedRow() throws {
        let digest = String(repeating: "a", count: 64)
        let row = ImportComparator.RowOccurrence(
            ordinal: 0, jsonRowID: "00000000-0000-4000-8000-000000000001", digest: digest,
            knowledge: [CatalogRecordDTO.KnowledgeSourceRow(field: .starRating, valueJSON: .int(2), setAt: nil)],
            derived: [CatalogRecordDTO.DerivedValueRow(kind: .transcript, seq: 0, valueJSON: .string("hi"), stampJSON: .object([:]))],
            expected: .quarantine(.unrepresentable))
        let json = ImportComparator.JSONSide(rows: [row])
        let sqlite = ImportComparator.SQLiteSide(
            fileLandings: [], quarantineLandings: [.init(ordinal: 0, jsonRowID: row.jsonRowID, digest: digest)],
            contentDigests: [],
            knowledgeSources: [.init(ordinal: 0, field: .starRating, valueJSON: .int(2), jsonRowID: row.jsonRowID, digest: nil)])
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .ok)
    }

    // MARK: - Resolved membership (codex D′ #1)

    @Test func aDroppedResolvedMemberIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.eventMembers.remove(Clean.resolved)
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.eventMemberMissing(Clean.resolved)]))
    }

    @Test func aMemberNoDecisionResolvesToIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        let stranger = ImportComparator.ResolvedMember(eventID: PoisonedCatalogFixture.eventTwoID, digest: Clean.healthyDigest,
                                                       rangeStart: 1, rangeEnd: 2)
        sqlite.eventMembers.insert(stranger)
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.eventMemberNotInSource(stranger)]))
    }

    @Test func aListedMemberThatIsNowhereIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.listedMemberKeys.removeAll()
        #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                == .misses([.eventMemberMissing(eventID: Clean.listed.eventID, key: Clean.listed.key)]))
    }

    // MARK: - Sidecar rows, whole (codex D′ #3)

    @Test func aDroppedLedgerLineIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.ledgerLines.removeAll { $0.sourceOrdinal == 2 }
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.ledgerLineMissing(ordinal: 2)]))
    }

    @Test func aLedgerLineWithAnotherPayloadIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.ledgerLines[2].payload = .object([:])
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.ledgerLineDiffers(ordinal: 2)]))
    }

    @Test func aDroppedIgnoredEntryIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.ignoredEntries.removeAll()
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.ignoredEntryMissing(ordinal: 0)]))
    }

    @Test func anIgnoredEntryWithAnotherValueIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.ignoredEntries[0].filename = "other.mov"
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.ignoredEntryDiffers(ordinal: 0)]))
    }

    @Test func aDroppedEventDecisionIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.eventDecisions.removeAll { $0.sourceOrdinal == 1 }
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.eventDecisionMissing(ordinal: 1)]))
    }

    @Test func anEventDecisionWithAnotherPayloadIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.eventDecisions[0].payload = .object(["kind": .string("member"), "verdict": .string("rejected")])
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.eventDecisionDiffers(ordinal: 1)]))
    }

    @Test func aDroppedEventRecordIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.events.removeAll()
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.eventMissing(ordinal: 0)]))
    }

    @Test func anEventRecordWithAnotherNameIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.events[0].name = "Lake day"
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.eventDiffers(ordinal: 0)]))
    }

    @Test func aDroppedMarkerIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.markers.removeAll()
        #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                == .misses([.markerMissing(file: "catalog-audit.json", ordinal: 0)]))
    }

    @Test func aMarkerFromOtherBytesIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.markers = [ImportComparator.MarkerKey(sourceFile: .catalogAudit, ordinal: 0, fileSHA256: "other")]
        #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                == .misses([.markerDiffers(file: "catalog-audit.json", ordinal: 0)]))
    }

    @Test func aDroppedPersonSearchIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.personSearchOrdinals.remove(0)
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.personSearchMissing(ordinal: 0)]))
    }

    @Test func anAuditResultAcceptedAgainstTheSnapshotRuleIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.auditResults = [Clean.audit(1, accepted: false)]
        #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                == .misses([.auditAcceptanceWrong(ordinal: 1, expected: true)]))
    }

    @Test func aDroppedAuditResultIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.auditResults = []
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.auditResultMissing(ordinal: 1)]))
    }

    @Test func anAuditResultWithAnotherWordIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.auditResults[0].detail = .object(["detail": .string("ENOENT")])
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.auditResultDiffers(ordinal: 1)]))
    }

    /// §10b "the comparator counts every one": the all-129-keys row carries
    /// every curated field; dropping any one of its knowledge rows is named.
    @Test func everyCuratedFieldIsCountedWhenDropped() throws {
        let row = try #require(try ImportTestSupport.catalog(ImportGoldenFixtures.full129).records.first)
        let occurrence = ImportComparator.RowOccurrence(ordinal: 0, record: row)
        let digest = try #require(occurrence.digest)
        let json = ImportComparator.JSONSide(rows: [occurrence])
        let kept = occurrence.knowledge.map {
            ImportComparator.KnowledgeKey(ordinal: 0, field: $0.field, valueJSON: $0.valueJSON, jsonRowID: occurrence.jsonRowID, digest: digest)
        }
        let derived = Set(occurrence.derived.map {
            ImportComparator.DerivedKey(digest: digest, kind: $0.kind, seq: $0.seq, sourceJSONRowID: occurrence.jsonRowID)
        })
        let clean = ImportComparator.SQLiteSide(
            fileLandings: [.init(ordinal: 0, fileID: occurrence.jsonRowID, digest: digest)],
            contentDigests: [digest], knowledgeSources: kept, derivedUnverified: derived,
            soundPrintDigests: Set([occurrence.soundPrintDigest].compactMap { $0 }))
        #expect(ImportComparator.compare(json: json, sqlite: clean) == .ok)
        #expect(Set(kept.map(\.field)) == Set(CatalogDDL.KnowledgeField.allCases))
        for field in CatalogDDL.KnowledgeField.allCases {
            var sqlite = clean
            sqlite.knowledgeSources.removeAll { $0.field == field }
            #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                    == .misses([.curatedValueMissing(ordinal: 0, field: field)]), "\(field.rawValue)")
        }
    }

    @Test func everyMissHasWords() {
        let member = ImportComparator.ResolvedMember(eventID: "e", digest: "d")
        let all: [ImportComparator.Miss] = [
            .rowMissing(ordinal: 0, jsonRowID: "x"), .rowLandedTwice(ordinal: 0),
            .rowLandedElsewhere(ordinal: 0, expected: .files, actual: .quarantine),
            .rowIdentityWrong(ordinal: 0, jsonRowID: "x", landedOn: "y"), .rowDigestWrong(ordinal: 0, expected: "a", actual: nil),
            .fileRowShared(fileID: "f", ordinals: [0, 1]), .rowNotInSource(ordinal: 0), .digestMissing("d"),
            .curatedValueMissing(ordinal: 0, field: .tags), .curatedValueDiffers(ordinal: 0, field: .tags),
            .curatedBindingWrong(ordinal: 0, field: .tags), .derivedValueMissing(ordinal: 0, kind: .scene, seq: 0),
            .soundPrintMissing(ordinal: 0, digest: "d"), .eventMissing(ordinal: 0), .eventDiffers(ordinal: 0),
            .eventDecisionMissing(ordinal: 0), .eventDecisionDiffers(ordinal: 0),
            .eventMemberMissing(eventID: "e", key: "k"), .eventMemberMissing(member), .eventMemberNotInSource(member),
            .ledgerLineMissing(ordinal: 0), .ledgerLineDiffers(ordinal: 0), .ignoredEntryMissing(ordinal: 0),
            .ignoredEntryDiffers(ordinal: 0), .markerMissing(file: "f", ordinal: 0), .markerDiffers(file: "f", ordinal: 0),
            .auditResultMissing(ordinal: 0), .auditResultDiffers(ordinal: 0), .auditAcceptanceWrong(ordinal: 0, expected: true),
            .personSearchMissing(ordinal: 0),
        ]
        #expect(Set(all.map(\.kind)) == Set(ImportComparator.Miss.Kind.allCases))
        for m in all {
            #expect(!m.words.isEmpty, "\(m)")
        }
    }
}

@Suite("Import comparator — scale")
struct ImportComparatorScaleTests {
    /// Budget, not yet measured on the Mac (cloud brief): set ~10× above a
    /// set-difference over 100k rows; re-baseline on the M4 and tighten.
    static let budget: Duration = .seconds(5)

    @Test func hundredThousandOccurrencesCompareWithinBudget() {
        let n = 100_000
        let digests = (0..<n).map { String(format: "%064lx", $0) }
        let rows = (0..<n).map { i in
            ImportComparator.RowOccurrence(
                ordinal: i, jsonRowID: String(format: "00000000-0000-4000-8000-%012ld", i), digest: digests[i],
                knowledge: [CatalogRecordDTO.KnowledgeSourceRow(field: .starRating, valueJSON: .int(2), setAt: nil)],
                expected: .files)
        }
        let json = ImportComparator.JSONSide(rows: rows)
        let sqlite = ImportComparator.SQLiteSide(
            fileLandings: rows.map { ImportComparator.FileLanding(ordinal: $0.ordinal, fileID: $0.jsonRowID, digest: $0.digest) },
            contentDigests: Set(digests),
            knowledgeSources: rows.map {
                ImportComparator.KnowledgeKey(ordinal: $0.ordinal, field: .starRating, valueJSON: .int(2), jsonRowID: $0.jsonRowID, digest: $0.digest)
            })
        let loadBefore = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        let verdict = ImportComparator.compare(json: json, sqlite: sqlite)
        let elapsed = clock.now - start
        #expect(verdict == .ok)
        expectWithinTimingBudget("import comparator 100k occurrences", measured: elapsed, budget: Self.budget,
                                 loadBefore: loadBefore)
    }
}
