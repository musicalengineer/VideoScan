// ImportGateTests.swift
// The §f truth table (contract docs/design/catalog_contract_freeze_2026_10_17.md):
// ONE test per table row (named by the row), one per precedence collision,
// one per run-level refusal, the N1 snapshot rule, and the poisoned fixture
// end to end. The words are pinned verbatim against the contract file.
// One condition per #expect.

import Foundation
import Testing
@testable import VideoScanCore

private enum G {
    static let hex = String(repeating: "c", count: 64)
    static let path = "/Volumes/T/clip.mov"
    static let window = ImportGate.AuditWindow(startedAt: 1_000, finishedAt: 2_000)

    static func finding(_ rule: String = "oneLiveRowPerPath", tier: Int = 5, words: String = "two live rows share a path",
                        needsDecision: Bool = true) -> ImportGate.Finding {
        ImportGate.Finding(tier: tier, rule: rule, recordID: "R", words: words, needsDecision: needsDecision)
    }

    /// A row that lands in main (§f row 8) unless a parameter says otherwise.
    static func input(occurrences: Int = 1,
                      digest: CatalogRecordDTO.DigestState = .known(digest: hex, source: .contentFixity),
                      marker: Bool = false,
                      audit: ImportGate.AuditEvidence? = ImportGate.AuditEvidence(result: .present),
                      seenAt: Int64? = 1_500,
                      findings: [ImportGate.Finding] = []) -> ImportGate.Input {
        ImportGate.Input(occurrences: occurrences, digest: digest, markerSet: marker, audit: audit,
                         rowFullPath: path, rowAuditSeenAt: seenAt, auditWindow: window, findings: findings)
    }

    static func judged(_ r: CatalogDDL.AuditResult) -> ImportGate.AuditEvidence {
        ImportGate.AuditEvidence(result: r, judgedPath: path)
    }

    static func reason(_ l: ImportGate.Landing) -> CatalogDDL.ReasonCode? { l.reason }
}

@Suite("Import gate — §f table, one test per row")
struct ImportGateTableTests {

    @Test func row1_aUUIDThatOccursTwiceQuarantinesEveryOccurrence() {
        let l = ImportGate.decide(G.input(occurrences: 2))
        #expect(l == .quarantine(reason: .duplicateId, words: "this catalog entry appears 2 times; each copy kept", findings: []))
    }

    @Test func row2_twoFixitiesThatDisagreeQuarantine() {
        let l = ImportGate.decide(G.input(digest: .disagree(digests: [G.hex, String(repeating: "d", count: 64)])))
        #expect(l == .quarantine(reason: .fixityDisagree, words: ImportGate.Words.fixityDisagree, findings: []))
    }

    @Test func row3_aMarkerWithADigestAndNoFindingIsMainTombstoned() {
        let l = ImportGate.decide(G.input(marker: true))
        #expect(l == .main(tombstoned: true))
    }

    @Test func row3b_aMarkerWithADigestAndATier5FindingQuarantines() {
        let f = G.finding()
        let l = ImportGate.decide(G.input(marker: true, findings: [f]))
        #expect(l == .quarantine(reason: .tier5Finding, words: f.words, findings: [f]))
    }

    @Test func row3b_aMarkedReferenceMovieQuarantinesAsReferenceMovie() {
        let f = G.finding(ImportGate.referenceMovieRule, words: "a reference movie")
        let l = ImportGate.decide(G.input(marker: true, findings: [f]))
        #expect(G.reason(l) == CatalogDDL.ReasonCode.referenceMovie)
    }

    @Test func row3c_aMarkerWithNoDigestQuarantinesAsHistory() {
        let l = ImportGate.decide(G.input(digest: .none, marker: true))
        #expect(l == .quarantine(reason: .removedNoDigest, words: ImportGate.Words.removedNoDigest, findings: []))
    }

    @Test func row4_auditGoneQuarantines() {
        let l = ImportGate.decide(G.input(audit: G.judged(.gone)))
        #expect(l == .quarantine(reason: .auditGone, words: ImportGate.Words.auditGone, findings: []))
    }

    @Test func row4b_auditNeverSeenQuarantines() {
        let l = ImportGate.decide(G.input(audit: G.judged(.neverSeen)))
        #expect(l == .quarantine(reason: .auditNeverSeen, words: ImportGate.Words.auditNeverSeen, findings: []))
    }

    @Test func row4b_noAuditResultReadsAsNeverSeen() {
        let l = ImportGate.decide(G.input(audit: nil))
        #expect(G.reason(l) == CatalogDDL.ReasonCode.auditNeverSeen)
    }

    @Test func row4c_couldNotCheckQuarantines() {
        let l = ImportGate.decide(G.input(audit: G.judged(.couldNotCheck)))
        #expect(l == .quarantine(reason: .auditCouldNotCheck, words: ImportGate.Words.auditCouldNotCheck, findings: []))
    }

    @Test func row4c_aLinkInThePathQuarantinesAsCouldNotCheck() {
        let l = ImportGate.decide(G.input(audit: G.judged(.link)))
        #expect(G.reason(l) == CatalogDDL.ReasonCode.auditCouldNotCheck)
    }

    @Test func row4d_auditChangedQuarantines() {
        let l = ImportGate.decide(G.input(audit: G.judged(.changed)))
        #expect(l == .quarantine(reason: .auditChanged, words: ImportGate.Words.auditChanged, findings: []))
    }

    @Test func row5_presentWithNoDigestQuarantines() {
        let l = ImportGate.decide(G.input(digest: .none))
        #expect(l == .quarantine(reason: .noWholeFileDigest, words: ImportGate.Words.noWholeFileDigest, findings: []))
    }

    @Test func row6_presentWithATier5FindingQuarantinesWithTheFindingsWords() {
        let f = G.finding()
        let l = ImportGate.decide(G.input(findings: [f]))
        #expect(l == .quarantine(reason: .tier5Finding, words: f.words, findings: [f]))
    }

    @Test func row6_aReferenceMovieFindingQuarantinesAsReferenceMovie() {
        let f = G.finding(ImportGate.referenceMovieRule, words: "a reference movie")
        let l = ImportGate.decide(G.input(findings: [f]))
        #expect(l == .quarantine(reason: .referenceMovie, words: f.words, findings: [f]))
    }

    @Test func row7_aTier4FindingOnlyIsMainAndListed() {
        let i = G.input(findings: [G.finding("derivedStampsMatchContent", tier: 4)])
        #expect(ImportGate.decide(i) == .main(tombstoned: false))
        #expect(ImportGate.tier4Listed(i))
    }

    @Test func row8_presentWithADigestAndNoFindingIsMain() {
        let i = G.input()
        #expect(ImportGate.decide(i) == .main(tombstoned: false))
        #expect(!ImportGate.tier4Listed(i))
    }
}

@Suite("Import gate — the contract's words, verbatim")
struct ImportGateWordsTests {

    /// Each reason's words appear in the contract §f table as `code` — "words".
    @Test func everyReasonsWordsAreTheContractsWords() throws {
        let contract = try ImportTestSupport.text(ImportTestSupport.contractURL)
        let pairs: [(String, String)] = [
            ("duplicateId", ImportGate.Words.duplicateId(7).replacingOccurrences(of: "7", with: "N")),
            ("fixityDisagree", ImportGate.Words.fixityDisagree),
            ("removedNoDigest", ImportGate.Words.removedNoDigest),
            ("auditGone", ImportGate.Words.auditGone),
            ("auditNeverSeen", ImportGate.Words.auditNeverSeen),
            ("auditCouldNotCheck", ImportGate.Words.auditCouldNotCheck),
            ("auditChanged", ImportGate.Words.auditChanged),
            ("noWholeFileDigest", ImportGate.Words.noWholeFileDigest),
        ]
        for (code, words) in pairs {
            #expect(contract.contains("`\(code)` — \"\(words)\""), "\(code)")
        }
    }
}

@Suite("Import gate — N1 snapshot rule")
struct ImportGateSnapshotTests {

    @Test func presentWithAStampBeforeTheAuditReadsAsNeverSeen() {
        #expect(G.reason(ImportGate.decide(G.input(seenAt: 999))) == CatalogDDL.ReasonCode.auditNeverSeen)
    }

    @Test func presentWithAStampAfterTheAuditReadsAsNeverSeen() {
        #expect(G.reason(ImportGate.decide(G.input(seenAt: 2_001))) == CatalogDDL.ReasonCode.auditNeverSeen)
    }

    @Test func presentWithNoStampReadsAsNeverSeen() {
        #expect(G.reason(ImportGate.decide(G.input(seenAt: nil))) == CatalogDDL.ReasonCode.auditNeverSeen)
    }

    @Test func presentOnTheWindowsEdgesIsAccepted() {
        #expect(ImportGate.decide(G.input(seenAt: 1_000)) == .main(tombstoned: false))
        #expect(ImportGate.decide(G.input(seenAt: 2_000)) == .main(tombstoned: false))
    }

    @Test func goneJudgedAtAnotherPathReadsAsNeverSeen() {
        let audit = ImportGate.AuditEvidence(result: .gone, judgedPath: "/Volumes/T/old.mov")
        #expect(G.reason(ImportGate.decide(G.input(audit: audit))) == CatalogDDL.ReasonCode.auditNeverSeen)
    }

    @Test func goneWithNoJudgedPathReadsAsNeverSeen() {
        let audit = ImportGate.AuditEvidence(result: .gone, judgedPath: nil)
        #expect(G.reason(ImportGate.decide(G.input(audit: audit))) == CatalogDDL.ReasonCode.auditNeverSeen)
    }
}

@Suite("Import gate — precedence collisions")
struct ImportGatePrecedenceTests {

    @Test func duplicateIdBeatsFixityDisagree() {
        let l = ImportGate.decide(G.input(occurrences: 3, digest: .disagree(digests: [G.hex, G.hex.uppercased()])))
        #expect(G.reason(l) == CatalogDDL.ReasonCode.duplicateId)
    }

    @Test func fixityDisagreeBeatsAMarker() {
        let l = ImportGate.decide(G.input(digest: .disagree(digests: [G.hex, String(repeating: "e", count: 64)]), marker: true))
        #expect(G.reason(l) == CatalogDDL.ReasonCode.fixityDisagree)
    }

    @Test func aMarkerBeatsAuditGone() {
        let l = ImportGate.decide(G.input(marker: true, audit: G.judged(.gone)))
        #expect(l == .main(tombstoned: true))
    }

    @Test func aMarkerWithNoDigestBeatsAuditPresent() {
        let l = ImportGate.decide(G.input(digest: .none, marker: true))
        #expect(G.reason(l) == CatalogDDL.ReasonCode.removedNoDigest)
    }

    @Test func auditGoneBeatsATier5FindingAndKeepsIt() {
        let f = G.finding(ImportGate.referenceMovieRule)
        let l = ImportGate.decide(G.input(audit: G.judged(.gone), findings: [f]))
        #expect(l == .quarantine(reason: .auditGone, words: ImportGate.Words.auditGone, findings: [f]))
    }

    @Test func noWholeFileDigestBeatsATier5FindingAndKeepsIt() {
        let f = G.finding()
        let l = ImportGate.decide(G.input(digest: .none, findings: [f]))
        #expect(l == .quarantine(reason: .noWholeFileDigest, words: ImportGate.Words.noWholeFileDigest, findings: [f]))
    }

    @Test func duplicateIdKeepsEveryTier5Finding() {
        let f = G.finding(ImportGate.referenceMovieRule)
        let l = ImportGate.decide(G.input(occurrences: 2, findings: [f]))
        #expect(l == .quarantine(reason: .duplicateId, words: ImportGate.Words.duplicateId(2), findings: [f]))
    }

    @Test func aTier5FindingBeatsATier4Finding() {
        let l = ImportGate.decide(G.input(findings: [G.finding("derivedStampsMatchContent", tier: 4), G.finding()]))
        #expect(G.reason(l) == CatalogDDL.ReasonCode.tier5Finding)
    }

    @Test func referenceMovieBeatsAnotherTier5RuleOnOneRow() {
        let l = ImportGate.decide(G.input(findings: [G.finding(), G.finding(ImportGate.referenceMovieRule)]))
        #expect(G.reason(l) == CatalogDDL.ReasonCode.referenceMovie)
    }

    @Test func aTier5FindingThatNeedsNoDecisionDoesNotGate() {
        let l = ImportGate.decide(G.input(findings: [G.finding(needsDecision: false)]))
        #expect(l == .main(tombstoned: false))
    }

    @Test func aTier4FindingOnAQuarantinedRowIsNotListed() {
        let i = G.input(digest: .none, findings: [G.finding("derivedStampsMatchContent", tier: 4)])
        #expect(!ImportGate.tier4Listed(i))
    }
}

@Suite("Import gate — run-level refusals, one test each")
struct ImportGateRunRefusalTests {

    static let sha = String(repeating: "f", count: 64)

    static func report(_ edit: (inout ImportGate.ReportFacts) -> Void = { _ in }) -> ImportGate.ReportFacts {
        var r = ImportGate.ReportFacts(outcome: "completed", catalogHashCertified: true, catalogSHA256: sha,
                                       snapshotGeneration: 41, startedAt: 3_000, findingsTotal: 2, findingsListed: 2,
                                       tiersNotRun: [], tiersPresent: [0, 1, 2, 3, 4, 5, 6])
        edit(&r)
        return r
    }

    static func audit(_ edit: (inout ImportGate.AuditMarkerFacts) -> Void = { _ in }) -> ImportGate.AuditMarkerFacts {
        var a = ImportGate.AuditMarkerFacts(outcome: "completed", partial: false, startedAt: 1_000, finishedAt: 2_000,
                                            hasRowResults: true, savedGeneration: 41)
        edit(&a)
        return a
    }

    static func run(_ edit: (inout ImportGate.RunInput) -> Void = { _ in }) -> [ImportGate.RunRefusal] {
        var r = ImportGate.RunInput(catalogVersion: 6, catalogGeneration: 41, catalogSHA256: sha,
                                    report: Self.report(), audit: Self.audit())
        edit(&r)
        return ImportGate.runLevelRefusals(r)
    }

    @Test func aCleanRunHasNoRefusal() {
        #expect(Self.run().isEmpty)
    }

    @Test func aJSONVersionAboveSixRefuses() {
        #expect(Self.run { $0.catalogVersion = 7 } == [.jsonVersionTooNew(7)])
    }

    @Test func aMissingReportRefuses() {
        let refusals = Self.run { $0.report = nil }
        #expect(refusals.contains(.reportMissing))
    }

    @Test func aReportThatDidNotCompleteRefuses() {
        #expect(Self.run { $0.report = Self.report { $0.outcome = "stopped" } } == [.reportNotCompleted("stopped")])
    }

    @Test func aReportThatDidNotCertifyTheHashRefuses() {
        #expect(Self.run { $0.report = Self.report { $0.catalogHashCertified = false } } == [.reportNotCertified])
    }

    @Test func aReportForAnotherFileRefuses() {
        let other = String(repeating: "0", count: 64)
        #expect(Self.run { $0.report = Self.report { $0.catalogSHA256 = other } }
                == [.reportHashMismatch(report: other, file: Self.sha)])
    }

    @Test func aReportForAnotherGenerationRefuses() {
        let refusals = Self.run { $0.report = Self.report { $0.snapshotGeneration = 40 } }
        #expect(refusals.contains(.reportGenerationMismatch(report: 40, file: 41)))
    }

    @Test func anAuditSavedAtAnotherGenerationRefuses() {
        #expect(Self.run { $0.audit = Self.audit { $0.savedGeneration = 40 } }
                == [.auditGenerationMismatch(audit: 40, snapshot: 41, file: 41)])
    }

    @Test func truncatedFindingsRefuse() {
        #expect(Self.run { $0.report = Self.report { $0.findingsTotal = 5_001; $0.findingsListed = 5_000 } }
                == [.findingsTruncated(total: 5_001, listed: 5_000)])
    }

    @Test func tier0NotRunRefuses() {
        #expect(Self.run { $0.report = Self.report { $0.tiersNotRun = [0] } } == [.tierNotRun(0)])
    }

    @Test func tier1NotRunRefuses() {
        #expect(Self.run { $0.report = Self.report { $0.tiersNotRun = [1] } } == [.tierNotRun(1)])
    }

    @Test func tier5AbsentFromTheReportRefuses() {
        #expect(Self.run { $0.report = Self.report { $0.tiersPresent = [0, 1, 2, 3, 4, 6] } } == [.tierNotRun(5)])
    }

    @Test func tier3NotRunDoesNotRefuse() {
        #expect(Self.run { $0.report = Self.report { $0.tiersNotRun = [3] } }.isEmpty)
    }

    @Test func aMissingAuditRefuses() {
        #expect(Self.run { $0.audit = nil } == [.auditMissing])
    }

    @Test func aPartialAuditRefuses() {
        #expect(Self.run { $0.audit = Self.audit { $0.partial = true } } == [.auditPartial])
    }

    @Test func anAuditThatDidNotCompleteRefuses() {
        #expect(Self.run { $0.audit = Self.audit { $0.outcome = "stopped" } } == [.auditNotCompleted("stopped")])
    }

    @Test func anAuditThatFinishedAfterVerifyStartedRefuses() {
        #expect(Self.run { $0.audit = Self.audit { $0.finishedAt = 3_000 } } == [.auditFinishedAfterIntegrityStarted])
    }

    @Test func anAuditWithNoPerRowResultsRefuses() {
        #expect(Self.run { $0.audit = Self.audit { $0.hasRowResults = false } } == [.auditHasNoRowResults])
    }

    @Test func aDuplicatedEventIDRefuses() {
        #expect(Self.run { $0.duplicateEventIDs = ["E1"] } == [.duplicateEventID("E1")])
    }

    @Test func anOpenDeleteDuplicatesPlanRefuses() {
        #expect(Self.run { $0.openDeleteDuplicatesPlans = ["plan-1"] } == [.openDeleteDuplicatesPlan("plan-1")])
    }

    @Test func anOpenArchiveAngelBatchRefuses() {
        #expect(Self.run { $0.openAngelBatches = ["batch-1"] } == [.openAngelBatch("batch-1")])
    }

    @Test func aRunningWriterRefuses() {
        #expect(Self.run { $0.runningWriters = ["the app"] } == [.anotherWriterRunning("the app")])
    }

    @Test func everyRefusalHasWords() {
        let all: [ImportGate.RunRefusal] = [
            .jsonVersionTooNew(7), .reportMissing, .reportNotCompleted("x"), .reportNotCertified,
            .reportHashMismatch(report: nil, file: "f"), .reportGenerationMismatch(report: nil, file: 1),
            .auditGenerationMismatch(audit: nil, snapshot: nil, file: 1), .findingsTruncated(total: 2, listed: 1),
            .tierNotRun(0), .auditMissing, .auditPartial, .auditNotCompleted("x"), .auditFinishedAfterIntegrityStarted,
            .auditHasNoRowResults, .duplicateEventID("e"), .openDeleteDuplicatesPlan("p"), .openAngelBatch("b"),
            .anotherWriterRunning("w"),
        ]
        for r in all {
            #expect(!r.words.isEmpty, "\(r)")
        }
    }

    @Test func theVersionRefusalNamesTheVersions() {
        #expect(ImportGate.RunRefusal.jsonVersionTooNew(7).words == "catalog.json is version 7; this importer reads versions 1–6")
    }
}

@Suite("Import gate — the poisoned fixture end to end")
struct ImportGateFixtureTests {

    @Test func everyShapeLandsWhereTheContractSays() throws {
        let run = try ImportTestSupport.fixtureRun()
        for (ordinal, shape) in run.fixture.order.enumerated() {
            let landing = ImportGate.decide(run.inputs[ordinal])
            let expected = PoisonedCatalogFixture.expected(shape)
            #expect(landing.reason == expected.reason, "\(shape.rawValue)")
            if expected.reason == nil {
                #expect(landing == .main(tombstoned: expected.tombstoned), "\(shape.rawValue)")
            }
        }
    }

    @Test func theFixtureRunHasNoRunLevelRefusal() throws {
        let run = try ImportTestSupport.fixtureRun()
        let input = ImportGate.RunInput(catalogVersion: run.catalog.version, catalogGeneration: run.catalog.generation,
                                        catalogSHA256: run.fixture.catalogSHA256, report: run.report.facts,
                                        audit: run.audit.facts)
        #expect(ImportGate.runLevelRefusals(input).isEmpty)
    }

    @Test func theStalePrintIsListed() throws {
        let run = try ImportTestSupport.fixtureRun()
        let ordinal = try #require(run.fixture.ordinals(of: .stalePrint).first)
        #expect(ImportGate.tier4Listed(run.inputs[ordinal]))
    }

    @Test func theCuratedConflictPairSharesOneDigestWithDifferentStars() throws {
        let run = try ImportTestSupport.fixtureRun()
        let a = try #require(run.fixture.ordinals(of: .curatedConflictA).first)
        let b = try #require(run.fixture.ordinals(of: .curatedConflictB).first)
        #expect(run.dtos[a].digestState.digest == run.dtos[b].digestState.digest)
        #expect(run.dtos[a].curated.starRating != run.dtos[b].curated.starRating)
        #expect(run.dtos[a].curated.userDate != run.dtos[b].curated.userDate)
    }

    @Test func theCaseAliasPairDiffersOnlyByCase() throws {
        let run = try ImportTestSupport.fixtureRun()
        let a = try #require(run.fixture.ordinals(of: .caseAliasUpper).first)
        let b = try #require(run.fixture.ordinals(of: .caseAliasLower).first)
        #expect(run.dtos[a].file.fullPath != run.dtos[b].file.fullPath)
        #expect(run.dtos[a].file.pathFold == run.dtos[b].file.pathFold)
    }

    @Test func theFixtureWritesAndReadsBackByteForByte() throws {
        let fixture = PoisonedCatalogFixture()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("poisoned-catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try fixture.write(to: dir)
        let back = try Data(contentsOf: dir.appendingPathComponent(PoisonedCatalogFixture.catalogFileName))
        #expect(back == fixture.catalogData)
    }

    @Test func theFixtureIsDeterministic() {
        #expect(PoisonedCatalogFixture().catalogData == PoisonedCatalogFixture().catalogData)
    }
}
