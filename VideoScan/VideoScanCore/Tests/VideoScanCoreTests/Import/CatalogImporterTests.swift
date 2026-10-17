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
//
// Codex D′ pins (docs/reviews/codex/codex-review-sqlite-importer-step-d-data-risk-2026-10-17.md),
// one suite section per finding, each shown red before its fix:
//   #1 the comparator proves identity and binding, not counts;
//   #2 a duplicate key in one JSON object refuses the run before any write;
//   #3 a sidecar that changes after the gate is refused; a payload altered
//      in the comparator's view is a miss;
//   #4 an unknown audit result word refuses the run; every audit row lands
//      with its word and detail; the marker keeps the file's hash;
//   #5 interior ledger corruption refuses; a torn last line lands with its bytes;
//   #6 a row a row-local CHECK would refuse is quarantined `unrepresentable`
//      and the run proceeds; an unrepresentable sidecar entry refuses;
//   #7 a write between the outer empty-target check and the transaction is
//      caught inside the transaction.
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
        let landed = try #require(try await Self.landing(scene, run.runID, ordinal))
        if let reason = expected.reason {
            #expect(landed.landedTable == .quarantine)
            let quarantined = try #require(try await Self.quarantineEntry(scene, run.runID, ordinal))
            #expect(quarantined.reasonCode == reason)
            #expect(quarantined.jsonRowID == PoisonedCatalogFixture.id(shape))
            #expect(quarantined.words == Self.expectedWords(shape))
            #expect(quarantined.findingsCount == Self.expectedFindings(shape))
        } else {
            #expect(landed.landedTable == .files)
            #expect(landed.landedRef == PoisonedCatalogFixture.id(shape))
        }
    }

    static func landing(_ scene: ImporterScene, _ runID: String, _ ordinal: Int) async throws -> CatalogRow.RowLanding? {
        try await scene.read { reader -> CatalogRow.RowLanding? in
            var found: CatalogRow.RowLanding?
            try reader.rowLandings(run: runID) { if $0.ordinal == ordinal { found = $0 } }
            return found
        }
    }

    static func quarantineEntry(_ scene: ImporterScene, _ runID: String, _ ordinal: Int) async throws -> CatalogRow.QuarantineReading? {
        try await scene.read { reader -> CatalogRow.QuarantineReading? in
            var found: CatalogRow.QuarantineReading?
            try reader.quarantineEntries(run: runID) { if $0.ordinal == ordinal { found = $0 } }
            return found
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
        #expect(r.ledgerLines == 4)                 // three lines and the torn last line, kept with its bytes (codex D′ #5)
        #expect(r.ledgerUnparseable == 1)
        #expect(r.auditResults == 15)
        #expect(r.auditAccepted == 15)
        #expect(r.markers == 2)
        let fromRows = try await scene.read { try $0.importReconciliation(run: run.runID) }
        #expect(fromRows.rowsBefore == r.rowsBefore)
        #expect(fromRows.knowledgeRows == r.knowledgeRows)
        #expect(r.line.hasPrefix("rows before 17 · main 5 (live 4, tombstoned 1) · quarantine 12 (by reason "))
        #expect(r.line.contains(" · digests 12 · knowledge rows 11 (by field "))
        #expect(r.line.contains(" · pending lineage 1 · events 2 (9 decisions, members 3 resolved / 1 listed) · ignored 2 (0 bound / 2 unbound) · ledger lines 4 (1 torn at the end, kept with its bytes) · searches 0 (zero-hit 0, unreadable 0) · audit results 15 (15 accepted / 0 refused) · markers 2"))
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
        try scene.replaceAudit { $0.rows = nil }
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
                                                          field: .starRating, value: .int(3),
                                                          digest: PoisonedCatalogFixture.digest("deadLink"))])
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
            CatalogRow.EventMemberReading(eventID: PoisonedCatalogFixture.eventOneID, digest: PoisonedCatalogFixture.digest("healthy"),
                                          importedKey: PoisonedCatalogFixture.digest("healthy")),
            CatalogRow.EventMemberReading(eventID: PoisonedCatalogFixture.eventOneID, digest: PoisonedCatalogFixture.digest("stalePrint"),
                                          importedKey: "pair:" + PoisonedCatalogFixture.pairGroupID),
            CatalogRow.EventMemberReading(eventID: PoisonedCatalogFixture.eventTwoID, digest: PoisonedCatalogFixture.digest("curated-shared"),
                                          importedKey: PoisonedCatalogFixture.digest("curated-shared")),
        ])
        let listed = try await scene.read { reader -> Set<String> in
            var set = Set<String>()
            try reader.listedMemberKeys(run: run.runID) { set.insert($0) }
            return set
        }
        #expect(listed.contains("id:" + PoisonedCatalogFixture.id(.sampledOnly)))
        let decisions = try await scene.read { reader -> [Int] in
            var out: [Int] = []
            try reader.eventDecisions(run: run.runID) { out.append($0.sourceOrdinal) }
            return out.sorted()
        }
        #expect(decisions == Array(2..<11))
        let markers = try await scene.read { reader -> [CatalogRow.MarkerReading] in
            var out: [CatalogRow.MarkerReading] = []
            try reader.jobMarkers(run: run.runID) { out.append($0) }
            return out.sorted { $0.sourceFile.rawValue < $1.sourceFile.rawValue }
        }
        #expect(markers.map(\.sourceFile) == [.catalogAudit, .fullHashBackfill])
        #expect(markers.map(\.ordinal) == [0, 0])
        let ledger = try await scene.read { reader -> [Int] in
            var out: [Int] = []
            try reader.ledgerLines(run: run.runID) { out.append($0.sourceOrdinal) }
            return out.sorted()
        }
        #expect(ledger == [0, 1, 2, 3])
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

// MARK: - Codex D′ #1: the comparator proves identity and binding

@Suite("CatalogImporter — codex D′ #1: identity, binding, resolved membership")
struct CatalogImporterIdentityTests {

    /// Codex's swap: two occurrences' file references exchanged and their
    /// notes attached to opposite digests. Every row is still "present"; the
    /// comparator must name all four misses.
    @Test func swappedFileReferencesAndSwappedBindingsAreNamed() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let healthy = try #require(scene.fixture.ordinals(of: .healthy).first)
        let copyA = try #require(scene.fixture.ordinals(of: .curatedConflictA).first)
        let deadLink = try #require(scene.fixture.ordinals(of: .deadLink).first)
        let run = await scene.run(seam: { side in
            let a = side.fileLandings.firstIndex { $0.ordinal == healthy }
            let b = side.fileLandings.firstIndex { $0.ordinal == copyA }
            if let a, let b {
                let swapped = side.fileLandings[a].fileID
                side.fileLandings[a].fileID = side.fileLandings[b].fileID
                side.fileLandings[b].fileID = swapped
            }
            let starA = side.knowledgeSources.firstIndex { $0.ordinal == copyA && $0.field == .starRating }
            let starD = side.knowledgeSources.firstIndex { $0.ordinal == deadLink && $0.field == .starRating }
            if let starA, let starD {
                let swapped = side.knowledgeSources[starA].digest
                side.knowledgeSources[starA].digest = side.knowledgeSources[starD].digest
                side.knowledgeSources[starD].digest = swapped
            }
        })
        #expect(run.outcome.misses == [
            .rowIdentityWrong(ordinal: healthy, jsonRowID: PoisonedCatalogFixture.id(.healthy), landedOn: PoisonedCatalogFixture.id(.curatedConflictA)),
            .rowIdentityWrong(ordinal: copyA, jsonRowID: PoisonedCatalogFixture.id(.curatedConflictA), landedOn: PoisonedCatalogFixture.id(.healthy)),
            .curatedBindingWrong(ordinal: deadLink, field: .starRating),
            .curatedBindingWrong(ordinal: copyA, field: .starRating),
        ])
        let counts = try await scene.read { try $0.recordCounts() }
        #expect(counts.isEmpty)
    }

    /// Clearing the whole membership view used to pass because every key was
    /// "listed" in the decision stream. The three resolved members are missed.
    @Test func aClearedMembershipViewIsNamedMemberByMember() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let run = await scene.run(seam: { side in side.eventMembers.removeAll() })
        let misses = try #require(run.outcome.misses)
        #expect(misses.count == 3)
        #expect(misses.allSatisfy { $0.kind == .eventMemberMissing })
        let counts = try await scene.read { try $0.recordCounts() }
        #expect(counts.isEmpty)
    }

    @Test func aLandingWhoseDigestIsNotTheRowsIsNamed() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let healthy = try #require(scene.fixture.ordinals(of: .healthy).first)
        let run = await scene.run(seam: { side in
            if let i = side.fileLandings.firstIndex(where: { $0.ordinal == healthy }) {
                side.fileLandings[i].digest = PoisonedCatalogFixture.digest("elsewhere")
            }
        })
        #expect(run.outcome.misses == [.rowDigestWrong(ordinal: healthy, expected: PoisonedCatalogFixture.digest("healthy"),
                                                       actual: PoisonedCatalogFixture.digest("elsewhere"))])
    }
}

// MARK: - Codex D′ #2: duplicate keys are refused before any decode

@Suite("CatalogImporter — codex D′ #2: duplicate JSON keys")
struct CatalogImporterDuplicateKeyTests {

    @Test func aRowCarryingOneKeyTwiceRefusesTheRunBeforeAnyWrite() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let text = try #require(String(data: scene.fixture.catalogData, encoding: .utf8))
        let poisoned = text.replacingOccurrences(of: "\"records\":[{", with: "\"records\":[{\"userNotes\":\"first\",\"userNotes\":\"second\",")
        try #require(poisoned != text)
        try scene.replaceCatalog(bytes: Data(poisoned.utf8))
        let run = await scene.run()
        #expect(run.outcome.refusalKinds == [.duplicateJSONKey])
        let words = run.outcome.refusals.first?.words ?? ""
        #expect(words.contains("catalog row 0"))
        #expect(words.contains("\"userNotes\""))
        let counts = try await scene.read { try $0.recordCounts() }
        #expect(counts.isEmpty)
        #expect(scene.sink.lines.count == 2)
    }

    @Test func aSidecarCarryingOneKeyTwiceRefusesTheRun() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let events = try #require(scene.fixture.sidecarData[PoisonedCatalogFixture.eventsFileName])
        let poisoned = Data("{\"storeVersion\":1,".utf8) + events.dropFirst()
        try scene.overwrite(PoisonedCatalogFixture.eventsFileName, with: poisoned)
        let run = await scene.run()
        #expect(run.outcome.refusalKinds == [.duplicateJSONKey])
        let words = run.outcome.refusals.first?.words ?? ""
        #expect(words.contains("events-decisions.json"))
        #expect(words.contains("\"storeVersion\""))
        let counts = try await scene.read { try $0.recordCounts() }
        #expect(counts.isEmpty)
    }
}

// MARK: - Codex D′ #3: sidecars are re-read and compared by payload

@Suite("CatalogImporter — codex D′ #3: sidecars re-read")
struct CatalogImporterSidecarRereadTests {

    @Test func anEventDecisionChangedAfterTheGateIsRefusedAndNothingIsWritten() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let run = await scene.run(decodeSeam: {
            try? scene.replaceEvents { events in
                guard var decisions = events["decisions"]?.arrayValue, var first = decisions[0].objectValue else { return }
                first["verdict"] = .string("rejected")
                decisions[0] = .object(first)
                events["decisions"] = .array(decisions)
            }
        })
        #expect(run.outcome.refusalKinds == [.catalogChangedDuringImport])
        #expect(run.outcome.refusals.first?.words.contains("events-decisions.json") == true)
        let counts = try await scene.read { try $0.recordCounts() }
        #expect(counts.isEmpty)
    }

    @Test func aDecisionPayloadAlteredInTheViewIsAMiss() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let run = await scene.run(seam: { side in
            if let i = side.eventDecisions.firstIndex(where: { $0.sourceOrdinal == 2 }) {
                side.eventDecisions[i].payload = .object(["kind": .string("member"), "verdict": .string("rejected")])
            }
        })
        #expect(run.outcome.misses == [.eventDecisionDiffers(ordinal: 2)])
    }

    @Test func aLedgerPayloadAlteredInTheViewIsAMiss() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let run = await scene.run(seam: { side in
            if let i = side.ledgerLines.firstIndex(where: { $0.sourceOrdinal == 0 }) {
                side.ledgerLines[i].payload = .object(["event": .string("dateSet")])
            }
        })
        #expect(run.outcome.misses == [.ledgerLineDiffers(ordinal: 0)])
    }
}

// MARK: - Codex D′ #4: audit result words

@Suite("CatalogImporter — codex D′ #4: audit result words")
struct CatalogImporterAuditWordsTests {

    @Test func anUnknownAuditResultWordRefusesTheRun() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        try scene.replaceAudit { $0.rows?[0].result = "unreadable" }
        let run = await scene.run()
        #expect(run.outcome.refusalKinds == [.auditResultUnknownWord])
        let words = run.outcome.refusals.first?.words ?? ""
        #expect(words.contains("result 1"))
        #expect(words.contains("\"unreadable\""))
        let counts = try await scene.read { try $0.recordCounts() }
        #expect(counts.isEmpty)
    }

    @Test func everyAuditRowLandsWithItsWordAndDetailAndTheMarkerKeepsTheFilesHash() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let run = await scene.run()
        try #require(run.outcome.reconciliation != nil)
        let results = try await scene.read { reader -> [CatalogRow.AuditResult] in
            var out: [CatalogRow.AuditResult] = []
            try reader.auditResults(run: run.runID) { out.append($0) }
            return out
        }
        #expect(results.count == 15)
        let deadLink = try #require(results.first { $0.jsonRowID == PoisonedCatalogFixture.id(.deadLink) })
        #expect(deadLink.result == .link)
        #expect(deadLink.detail == .object(["detail": .string("a link is in the path")]))
        #expect(deadLink.judgedPath == PoisonedCatalogFixture.path(.deadLink))
        let marker = try await scene.read { reader -> CatalogRow.MarkerReading? in
            var found: CatalogRow.MarkerReading?
            try reader.jobMarkers(run: run.runID) { if $0.sourceFile == .catalogAudit { found = $0 } }
            return found
        }
        #expect(marker?.fileSHA256 == ImporterScene.sha256(scene.fixture.auditData))
    }
}

// MARK: - Codex D′ #5: the ledger's torn end and its interior

@Suite("CatalogImporter — codex D′ #5: ledger corruption")
struct CatalogImporterLedgerTests {

    private static var lines: [String] { PoisonedCatalogFixture.ledgerText().split(separator: "\n").map(String.init) }

    @Test func aMalformedLineBeforeTheEndRefusesTheRun() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let l = Self.lines
        try scene.replaceLedger([l[0], l[3], l[2]].joined(separator: "\n") + "\n")
        let run = await scene.run()
        #expect(run.outcome.refusalKinds == [.ledgerCorruptLine])
        #expect(run.outcome.refusals.first?.words.contains("line 1") == true)
        let counts = try await scene.read { try $0.recordCounts() }
        #expect(counts.isEmpty)
    }

    @Test func aMalformedLastLineThatIsTerminatedRefusesTheRun() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        try scene.replaceLedger(PoisonedCatalogFixture.ledgerText() + "\n")
        let run = await scene.run()
        #expect(run.outcome.refusalKinds == [.ledgerCorruptLine])
        #expect(run.outcome.refusals.first?.words.contains("line 3") == true)
    }

    @Test func aTornLastLineLandsAsAnUnparseableRowWithItsBytes() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let run = await scene.run()
        let r = try #require(run.outcome.reconciliation)
        #expect(r.ledgerUnparseable == 1)
        let torn = try await scene.read { reader -> CatalogRow.Ledger? in
            var found: CatalogRow.Ledger?
            try reader.ledgerLines(run: run.runID) { if $0.sourceOrdinal == 3 { found = $0 } }
            return found
        }
        #expect(torn?.kind == LedgerLinesJSON.Line.unparseableKind)
        #expect(torn?.payload["rawText"] == .string("{\"at\":\"2026-"))
        #expect(torn?.payload["rawBase64"] == .string(Data("{\"at\":\"2026-".utf8).base64EncodedString()))
    }
}

// MARK: - Codex D′ #6: an unrepresentable row is quarantined, not fatal

@Suite("CatalogImporter — codex D′ #6: unrepresentable rows")
struct CatalogImporterPreflightTests {

    @Test func aRowWhoseVolumeIdIsNotAUUIDIsQuarantinedAndTheRunProceeds() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        try scene.replaceRow(.healthy) { row in
            row["scanContext"] = .object(["volumeUUID": .string("VU-1"), "volumeName": .string("MyBook"), "scanHost": .string("FixtureHost")])
        }
        let run = await scene.run()
        let r = try #require(run.outcome.reconciliation, Comment(rawValue: "\(run.outcome)"))
        #expect(r.rowsMain == 4)
        #expect(r.quarantineByReason["unrepresentable"] == 1)
        #expect(r.digests == 11)                     // no content row through an unrepresentable occurrence
        let ordinal = try #require(scene.fixture.ordinals(of: .healthy).first)
        let entry = try #require(try await CatalogImporterTests.quarantineEntry(scene, run.runID, ordinal))
        #expect(entry.reasonCode == .unrepresentable)
        #expect(entry.words.contains("volume id \"VU-1\" is not a 36-character UUID"))
        #expect(entry.words.hasPrefix("cannot be stored as-is (the gate said main): "))
    }

    @Test func aHashedRowWithANegativeSizeIsQuarantinedAndTheRunProceeds() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        try scene.replaceRow(.healthy) { row in
            row["sizeBytes"] = .int(-1)
            if var fixity = row["contentFixity"]?.objectValue {
                fixity["byteCount"] = .int(-1)
                row["contentFixity"] = .object(fixity)
            }
        }
        let run = await scene.run()
        let r = try #require(run.outcome.reconciliation, Comment(rawValue: "\(run.outcome)"))
        #expect(r.quarantineByReason["unrepresentable"] == 1)
        let ordinal = try #require(scene.fixture.ordinals(of: .healthy).first)
        let entry = try #require(try await CatalogImporterTests.quarantineEntry(scene, run.runID, ordinal))
        #expect(entry.words.contains("size_bytes is negative (-1)"))
        #expect(entry.digest == PoisonedCatalogFixture.digest("healthy"))
    }

    @Test func anEventMemberWithABadRangeRefusesTheRun() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        try scene.replaceEvents { events in
            guard var decisions = events["decisions"]?.arrayValue else { return }
            decisions.append(.object(["kind": .string("member"), "eventID": .string(PoisonedCatalogFixture.eventOneID),
                                      "range": .object(["contentKey": .string(PoisonedCatalogFixture.digest("healthy")),
                                                        "start": .int(5), "end": .int(2)]),
                                      "verdict": .string("accepted")]))
            events["decisions"] = .array(decisions)
        }
        let run = await scene.run()
        #expect(run.outcome.refusalKinds == [.unrepresentableSidecarEntry])
        #expect(run.outcome.refusals.first?.words.contains("range start 5.0 is after its end 2.0") == true)
        let counts = try await scene.read { try $0.recordCounts() }
        #expect(counts.isEmpty)
    }
}

// MARK: - Codex D′ #7: the empty-target check repeats inside the transaction

@Suite("CatalogImporter — codex D′ #7: empty-target race")
struct CatalogImporterEmptyTargetTests {

    @Test func aWriteBetweenTheOuterCheckAndTheTransactionIsRefusedInsideIt() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let run = await scene.run(preTransaction: { repository in
            _ = await repository.write(as: .ui) { tx in
                try tx.insertContent(CatalogRecordDTO.ContentRow(digest: String(repeating: "e", count: 64), algorithm: "sha256",
                                                                 byteCount: 1, firstSeenAt: 0, firstSeenHow: .job))
            }
        })
        #expect(run.outcome.refusalKinds == [.targetNotEmpty])
        let counts = try await scene.read { try $0.recordCounts() }
        #expect(counts == CatalogRow.TableCounts(files: 0, quarantine: 0, content: 1, importRuns: 0))
        let generation = try await scene.read { $0.generation }
        #expect(generation == 1)
    }
}
