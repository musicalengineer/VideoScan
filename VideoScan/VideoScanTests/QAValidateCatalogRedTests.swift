// QAValidateCatalogRedTests.swift — QA red tests for feat/validate-catalog-one-verb (2026-10-20).
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let qaNow = Date(timeIntervalSince1970: 2_000_000_000)

private func qaReport(tiers: [IntegrityTier], findings: [IntegrityFinding], total: Int) -> IntegrityReport {
    IntegrityReport(runID: UUID(), startedAt: qaNow, verifiedAt: qaNow, outcome: .completed, catalogFile: "/x/catalog.json",
                    rowsTotal: 100, rowsLive: 100, elapsedSeconds: 1, tiers: tiers, findings: findings, findingsTotal: total)
}

@Suite("QA red — Validate Catalog / reality band")
struct QAValidateCatalogRedTests {

    // P1: IntegrityRealityFacts.swift:78-88 — breaks come only from KEPT findings; the 5,000 cap is first-come
    // in tier order (VerifyCatalogJob.swift:259), so tier 3 silent-print findings can push every tier-4/5 break out.
    @Test("a report that hit the findings cap still turns the band RED when a tier counted decisions it could not keep")
    func cappedReportKeepsItsBreaks() {
        let silent = (0..<IntegrityReport.findingsCap).map { _ in
            IntegrityFinding(tier: 3, rule: VerifyCatalogTiers.silentPrintRule, recordID: UUID(), filename: "f.mov",
                             words: "the header says Video+Audio, but the sound print heard nothing (silent)", needsDecision: true)
        }
        let t3 = IntegrityTier(tier: 3, name: VerifyCatalogTiers.name(3), verifiedAt: qaNow, result: .needsDecision(silent.count),
                               needsDecision: silent.count, summary: "silent")
        let t5 = IntegrityTier(tier: 5, name: VerifyCatalogTiers.name(5), verifiedAt: qaNow, result: .needsDecision(2),
                               needsDecision: 2, summary: "2 paths have more than one live row")
        let r = qaReport(tiers: [t3, t5], findings: silent, total: silent.count + 2)
        let f = IntegrityRealityFacts.from(report: r)
        let facts = CatalogRealityFacts(validation: .completed(at: qaNow), breaks: f.breaks, rowsToCheck: 100, unsettled: f.unsettled)
        #expect(CatalogRealityPolicy.colour(facts, now: qaNow) == .red, "tier 5 counted 2 decisions; the band says \(CatalogRealityPolicy.colour(facts, now: qaNow))")
    }

    // P2: IntegrityRealityFacts.swift:121-133 — gaps() only reads tier 1's couldNotCheck; tier 5's
    // "generation could not be read" (+1, no finding — VerifyCatalogTiers.swift:502) vanishes.
    @Test("tier 5 could not read the store's generation → not green")
    func tier5GenerationUnreadableIsNotGreen() {
        let t5 = IntegrityTier(tier: 5, name: VerifyCatalogTiers.name(5), verifiedAt: qaNow, result: .couldNotCheck(1),
                               checked: 100, passed: 100, couldNotCheck: 1,
                               summary: "catalog.sqlite's generation could not be read (not asked) — run again")
        let f = IntegrityRealityFacts.from(report: qaReport(tiers: [t5], findings: [], total: 0))
        let facts = CatalogRealityFacts(validation: .completed(at: qaNow), breaks: f.breaks, rowsToCheck: 100, unsettled: f.unsettled)
        #expect(CatalogRealityPolicy.colour(facts, now: qaNow) != .green)
    }

    // P2: MissingCopyCounts.swift:516-518 — group membership alone counts as "another copy is present",
    // even when both rows carry DIFFERENT whole-file SHA-256s.
    @Test("a live group-mate with a DIFFERENT full SHA-256 is not another copy")
    func differentDigestIsNotACopy() {
        let g = UUID()
        let counts = MissingCopyCalculator.count([MissingCopyInput(group: g, digest: "aaa", isMissing: true),
                                                  MissingCopyInput(group: g, digest: "bbb", isMissing: false)])
        #expect(counts == MissingCopyCounts(noOtherCopy: 1, otherCopyPresent: 0))
    }

    // P2: with no full SHA-256 on either side, a likeness/sampled-hash group is not proof of a surviving copy.
    // RULING (Manager 2026-10-20, relaying QA's case b): it is its own review line, "Missing — a possible copy,
    // not proven" (door: Fill In Full Hashes, then Validate) — never "another copy is present". The expectation
    // below names that third count (feature-dev, when the line was added).
    @Test("group membership without a matching full SHA-256 is not proof of a surviving copy")
    func groupWithoutDigestIsNotProof() {
        let g = UUID()
        let counts = MissingCopyCalculator.count([MissingCopyInput(group: g, digest: nil, isMissing: true),
                                                  MissingCopyInput(group: g, digest: nil, isMissing: false)])
        #expect(counts == MissingCopyCounts(noOtherCopy: 0, otherCopyPresent: 0, possibleCopyNotProven: 1))
    }

    // P3: CatalogFreshnessFacts.swift:108-112 — a corrupt catalog-audit.json reads as nil = "never ran" (yellow),
    // not as an unreadable record (red, per the claim "unreadable sidecar/report → RED").
    @Test("a corrupt catalog-audit.json is an unreadable record (red), not 'never validated'")
    func corruptAuditRecordIsRed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qa-validate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent(CatalogAuditRunMarker.fileName))
        let facts = CatalogFreshnessFactsReader.read(catalogFile: folder.appendingPathComponent("catalog.json").path)
        let reality = CatalogRealityFactsBuilder.realityFacts(facts)
        #expect(reality.unreadable.contains { $0.contains(CatalogAuditRunMarker.fileName) }, "unreadable = \(reality.unreadable)")
    }

    // P3: ValidateCatalogJob.swift:222-233 — a record dated in the FUTURE (clock stepped back since, or a copied
    // marker) passes as "this run's" when the run's own persist failed silently (CatalogAuditRun.swift:435 try?).
    @Test("a completed audit record dated after now is not this run's")
    func futureDatedRecordIsNotThisRun() {
        let started = Date()
        var future = CatalogAuditRunRecord(startedAt: started.addingTimeInterval(86_400))
        future.outcome = .completed
        future.finishedAt = started.addingTimeInterval(86_500)
        #expect(ValidateCatalogJob.auditRecordProblem(future, auditStartedAt: started) != nil)
    }
}
