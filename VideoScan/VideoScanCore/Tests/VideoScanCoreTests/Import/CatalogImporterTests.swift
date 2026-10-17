// CatalogImporterTests.swift
// Step D′ end to end on the poisoned fixture: every one of its 17 shapes
// lands where contract §f says (one test per shape, the table and the
// words), the comparator passes, the reconciliation line equals the counts,
// a second run into the same database is refused, and an injected
// comparator miss rolls everything back with the miss named. Isolation:
// a poisoned audit marker, a report whose hash is not the file's, a
// read-only target folder, a catalog that changes mid-import. TRUTH:
// knowledge_sources holds every curated value of every row (per field,
// against the JSON), and a quarantined row's stars are in raw_row AND in
// knowledge_sources under its json_row_id.
// One condition per #expect.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("CatalogImporter — the poisoned fixture lands where §f says")
struct CatalogImporterTests {

    // MARK: - Logic: per-shape landings

    @Test("every shape lands in its §f row", arguments: PoisonedCatalogFixture.Shape.allCases)
    func everyShapeLandsWhereTheContractSays(shape: PoisonedCatalogFixture.Shape) async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let run = await scene.run()
        try #require(run.outcome.reconciliation != nil, Comment(rawValue: "\(run.outcome)"))
        let ordinal = try #require(scene.fixture.ordinals(of: shape).first)
        let expected = PoisonedCatalogFixture.expected(shape)
        let landing = try await scene.read { reader -> CatalogRow.RowLanding? in
            var found: CatalogRow.RowLanding?
            try reader.rowLandings(run: run.runID) { if $0.ordinal == ordinal { found = $0 } }
            return found
        }
        let landed = try #require(landing)
        if let reason = expected.reason {
            #expect(landed.landedTable == .quarantine)
            let entry = try await scene.read { reader -> CatalogRow.QuarantineReading? in
                var found: CatalogRow.QuarantineReading?
                try reader.quarantineEntries(run: run.runID) { if $0.ordinal == ordinal { found = $0 } }
                return found
            }
            let quarantined = try #require(entry)
            #expect(quarantined.reasonCode == reason)
            #expect(quarantined.jsonRowID == PoisonedCatalogFixture.id(shape))
            #expect(quarantined.words == Self.expectedWords(shape))
            #expect(quarantined.findingsCount == Self.expectedFindings(shape))
        } else {
            #expect(landed.landedTable == .files)
            #expect(landed.landedRef == PoisonedCatalogFixture.id(shape))
        }
    }

    /// The §f words, by shape: the gate's constants for presence reasons, the
    /// finding's own words for tier-5 reasons.
    private static func expectedWords(_ shape: PoisonedCatalogFixture.Shape) -> String {
        switch shape {
        case .deadLink: return ImportGate.Words.auditCouldNotCheck
        case .neverSeen: return ImportGate.Words.auditNeverSeen
        case .sampledOnly: return ImportGate.Words.noWholeFileDigest
        case .changedSize: return ImportGate.Words.auditChanged
        case .duplicateIDFirst, .duplicateIDSecond: return ImportGate.Words.duplicateId(2)
        case .disagreeingFixities: return ImportGate.Words.fixityDisagree
        case .caseAliasUpper, .caseAliasLower: return "two rows name one file by case on a case-insensitive volume"
        case .supersessionCycleA, .supersessionCycleB: return "repairs supersede each other in a circle"
        case .referenceMovie: return "a reference movie: its media live in other files"
        case .healthy, .tombstonedWithDigest, .curatedConflictA, .curatedConflictB, .stalePrint: return ""
        }
    }

    /// Every tier-5 finding for the record rides on its quarantine row (F5r3).
    private static func expectedFindings(_ shape: PoisonedCatalogFixture.Shape) -> Int {
        PoisonedCatalogFixture.findings().filter { $0.tier == 5 && $0.recordID == PoisonedCatalogFixture.id(shape) }.count
    }

    @Test func theTombstonedShapeIsCountedAsTombstonedMain() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let run = await scene.run()
        let r = try #require(run.outcome.reconciliation)
        #expect(r.rowsTombstoned == 1)
        #expect(r.rowsLive == 4)
    }

    // MARK: - Logic: the comparator passes and the line equals the counts

    @Test func theReconciliationLineEqualsTheCounts() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let run = await scene.run()
        let r = try #require(run.outcome.reconciliation)
        #expect(r.rowsBefore == 17)
        #expect(r.rowsMain == 5)
        #expect(r.rowsQuarantine == 12)
        #expect(r.quarantineByReason == ["auditCouldNotCheck": 1, "auditNeverSeen": 1, "noWholeFileDigest": 1, "auditChanged": 1,
                                         "duplicateId": 2, "fixityDisagree": 1, "tier5Finding": 4, "referenceMovie": 1])
        #expect(r.digests == 12)
        // 3 stars (two conflicting copies + the quarantined deadLink), the two
        // copies' dates and confidences, the cycle's two supersededByID and one
        // repairConfirmedDate, and the disagreeing row's archiveFixity (§10b: a
        // promotion record is curated, kept even when its digest is not trusted).
        #expect(r.knowledgeRows == 11)
        #expect(r.knowledgeByField == ["starRating": 3, "userDate": 2, "userDateConfidence": 2, "supersededByID": 2,
                                       "repairConfirmedDate": 1, "archiveFixity": 1])
        #expect(r.conflictsByField == ["starRating": 1, "userDate": 1, "userDateConfidence": 1])
        #expect(r.unverified == 0)
        #expect(r.pendingLineage == 1)
        #expect(r.events == 2)
        #expect(r.eventDecisions == 9)
        #expect(r.membersResolved == 3)
        #expect(r.membersListed == 1)
        #expect(r.ignored == 2)
        #expect(r.ignoredBound == 0)
        #expect(r.ledgerLines == 3)
        #expect(r.ledgerUnparseable == 1)
        #expect(r.auditResults == 15)
        #expect(r.auditAccepted == 15)
        #expect(r.markers == 2)
        let fromRows = try await scene.read { try $0.importReconciliation(run: run.runID) }
        #expect(fromRows.rowsBefore == r.rowsBefore)
        #expect(fromRows.knowledgeRows == r.knowledgeRows)
        #expect(r.line.hasPrefix("rows before 17 · main 5 (live 4, tombstoned 1) · quarantine 12 (by reason "))
        #expect(r.line.contains(" · digests 12 · knowledge rows 11 (by field "))
        #expect(r.line.contains(" · pending lineage 1 · events 2 (9 decisions, members 3 resolved / 1 listed) · ignored 2 (0 bound / 2 unbound) · ledger lines 3 (1 unparseable, not imported) · searches 0 (zero-hit 0, unreadable 0) · audit results 15 (15 accepted / 0 refused) · markers 2"))
        let lines = scene.sink.lines
        #expect(lines.first?.hasPrefix("START import ") == true)
        #expect(lines.last == "OUTCOME imported · " + r.line)
    }

    @Test func theImportCommitsOneGenerationWithTheFileCounts() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        _ = await scene.run()
        let generation = try await scene.read { $0.generation }
        #expect(generation == 1)
        let counts = try await scene.read { try $0.recordCounts() }
        #expect(counts == CatalogRow.TableCounts(files: 5, quarantine: 12, content: 12, importRuns: 1))
    }

    @Test func aSecondRunIntoTheSameDatabaseIsRefused() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let first = await scene.run()
        #expect(first.outcome.reconciliation != nil)
        let second = await scene.run()
        #expect(second.outcome.refusalKinds == [.targetNotEmpty])
        let counts = try await scene.read { try $0.recordCounts() }
        #expect(counts.importRuns == 1)
    }

    @Test func aComparatorMissRollsEverythingBackAndNamesIt() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let ordinal = try #require(scene.fixture.ordinals(of: .curatedConflictA).first)
        let run = await scene.run(seam: { side in
            side.knowledgeSources.removeAll { $0.ordinal == ordinal && $0.field == .starRating }
        })
        #expect(run.outcome.misses == [.curatedValueMissing(ordinal: ordinal, field: .starRating)])
        let counts = try await scene.read { try $0.recordCounts() }
        #expect(counts.isEmpty)
        let generation = try await scene.read { $0.generation }
        #expect(generation == 0)
        #expect(scene.sink.lines.last?.hasPrefix("OUTCOME rolled back · 1 miss(es) · catalog row \(ordinal): its starRating was not kept") == true)
    }

    // MARK: - Isolation (poisoned state)

    @Test func anAuditMarkerWithoutRowResultsRefusesTheRun() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        var marker = try AuditMarkerJSON.decode(scene.fixture.auditData)
        marker.rows = nil
        try scene.overwrite(PoisonedCatalogFixture.auditFileName, with: try CatalogJSONValue.makeEncoder().encode(marker))
        let run = await scene.run()
        #expect(run.outcome.refusalKinds == [.auditHasNoRowResults])
        let counts = try await scene.read { try $0.recordCounts() }
        #expect(counts.isEmpty)
    }

    @Test func aReportWhoseHashIsNotTheFrozenFilesIsRefused() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        try scene.overwrite(PoisonedCatalogFixture.catalogFileName, with: scene.fixture.catalogData + Data(" ".utf8))
        let run = await scene.run()
        #expect(run.outcome.refusalKinds == [.reportHashMismatch])
    }

    @Test func aReadOnlyTargetFolderFailsBeforeAnyWrite() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scene.databaseFolder.path)
        let run = await scene.run()
        let words = try #require(run.outcome.failureWords)
        #expect(words.hasPrefix("the target "))
        #expect(scene.sink.lines.count == 2)                       // START and OUTCOME only: no row line was ever reached
    }

    @Test func aCatalogThatChangesMidImportIsRefusedAndNothingIsWritten() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let poisoned = scene.fixture.catalogData + Data("\n".utf8)
        let target = scene.inputs.catalogURL
        let run = await scene.run(decodeSeam: { try? poisoned.write(to: target, options: .atomic) })
        #expect(run.outcome.refusalKinds == [.catalogChangedDuringImport])
        let counts = try await scene.read { try $0.recordCounts() }
        #expect(counts.isEmpty)
        let generation = try await scene.read { $0.generation }
        #expect(generation == 0)
    }

    // MARK: - TRUTH

    @Test func knowledgeSourcesHoldsEveryCuratedValueOfEveryRowPerField() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let run = await scene.run()
        try #require(run.outcome.reconciliation != nil)
        // Independently from the JSON: every curated value of every row, by field.
        var expected: [CatalogDDL.KnowledgeField: Int] = [:]
        for record in try CatalogFileJSON.decode(scene.fixture.catalogData).records {
            for value in CatalogRecordDTO.knowledgeSourceRows(raw: record.raw) { expected[value.field, default: 0] += 1 }
        }
        let stored = try await scene.read { reader -> [CatalogDDL.KnowledgeField: Int] in
            var counts: [CatalogDDL.KnowledgeField: Int] = [:]
            try reader.knowledgeSources(run: run.runID) { counts[$0.field, default: 0] += 1 }
            return counts
        }
        #expect(stored == expected)
        #expect(stored.values.reduce(0, +) == 11)
    }

    @Test func aQuarantinedRowsStarsAreInItsRawRowAndInKnowledgeSources() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let run = await scene.run()
        let ordinal = try #require(scene.fixture.ordinals(of: .deadLink).first)
        let raw = try await scene.read { reader -> [String: CatalogJSONValue]? in
            var found: [String: CatalogJSONValue]?
            try reader.quarantineRawRows(run: run.runID) { if $0 == ordinal { found = $1 } }
            return found
        }
        #expect(raw?["starRating"] == .int(3))
        let knowledge = try await scene.read { reader -> [CatalogRow.KnowledgeReading] in
            var rows: [CatalogRow.KnowledgeReading] = []
            try reader.knowledgeSources(run: run.runID) { if $0.ordinal == ordinal { rows.append($0) } }
            return rows
        }
        #expect(knowledge == [CatalogRow.KnowledgeReading(ordinal: ordinal, jsonRowID: PoisonedCatalogFixture.id(.deadLink),
                                                          field: .starRating, value: .int(3))])
    }

    // MARK: - Sidecars land

    @Test func theSidecarsLandWithTheirOrdinals() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let run = await scene.run()
        try #require(run.outcome.reconciliation != nil)
        let members = try await scene.read { reader -> Set<CatalogRow.EventMemberReading> in
            var set = Set<CatalogRow.EventMemberReading>()
            try reader.eventMembers { set.insert($0) }
            return set
        }
        #expect(members == [
            CatalogRow.EventMemberReading(eventID: PoisonedCatalogFixture.eventOneID, importedKey: PoisonedCatalogFixture.digest("healthy")),
            CatalogRow.EventMemberReading(eventID: PoisonedCatalogFixture.eventOneID, importedKey: "pair:" + PoisonedCatalogFixture.pairGroupID),
            CatalogRow.EventMemberReading(eventID: PoisonedCatalogFixture.eventTwoID, importedKey: PoisonedCatalogFixture.digest("curated-shared")),
        ])
        let listed = try await scene.read { reader -> Set<String> in
            var set = Set<String>()
            try reader.listedMemberKeys(run: run.runID) { set.insert($0) }
            return set
        }
        #expect(listed.contains("id:" + PoisonedCatalogFixture.id(.sampledOnly)))
        let decisions = try await scene.read { reader -> [Int] in
            var out: [Int] = []
            try reader.eventDecisionOrdinals(run: run.runID) { out.append($0) }
            return out.sorted()
        }
        #expect(decisions == Array(2..<11))
        let markers = try await scene.read { reader -> Set<CatalogRow.MarkerReading> in
            var set = Set<CatalogRow.MarkerReading>()
            try reader.jobMarkers(run: run.runID) { set.insert($0) }
            return set
        }
        #expect(markers == [CatalogRow.MarkerReading(sourceFile: .catalogAudit, ordinal: 0),
                            CatalogRow.MarkerReading(sourceFile: .fullHashBackfill, ordinal: 0)])
        let ledger = try await scene.read { reader -> [Int] in
            var out: [Int] = []
            try reader.ledgerOrdinals(run: run.runID) { out.append($0) }
            return out.sorted()
        }
        #expect(ledger == [0, 1, 2])
    }

    @Test func withoutSidecarsTheImportStillCompletes() async throws {
        let scene = try ImporterScene.make(sidecars: false)
        defer { scene.remove() }
        let run = await scene.run()
        let r = try #require(run.outcome.reconciliation)
        #expect(r.events == 0)
        #expect(r.ledgerLines == 0)
        #expect(r.markers == 1)
    }

    // MARK: - Media matrix: not applicable (the importer opens no media file; it reads JSON and writes SQLite).
}
