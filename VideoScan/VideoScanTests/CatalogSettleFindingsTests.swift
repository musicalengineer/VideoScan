// CatalogSettleFindingsTests.swift
// "Let the machine settle every finding the machine can settle" (Rick
// 2026-10-19): Verify Catalog reads catalog.sqlite (GH #342); duplicate
// groups are sets of COPIES (split by whole-file SHA-256, never formed
// across different digests); a Live Photo's silent motion clip is silent by
// design; a person's "Silent — checked" tag passes a silent print.
//
// Dimensions (CLAUDE.md feature-test checklist):
//   LOGIC      the partition rule; the repair plan (stay / new group / leave,
//              words, keeper follows); the detector never stamps different
//              digests into one group; tier 3's expected-silence rules, red
//              and green at their edges; tier 5 over catalog.sqlite.
//   SCALE      100k grouped facts through the plan inside a budget, and the
//              second plan is empty (idempotent at scale).
//   ISOLATION  a read-only session refuses the split and changes nothing;
//              Verify under catalog.sqlite reads the DATABASE, not memory and
//              not the frozen catalog.json (a record dropped from memory is
//              still verified; catalog.json is not named).
//   SENSOR     the door makes its safety copy before it applies and saves
//              through the one writer; the detector calls the partition;
//              Verify's live source asks the cutover first.
//   TRUTH      end to end on a CutoverScene: red Verify → split → green
//              Verify, read back from catalog.sqlite, and a second run plans
//              nothing (no second safety copy).
//   MEDIA      N/A — nothing opens a media file.
// Plus an OPT-IN evidence run against a COPY of a real catalog
// (`CatalogSettleRealCopyEvidence`, no-op unless its request file exists).
//
// Suites (filter by SUITE): DuplicateDigestPartitionTests ·
// DuplicateDigestSplitPlanTests · DuplicateDetectorDigestTests ·
// VerifyCatalogExpectedSilenceTests · VerifyCatalogSQLiteTierTests ·
// VerifyCatalogSQLiteSourceTests · DuplicateDigestSplitDoorTests ·
// DuplicateDigestSplitScaleTests · CatalogSettleFindingsSensorTests ·
// CatalogSettleRealCopyEvidence

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let settleNow = Date(timeIntervalSince1970: 1_760_850_000)   // 2026-10-19
private func hex(_ n: Int) -> String { String(format: "%064x", n) }
private let fixityStamp = FileIdentityStamp(device: 1, inode: 2, size: 100, mtimeNs: 3)

private typealias Fact = DuplicateGroupDigestSplit.MemberFact

private func fact(_ name: String, group: UUID, digest: String?, _ disposition: DuplicateDisposition = .extraCopy,
                  confidence: DuplicateConfidence = .high, best: String = "") -> Fact {
    Fact(id: UUID(), groupID: group, filename: name, digest: digest, disposition: disposition, confidence: confidence, bestMatch: best)
}

// MARK: - LOGIC: the partition rule

@Suite("Duplicate groups are copies — the partition rule")
struct DuplicateDigestPartitionTests {

    @Test("members bucket by whole-file digest (case-insensitive); the keeper's bucket comes first; a bucket of one leaves")
    func bucketsByDigest() {
        let members = ["K:a", "x:B", "y:A", "z:b", "w:c"]   // name:digest
        let parts = DuplicateGroupDigestSplit.partition(members, keeper: 0) { String($0.split(separator: ":")[1]) }
        #expect(parts == [["K:a", "y:A"], ["x:B", "z:b"]], "w:c has no copy and leaves")
    }

    @Test("an unknown digest is not known to differ: it stays with the keeper; at most one known digest leaves the group as it is")
    func unknownStaysWithKeeper() {
        let members: [(String, String?)] = [("K", "a"), ("u", nil), ("x", "b"), ("y", "b")]
        let parts = DuplicateGroupDigestSplit.partition(members, keeper: 0) { $0.1 }.map { $0.map(\.0) }
        #expect(parts == [["K", "u"], ["x", "y"]])
        let oneKnown: [(String, String?)] = [("K", "a"), ("u", nil), ("v", nil)]
        #expect(DuplicateGroupDigestSplit.partition(oneKnown, keeper: 0) { $0.1 }.map { $0.map(\.0) } == [["K", "u", "v"]])
    }
}

// MARK: - LOGIC: the repair plan

@Suite("Split Duplicate Groups by Full Hash — the plan")
struct DuplicateDigestSplitPlanTests {

    @Test("a group of 5 with 3 digests: the keeper's copies stay under the old id; another pair becomes a new group with an elected keeper; the unique file leaves; the words name each")
    func splitsIntoCopies() throws {
        let g = UUID(), fresh = UUID()
        let keeper = fact("keep.mov", group: g, digest: hex(1), .keep, best: "pair1.mov")
        let mate = fact("mate.mov", group: g, digest: hex(1).uppercased(), .review, confidence: .medium)
        let p1 = fact("pair1.mov", group: g, digest: hex(2))
        let p2 = fact("pair2.mov", group: g, digest: hex(2), .review, confidence: .low)
        let lone = fact("lone.mov", group: g, digest: hex(3))
        let plan = DuplicateGroupDigestSplit.plan([keeper, mate, p1, p2, lone], elect: { $0.last }, newID: { fresh })
        let byID = Dictionary(uniqueKeysWithValues: plan.changes.map { ($0.id, $0) })
        #expect(plan.changes.count == 5)
        #expect(byID[keeper.id] == .init(id: keeper.id, groupID: g, disposition: .keep, groupCount: 2, bestMatch: "mate.mov"),
                "its old best match left with the other pair; the remaining copy is named")
        #expect(byID[mate.id] == .init(id: mate.id, groupID: g, disposition: .review, groupCount: 2, bestMatch: "keep.mov"))
        #expect(byID[p2.id] == .init(id: p2.id, groupID: fresh, disposition: .keep, groupCount: 2, bestMatch: "pair1.mov"), "elected")
        #expect(byID[p1.id] == .init(id: p1.id, groupID: fresh, disposition: .extraCopy, groupCount: 2, bestMatch: "pair2.mov"))
        #expect(byID[lone.id] == .init(id: lone.id, groupID: nil, disposition: .none, groupCount: 0, bestMatch: ""))
        let words = try #require(plan.groups.first?.words)
        #expect(words == "group \(DuplicateGroupDigestSplit.short(g)) (5 files, 3 different whole-file SHA-256s): 2 stay with keeper keep.mov · "
                + "2 became group \(DuplicateGroupDigestSplit.short(fresh)) (keeper pair2.mov) · lone.mov left — its whole-file SHA-256 matches no other member")
        #expect(plan.recordsLeaving == 1 && plan.newGroupCount == 1)
    }

    @Test("a keeper with no copy in its group: the group is gone, the keeper leaves, the other copies become a group of their own")
    func keeperAlone() {
        let g = UUID()
        let keeper = fact("keep.mov", group: g, digest: hex(1), .keep)
        let a = fact("a.mov", group: g, digest: hex(2))
        let b = fact("b.mov", group: g, digest: hex(2))
        let plan = DuplicateGroupDigestSplit.plan([keeper, a, b])
        #expect(plan.changes.first { $0.id == keeper.id }?.groupID == nil)
        #expect(Set(plan.changes.compactMap(\.groupID)).count == 1)
        #expect(!plan.changes.contains { $0.groupID == g })
        #expect(plan.groups.first?.words.contains("the keeper keep.mov has no other copy here — the group is gone") == true)
    }

    @Test("IDEMPOTENT: applying a plan and planning again plans nothing; groups of one digest (plus unknowns) are never touched")
    func idempotent() {
        let g = UUID(), h = UUID()
        var facts = [fact("k", group: g, digest: hex(1), .keep), fact("a", group: g, digest: hex(1)), fact("b", group: g, digest: hex(2)),
                     fact("c", group: g, digest: hex(2)), fact("d", group: g, digest: hex(4)),
                     fact("u", group: h, digest: hex(9), .keep), fact("v", group: h, digest: nil)]
        let first = DuplicateGroupDigestSplit.plan(facts)
        #expect(first.groups.count == 1, "group h holds one known digest")
        let changes = Dictionary(uniqueKeysWithValues: first.changes.map { ($0.id, $0) })
        facts = facts.compactMap { f in
            guard let c = changes[f.id] else { return f }
            guard let group = c.groupID else { return nil }
            return Fact(id: f.id, groupID: group, filename: f.filename, digest: f.digest, disposition: c.disposition,
                        confidence: f.confidence, bestMatch: c.bestMatch)
        }
        #expect(DuplicateGroupDigestSplit.plan(facts).isEmpty)
    }
}

// MARK: - LOGIC: the cause — the detector

@Suite("DuplicateDetector never stamps different whole-file digests into one group")
struct DuplicateDetectorDigestTests {

    private func copy(_ name: String, digest: String?) -> VideoRecord {
        let r = makeDuplicateRecord(filename: name, streamType: .videoAndAudio, sizeBytes: 100, durationSeconds: 60,
                                    partialMD5: "same-head-and-tail", resolution: "1920x1080", videoCodec: "h264", audioCodec: "aac")
        r.fullPath = "/Volumes/Synthetic/\(UUID().uuidString.prefix(6))/\(name)"
        if let digest { r.contentFixity = ContentFixity(digest: digest, byteCount: 100, stamp: fixityStamp, computedAt: settleNow) }
        return r
    }

    @Test("same sampled hash + size + name, DIFFERENT whole-file SHA-256: no group (each is unique); same SHA-256: one group of copies")
    func differentDigestsNeverGroup() {
        let a = copy("clip.mov", digest: hex(1)), b = copy("clip.mov", digest: hex(2))
        #expect(DuplicateDetector.analyze(records: [a, b]).groups == 0)
        #expect(a.duplicateGroupID == nil && b.duplicateGroupID == nil)
        let c = copy("clip.mov", digest: hex(7)), d = copy("clip.mov", digest: hex(7))
        #expect(DuplicateDetector.analyze(records: [c, d]).groups == 1)
        #expect(c.duplicateGroupID != nil && c.duplicateGroupID == d.duplicateGroupID)
    }

    @Test("a star of four with two digests becomes two groups of copies, each with one keeper; a file whose digest is unknown stays with the keeper's copies")
    func starSplits() {
        let rs = [copy("clip.mov", digest: hex(1)), copy("clip.mov", digest: hex(1)), copy("clip.mov", digest: hex(2)),
                  copy("clip.mov", digest: hex(2)), copy("clip.mov", digest: nil)]
        // The keeper must carry a KNOWN digest for "stays with the keeper's
        // copies" to mean anything: an unknown-digest keeper is its own
        // bucket (not proven a copy of anyone) and is left ungrouped.
        rs[4].isPlayable = "No"
        let summary = DuplicateDetector.analyze(records: rs)
        #expect(summary.groups == 2)
        let groups = Dictionary(grouping: rs.filter { $0.duplicateGroupID != nil }, by: { $0.duplicateGroupID! })
        #expect(groups.count == 2)
        for (_, members) in groups {
            #expect(Set(members.compactMap { VideoScanModel.storedFullDigest($0) }).count == 1, "one digest per group")
            #expect(members.filter { $0.duplicateDisposition == .keep }.count == 1)
            #expect(members.allSatisfy { $0.duplicateGroupCount == members.count })
        }
        #expect(rs[4].duplicateGroupID != nil, "the unknown-digest copy is grouped, not dropped")
    }
}

// MARK: - LOGIC: tier 3 expected silence

private func silentRow(_ path: String, seconds: Double, tagged: Bool = false) -> IntegrityRow {
    IntegrityRow(fullPath: path, sizeBytes: 100, durationSeconds: seconds, streamTypeRaw: StreamType.videoAndAudio.rawValue,
                 fullDigest: hex(5), audioFingerprint: AudioFingerprintStamp(computedAt: settleNow, contentDigest: "sha256:" + hex(5),
                                                                              sizeBytes: 100, outcome: .fingerprinted, analyzedSeconds: max(seconds, 1),
                                                                              complete: true, landmarks: 0, bytes: 0),
                 silenceCheckedByPerson: tagged)
}

private func tier3(_ rows: [IntegrityRow]) -> VerifyCatalogTiers.TierOutcome {
    VerifyCatalogTiers.sound(.init(snapshot: VerifyCatalogSnapshot(rows: rows, events: [], catalogFile: "/nowhere/catalog.sqlite"),
                                   previous: nil, constraintFindings: nil, runID: UUID(), now: settleNow))
}

@Suite("Verify Catalog tier 3 — silence that is expected")
struct VerifyCatalogExpectedSilenceTests {

    static let lib = "/Volumes/Synthetic/Pictures/Photos Library.photoslibrary/resources/media/version/01/00"

    @Test("a short Live Photo motion clip in a photo library is PASSED with words — videocomplementoutput, IMG_*.MOV in a .photoslibrary, a clip in an iPhoto Library folder or a .migratedphotolibrary")
    func livePhotosPass() {
        let rows = [silentRow(Self.lib + "/videocomplementoutput_1a.mov", seconds: 2.1),
                    silentRow("/Volumes/Synthetic/Pictures/Photos Library.photoslibrary/resources/modelresources/1/2/IMG_0001.MOV", seconds: 2.2),
                    silentRow("/Volumes/Synthetic/Old/iPhoto Library/Masters/2013/IMG_0002.MOV", seconds: 2.0),
                    silentRow("/Volumes/Synthetic/Old/iPhoto Library.migratedphotolibrary/Previews/x/IMG_0003.MOV", seconds: 3.5)]
        let out = tier3(rows)
        #expect(out.findings.isEmpty)
        #expect(out.tier.result == .ok && out.tier.passed == 4 && out.tier.needsDecision == 0)
        #expect(out.tier.summary.contains("4 Live Photo motion clips — silent by design"), Comment(rawValue: out.tier.summary))
    }

    @Test("NARROW: a long clip in a library, a short clip OUTSIDE a library, a long videocomplementoutput, an unknown duration — each still needs a decision")
    func narrowRuleStillFlags() {
        let rows = [silentRow(Self.lib + "/IMG_0009.MOV", seconds: 12.3),
                    silentRow("/Volumes/Synthetic/AVCHD/BDMV/STREAM/00051.MTS", seconds: 1.0),
                    silentRow("/Volumes/Synthetic/Exports/videocomplementoutput_9.mov", seconds: 8.0),
                    silentRow(Self.lib + "/videocomplementoutput_0.mov", seconds: 0),
                    silentRow(Self.lib + "/IMG_0010.MOV", seconds: 3.51)]
        let out = tier3(rows)
        #expect(out.findings.count == 5)
        #expect(out.tier.result == .needsDecision(5))
        #expect(!out.tier.summary.contains("silent by design"))
    }

    @Test("a person's \"Silent — checked\" tag passes a silent print anywhere; the projection reads the tag case-insensitively from the record")
    func checkedByPerson() {
        let out = tier3([silentRow("/Volumes/Synthetic/Fog 01.dv", seconds: 4.6, tagged: true),
                         silentRow("/Volumes/Synthetic/Fog 02.dv", seconds: 4.6)])
        #expect(out.findings.count == 1 && out.findings.first?.filename == "Fog 02.dv")
        #expect(out.tier.summary.contains("1 silent clip checked by a person"), Comment(rawValue: out.tier.summary))
        let r = VideoRecord()
        r.fullPath = "/Volumes/Synthetic/a.mov"
        r.tags = ["Gold", "silent — CHECKED"]
        #expect(IntegrityRow(record: r).silenceCheckedByPerson)
        r.tags = ["Silent"]
        #expect(!IntegrityRow(record: r).silenceCheckedByPerson)
        #expect(WorkflowTags.quickPicks.contains(WorkflowTags.silentChecked) && !WorkflowTags.silentChecked.contains(","))
    }
}

// MARK: - LOGIC: tier 5 over catalog.sqlite

@Suite("Verify Catalog tier 5 — catalog.sqlite's generation, never a byte hash")
struct VerifyCatalogSQLiteTierTests {

    private func tier5(_ read: VerifyCatalogTiers.DatabaseGenerationRead?) -> VerifyCatalogTiers.TierOutcome {
        let snap = VerifyCatalogSnapshot(rows: [IntegrityRow(fullPath: "/Volumes/Synthetic/a.mov")], events: [],
                                         catalogFile: "/nonexistent-\(UUID().uuidString)/catalog.sqlite", catalogGeneration: 7, store: .sqlite)
        var input = VerifyCatalogTiers.TierInput(snapshot: snap, previous: nil, constraintFindings: nil, runID: UUID(), now: settleNow)
        input.databaseGeneration = read
        return VerifyCatalogTiers.constraints(input)
    }

    @Test("same generation → ok, the words name catalog.sqlite and its generation; no file is hashed (the path does not even exist)")
    func sameGeneration() {
        let out = tier5(.read(7))
        #expect(out.tier.result == .ok)
        #expect(out.catalogHash == nil)
        #expect(out.tier.summary.contains("catalog.sqlite at generation 7 — the findings describe it"), Comment(rawValue: out.tier.summary))
        #expect(!out.tier.summary.contains("catalog.json"))
    }

    @Test("the store moved on → said (run again), never a decision; the generation could not be read → could not check")
    func movedOrUnreadable() {
        let moved = tier5(.read(9))
        #expect(moved.tier.result == .ok)
        #expect(moved.tier.summary.contains("findings describe generation 7; catalog.sqlite is generation 9 — run again"), Comment(rawValue: moved.tier.summary))
        let lost = tier5(.unreadable("closed"))
        #expect(lost.tier.result == .couldNotCheck(1))
        #expect(lost.tier.summary.contains("catalog.sqlite's generation could not be read (closed)"))
    }
}

// MARK: - ISOLATION + TRUTH: the job under catalog.sqlite (GH #342)

@MainActor
private func verify(_ scene: CutoverScene) async -> VerifyCatalogJob {
    let job = VerifyCatalogJob(model: scene.model)
    job.eventsForTesting = []
    job.start()
    await job.task?.value
    return job
}

@Suite("Verify Catalog reads catalog.sqlite, the authority (GH #342)", .serialized)
@MainActor
struct VerifyCatalogSQLiteSourceTests {

    @Test("the report names catalog.sqlite and ITS generation, the rows come from the database (a record dropped from memory is still verified), catalog.json is neither named nor read")
    func verifiesTheDatabase() async throws {
        let scene = try CutoverScene.make("vc_sqlite", healthyRows: 4); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        #expect(model.catalogCutover.isSQLiteAuthority)
        #expect(model.saveCatalogNow())
        let repository = try #require(model.catalogCutover.committer?.repository)
        let generation = await repository.generation
        let stored = try await CatalogLoad.rows(repository)
        let storedCount = Set(stored.rows.map(\.file.id) + stored.pending.map(\.id)).count
        let dropped = try scene.bulk(2)
        model.records.removeAll { $0.id == dropped.id }   // memory drifts; the database still holds it

        let job = await verify(scene)
        let report = try #require(job.report)
        #expect(report.outcome == .completed)
        #expect(report.catalogFile == scene.databaseURL.path)
        #expect(report.snapshotGeneration == generation)
        #expect(report.catalogGeneration == generation)
        #expect(report.catalogSHA256 == nil, "a WAL database is not byte-hashed")
        #expect(!report.catalogChangedDuringRun)
        #expect(report.rowsTotal == storedCount, "the database's rows, not memory's \(model.records.count)")
        #expect(report.tier(5)?.summary.contains("catalog.sqlite at generation \(generation)") == true, Comment(rawValue: report.tier(5)?.summary ?? ""))
        #expect(!report.tiers.contains { $0.summary.contains("catalog.json") })
        #expect(IntegrityReportStore.read(besideCatalogAt: scene.databaseURL).report?.runID == report.runID)
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("Verify catalog: START — catalog.sqlite at generation \(generation):"), Comment(rawValue: log))
    }
}

// MARK: - TRUTH + ISOLATION: the door on a real catalog.sqlite

@Suite("Split Duplicate Groups by Full Hash — the door", .serialized)
@MainActor
struct DuplicateDigestSplitDoorTests {

    @Test("TRUTH end to end: a group of three different digests → Verify red → split (safety copy, one commit) → catalog.sqlite holds no group → Verify green; a second run plans nothing and makes no second copy")
    func redSplitGreen() async throws {
        let scene = try CutoverScene.make("split_door", healthyRows: 5); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let g = UUID()
        let members = try (0..<3).map { try scene.bulk($0) }
        for (i, r) in members.enumerated() {
            r.duplicateGroupID = g
            r.duplicateConfidence = .high
            r.duplicateDisposition = i == 0 ? .keep : .extraCopy
            r.duplicateReasons = "hash+duration"
            r.duplicateGroupCount = 3
            r.dupAnalyzedAt = settleNow
        }
        #expect(model.saveCatalogNow())
        let red = try #require(await verify(scene).report)
        #expect(red.findings.filter { $0.rule == "duplicateGroupDigestsAgree" }.count == 1)

        let outcome = model.splitDuplicateGroupsByFullDigest()
        guard case .split(let groups, let newGroups, let left, let saved, let copy) = outcome else {
            Issue.record("expected a split, got \(outcome)"); return
        }
        #expect(groups == 1 && newGroups == 0 && left == 3 && saved)
        #expect(copy.hasSuffix(".sqlite") && copy.contains("catalog.pre-dup-split.") && FileManager.default.fileExists(atPath: copy))
        let reloaded = try await scene.sqliteLoad()
        #expect(!reloaded.records.contains { $0.duplicateGroupID == g }, "catalog.sqlite holds no member of the false group")
        let green = try #require(await verify(scene).report)
        #expect(green.findings.filter { $0.rule == "duplicateGroupDigestsAgree" }.isEmpty)

        let copiesBefore = try FileManager.default.contentsOfDirectory(atPath: scene.folder.path).filter { $0.contains("pre-dup-split") }
        #expect(model.splitDuplicateGroupsByFullDigest() == .nothingToSplit)
        let copiesAfter = try FileManager.default.contentsOfDirectory(atPath: scene.folder.path).filter { $0.contains("pre-dup-split") }
        #expect(copiesBefore == copiesAfter, "no safety copy when nothing changes")
        let log = scene.sandbox.catalogLogText()
        for line in ["Split duplicate groups: START — 1 of 1", "Split duplicate groups: safety copy: ",
                     "Split duplicate groups: 1 of 1 — group ", "Split duplicate groups: OUTCOME — 1 group(s) split",
                     "Split duplicate groups: OUTCOME — nothing to split"] {
            #expect(log.contains(line), "missing: \(line)")
        }
    }

    @Test("copies stay together on catalog.json too: the keeper's copy stays, the other pair becomes a group, the unique file leaves")
    func copiesOnJSON() throws {
        let sb = try ShowAgainSandbox.make("split_json"); defer { sb.cleanup() }
        let g = UUID()
        let digests = [hex(1), hex(1), hex(2), hex(2), hex(3)]
        let rs = try digests.enumerated().map { i, d -> VideoRecord in
            let r = try sb.record("m\(i).mov", bytes: 100, stage: .none)
            r.contentFixity = ContentFixity(digest: d, byteCount: 100, stamp: fixityStamp, computedAt: settleNow)
            r.duplicateGroupID = g
            r.duplicateConfidence = .high
            r.duplicateDisposition = i == 0 ? .keep : .extraCopy
            return r
        }
        guard case .split(1, 1, 1, _, _) = sb.model.splitDuplicateGroupsByFullDigest() else { Issue.record("expected 1/1/1"); return }
        #expect(rs[0].duplicateGroupID == g && rs[1].duplicateGroupID == g && rs[0].duplicateDisposition == .keep)
        #expect(rs[2].duplicateGroupID != nil && rs[2].duplicateGroupID == rs[3].duplicateGroupID && rs[2].duplicateGroupID != g)
        #expect([rs[2], rs[3]].filter { $0.duplicateDisposition == .keep }.count == 1)
        #expect(rs[4].duplicateGroupID == nil && rs[4].duplicateDisposition == .none)
    }

    @Test("ISOLATION: a read-only session refuses and changes nothing")
    func readOnlyRefuses() throws {
        let sb = try ShowAgainSandbox.make("split_ro"); defer { sb.cleanup() }
        let g = UUID()
        let rs = try [hex(1), hex(2)].enumerated().map { i, d -> VideoRecord in
            let r = try sb.record("r\(i).mov", bytes: 100, stage: .none)
            r.contentFixity = ContentFixity(digest: d, byteCount: 100, stamp: fixityStamp, computedAt: settleNow)
            r.duplicateGroupID = g
            r.duplicateDisposition = i == 0 ? .keep : .extraCopy
            return r
        }
        sb.model.isReadOnly = true
        guard case .refused = sb.model.splitDuplicateGroupsByFullDigest() else { Issue.record("expected refused"); return }
        #expect(rs.allSatisfy { $0.duplicateGroupID == g })
    }
}

// MARK: - SCALE

@Suite("Split Duplicate Groups — scale (100k grouped rows)", .serialized)
struct DuplicateDigestSplitScaleTests {

    /// 100k facts in 25k groups of four; every fifth group holds two digests
    /// (2 + 2), every tenth also a unique file. Budget (Debug, M4 Max): 2 s.
    @Test(.timeLimit(.minutes(1)))
    func planAt100k() {
        var facts: [Fact] = []
        facts.reserveCapacity(100_000)
        for g in 0..<25_000 {
            let group = UUID()
            for m in 0..<4 {
                var digest = hex(g * 10)
                if g % 5 == 0, m >= 2 { digest = hex(g * 10 + 1) }
                if g % 10 == 0, m == 3 { digest = hex(g * 10 + 2) }
                facts.append(fact("g\(g)-m\(m).mov", group: group, digest: digest, m == 0 ? .keep : .extraCopy))
            }
        }
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        var plan = DuplicateGroupDigestSplit.Plan()
        let measured = clock.measure { plan = DuplicateGroupDigestSplit.plan(facts) }
        #expect(plan.groups.count == 5_000)
        #expect(plan.recordsLeaving == 2_500 * 2, "g%10==0: m2 and m3 each unique")
        #expect(plan.newGroupCount == 2_500, "g%5==0 but not %10: m2+m3 become a group")
        expectWithinTimingBudget("split plan over 100k grouped rows", measured: measured,
                                 budget: PerformanceLane.debugCeiling(.seconds(2)), loadBefore: load)
    }
}

// MARK: - SENSOR

@Suite("Settle findings — sensors")
struct CatalogSettleFindingsSensorTests {

    @Test("the door: safety copy BEFORE apply, apply BEFORE the one save; it writes only duplicate-group fields")
    func doorOrder() throws {
        let code = try SourceTree.appCode(named: "VideoScanModel+DuplicateDigestSplit.swift")
        let copy = try #require(code.range(of: "snapshotCatalog(prefix: \"pre-dup-split\")"))
        let apply = try #require(code.range(of: "applyDuplicateDigestSplit(plan, byID: byID)"))
        let save = try #require(code.range(of: "let saved = saveCatalogNow()"))
        #expect(copy.lowerBound < apply.lowerBound && apply.lowerBound < save.lowerBound)
        for forbidden in ["stampRemoval(", "clearRemoval(", "removeItem(", "trashItem(", "moveItem(", "write(to:"] {
            #expect(!code.contains(forbidden), "the split calls \(forbidden)")
        }
        for field in ["removal", "fullPath", "contentFixity", "archiveFixity", "sizeBytes", "lifecycleStage"] {
            #expect(code.range(of: #"\.\#(field)\s*=[^=]"#, options: .regularExpression) == nil, "the split writes .\(field)")
        }
    }

    @Test("the detector partitions every star group by whole-file digest; Verify's live source asks the SQLite cutover first")
    func causeAndSource() throws {
        let detector = try SourceTree.appSource(named: "DuplicateDetector.swift")
        #expect(detector.contains("DuplicateGroupDigestSplit.partition("))
        let job = try SourceTree.appCode(named: "Integrity/VerifyCatalogJob.swift")
        #expect(job.contains("if let repository = model.catalogCutover.committer?.repository, let database = model.catalogCutover.databaseURL"))
        #expect(job.contains("try await CatalogLoad.rows(repository)"))
    }
}

// MARK: - OPT-IN evidence against a COPY of a real catalog

/// Runs ONLY when `~/Library/Logs/VideoScan/settle-evidence/request.json`
/// exists: `{"database": "<a .backup COPY of catalog.sqlite>", "audit":
/// "<a copy of catalog-audit.json or empty>", "output": "<result .json>"}`.
/// Everything happens in a sandbox COPY of that copy — never on a live
/// catalog. Writes the before/after counts and the residual list.
@Suite("Settle findings — real-catalog COPY evidence (opt-in)", .serialized)
@MainActor
struct CatalogSettleRealCopyEvidence {

    struct Request: Decodable { var database: String; var audit: String?; var output: String }

    @Test(.timeLimit(.minutes(10)))
    func evidence() async throws {
        let requestURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VideoScan/settle-evidence/request.json")
        guard let data = try? Data(contentsOf: requestURL) else { return }   // opt-in: no request, nothing to do
        let request = try JSONDecoder().decode(Request.self, from: data)
        let scene = try CutoverScene.make("evidence"); defer { scene.cleanup() }
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: scene.folder.path) { try fm.removeItem(at: scene.folder.appendingPathComponent(name)) }
        try fm.copyItem(at: URL(fileURLWithPath: request.database), to: scene.databaseURL)
        if let audit = request.audit, !audit.isEmpty {
            try fm.copyItem(at: URL(fileURLWithPath: audit), to: scene.folder.appendingPathComponent("catalog-audit.json"))
        }
        try scene.writeLatch()
        let model = scene.model
        model.records = model.loadCatalogAtLaunch()
        // As the app's launch does (VideoScanModel init): the designation
        // catalog_state holds becomes the model's — else the first commit
        // would "clear" it and the committer refuses (GH #167).
        model.masterArchive = model.catalogStore.masterArchive
        #expect(model.catalogCutover.isSQLiteAuthority)

        let before = try #require(await verify(scene).report)
        let repository = try #require(model.catalogCutover.committer?.repository)
        let rowsBefore = try await VideoScanModel.databaseRows(repository).rows
        let oldRuleDup = CatalogConstraints.index(rowsBefore).disagreeingGroups.values.filter(\.sampledHashMatch).count
        let split = model.splitDuplicateGroupsByFullDigest()
        let after = try #require(await verify(scene).report)
        let rowsAfter = try await VideoScanModel.databaseRows(repository).rows
        let byID = Dictionary(rowsAfter.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        func counts(_ r: IntegrityReport) -> [String: Int] {
            var c: [String: Int] = [:]
            for f in r.findings where f.needsDecision { c[f.rule, default: 0] += 1 }
            return c
        }
        var residual: [[String: String]] = after.findings.filter(\.needsDecision).map { f in
            ["rule": f.rule, "filename": f.filename ?? "", "path": f.recordID.flatMap { byID[$0]?.fullPath } ?? "", "words": f.words]
        }
        let auditURL = scene.folder.appendingPathComponent("catalog-audit.json")
        if let auditData = try? Data(contentsOf: auditURL),
           let audit = try? JSONSerialization.jsonObject(with: auditData) as? [String: Any],
           let rows = audit["rows"] as? [[String: Any]] {
            for row in rows where (row["result"] as? String) == "stillMissing" {
                let id = (row["id"] as? String).flatMap(UUID.init(uuidString:))
                let r = id.flatMap { byID[$0] }
                residual.append(["rule": "auditStillMissing", "filename": r?.filename ?? "", "path": r?.fullPath ?? (row["id"] as? String ?? ""),
                                 "words": "Missing — not at its path when Audit Catalog last looked; reconnect its drive or decide Remove from Catalog"])
            }
        }
        let tier3Before = before.tier(3)?.summary ?? "", tier3After = after.tier(3)?.summary ?? ""
        let result: [String: Any] = [
            "catalogFile": after.catalogFile, "generationBefore": before.snapshotGeneration ?? -1, "generationAfter": after.snapshotGeneration ?? -1,
            "rowsTotal": after.rowsTotal, "rowsLive": after.rowsLive,
            "needsDecisionBefore": counts(before), "needsDecisionAfter": counts(after),
            "duplicateRuleBeforeOldDefinition_hashGroupsOnly": oldRuleDup,
            "split": String(describing: split), "tier3Before": tier3Before, "tier3After": tier3After,
            "tier5After": after.tier(5)?.summary ?? "", "tier0After": after.tier(0)?.summary ?? "",
            "residual": residual,
            "logTail": scene.sandbox.catalogLogText().split(separator: "\n").suffix(60).joined(separator: "\n"),
        ]
        let out = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: URL(fileURLWithPath: request.output))
    }
}
