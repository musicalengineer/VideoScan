// PromoteArchiveIntegrityRuleTests.swift
// The seams behind GH #219 and GH #190 (see PromoteArchiveIntegrityTests.swift
// for the end-to-end red→green cases): the date-agreement RULE and its
// Verify SENSOR, the sha256 digest INDEX, the engine's checked-digest GUARD,
// a LYING stored fixity, and both 100k SCALE budgets. Sandboxed under the
// process temp dir; nothing here touches /Volumes, App Support or the real
// archive.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - GH #219: the rule (pure) and the sensor (Verify Archive Copies)

@Suite("GH #219 — date agreement rule + Verify sensor", .serialized)
@MainActor
struct ArchiveDateAgreementSensorTests {

    typealias A = ArchiveDateAgreement

    @Test("agree = equal at the coarser precision; decades contain years; Undated agrees only with Undated")
    func agreeRule() {
        #expect(A.agree(.year(1992), .day(year: 1992, month: 7, day: 15)))
        #expect(A.agree(.month(year: 1992, month: 7), .day(year: 1992, month: 7, day: 15)))
        #expect(!A.agree(.month(year: 1992, month: 6), .day(year: 1992, month: 7, day: 15)))
        #expect(!A.agree(.year(1991), .year(1992)))
        #expect(A.agree(.year(1945), .decade(startYear: 1940)) && A.agree(.decade(startYear: 1940), .year(1949)))
        #expect(!A.agree(.year(1990), .decade(startYear: 1940)) && !A.agree(.year(1950), .decade(startYear: 1940)))
        #expect(A.agree(.unknown, .unknown) && !A.agree(.year(1990), .unknown) && !A.agree(.unknown, .decade(startYear: 1990)))
    }

    @Test("promoteRefusal: only when the record would keep a contradicting own date; never when Promote writes the chosen one")
    func promoteRefusalRule() {
        #expect(A.promoteRefusal(placement: .year(1947), writesChosenDate: true, sourceUserDate: "1990",
                                 sourceKnown: true, isMachineProposal: false) == nil)
        let r = A.promoteRefusal(placement: .decade(startYear: 1940), writesChosenDate: false, sourceUserDate: "1990",
                                 sourceKnown: true, isMachineProposal: false)
        #expect(r?.contains("the 1940s") == true && r?.contains("1990 (known)") == true
                && r?.contains("Nothing was filed") == true, "\(r ?? "nil")")
        #expect(A.promoteRefusal(placement: .decade(startYear: 1940), writesChosenDate: false, sourceUserDate: "1945",
                                 sourceKnown: true, isMachineProposal: false) == nil)
        #expect(A.promoteRefusal(placement: .decade(startYear: 1940), writesChosenDate: false, sourceUserDate: nil,
                                 sourceKnown: false, isMachineProposal: false) == nil)
        // The resolver refining a year-only date by an agreeing camera date is NOT a disagreement.
        #expect(A.promoteRefusal(placement: .day(year: 1992, month: 7, day: 15), writesChosenDate: false,
                                 sourceUserDate: "1992", sourceKnown: true, isMachineProposal: false) == nil)
        let m = A.promoteRefusal(placement: .year(1999), writesChosenDate: false, sourceUserDate: "2004",
                                 sourceKnown: false, isMachineProposal: true)
        #expect(m?.contains("machine guess") == true, "\(m ?? "nil")")
    }

    @Test("problems: all agree → none; index ≠ placement; catalog ≠ index — each named")
    func problemsRule() {
        let rel = "30_Video/1940-1949/1947/1947-xx-xx_Wedding.mov"
        #expect(A.problems(relPath: rel, manifestDate: "1947-xx-xx", userDate: "1947", filedDate: "1947").isEmpty)
        #expect(A.problems(relPath: "30_Video/1940-1949/xxxx-xx-xx_W.mov", manifestDate: "1940s", userDate: nil, filedDate: nil).isEmpty)
        #expect(A.problems(relPath: "30_Video/Undated/xxxx-xx-xx_W.mov", manifestDate: "", userDate: nil, filedDate: nil).isEmpty)
        let idx = A.problems(relPath: rel, manifestDate: "2004-xx-xx", userDate: nil, filedDate: "1947")
        #expect(idx.count == 2 && idx[0].contains("index says 2004") && idx[0].contains("1947"), "\(idx)")
        let cat = A.problems(relPath: rel, manifestDate: "1947-xx-xx", userDate: "1990", filedDate: "1947")
        #expect(cat.count == 1 && cat[0].contains("catalog says 1990"), "\(cat)")
        // The pre-fix #219 shape: decade folder + manifest, the source's 1990 on the record.
        let old = A.problems(relPath: "30_Video/1940-1949/xxxx-xx-xx_W.mov", manifestDate: "1940s", userDate: "1990", filedDate: nil)
        #expect(old.count == 1 && old[0].contains("the 1940s"), "\(old)")
    }

    @Test("SENSOR (Verify): a disagreeing archived record is FLAGGED — counted, logged, summarized — and nothing is rewritten")
    func verifyFlagsDisagreement() async throws {
        let (sb, model) = try PromoteIntegrityHarness.setup("219verify")
        defer { sb.cleanup() }
        let a = try PromoteIntegrityHarness.source(sb, model, name: "test_a.mov", seed: 21)
        let b = try PromoteIntegrityHarness.source(sb, model, name: "test_b.mov", seed: 22)
        _ = try await PromoteIntegrityHarness.run(model, ids: [a.id, b.id]) {
            $0.archiveDateOverrides[a.id] = .year(1947); $0.archiveDateSources[a.id] = .typed
            $0.archiveDateOverrides[b.id] = .year(1952); $0.archiveDateSources[b.id] = .typed
        }
        let clean = VerifyArchiveCopiesJob(model: model)
        clean.start(); await clean.task?.value
        #expect(clean.tally.dateDisagreements == 0, "a fresh Promote agrees everywhere: \(clean.dateDisagreementLines)")

        // A pre-fix record: its catalog date came from the source (1990).
        let copyA = try #require(model.masterArchiveCopy(of: a))
        copyA.userDate = "1990"; copyA.userDateConfidence = UserDateConfidence.known.rawValue
        let manifestBefore = try Data(contentsOf: sb.manifestURL)
        let job = VerifyArchiveCopiesJob(model: model)
        job.start(); await job.task?.value
        #expect(job.tally.dateDisagreements == 1, "\(job.tally)")
        #expect(job.dateDisagreementLines.first?.contains("1947-xx-xx_test_a") == true
                && job.dateDisagreementLines.first?.contains("catalog says 1990") == true, "\(job.dateDisagreementLines)")
        #expect(VerifyArchiveCopiesJob.summaryLine(job.tally).contains("1 date disagreement"))
        guard case .finished = job.state else { Issue.record("report only — never red: \(job.state)"); return }
        #expect(copyA.userDate == "1990", "the sensor never rewrites an archived record")
        #expect(try Data(contentsOf: sb.manifestURL) == manifestBefore, "nor the index")
    }

    @Test("SCALE: the sensor over 100k archived records + 100k index rows inside the Verify plan, within budget",
          .timeLimit(.minutes(2)))
    func sensorScale() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("219scale")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        let root = sb.archiveRoot.path
        var text = MasterArchiveLayout.manifestHeader + "\n"
        text.reserveCapacity(100_000 * 220)
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let y = 1950 + i % 50
            let rel = "30_Video/\(y - y % 10)-\(y - y % 10 + 9)/\(y)/\(y)-xx-xx_Clip_\(i).mov"
            text += ArchiveManifestCSV.line(for: .init(promotedAt: Date(), archiveRelPath: rel,
                                                       sha256: String(format: "%064x", i), sizeBytes: 10,
                                                       originalPath: "/Volumes/test_V/c\(i).mov", originalVolume: "test_V",
                                                       recordID: UUID(), sourceRecordID: UUID(),
                                                       recordDate: "\(y)-xx-xx", dateConfidence: "user-known",
                                                       people: [], starRating: 3))
            let r = VideoRecord()
            r.fullPath = root + "/" + rel
            r.filename = (rel as NSString).lastPathComponent
            r.derivationKind = ArchivePromotion.derivationKind
            r.userDate = i % 2 == 0 ? "\(y)" : "\(y + 1)"          // every odd record disagrees
            recs.append(r)
        }
        model.records = recs
        let manifest = VerifyArchiveManifestIndex.parse(text: text)
        // The sensor's OWN cost: the per-record rule over 100k (row, record)
        // pairs — O(1) each, no I/O. (collectPlan's pre-existing per-record
        // path work is Verify's, timed by its own suite.)
        let pairs = recs.compactMap { r -> (VerifyArchiveManifestIndex.Row, String?, String?)? in
            guard let rel = VerifyArchiveCopiesJob.relPath(of: r.fullPath, underRoot: root),
                  let row = manifest.byRelPath[rel] else { return nil }
            return (row, r.userDate, r.archiveFiledDate)
        }
        #expect(pairs.count == 100_000)
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        var flagged = 0
        let elapsed = clock.measure {
            for (row, ud, filed) in pairs where !ArchiveDateAgreement.problems(
                relPath: row.relPath, manifestDate: row.recordDate, userDate: ud, filedDate: filed).isEmpty {
                flagged += 1
            }
        }
        #expect(flagged == 50_000)
        expectWithinTimingBudget("GH #219 sensor rule over 100k archived records", measured: elapsed,
                                 budget: PerformanceLane.debugCeiling(.seconds(1)), loadBefore: load)
        // Wired into the Verify plan: the same 50k are flagged there.
        let plan = VerifyArchiveCopiesJob.collectPlan(model: model, root: root, manifest: manifest)
        #expect(plan.items.count == 100_000)
        #expect(plan.dateDisagreements.count == 50_000)
    }
}

// MARK: - GH #190: the index, the engine guard, a lying fixity, scale

@Suite("GH #190 — digest index, engine guard and scale", .serialized)
@MainActor
struct ArchiveDigestIndexTests {

    typealias H = PromoteIntegrityHarness

    private static func row(_ rel: String, _ sha: String) -> String {
        ArchiveManifestCSV.line(for: .init(promotedAt: Date(), archiveRelPath: rel, sha256: sha, sizeBytes: 1,
                                           originalPath: "/Volumes/test_V/x.mov", originalVolume: "test_V",
                                           recordID: UUID(), sourceRecordID: UUID(), recordDate: "",
                                           dateConfidence: "", people: [], starRating: 3))
    }

    @Test("parse: first row wins, case-folded; malformed rows (short, bad digest, escaping relpath) are skipped AND counted")
    func parseRules() {
        let a = String(repeating: "ab", count: 32), b = String(repeating: "CD", count: 32)
        let c = String(repeating: "9", count: 64)
        let text = MasterArchiveLayout.manifestHeader + "\n"
            + Self.row("30_Video/Undated/xxxx-xx-xx_first.mov", a)
            + Self.row("30_Video/Undated/xxxx-xx-xx_second.mov", a)
            + Self.row("30_Video/Undated/xxxx-xx-xx_upper.mov", b)
            + Self.row("30_Video/Undated/xxxx-xx-xx_bad.mov", "not-a-digest")
            + Self.row("../../evil.mov", c)                                   // escapes the root (codex R4-A)
            + "\"short\",\"row\"\n\n"
        let idx = ArchiveDigestIndex.parse(manifestText: text)
        #expect(idx.relPath(forDigest: a) == "30_Video/Undated/xxxx-xx-xx_first.mov")
        #expect(idx.relPath(forDigest: b.lowercased()) == "30_Video/Undated/xxxx-xx-xx_upper.mov")
        #expect(idx.relPath(forDigest: c) == nil, "a row naming a path outside the archive is never indexed")
        #expect(idx.count == 2 && idx.malformedRows == 3, "\(idx.count) / \(idx.malformedRows)")
    }

    @Test("containment (codex R4-A): only relative, ≥2-component paths with no empty / . / .. component are indexable",
          arguments: [("30_Video/Undated/x.mov", true), ("30_Video/x.mov", true), ("30_Video/..x/x..mov", true),
                      ("x.mov", false), ("/abs/x.mov", false), ("../../evil.mov", false), ("30_Video/../../evil.mov", false),
                      ("30_Video/./x.mov", false), ("30_Video//x.mov", false), ("30_Video/", false), ("", false)])
    func lexicalContainment(_ rel: String, _ ok: Bool) {
        #expect(ArchiveDigestIndex.isLexicallyContained(rel) == ok, "\(rel)")
        // Never looser than the engine's own rule.
        if ArchiveDigestIndex.isLexicallyContained(rel) {
            #expect(ArchivePromoteEngine.isContainedRelPath(rel, root: "/private/tmp/test_190_root"), "\(rel)")
        }
    }

    @Test("fixity leg: only copies INSIDE this root, with a size-matching digest, outside 00_Index")
    func fixityLeg() {
        let root = "/private/tmp/test_190_root"
        func copy(_ path: String, _ sha: String, fixitySize: Int64 = 5) -> VideoRecord {
            let r = VideoRecord(); r.fullPath = path; r.sizeBytes = 5
            r.derivationKind = ArchivePromotion.derivationKind
            r.archiveFixity = ArchiveFixity(digest: sha, verifiedAt: Date(), sizeBytes: fixitySize)
            return r
        }
        let d1 = String(repeating: "1", count: 64), d2 = String(repeating: "2", count: 64)
        let d3 = String(repeating: "3", count: 64), d4 = String(repeating: "4", count: 64)
        var idx = ArchiveDigestIndex()
        idx.addArchiveCopies([
            copy(root + "/30_Video/Undated/xxxx-xx-xx_in.mov", d1),
            copy("/Volumes/test_OldArchive/30_Video/x.mov", d2),                      // another archive
            copy(root + "/30_Video/Undated/xxxx-xx-xx_stale.mov", d3, fixitySize: 9),  // fixity for other bytes
            copy(root + "/00_Index/00_manifest.csv", d4),
        ], root: root)
        #expect(idx.relPath(forDigest: d1) == "30_Video/Undated/xxxx-xx-xx_in.mov")
        #expect(idx.relPath(forDigest: d2) == nil && idx.relPath(forDigest: d3) == nil && idx.relPath(forDigest: d4) == nil)
    }

    @Test("ENGINE: copied bytes that differ from the checked digest are refused before publish — no file, no partial")
    func engineExpectedDigest() throws {
        let (sb, _) = try H.setup("190engine")
        defer { sb.cleanup() }
        let src = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_e.mov"), bytes: 50_000, seed: 31)
        let rel = "30_Video/Undated/xxxx-xx-xx_test_e.mov"
        let h = try ArchivePromoteEngine.openSource(path: src.path)
        defer { h.close() }
        #expect(throws: ArchivePromoteEngine.Failure.sourceChangedDuringCopy(src.path)) {
            try ArchivePromoteEngine.copyVerifyPublish(source: h, root: sb.archiveRoot.path, relativePath: rel,
                                                       expectedSourceSHA: String(repeating: "0", count: 64))
        }
        #expect(MasterArchiveTestSupport.archivedFiles(sb).isEmpty && H.partials(sb).isEmpty)
        let right = try #require(MasterArchiveTestSupport.sha256(ofFile: src.path))
        let ok = try ArchivePromoteEngine.copyVerifyPublish(source: h, root: sb.archiveRoot.path, relativePath: rel,
                                                            expectedSourceSHA: right.uppercased())
        #expect(ok.sha256 == right && MasterArchiveTestSupport.archivedFiles(sb) == [rel])
    }

    @Test("a LYING stored fixity (fresh stamp, wrong digest) cannot smuggle bytes in: refused, claim released, a later honest Promote lands")
    func lyingFixityRefusedThenHonestLands() async throws {
        let (sb, model) = try H.setup("190lying")
        defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_tape.mov", seed: 32)
        let stamp = try #require(FileIdentityStamp.capture(path: a.fullPath))
        let wrong = String(repeating: "e", count: 64)
        let lying = ContentFixity(digest: wrong, byteCount: a.sizeBytes, stamp: stamp)
        try #require(lying.isUsableForVerification, "the sandbox volume must yield a UUID-bound stamp for this test")
        a.contentFixity = lying
        let job = try await H.run(model, ids: [a.id])
        let o = try #require(H.outcome(job, a.id))
        #expect(o.kind == .failed && o.detail.contains("source changed"), "\(o.kind) — \(o.detail)")
        #expect(MasterArchiveTestSupport.archivedFiles(sb).isEmpty && H.partials(sb).isEmpty)
        #expect(MasterArchiveTestSupport.manifestRows(sb).isEmpty)
        #expect(model.promoteDigestClaim(wrong, root: sb.archiveRoot.path) == nil, "a failed file releases its claim")
        a.contentFixity = nil
        let again = try await H.run(model, ids: [a.id])
        #expect(H.outcome(again, a.id)?.kind == .promoted, "\(again.outcomes)")
        let sha = try #require(MasterArchiveTestSupport.sha256(ofFile: a.fullPath))
        #expect(model.promoteDigestClaim(sha, root: sb.archiveRoot.path) == MasterArchiveTestSupport.archivedFiles(sb).first)
    }

    @Test("SCALE: 100k-row index — parse + 100k-copy fixity leg + 100k O(1) lookups within budget (no per-file manifest scan)",
          .timeLimit(.minutes(2)))
    func scale100k() {
        var text = MasterArchiveLayout.manifestHeader + "\n"
        text.reserveCapacity(100_000 * 220)
        for i in 0..<100_000 { text += Self.row("30_Video/1990-1999/1994/1994-xx-xx_Clip_\(i).mov", String(format: "%064x", i)) }
        let root = "/private/tmp/test_190_scale_root"
        var copies: [VideoRecord] = []
        copies.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.fullPath = root + "/30_Video/Undated/xxxx-xx-xx_c\(i).mov"; r.sizeBytes = 7
            r.derivationKind = ArchivePromotion.derivationKind
            r.archiveFixity = ArchiveFixity(digest: String(format: "%064x", 200_000 + i), verifiedAt: Date(), sizeBytes: 7)
            copies.append(r)
        }
        // Half the lookups hit the manifest leg, half the fixity leg.
        let probes = (0..<100_000).map { String(format: "%064x", $0 % 2 == 0 ? $0 : 200_000 + $0) }
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        var hits = 0
        var idx = ArchiveDigestIndex()
        let elapsed = clock.measure {
            idx = ArchiveDigestIndex.parse(manifestText: text)
            idx.addArchiveCopies(copies, root: root)
            for p in probes where idx.relPath(forDigest: p) != nil { hits += 1 }
        }
        #expect(idx.count == 200_000 && idx.malformedRows == 0)
        #expect(hits == 100_000, "\(hits)")
        #expect(idx.relPath(forDigest: String(format: "%064x", 150_000)) == nil)
        expectWithinTimingBudget("GH #190 digest index, 100k rows + 100k copies + 100k lookups", measured: elapsed,
                                 budget: PerformanceLane.debugCeiling(.seconds(4)), loadBefore: load)
    }
}
