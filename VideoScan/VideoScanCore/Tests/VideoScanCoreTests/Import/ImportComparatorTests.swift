// ImportComparatorTests.swift
// The comparator (contract §f "Comparator", brief deliverable 3): a clean pair
// passes, and each miss class is caught and named — a dropped row, a dropped
// digest, a dropped curated value, a dropped event member, a duplicate
// landing — plus the sidecar classes. Built on the poisoned fixture, so the
// clean pair is what a correct importer would write for it.
// One condition per #expect.

import Foundation
import Testing
@testable import VideoScanCore

/// A "correct importer" in miniature: what SQLite would hold for the fixture
/// if every occurrence landed where the gate says.
private enum Clean {

    static func pair() throws -> (json: ImportComparator.JSONSide, sqlite: ImportComparator.SQLiteSide) {
        let run = try ImportTestSupport.fixtureRun()
        // The JSON side is re-decoded independently, from the bytes.
        let rows = ImportComparator.JSONSide.occurrences(from: try CatalogFileJSON.decode(run.fixture.catalogData))
        var files: [ImportComparator.FileLanding] = []
        var quarantine: [Int] = []
        var raws: [Int: [String: CatalogJSONValue]] = [:]
        var knowledge: [ImportComparator.KnowledgeKey] = []
        var derived = Set<ImportComparator.DerivedKey>()
        for (ordinal, input) in run.inputs.enumerated() {
            let dto = run.dtos[ordinal]
            switch ImportGate.decide(input) {
            case .main:
                files.append(.init(ordinal: ordinal, fileID: dto.file.id))
            case .quarantine:
                quarantine.append(ordinal)
                raws[ordinal] = dto.raw
            }
            for k in dto.knowledgeSources {
                knowledge.append(.init(ordinal: ordinal, field: k.field, valueJSON: k.valueJSON))
            }
            if let digest = dto.digestState.digest {
                for d in dto.derivedUnverified {
                    derived.insert(.init(digest: digest, kind: d.kind, seq: d.seq, sourceJSONRowID: dto.file.id))
                }
            }
        }
        let digests = Set(run.dtos.compactMap { $0.digestState.digest })
        let members = [ImportComparator.EventMember(eventID: "E1", key: "sha256:" + (digests.min() ?? "")),
                       ImportComparator.EventMember(eventID: "E1", key: "id:" + PoisonedCatalogFixture.id(.sampledOnly))]
        let markers = [ImportComparator.MarkerKey(sourceFile: .catalogAudit, ordinal: 0)]
        let json = ImportComparator.JSONSide(
            rows: rows, eventDecisionOrdinals: [0, 1], eventMembers: members, ledgerOrdinals: [0, 1, 2],
            ignoredOrdinals: [0], markers: markers, auditResults: [], auditWindow: run.audit.window,
            personSearchOrdinals: [0])
        let sqlite = ImportComparator.SQLiteSide(
            fileLandings: files, quarantineOrdinals: quarantine, quarantineRawRows: raws, contentDigests: digests,
            knowledgeSources: knowledge, derivedUnverified: derived, soundPrintDigests: [],
            eventDecisionOrdinals: [0, 1], eventMembers: [members[0]], listedMemberKeys: [members[1].key],
            ledgerOrdinals: [0, 1, 2], ignoredOrdinals: [0], markers: Set(markers), auditResults: [:],
            personSearchOrdinals: [0])
        return (json, sqlite)
    }
}

@Suite("Import comparator — clean pair and every miss class")
struct ImportComparatorTests {

    @Test func aCleanPairPasses() throws {
        let (json, sqlite) = try Clean.pair()
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .ok)
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
        let digest = PoisonedCatalogFixture.digest("healthy")
        sqlite.contentDigests.remove(digest)
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.digestMissing(digest)]))
    }

    @Test func aDroppedCuratedValueIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        let ordinal = try #require(PoisonedCatalogFixture().ordinals(of: .curatedConflictA).first)
        sqlite.knowledgeSources.removeAll { $0.ordinal == ordinal && $0.field == .starRating }
        #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                == .misses([.curatedValueMissing(ordinal: ordinal, field: .starRating)]))
    }

    @Test func aCuratedValueKeptWithAnotherValueIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        let ordinal = try #require(PoisonedCatalogFixture().ordinals(of: .curatedConflictA).first)
        let i = try #require(sqlite.knowledgeSources.firstIndex { $0.ordinal == ordinal && $0.field == .starRating })
        sqlite.knowledgeSources[i].valueJSON = .int(1)
        #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                == .misses([.curatedValueDiffers(ordinal: ordinal, field: .starRating)]))
    }

    @Test func aQuarantinedRowsCuratedValueMayLiveInItsRawRow() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        let ordinal = try #require(PoisonedCatalogFixture().ordinals(of: .supersessionCycleA).first)
        sqlite.knowledgeSources.removeAll { $0.ordinal == ordinal }
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .ok)
    }

    @Test func aDroppedEventMemberIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        let member = try #require(json.eventMembers.first)
        sqlite.eventMembers.remove(member)
        #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                == .misses([.eventMemberMissing(eventID: member.eventID, key: member.key)]))
    }

    @Test func aDuplicateLandingInFilesAndQuarantineIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        let landing = try #require(sqlite.fileLandings.first)
        sqlite.quarantineOrdinals.append(landing.ordinal)
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.rowLandedTwice(ordinal: landing.ordinal)]))
    }

    @Test func twoOccurrencesOnOneFilesRowAreNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        let a = try #require(PoisonedCatalogFixture().ordinals(of: .curatedConflictA).first)
        let b = try #require(PoisonedCatalogFixture().ordinals(of: .curatedConflictB).first)
        let target = try #require(sqlite.fileLandings.first { $0.ordinal == a }?.fileID)
        let i = try #require(sqlite.fileLandings.firstIndex { $0.ordinal == b })
        sqlite.fileLandings[i].fileID = target
        #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                == .misses([.fileRowShared(fileID: target, ordinals: [a, b].sorted())]))
    }

    @Test func aLandingForARowTheFileDoesNotHaveIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.quarantineOrdinals.append(999)
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.rowNotInSource(ordinal: 999)]))
    }

    @Test func aDroppedDerivedValueIsNamed() throws {
        let pair = try Clean.pair()
        var json = pair.json
        let sqlite = pair.sqlite
        let ordinal = try #require(PoisonedCatalogFixture().ordinals(of: .healthy).first)
        // The healthy row carries no derived values; give the JSON side one the SQLite side lacks.
        let i = try #require(json.rows.firstIndex { $0.ordinal == ordinal })
        json.rows[i].derived = [CatalogRecordDTO.DerivedValueRow(kind: .transcript, seq: 0, valueJSON: .string("hi"),
                                                                 stampJSON: .object([:]))]
        #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                == .misses([.derivedValueMissing(ordinal: ordinal, kind: .transcript, seq: 0)]))
    }

    @Test func aDroppedLedgerLineIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.ledgerOrdinals.remove(2)
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.ledgerLineMissing(ordinal: 2)]))
    }

    @Test func aDroppedIgnoredEntryIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.ignoredOrdinals.remove(0)
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.ignoredEntryMissing(ordinal: 0)]))
    }

    @Test func aDroppedEventDecisionIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.eventDecisionOrdinals.remove(1)
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.eventDecisionMissing(ordinal: 1)]))
    }

    @Test func aDroppedMarkerIsNamed() throws {
        let pair = try Clean.pair()
        let json = pair.json
        var sqlite = pair.sqlite
        sqlite.markers.removeAll()
        #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                == .misses([.markerMissing(file: "catalog-audit.json", ordinal: 0)]))
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
        var json = pair.json
        var sqlite = pair.sqlite
        let window = json.auditWindow
        json.auditResults = [ImportComparator.AuditResultOccurrence(
            ordinal: 0, evidence: ImportGate.AuditEvidence(result: .present), rowFullPath: "/V/a.mov",
            rowAuditSeenAt: window.startedAt - 1)]
        sqlite.auditResults = [0: true]
        #expect(ImportComparator.compare(json: json, sqlite: sqlite)
                == .misses([.auditAcceptanceWrong(ordinal: 0, expected: false)]))
    }

    @Test func aDroppedAuditResultIsNamed() throws {
        let pair = try Clean.pair()
        var json = pair.json
        var sqlite = pair.sqlite
        json.auditResults = [ImportComparator.AuditResultOccurrence(
            ordinal: 0, evidence: ImportGate.AuditEvidence(result: .gone, judgedPath: "/V/a.mov"), rowFullPath: "/V/a.mov",
            rowAuditSeenAt: nil)]
        sqlite.auditResults = [:]
        #expect(ImportComparator.compare(json: json, sqlite: sqlite) == .misses([.auditResultMissing(ordinal: 0)]))
    }

    /// §10b "the comparator counts every one": the all-129-keys row carries
    /// every curated field; dropping any one of its knowledge rows is named.
    @Test func everyCuratedFieldIsCountedWhenDropped() throws {
        let row = try #require(try ImportTestSupport.catalog(ImportGoldenFixtures.full129).records.first)
        let occurrence = ImportComparator.RowOccurrence(ordinal: 0, record: row)
        let digest = try #require(occurrence.digest)
        let json = ImportComparator.JSONSide(rows: [occurrence])
        let kept = occurrence.knowledge.map {
            ImportComparator.KnowledgeKey(ordinal: 0, field: $0.field, valueJSON: $0.valueJSON)
        }
        let derived = Set(occurrence.derived.map {
            ImportComparator.DerivedKey(digest: digest, kind: $0.kind, seq: $0.seq, sourceJSONRowID: occurrence.jsonRowID)
        })
        let clean = ImportComparator.SQLiteSide(
            fileLandings: [.init(ordinal: 0, fileID: occurrence.jsonRowID)], quarantineOrdinals: [],
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
        let all: [ImportComparator.Miss] = [
            .rowMissing(ordinal: 0, jsonRowID: "x"), .rowLandedTwice(ordinal: 0), .fileRowShared(fileID: "f", ordinals: [0, 1]),
            .rowNotInSource(ordinal: 0), .digestMissing("d"), .curatedValueMissing(ordinal: 0, field: .tags),
            .curatedValueDiffers(ordinal: 0, field: .tags), .derivedValueMissing(ordinal: 0, kind: .scene, seq: 0),
            .soundPrintMissing(ordinal: 0, digest: "d"), .eventDecisionMissing(ordinal: 0),
            .eventMemberMissing(eventID: "e", key: "k"), .ledgerLineMissing(ordinal: 0), .ignoredEntryMissing(ordinal: 0),
            .markerMissing(file: "f", ordinal: 0), .auditResultMissing(ordinal: 0),
            .auditAcceptanceWrong(ordinal: 0, expected: true), .personSearchMissing(ordinal: 0),
        ]
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
                knowledge: [CatalogRecordDTO.KnowledgeSourceRow(field: .starRating, valueJSON: .int(2), setAt: nil)])
        }
        let json = ImportComparator.JSONSide(rows: rows)
        let sqlite = ImportComparator.SQLiteSide(
            fileLandings: rows.map { ImportComparator.FileLanding(ordinal: $0.ordinal, fileID: $0.jsonRowID) },
            quarantineOrdinals: [], contentDigests: Set(digests),
            knowledgeSources: rows.map { ImportComparator.KnowledgeKey(ordinal: $0.ordinal, field: .starRating, valueJSON: .int(2)) })
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
