// VerifyCatalogTests.swift
// Verify Catalog, first slice (Rick 2026-10-16,
// docs/design/integrity_first_2026_10_16.md §3–§5) — the five dimensions
// plus TRUTH:
//   LOGIC     — every constraint rule red and green on synthetic rows (one
//               test per rule); the tier evaluators from the stamps; the
//               report's Codable shape; the catalog-file hash words.
//   SCALE     — 100k rows + 2k events through `CatalogConstraints.check`
//               inside a budget (the measured number is in the handoff).
//   ISOLATION — a poisoned integrity-latest.json (garbage, a future schema)
//               reads as "never run" with the row's red words, no crash;
//               a read-only catalog folder → "report could not be written",
//               OUTCOME still logged; every test in its own sandbox.
//   SENSOR    — the job's sources never call stampRemoval / clearRemoval /
//               removeItem / trashItem / moveItem / write(to:) / Process(),
//               never open a media file; the one writer is AtomicFilePublish
//               in IntegrityReport.swift; the one FileHandle read is the
//               catalog file's hash.
//   TRUTH     — the P0 shapes produce findings: a dangling derivedFrom, a
//               `v1:` value in a sha256 fixity field, two live rows at one
//               path, a Video+Audio row with a silent print, a promotion
//               source with no derivedFrom.
// Media matrix: N/A — nothing opens a media file (the sensor pins it).
//
// Suites (filter by SUITE — method-level -only-testing runs zero tests):
//   VerifyCatalogConstraintTests · VerifyCatalogTierTests ·
//   VerifyCatalogReportTests · VerifyCatalogScaleTests ·
//   VerifyCatalogJobTests · VerifyCatalogStatusTests · VerifyCatalogSensorTests

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let now = Date(timeIntervalSince1970: 1_760_600_000)   // 2026-10-16
private let sha = String(repeating: "ab", count: 32)            // a 64-hex digest
private let stamp = FileIdentityStamp(device: 1, inode: 2, size: 100, mtimeNs: 3)

private func row(_ path: String = "/Volumes/LaCie/a.mov", id: UUID = UUID()) -> IntegrityRow {
    IntegrityRow(id: id, fullPath: path, sizeBytes: 100)
}

private func findings(_ rows: [IntegrityRow], events: [IntegrityEventFact] = [],
                      rule: CatalogConstraints.Rule) -> [CatalogConstraints.Finding] {
    CatalogConstraints.check(rows: rows, events: events).filter { $0.rule == rule }
}

private func print(outcome: AudioFingerprintStamp.Outcome = .fingerprinted, seconds: Double = 60, landmarks: Int = 500,
                   digest: String = "sha256:" + sha, size: Int64 = 100) -> AudioFingerprintStamp {
    AudioFingerprintStamp(computedAt: now, contentDigest: digest, sizeBytes: size, outcome: outcome,
                          analyzedSeconds: seconds, complete: true, landmarks: landmarks, bytes: landmarks * 8)
}

// MARK: - Logic: one test per rule

@Suite("Verify Catalog — constraints, one rule at a time")
struct VerifyCatalogConstraintTests {

    @Test("unique ids: two rows with one id are a finding; distinct ids are not")
    func uniqueIDs() {
        let id = UUID()
        let red = findings([row("/a.mov", id: id), row("/b.mov", id: id)], rule: .uniqueIDs)
        #expect(red.count == 1)
        #expect(red.first?.words.hasPrefix("2 rows carry the same id") == true)
        #expect(red.first?.recordID == id)
        #expect(findings([row("/a.mov"), row("/b.mov")], rule: .uniqueIDs).isEmpty)
    }

    @Test("one live row per path: two live rows at one path are a finding; a removed row sharing the path is not")
    func oneLiveRowPerPath() {
        let red = findings([row("/same.mov"), row("/same.mov")], rule: .oneLiveRowPerPath)
        #expect(red.count == 1)
        #expect(red.first?.words == "2 rows share the path /same.mov")
        var gone = row("/same.mov")
        gone.removal = .removedFromCatalog(at: now, reason: .userRemoved)
        #expect(findings([row("/same.mov"), gone], rule: .oneLiveRowPerPath).isEmpty)
    }

    @Test("lineage targets exist: a dangling derivedFrom and a dangling supersededByID are findings; links to rows that exist are not")
    func lineageTargetsExist() {
        let parent = row("/parent.mov")
        var child = row("/child.mov"); child.derivedFrom = parent.id
        var orphan = row("/orphan.mov"); orphan.derivedFrom = UUID()
        var retired = row("/old.mov"); retired.supersededByID = UUID()
        let red = findings([parent, child, orphan, retired], rule: .lineageTargetsExist)
        #expect(red.count == 2)
        #expect(red.first?.words.hasPrefix("lineage points at a row that no longer exists") == true)
        #expect(red.last?.words.hasPrefix("superseded by a row that no longer exists") == true)
        #expect(findings([parent, child], rule: .lineageTargetsExist).isEmpty)
    }

    @Test("promotions have a source: an archive copy with no derivedFrom is a finding; one with its source is not")
    func promotionsHaveASource() {
        let source = row("/source.mov")
        var copy = row("/Archive/copy.mov"); copy.derivationKind = ArchivePromotion.derivationKind; copy.derivedFrom = source.id
        var bare = row("/Archive/bare.mov"); bare.derivationKind = ArchivePromotion.derivationKind
        let red = findings([source, copy, bare], rule: .promotionsHaveASource)
        #expect(red.count == 1)
        #expect(red.first?.recordID == bare.id)
        #expect(findings([source, copy], rule: .promotionsHaveASource).isEmpty)
    }

    @Test("removal marker ⇔ lifecycle: In the Trash with a stage other than Trashed is a finding; Missing leaves the stage alone")
    func removalMirrorsLifecycle() {
        var trashed = row("/t.mov"); trashed.removal = .inTrash(movedAt: now, trashPath: nil, reason: .catalogTrash); trashed.lifecycleStage = .cataloged
        var okTrashed = row("/ok.mov"); okTrashed.removal = trashed.removal; okTrashed.lifecycleStage = .trashed
        var missing = row("/m.mov"); missing.removal = .missing(noticedAt: now, lastSeen: nil, reason: .missingAtAudit); missing.lifecycleStage = .archived
        let red = findings([trashed, okTrashed, missing], rule: .removalMirrorsLifecycle)
        #expect(red.count == 1)
        #expect(red.first?.recordID == trashed.id)
        #expect(red.first?.words.contains("expected \"Trashed\"") == true)
    }

    @Test("required fields: an empty path and a negative size are findings; a plain row is not")
    func requiredFields() {
        var noPath = row(""); noPath.sizeBytes = 10
        var negative = row("/n.mov"); negative.sizeBytes = -1
        let red = findings([noPath, negative, row()], rule: .requiredFields)
        #expect(red.count == 2)
        #expect(red.first?.words == "a row with no path")
        #expect(red.last?.words == "a negative size (-1)")
    }

    @Test("whole-file digests are whole: a `v1:` value or a short string in a sha256 fixity is a finding; 64 hex is not")
    func wholeFileDigestsAreWhole() {
        var sampled = row("/s.mov")
        sampled.contentFixity = ContentFixity(digest: "v1:" + sha, byteCount: 100, stamp: stamp, computedAt: now)
        var short = row("/short.mov")
        short.archiveFixity = ArchiveFixity(digest: "abc", verifiedAt: now, sizeBytes: 100)
        var good = row("/g.mov")
        good.contentFixity = ContentFixity(digest: sha, byteCount: 100, stamp: stamp, computedAt: now)
        good.archiveFixity = ArchiveFixity(digest: sha.uppercased(), verifiedAt: now, sizeBytes: 100)
        let red = findings([sampled, short, good], rule: .wholeFileDigestsAreWhole)
        #expect(red.count == 2)
        #expect(red.first?.words.contains("sampled \"v1:\" value") == true)
        #expect(red.last?.words.contains("not a 64-character SHA-256") == true)
    }

    @Test("removal revision never negative")
    func removalRevisionNonNegative() {
        var bad = row("/b.mov"); bad.removalRevision = -3
        var fine = row("/f.mov"); fine.removalRevision = 7
        let red = findings([bad, fine], rule: .removalRevisionNonNegative)
        #expect(red.count == 1)
        #expect(red.first?.recordID == bad.id)
    }

    @Test("an audit stamp names its volume: an empty UUID is a finding; a stamp with one, or no stamp, is not")
    func auditStampNamesItsVolume() {
        var empty = row("/e.mov"); empty.auditSeenOn = AuditSeenOn(volumeUUID: "  ", mountFrom: nil, seenAt: now)
        var named = row("/n.mov"); named.auditSeenOn = AuditSeenOn(volumeUUID: "6E6F7420-7468-6973-2D64-7269766521AA", mountFrom: nil, seenAt: now)
        let red = findings([empty, named, row()], rule: .auditStampNamesItsVolume)
        #expect(red.count == 1)
        #expect(red.first?.recordID == empty.id)
    }

    @Test("event members exist: by id, by pair group and by whole-file digest; a member of none is a finding")
    func eventMembersExist() {
        let byID = row("/id.mov")
        let pairID = UUID()
        var byPair = row("/pair.mov"); byPair.pairGroupID = pairID
        var byDigest = row("/d.mov"); byDigest.fullDigest = sha.uppercased()
        let rows = [byID, byPair, byDigest]
        let good = IntegrityEventFact(name: "Christmas 1991", memberKeys: ["id:" + byID.id.uuidString, "pair:" + pairID.uuidString, sha])
        let bad = IntegrityEventFact(name: "Lost one", memberKeys: ["id:" + UUID().uuidString, "pair:" + UUID().uuidString, String(repeating: "cd", count: 32)])
        #expect(findings(rows, events: [good], rule: .eventMembersExist).isEmpty)
        let red = findings(rows, events: [good, bad], rule: .eventMembersExist)
        #expect(red.count == 3)
        #expect(red.allSatisfy { $0.words.hasPrefix("event \"Lost one\"") })
        #expect(red.allSatisfy { $0.recordID == nil })
    }

    @Test("derived stamps match the content (tier 4): a print keyed on another SHA-256, another sampled hash or another size is stale; a matching one, or a row whose digest is unknown, is not")
    func derivedStampsMatchContent() {
        var otherSHA = row("/o.mov"); otherSHA.fullDigest = String(repeating: "cd", count: 32); otherSHA.audioFingerprint = print()
        var otherSize = row("/z.mov"); otherSize.fullDigest = sha; otherSize.audioFingerprint = print(size: 99)
        var otherSampled = row("/v.mov"); otherSampled.contentHash = "v1:" + sha; otherSampled.audioFingerprint = print(digest: "v1:" + String(repeating: "ef", count: 32))
        var same = row("/s.mov"); same.fullDigest = sha.uppercased(); same.audioFingerprint = print()
        var unknown = row("/u.mov"); unknown.audioFingerprint = print()
        let red = findings([otherSHA, otherSize, otherSampled, same, unknown], rule: .derivedStampsMatchContent)
        #expect(red.map(\.recordID) == [otherSHA.id, otherSize.id, otherSampled.id])
        #expect(red.allSatisfy { $0.words.hasPrefix("stale derived knowledge") })
        #expect(CatalogConstraints.Rule.derivedStampsMatchContent.tier == 4)
        #expect(CatalogConstraints.Rule.allCases.filter { $0.tier == 5 }.count == 10)
    }

    @Test("TRUTH: the P0 shapes each produce a finding, and a clean catalog produces none")
    func theP0ShapesProduceFindings() {
        var dangling = row("/Projects/_staging/clip.mov"); dangling.derivedFrom = UUID()
        var sampledFixity = row("/Volumes/LaCie/Christmas-c1990s.flv")
        sampledFixity.contentFixity = ContentFixity(digest: "v1:" + sha, byteCount: 100, stamp: stamp, computedAt: now)
        let twin1 = row("/Volumes/LaCie/twin.mov"), twin2 = row("/Volumes/LaCie/twin.mov")
        var bare = row("/Volumes/FamilyArchive/1990s/x.mov"); bare.derivationKind = ArchivePromotion.derivationKind
        let all = CatalogConstraints.check(rows: [dangling, sampledFixity, twin1, twin2, bare], events: [])
        #expect(all.map(\.rule) == [.oneLiveRowPerPath, .lineageTargetsExist, .promotionsHaveASource, .wholeFileDigestsAreWhole])
        let everyOneIsADecision = all.allSatisfy { $0.needsDecision }
        #expect(everyOneIsADecision)
        #expect(CatalogConstraints.check(rows: [row("/a.mov"), row("/b.mov")], events: []).isEmpty)
    }

    @Test("the rule table runs every rule once, in declaration order, and `check` is pure (same input, same output)")
    func ruleTableIsComplete() {
        #expect(CatalogConstraints.rules.count == CatalogConstraints.Rule.allCases.count)
        let rows = [row("/a.mov"), row("/a.mov")]
        #expect(CatalogConstraints.check(rows: rows, events: []) == CatalogConstraints.check(rows: rows, events: []))
    }
}

// MARK: - Logic: the tiers from the stamps

@Suite("Verify Catalog — tiers from the stamps")
struct VerifyCatalogTierTests {

    private func input(_ rows: [IntegrityRow], previous: IntegrityReport? = nil) -> VerifyCatalogTiers.TierInput {
        VerifyCatalogTiers.TierInput(snapshot: VerifyCatalogSnapshot(rows: rows, events: [], catalogFile: "/nowhere/catalog.json"),
                                     previous: previous, constraintFindings: nil, runID: UUID(), now: now)
    }

    @Test("tier 0 reads the audit's marker: absent → not run; completed with gone rows → needs a decision; completed clean → ok; partial / failed → could not check")
    func presenceFromTheAuditMarker() {
        #expect(VerifyCatalogTiers.presence(audit: nil).tier.result == .notRun("Audit Catalog has not run — Catalog ▸ Audit Catalog… (the nightly runs it too)"))
        var r = CatalogAuditRunRecord(startedAt: now.addingTimeInterval(-60))
        r.finishedAt = now
        r.outcome = .completed
        r.counts = ["present": 97, "gone": 2, "changed": 1, "planned": 100]
        let red = VerifyCatalogTiers.presence(audit: r).tier
        #expect(red.result == .needsDecision(3))
        #expect(red.checked == 100)
        #expect(red.verifiedAt == now)
        #expect(red.runID == nil, "another job's record stands in")
        r.counts = ["present": 100, "planned": 100]
        #expect(VerifyCatalogTiers.presence(audit: r).tier.result == .ok)
        r.outcome = .stopped
        r.counts = ["present": 40, "planned": 100]
        #expect(VerifyCatalogTiers.presence(audit: r).tier.result == .couldNotCheck(60))
        r.outcome = .failed
        #expect(VerifyCatalogTiers.presence(audit: r).tier.result == .couldNotCheck(100))
    }

    @Test("tier 1: active rows with a whole-file SHA-256 pass; a sampled hash never counts; removed rows are not asked")
    func identityFromTheStamps() {
        var known = row("/k.mov"); known.fullDigest = sha
        var sampled = row("/s.mov"); sampled.contentHash = "v1:" + sha
        var gone = row("/g.mov"); gone.removal = .missing(noticedAt: now, lastSeen: nil, reason: .missingAtAudit)
        let t = VerifyCatalogTiers.evaluate(1, input: input([known, sampled, gone])).tier
        #expect(t.checked == 2)
        #expect(t.passed == 1)
        #expect(t.result == .couldNotCheck(1))
        #expect(t.summary.contains("Fill In Full Hashes"))
        let clean = VerifyCatalogTiers.evaluate(1, input: input([known])).tier
        #expect(clean.result == .ok)
    }

    @Test("tier 3: a Video+Audio row whose print is silent or says noAudio needs a decision; a print that heard sound passes; rows without a print could not be checked")
    func soundAgainstTheHeader() {
        let va = StreamType.videoAndAudio.rawValue
        var silent = row("/silent.m4v"); silent.streamTypeRaw = va; silent.audioFingerprint = print(landmarks: 0)
        var noStream = row("/nostream.mov"); noStream.streamTypeRaw = va; noStream.audioFingerprint = print(outcome: .noAudio, seconds: 0, landmarks: 0)
        var heard = row("/heard.mov"); heard.streamTypeRaw = va; heard.audioFingerprint = print()
        var unprinted = row("/none.mov"); unprinted.streamTypeRaw = va
        var videoOnly = row("/v.mxf"); videoOnly.streamTypeRaw = StreamType.videoOnly.rawValue; videoOnly.audioFingerprint = print(landmarks: 0)
        let out = VerifyCatalogTiers.evaluate(3, input: input([silent, noStream, heard, unprinted, videoOnly]))
        #expect(out.tier.result == .needsDecision(2))
        #expect(out.tier.checked == 3)
        #expect(out.tier.couldNotCheck == 1)
        #expect(out.findings.map(\.recordID) == [silent.id, noStream.id])
        #expect(out.findings.first?.words == "the header says Video+Audio, but the sound print heard nothing (silent)")
        #expect(out.findings.last?.words == "the header says Video+Audio, but ffmpeg found no audio stream")
        #expect(out.findings.first?.filename == "silent.m4v")
        #expect(out.tier.summary == "2 headers say sound the print never heard")
    }

    @Test("tier 4 computes the constraints once and hands them to tier 5; tier 5 names the worst rule first and carries the filename")
    func derivedThenConstraints() {
        var dangling = row("/d.mov"); dangling.derivedFrom = UUID()
        var stale = row("/s.mov"); stale.fullDigest = String(repeating: "cd", count: 32); stale.audioFingerprint = print()
        let twins = [row("/t.mov"), row("/t.mov")]
        var inp = input([dangling, stale] + twins)
        let four = VerifyCatalogTiers.evaluate(4, input: inp)
        #expect(four.tier.result == .needsDecision(1))
        #expect(four.constraintFindings?.count == 3)
        inp.constraintFindings = four.constraintFindings
        let five = VerifyCatalogTiers.evaluate(5, input: inp)
        #expect(five.tier.result == .needsDecision(2))
        #expect(five.tier.summary == "1 lineage links point at nothing · 1 paths have more than one live row")
        #expect(five.findings.map(\.filename) == ["t.mov", "d.mov"])
        #expect(five.tier.checked == 4)
        #expect(five.tier.passed == 2)
    }

    @Test("tiers 2 and 6 say not built; a stopped tier says so; every tier has a name")
    func notBuiltAndStopped() {
        #expect(VerifyCatalogTiers.evaluate(2, input: input([])).tier.result == .notRun("weekly deep pass — not built yet"))
        #expect(VerifyCatalogTiers.evaluate(6, input: input([])).tier.result == .notRun("truth sweep — not built yet"))
        #expect(VerifyCatalogTiers.stopped(3).result == .notRun("stopped before this tier"))
        #expect(VerifyCatalogTiers.order.map(VerifyCatalogTiers.name).allSatisfy { !$0.isEmpty })
    }
}

// MARK: - Logic: the report and the catalog-file hash

@Suite("Verify Catalog — the report file and the catalog hash")
struct VerifyCatalogReportTests {

    private func sampleReport(outcome: IntegrityReport.Outcome = .completed) -> IntegrityReport {
        IntegrityReport(runID: UUID(), startedAt: now.addingTimeInterval(-5), verifiedAt: outcome == .completed ? now : nil,
                        outcome: outcome, catalogFile: "/x/catalog.json", catalogGeneration: 41, catalogSHA256: sha, catalogByteCount: 1_234,
                        rowsTotal: 10, rowsLive: 9, elapsedSeconds: 5,
                        tiers: [IntegrityTier(tier: 0, name: "File presence", verifiedAt: now, result: .ok, checked: 9, passed: 9, summary: "9 rows present at their path"),
                                IntegrityTier(tier: 2, name: "Bytes still the bytes", result: .notRun("weekly deep pass — not built yet"), summary: "not built"),
                                IntegrityTier(tier: 3, name: "Decodes and sounds", verifiedAt: now, result: .needsDecision(519), checked: 600, passed: 81, needsDecision: 519, summary: "519 headers say sound the print never heard"),
                                IntegrityTier(tier: 5, name: "Relations and constraints", verifiedAt: now, result: .needsDecision(3), checked: 10, passed: 7, needsDecision: 3, couldNotCheck: 1, summary: "3 rows share a path")],
                        findings: [IntegrityFinding(tier: 5, rule: "oneLiveRowPerPath", recordID: UUID(), filename: "twin.mov", words: "2 rows share the path /twin.mov", needsDecision: true)],
                        findingsTotal: 522)
    }

    @Test("the report round-trips through its JSON shape (kind/count/words for a result), and the derived words name the worst tier first")
    func reportRoundTrips() throws {
        let r = sampleReport()
        let data = try IntegrityReportStore.encoder.encode(r)
        let text = String(bytes: data, encoding: .utf8) ?? ""
        #expect(text.contains("\"kind\" : \"needsDecision\""))
        #expect(text.contains("\"count\" : 519"))
        #expect(text.contains("\"schemaVersion\" : 1"))
        #expect(!text.contains("_0"), "no synthesized associated-value keys")
        #expect(IntegrityReportStore.read(data: data) == .report(r))
        #expect(r.needsDecisionTotal == 522)
        #expect(r.decisionWords == "519 headers say sound the print never heard · 3 rows share a path")
        #expect(r.outcomeLine.hasPrefix("522 finding(s) need a decision across 3 tier(s) run"))
        #expect(r.outcomeLine.contains("1 of 522 findings kept"))
    }

    @Test("the strict reader: missing → never run; garbage, a future schema and a damaged body → unreadable with words; never a crash")
    func strictReader() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vc_read_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = dir.appendingPathComponent("catalog.json")
        #expect(IntegrityReportStore.read(besideCatalogAt: catalog) == .missing)
        let latest = IntegrityReportStore.latestURL(besideCatalogAt: catalog)
        try Data("not json at all {{{".utf8).write(to: latest)
        #expect(IntegrityReportStore.read(besideCatalogAt: catalog) == .unreadable("not readable as an integrity report"))
        try Data(#"{"schemaVersion": 99, "tiers": "whatever"}"#.utf8).write(to: latest)
        #expect(IntegrityReportStore.read(besideCatalogAt: catalog) == .unreadable("written by a newer VideoScan (schema 99) — not read"))
        try Data(#"{"schemaVersion": 1, "runID": "nope"}"#.utf8).write(to: latest)
        #expect(IntegrityReportStore.read(besideCatalogAt: catalog) == .unreadable("the report is damaged — the next run replaces it"))
        // As facts: all of those are "never run" (no date, no count) with the row's red words.
        for read in [IntegrityReportStore.Read.unreadable("x"), .missing] {
            let f = IntegrityReportFacts.from(read)
            #expect(f.lastCompleted == nil)
            #expect(f.needsDecision == 0)
            #expect(f.outcome == .neverRan)
        }
        #expect(IntegrityReportFacts.from(.unreadable("x")).problem == "integrity-latest.json can't be read: x")
        #expect(IntegrityReportFacts.from(.missing).problem == nil)
    }

    @Test("facts from a report: completed → ok with its verifiedAt and the decision sum; stopped → partial; failed → failed")
    func factsFromAReport() {
        let done = IntegrityReportFacts.from(.report(sampleReport()))
        #expect(done.outcome == .ok)
        #expect(done.lastCompleted == now)
        #expect(done.needsDecision == 522)
        #expect(done.decisionWords?.hasPrefix("519 headers") == true)
        #expect(IntegrityReportFacts.from(.report(sampleReport(outcome: .stopped))).outcome == .partial)
        #expect(IntegrityReportFacts.from(.report(sampleReport(outcome: .stopped))).lastCompleted == nil)
        #expect(IntegrityReportFacts.from(.report(sampleReport(outcome: .failed))).outcome == .failed)
    }

    @Test("write publishes the latest and a dated copy beside the catalog, atomically, and the dated name is the calendar date")
    func writeLatestAndDated() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vc_write_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = dir.appendingPathComponent("catalog.json")
        let urls = try IntegrityReportStore.write(sampleReport(), besideCatalogAt: catalog, now: now)
        #expect(urls.latest.lastPathComponent == "integrity-latest.json")
        let expectedDated = IntegrityReportStore.datedFileName(for: now)
        #expect(urls.dated.lastPathComponent == expectedDated)
        #expect(expectedDated.range(of: #"^integrity-\d{4}-\d{2}-\d{2}\.json$"#, options: .regularExpression) != nil)
        #expect(IntegrityReportStore.read(besideCatalogAt: catalog).report?.findingsTotal == 522)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter(AtomicFilePublish.isTemporaryPublishArtifact)
        #expect(leftovers.isEmpty)
    }

    @Test("the catalog file's SHA-256 is streamed and equals a one-shot digest; the generation is read from the header")
    func catalogFileHashStreams() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vc_hash_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("catalog.json")
        var body = Data(#"{"version": 4, "generation": 1234, "savedAt": 0, "records": ["#.utf8)
        body.append(Data(repeating: 0x20, count: 3 * CatalogFileHash.chunkBytes + 17))   // three chunks and a tail
        body.append(Data("]}".utf8))
        try body.write(to: url)
        let h = try CatalogFileHash.of(fileAt: url)
        #expect(h.sha256 == SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())
        #expect(h.byteCount == Int64(body.count))
        #expect(h.generation == 1234)
        #expect(CatalogFileHash.generation(inHeader: Data("{\"records\": []}".utf8)) == nil)
    }

    @Test("run to run: first run, unchanged, changed with a new generation (expected), changed with the same generation (a finding), unknown, not on disk")
    func hashComparisonWords() {
        let current = CatalogFileHash(sha256: "b", byteCount: 1, generation: 42)
        #expect(CatalogFileHash.compare(previousSHA: nil, previousGeneration: nil, current: current) == .firstRun)
        #expect(CatalogFileHash.compare(previousSHA: "b", previousGeneration: 42, current: current) == .unchanged)
        #expect(CatalogFileHash.compare(previousSHA: "a", previousGeneration: 41, current: current) == .changedExpected(from: 41, to: 42))
        #expect(CatalogFileHash.compare(previousSHA: "a", previousGeneration: 42, current: current) == .changedSameGeneration(42))
        #expect(CatalogFileHash.compare(previousSHA: "a", previousGeneration: nil, current: current) == .changedGenerationUnknown)
        #expect(CatalogFileHash.compare(previousSHA: "a", previousGeneration: 1, current: nil) == .notOnDisk)
        #expect(CatalogFileHash.Comparison.changedSameGeneration(42).needsDecision)
        #expect(!CatalogFileHash.Comparison.changedExpected(from: 41, to: 42).needsDecision)
        #expect(CatalogFileHash.Comparison.changedExpected(from: 41, to: 42).words == "catalog.json changed (generation 41 → 42, expected)")
        #expect(CatalogFileHash.Comparison.changedSameGeneration(42).words.contains("SAME generation (42) — look"))
    }
}

// MARK: - Scale

@Suite("Verify Catalog — scale (100k rows, 2k events)", .serialized)
struct VerifyCatalogScaleTests {

    /// 100k synthetic rows with every relation kind sprinkled in (1 in 1,000
    /// is a finding of some rule) and 2,000 events of 5 members each, through
    /// `check`. Budget (Debug, M4 Max, headroom ×3+): 2 s.
    @Test(.timeLimit(.minutes(1)))
    func checkAt100k() {
        var rows: [IntegrityRow] = []
        rows.reserveCapacity(100_000)
        var ids: [UUID] = []
        ids.reserveCapacity(100_000)
        for i in 0..<100_000 {
            var r = IntegrityRow(fullPath: "/Volumes/D\(i % 10)/folder\(i % 100)/clip_\(i).mov", sizeBytes: Int64(1_000 + i))
            if i % 2 == 0 { r.fullDigest = String(format: "%064x", i) }
            if i % 3 == 0 { r.pairGroupID = UUID() }
            if i % 7 == 0 { r.audioFingerprint = AudioFingerprintStamp(computedAt: now, contentDigest: r.fullDigest.map { "sha256:" + $0 } ?? "v1:x", sizeBytes: r.sizeBytes, outcome: .fingerprinted, analyzedSeconds: 10, complete: true, landmarks: 5, bytes: 40) }
            if i % 1_000 == 1 { r.derivedFrom = UUID() }
            if i % 1_000 == 2 { r.contentFixity = ContentFixity(digest: "v1:" + sha, byteCount: r.sizeBytes, stamp: stamp, computedAt: now) }
            if i > 0, i % 1_000 == 3 { r.fullPath = rows[i - 1].fullPath }
            rows.append(r)
            ids.append(r.id)
        }
        var events: [IntegrityEventFact] = []
        for e in 0..<2_000 {
            let keys = (0..<5).map { k -> String in
                let r = rows[(e * 37 + k * 11) % rows.count]
                return r.fullDigest ?? "id:" + r.id.uuidString
            }
            events.append(IntegrityEventFact(name: "Event \(e)", memberKeys: keys + (e % 100 == 0 ? ["id:" + UUID().uuidString] : [])))
        }
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        var found: [CatalogConstraints.Finding] = []
        let measured = clock.measure { found = CatalogConstraints.check(rows: rows, events: events) }
        let byRule = Dictionary(grouping: found, by: \.rule).mapValues(\.count)
        #expect(byRule[.lineageTargetsExist] == 100)
        #expect(byRule[.wholeFileDigestsAreWhole] == 100)
        #expect(byRule[.oneLiveRowPerPath] == 100)
        #expect(byRule[.eventMembersExist] == 20)
        #expect(byRule[.derivedStampsMatchContent] == nil)
        expectWithinTimingBudget("constraints over 100k rows + 2k events", measured: measured,
                                 budget: PerformanceLane.debugCeiling(.seconds(2)), loadBefore: load)
    }
}

// MARK: - The job (sandboxed catalog, real filesystem)

@MainActor
private func runVerify(_ sb: ShowAgainSandbox, events: [IntegrityEventFact] = [],
                       configure: (VerifyCatalogJob) -> Void = { _ in }) async -> VerifyCatalogJob {
    let job = VerifyCatalogJob(model: sb.model)
    job.eventsForTesting = events
    configure(job)
    job.start()
    await job.task?.value
    return job
}

@Suite("Verify Catalog — the job", .serialized)
@MainActor
struct VerifyCatalogJobTests {

    @Test("a run writes integrity-latest.json and the dated copy beside the catalog, fills tiers 0–6 (2 and 6 not built), logs START, one line per tier and OUTCOME through the catalog sink, and changes no row")
    func aRunWritesTheReportAndLogs() async throws {
        let sb = try ShowAgainSandbox.make("vc_run"); defer { sb.cleanup() }
        let a = try sb.live("a.mov")
        let b = try sb.live("b.mov")
        a.contentFixity = ContentFixity(digest: sha, byteCount: a.sizeBytes, stamp: stamp, computedAt: now)
        let before = (a.removal, b.removal, a.lifecycleStage, b.removalRevision, sb.model.records.count)
        let job = await runVerify(sb)
        guard case .finished(let summary) = job.state else { Issue.record("expected finished, got \(job.state)"); return }
        #expect(summary.contains("report → integrity-latest.json"), Comment(rawValue: summary))
        let report = try #require(job.report)
        #expect(report.tiers.map(\.tier) == [0, 1, 2, 3, 4, 5, 6])
        #expect(report.tier(0)?.result == .notRun("Audit Catalog has not run — Catalog ▸ Audit Catalog… (the nightly runs it too)"))
        #expect(report.tier(1)?.result == .couldNotCheck(1), "b.mov has no whole-file hash")
        #expect(report.tier(2)?.result == .notRun("weekly deep pass — not built yet"))
        #expect(report.tier(5)?.result == .ok)
        #expect(report.tier(6)?.result == .notRun("truth sweep — not built yet"))
        #expect(report.outcome == .completed)
        #expect(report.verifiedAt != nil)
        #expect(report.rowsTotal == 2)
        #expect(report.rowsLive == 2)
        #expect(report.tier(5)?.runID == job.id)
        // On disk, readable by the strict reader and by the Catalog Status facts.
        let catalog = URL(fileURLWithPath: sb.model.catalogStore.fileLocation)
        let onDisk = IntegrityReportStore.read(besideCatalogAt: catalog).report
        #expect(onDisk?.runID == report.runID)
        #expect(onDisk?.tiers.map(\.result) == report.tiers.map(\.result))
        #expect(FileManager.default.fileExists(atPath: catalog.deletingLastPathComponent().appendingPathComponent(IntegrityReportStore.datedFileName(for: Date())).path))
        #expect(CatalogFreshnessFactsReader.read(catalogFile: catalog.path).integrity.outcome == .ok)
        // The sink: START, one line per tier, OUTCOME.
        let log = sb.catalogLogText()
        #expect(log.contains("Verify catalog: START — 2 row(s) (2 live)"), Comment(rawValue: log))
        for n in 0...6 { #expect(log.contains("Verify catalog: tier \(n) "), "no line for tier \(n)") }
        #expect(log.contains("Verify catalog: OUTCOME — "), Comment(rawValue: log))
        // Nothing changed on the rows.
        #expect(a.removal == before.0 && b.removal == before.1)
        #expect(a.lifecycleStage == before.2 && b.removalRevision == before.3)
        #expect(sb.model.records.count == before.4)
    }

    @Test("TRUTH: the P0 shapes produce findings through the job — a dangling derivedFrom, a `v1:` value in a sha256 fixity field, two live rows at one path, a Video+Audio row with a silent print, a promotion source with no derivedFrom — grouped by tier with the filename and the words; the chip goes red")
    func theP0ShapesProduceFindingsThroughTheJob() async throws {
        let sb = try ShowAgainSandbox.make("vc_truth"); defer { sb.cleanup() }
        let dangling = try sb.live("dangling.mov"); dangling.derivedFrom = UUID()
        let sampled = try sb.live("Christmas-c1990s.flv")
        sampled.contentFixity = ContentFixity(digest: "v1:" + sha, byteCount: sampled.sizeBytes, stamp: stamp, computedAt: now)
        let twin = try sb.live("twin.mov")
        let twin2 = VideoRecord(); twin2.fullPath = twin.fullPath; twin2.filename = twin.filename; twin2.sizeBytes = twin.sizeBytes
        sb.model.records.append(twin2)
        let silent = try sb.live("silent.m4v")
        silent.streamTypeRaw = StreamType.videoAndAudio.rawValue
        silent.audioFingerprint = print(landmarks: 0, size: silent.sizeBytes)
        let bare = try sb.live("archive_copy.mov"); bare.derivationKind = ArchivePromotion.derivationKind
        let job = await runVerify(sb)
        #expect(job.findingsTotal == 5, "\(job.findings)")
        #expect(job.findingsByTier[3]?.map(\.filename) == ["silent.m4v"])
        #expect(job.findingsByTier[5]?.map(\.filename) == ["twin.mov", "dangling.mov", "archive_copy.mov", "Christmas-c1990s.flv"])
        let everyOneIsADecision = job.findings.allSatisfy { $0.needsDecision }
        #expect(everyOneIsADecision)
        let report = try #require(job.report)
        #expect(report.needsDecisionTotal == 5)
        // Tier 5 (4 decisions) before tier 3 (1); inside tier 5 equal counts sort by rule key.
        #expect(report.decisionWords == "1 lineage links point at nothing · 1 paths have more than one live row · 1 archive copies name no source · 1 whole-file digests are not whole · 1 headers say sound the print never heard")
        // Catalog Status: the Integrity row is red with those words.
        let facts = CatalogFreshnessFactsReader.read(catalogFile: sb.model.catalogStore.fileLocation)
        let coverage = AnalyzeCoverageCalculator.compute(inputs: AnalyzeCoverageCalculator.project(sb.model.records), volumes: [],
                                                         mountedRoots: ["/"], scope: AnalysisScope(), now: Date())
        let rows = CatalogFreshnessRows.rows(report: coverage, facts: facts, running: [])
        let state = CatalogFreshnessState.judged(rows: rows, now: Date())
        let verdict = try #require(state.verdict(.integrity))
        #expect(verdict.colour == .red)
        #expect(verdict.words == "5 findings — 1 lineage links point at nothing · 1 paths have more than one live row · 1 archive copies name no source · 1 whole-file digests are not whole · 1 headers say sound the print never heard")
        #expect(state.summary.colour == .red)
        #expect(CatalogStatusDoor.door(for: verdict.reason, cycler: .integrity) == .verifyAgain)
        // And every row is as it was: no marker, no save of the catalog.
        #expect(sb.model.records.allSatisfy { $0.removal == nil })
        #expect(!FileManager.default.fileExists(atPath: sb.model.catalogStore.fileLocation), "the job never saves the catalog")
    }

    @Test("the second run compares the catalog file's hash: unchanged, then changed with a new generation (expected), then changed with the SAME generation — a finding")
    func theSecondRunComparesTheCatalogHash() async throws {
        let sb = try ShowAgainSandbox.make("vc_hash"); defer { sb.cleanup() }
        try sb.live("a.mov")
        let catalog = URL(fileURLWithPath: sb.model.catalogStore.fileLocation)
        try Data(#"{"version": 4, "generation": 10, "records": []}"#.utf8).write(to: catalog)
        let first = await runVerify(sb)
        #expect(first.report?.catalogGeneration == 10)
        #expect(first.report?.tier(5)?.summary.contains("first run") == true)
        let second = await runVerify(sb)
        #expect(second.report?.tier(5)?.summary.contains("unchanged") == true)
        try Data(#"{"version": 4, "generation": 11, "records": [ ]}"#.utf8).write(to: catalog)
        let third = await runVerify(sb)
        #expect(third.report?.tier(5)?.summary.contains("generation 10 → 11, expected") == true)
        #expect(third.report?.tier(5)?.result == .ok)
        try Data(#"{"version": 4, "generation": 11, "records": [  ]}"#.utf8).write(to: catalog)
        let fourth = await runVerify(sb)
        #expect(fourth.report?.tier(5)?.result == .needsDecision(1))
        #expect(fourth.findingsByTier[5]?.first?.rule == VerifyCatalogTiers.catalogFileRule)
        #expect(fourth.findingsByTier[5]?.first?.words.contains("SAME generation (11) — look") == true)
    }

    @Test("ISOLATION: a read-only catalog folder — the run finishes its tiers, says 'report could not be written', still logs OUTCOME, ends Failed with the findings in hand")
    func readOnlyCatalogFolder() async throws {
        let sb = try ShowAgainSandbox.make("vc_readonly"); defer { sb.cleanup() }
        try sb.live("a.mov")
        let folder = sb.catalogDir
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let job = await runVerify(sb)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        guard case .failed(let message) = job.state else { Issue.record("expected failed, got \(job.state)"); return }
        #expect(message.hasPrefix("report could not be written:"), Comment(rawValue: message))
        #expect(job.reportProblem?.hasPrefix("report could not be written:") == true)
        #expect(job.tiers.count == 7, "the tiers ran")
        let log = sb.catalogLogText()
        #expect(log.contains("Verify catalog: OUTCOME failed — report could not be written:"), Comment(rawValue: log))
        #expect(!FileManager.default.fileExists(atPath: IntegrityReportStore.latestURL(besideCatalogAt: URL(fileURLWithPath: sb.model.catalogStore.fileLocation)).path))
    }

    @Test("ISOLATION: a poisoned integrity-latest.json beside the catalog — the job runs, replaces it, and the facts before the run read 'never run' with the red words, never a crash")
    func poisonedLatestReport() async throws {
        let sb = try ShowAgainSandbox.make("vc_poison"); defer { sb.cleanup() }
        try sb.live("a.mov")
        let catalog = URL(fileURLWithPath: sb.model.catalogStore.fileLocation)
        try Data(#"{"version": 4, "generation": 3, "records": []}"#.utf8).write(to: catalog)
        let latest = IntegrityReportStore.latestURL(besideCatalogAt: catalog)
        try Data(#"{"schemaVersion": 7, "from": "the future"}"#.utf8).write(to: latest)
        let poisoned = CatalogFreshnessFactsReader.read(catalogFile: catalog.path).integrity
        #expect(poisoned.lastCompleted == nil)
        #expect(poisoned.outcome == .neverRan)
        #expect(poisoned.problem == "integrity-latest.json can't be read: written by a newer VideoScan (schema 7) — not read")
        let job = await runVerify(sb)
        #expect(job.state == .finished(summary: job.subtitle))
        #expect(job.report?.tier(5)?.summary.contains("first run") == true, "a poisoned report is no previous hash")
        #expect(IntegrityReportStore.read(besideCatalogAt: catalog).report?.runID == job.id, "the poisoned file was replaced")
        #expect(CatalogFreshnessFactsReader.read(catalogFile: catalog.path).integrity.problem == nil)
    }

    @Test("Stop ends after the current tier: the tiers not reached say so, the report's outcome is stopped and Catalog Status reads it as partial")
    func stopEndsAfterTheCurrentTier() async throws {
        let sb = try ShowAgainSandbox.make("vc_stop"); defer { sb.cleanup() }
        try sb.live("a.mov")
        let job = VerifyCatalogJob(model: sb.model)
        job.eventsForTesting = []
        job.start()
        job.cancel()                                                    // before the first tier: nothing runs
        await job.task?.value
        #expect(job.state == .cancelled)
        let report = try #require(job.report)
        #expect(report.outcome == .stopped)
        #expect(report.verifiedAt == nil)
        #expect(report.tiers.count == 7)
        #expect(report.tiers.contains { $0.result == .notRun("stopped before this tier") })
        #expect(IntegrityReportFacts.from(.report(report)).outcome == .partial)
        #expect(sb.catalogLogText().contains("Verify catalog: OUTCOME stopped (partial)"))
    }

    @Test("a second Verify Catalog while one runs is refused through the center; the center's START line names the read-only plan")
    func secondRunIsRefused() async throws {
        let sb = try ShowAgainSandbox.make("vc_refuse"); defer { sb.cleanup() }
        try sb.live("a.mov")
        let center = MediaFileOperationsCenter()
        let first = center.startVerifyCatalog(model: sb.model)
        first.eventsForTesting = []
        let second = center.startVerifyCatalog(model: sb.model)
        #expect(second.wasRefused)
        if case .failed(let why) = second.state { #expect(why.contains("already running")) } else { Issue.record("expected refused") }
        await first.task?.value
        #expect(!first.state.isActive)
        #expect(CatalogFreshnessSnapshot.jobRunning(in: center).isEmpty)
    }

    @Test("confirmed events reach the constraints as content keys; a dismissed or merged-away event does not")
    func eventFactsFromTheDecisionSnapshot() {
        let live = EventRecord(name: "Christmas", categories: [])
        let gone = EventRecord(name: "Dup", categories: [])
        // The merge first: the snapshot keys a membership by the effective
        // event AT APPLY TIME (EventsDecisionSnapshot.apply), so a member
        // recorded before its event was merged stays under the old key.
        let snapshot = EventsDecisionSnapshot(events: [live, gone], decisions: [
            .merged(from: gone.id, into: live.id),
            .member(eventID: live.id, range: ContentRange(contentKey: sha), verdict: .accepted),
            .member(eventID: live.id, range: ContentRange(contentKey: "id:" + UUID().uuidString), verdict: .rejected),
            .member(eventID: gone.id, range: ContentRange(contentKey: "pair:" + UUID().uuidString), verdict: .accepted),
        ])
        let facts = VideoScanModel.confirmedEventFacts(snapshot)
        #expect(facts.map(\.name) == ["Christmas"])
        #expect(facts.first?.memberKeys.count == 2, "the merged event's member now belongs to Christmas; the rejected one does not")
    }
}

// MARK: - Catalog Status

@Suite("Verify Catalog — the Integrity row of Catalog Status")
struct VerifyCatalogStatusTests {

    private func rowFor(_ facts: IntegrityReportFacts, eligible: Int = 10) -> FreshnessRow {
        var report = AnalyzeCoverageReport()
        report.computedAt = now
        var counts = AnalyzeCoverageCounts()
        counts.eligible = eligible
        report.byCycler[.integrity] = counts
        return CatalogFreshnessRows.row(.integrity, report: report, facts: CatalogFreshnessFacts(integrity: facts), running: [])
    }

    @Test("the registry: Integrity is the fourth row, an MFO-backed integrity kind, pausable, no volume scope, manual today")
    func registry() {
        #expect(AnalyzeCycler.allCases[3] == .integrity)
        #expect(AnalyzeCycler.integrity.isIntegrity)
        #expect(AnalyzeCycler.integrity.title == "Integrity")
        #expect(AnalyzeCycler.integrity.isPausable)
        #expect(!AnalyzeCycler.integrity.hasVolumeScope)
        #expect(!AnalyzeCycler.integrity.autoRunsToday)
        #expect(!AnalyzeCoverageReport().coverageKnown(.integrity))
        #expect(MediaFileOperationKind.verifyCatalog.badgeText == "Verify Catalog")
        #expect(MediaFileOperationKind.verifyCatalog.hasDetailView)
    }

    @Test("never run → yellow 'never run'; a completed clean report → green with its date; decisions → red with the worst tier's words; overdue by a day → yellow; unreadable → red store words")
    func rowColours() {
        let wording = FreshnessWording(calendar: Calendar(identifier: .gregorian), groupingSeparator: ",")
        let never = FreshnessPolicy.judge(rowFor(IntegrityReportFacts()), now: now, wording: wording)
        #expect(never.colour == .yellow)
        #expect(never.reason == .neverRan(waiting: 10))
        let green = FreshnessPolicy.judge(rowFor(IntegrityReportFacts(lastCompleted: now.addingTimeInterval(-600), outcome: .ok)), now: now, wording: wording)
        #expect(green.colour == .green)
        #expect(green.words == "current · checked 10 minutes ago")
        let red = FreshnessPolicy.judge(rowFor(IntegrityReportFacts(lastCompleted: now, outcome: .ok, needsDecision: 522,
                                                                   decisionWords: "3 rows share a path · 519 headers say sound the print never heard")),
                                        now: now, wording: wording)
        #expect(red.colour == .red)
        #expect(red.words == "522 findings — 3 rows share a path · 519 headers say sound the print never heard")
        let overdue = FreshnessPolicy.judge(rowFor(IntegrityReportFacts(lastCompleted: now.addingTimeInterval(-25 * 3_600), outcome: .ok)), now: now, wording: wording)
        #expect(overdue.colour == .yellow)
        #expect(overdue.reason == .overdue(lastCompleted: now.addingTimeInterval(-25 * 3_600)))
        let broken = FreshnessPolicy.judge(rowFor(IntegrityReportFacts(problem: "integrity-latest.json can't be read: x")), now: now, wording: wording)
        #expect(broken.colour == .red)
        #expect(broken.reason == .storeUnavailable("integrity-latest.json can't be read: x"))
        let partial = FreshnessPolicy.judge(rowFor(IntegrityReportFacts(outcome: .partial)), now: now, wording: wording)
        #expect(partial.reason == .lastRunPartial)
    }

    @Test("the door: red decisions on Integrity → 'Verify again'; yellow → Run now; the summary band names the Integrity item")
    func doorAndBand() {
        #expect(CatalogStatusDoor.door(for: .needsDecision(3), cycler: .integrity) == .verifyAgain)
        #expect(CatalogStatusDoor.verifyAgain.title == "Verify again")
        #expect(CatalogStatusDoor.verifyAgain.isEnabled)
        #expect(CatalogStatusDoor.door(for: .neverRan(waiting: 1), cycler: .integrity) == .runNow)
        #expect(CatalogStatusDoor.door(for: .needsDecision(3), cycler: .filePresence) == .fixLinks, "the audit's door is unchanged")
        let rows = [rowFor(IntegrityReportFacts(lastCompleted: now, outcome: .ok, needsDecision: 2, decisionWords: "2 rows share a path"))]
        let summary = FreshnessPolicy.summarize(rows, now: now, wording: FreshnessWording(calendar: Calendar(identifier: .gregorian), groupingSeparator: ","))
        #expect(summary.colour == .red)
        #expect(summary.items.first?.title == "Integrity")
        #expect(summary.headline == "Needs a decision: 2 findings — 2 rows share a path")
    }

    @Test("Run now on the Integrity row starts Verify Catalog through the center; the runner sees it running and can stop it")
    @MainActor func runNowStartsVerifyCatalog() async throws {
        let sb = try ShowAgainSandbox.make("vc_runnow"); defer { sb.cleanup() }
        try sb.live("a.mov")
        let center = MediaFileOperationsCenter()
        let runner = AnalyzeRunner(model: sb.model, orchestrator: nil, center: center)
        #expect(!runner.isRunning(.integrity))
        runner.runNow(.integrity, source: "test")
        let job = try #require(center.jobs.first as? VerifyCatalogJob)
        #expect(runner.isRunning(.integrity) || !job.state.isActive)
        #expect(runner.activeIntegrityJob(for: .integrity) === job || !job.state.isActive)
        await job.task?.value
        #expect(!job.state.isActive)
        #expect(sb.catalogLogText().contains("Analyze: Integrity — START — all reachable (test)"))
    }
}

// MARK: - Sensor

@Suite("Verify Catalog — sensor: read-only on the catalog and on media; one writer")
struct VerifyCatalogSensorTests {

    static let reportFile = "IntegrityReport.swift"
    static let hashFile = "CatalogFileHash.swift"
    static let sources = [
        "CatalogConstraints.swift", hashFile, reportFile, "VerifyCatalogTiers.swift",
        "VerifyCatalogJob.swift", "VerifyCatalogDetailView.swift", "VerifyCatalogMenuItem.swift",
    ]

    static func code(_ name: String) throws -> String {
        try SourceTree.appSource(named: "Integrity/" + name).split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    @Test("MOPS-15: no file-moving, -removing or -writing call, no row write, no catalog save, no Process(), nothing that opens media, in any Verify Catalog source")
    func sourcesTouchNoFileNoRowNoMedia() throws {
        let forbidden = ["stampRemoval(", "clearRemoval(", "revertRemoval(", "removeItem(", "trashItem(", "moveItem(", "copyItem(",
                         "replaceItem", "linkItem(", "unlink(", "rename(", "renamex", "renameat", "chflags", "truncate(",
                         "write(to:", "FileHandle(forWriting", "FileHandle(forUpdating", "O_WRONLY", "O_RDWR", "setAttributes",
                         "Process()", "Process(", "posix_spawn", "ProcessRunner", "ExecuteShellCommand", "ffmpegPath", "ffprobePath",
                         "AVAsset", "AVURLAsset", "AVPlayer", "saveCatalog", "records.remove", "records.append",
                         "noteCatalogRecordsMutated", "purgedAt", "setAside(", "analyzeDuplicates", "deleteConfirmedJunk"]
        // A record field written through anything but `self.` (IntegrityRow's
        // own memberwise init assigns its OWN copies — a value, never a row).
        let writes = [#"(?<!self)\.removal\s*=[^=]"#, #"(?<!self)\.lifecycleStage\s*=[^=]"#, #"(?<!self)\.archiveStage\s*=[^=]"#,
                      #"(?<!self)\.auditSeenOn\s*=[^=]"#, #"(?<!self)\.contentFixity\s*=[^=]"#,
                      #"(?<!self)\.audioFingerprint\s*=[^=]"#, #"(?<!self)\.derivedFrom\s*=[^=]"#]
        for name in Self.sources {
            let code = try Self.code(name)
            for call in forbidden { #expect(!code.contains(call), "\(name) contains \(call)") }
            for pattern in writes {
                #expect(code.range(of: pattern, options: .regularExpression) == nil, "\(name) writes a record field (\(pattern))")
            }
        }
    }

    @Test("the ONE writer is AtomicFilePublish in IntegrityReport.swift (the latest and the dated copy); the ONE FileHandle read is the catalog file's hash")
    func oneWriterOneRead() throws {
        for name in Self.sources where name != Self.reportFile {
            #expect(!(try Self.code(name)).contains("AtomicFilePublish"), "\(name) writes a file")
        }
        let report = try Self.code(Self.reportFile)
        #expect(report.components(separatedBy: "AtomicFilePublish.write(").count == 3, "exactly two publishes: the latest and the dated copy")
        #expect(report.contains("to: latest, durability: .fullFsync"), "the latest survives a forced reboot")
        for name in Self.sources where name != Self.hashFile {
            #expect(!(try Self.code(name)).contains("FileHandle("), "\(name) opens a file handle")
        }
        let hash = try Self.code(Self.hashFile)
        #expect(hash.components(separatedBy: "FileHandle(forReadingFrom:").count == 2, "one read handle, on the catalog file")
        #expect(hash.contains("while let chunk = try handle.read(upToCount: chunkBytes)"), "streamed, never slurped")
        #expect(!hash.contains("Data(contentsOf:"), "never the whole file in memory")
    }

    @Test("the job runs the tiers off the main actor on Sendable values, snapshots the rows in ONE pass, and logs through the one sink; the registry and the runner know the kind")
    func shapeOfTheJob() throws {
        let job = try Self.code("VerifyCatalogJob.swift")
        #expect(job.contains("Task.detached(priority: .userInitiated) { [input] in"), "tiers run off the main actor")
        #expect(job.contains("for r in records { rows.append(IntegrityRow(record: r)) }"), "one O(records) pass")
        #expect(job.components(separatedBy: "func verifyCatalogNote(").count == 2)
        #expect(job.contains("log(\"Verify catalog: \" + line)") && job.contains("appLog.write(\"[verify-catalog] \" + line)"))
        #expect(job.contains("model.verifyCatalogNote(\"START — ") && job.contains("model.verifyCatalogNote(\"OUTCOME — "))
        #expect(job.contains("IntegrityReport.findingsCap"), "findings are capped in memory")
        let view = try Self.code("VerifyCatalogDetailView.swift")
        #expect(!view.contains("model.") && !view.contains(".records"), "the detail view reads the job only")
        let runner = try SourceTree.appSource(named: "AnalyzeRunner.swift")
        #expect(runner.contains("case .integrity:\n                _ = c.startVerifyCatalog(model: model)"))
        let snapshot = try SourceTree.appSource(named: "CatalogFreshnessSnapshot.swift")
        #expect(snapshot.contains("else if job is VerifyCatalogJob { s.insert(.integrity) }"))
        let app = try SourceTree.appSource(named: "VideoScanApp.swift")
        #expect(app.contains("VerifyCatalogMenuItem(model: catalogModel, center: fileOpsCenter"))
    }
}
