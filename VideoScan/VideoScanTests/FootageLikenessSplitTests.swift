// FootageLikenessSplitTests.swift
// Weak likeness has a home: catalog.sqlite's `footage_likeness` (schema
// v1.11, Rick approved 2026-10-19). The split records what each old
// duplicate group knew as PAIRS, then splits EVERY multi-digest group — no
// more holds under catalog.sqlite — and Verify Catalog lists undecided weak
// pairs as a yellow, informational item, never red.
//
// Dimensions (CLAUDE.md feature-test checklist):
//   LOGIC      the pairs follow the old star (keeper's content ↔ each other
//              content): weak / anchored by the duplicate check's rule,
//              'oldGroup' with the group's reasons verbatim when today's
//              rule does not pair them, NO pair for a different length;
//              `.pairs` never holds; `Plan.holding` drops a group's changes
//              and says why; idempotent. The inspector's "Same footage as
//              (possible)" lists unanswered weak pairs only. Verify's rule
//              lists undecided weak pairs on live rows, needsDecision false.
//   SCALE      100k grouped facts planned with pairs; 100k pairs absorbed;
//              Verify's likeness rule over 100k rows + 50k pairs — budgets.
//   ISOLATION  a blocked committer refuses the split: nothing recorded,
//              nothing changed; a read-only session refuses; the in-memory
//              likeness store of one model is not another's.
//   SENSOR     no delete path reads footage likeness; the only writer of the
//              table is the split door, through `commitSideTables`.
//   TRUTH      end to end on catalog.sqlite: a weak-only group of three
//              codecs (the 403 class) → split → 0 multi-digest groups, two
//              pairs in footage_likeness, nobody lost; Verify: no red
//              `duplicateGroupDigestsAgree`, two yellow possible pairs; Rick
//              answers one "not the same" → one left; a second split plans
//              nothing and records nothing.
//   MEDIA      N/A — the split opens no media (the likeness rule's media
//              matrix is SameFootageMediaMatrixTests).
//
// Suites (filter by SUITE): FootageLikenessPairsTests ·
// FootageLikenessInspectorTests · FootageLikenessVerifyRuleTests ·
// FootageLikenessDoorTests · FootageLikenessScaleTests · FootageLikenessSensorTests
// Synthetic names only.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let flNow = Date(timeIntervalSince1970: 1_760_850_000)   // 2026-10-19
private func flHex(_ n: Int) -> String { String(format: "%064x", n) }
private let flStamp = FileIdentityStamp(device: 1, inode: 2, size: 100, mtimeNs: 3)

private typealias FLFact = DuplicateGroupDigestSplit.MemberFact

/// Three files of one synthetic recording in three codecs; `timecode`
/// decides the strength ("00:00:00:00" anchors nothing).
private func trio(timecode: String, digests: [String?] = [flHex(1), flHex(2), flHex(3)],
                  durations: [Double] = [600, 600, 600]) -> [DuplicateLikeness.Facts] {
    let codecs = ["ffv1", "h264", "dvvideo"]
    let names = ["test_synthetic_master.mkv", "test_family_export.mov", "test_tape_transfer.mov"]
    return (0..<3).map { i in
        DuplicateLikeness.Facts(filename: names[i], fullPath: "/Volumes/Synthetic/\(names[i])", partialMD5: "p\(i)",
                                sizeBytes: Int64(1_000 + i), timecode: timecode, durationSeconds: durations[i],
                                resolution: "720x480", videoCodec: codecs[i], digest: digests[i])
    }
}

private func fact(_ f: DuplicateLikeness.Facts?, id: UUID = UUID(), name: String = "", digest: String? = nil, group: UUID,
                  _ d: DuplicateDisposition = .extraCopy, reasons: String = "timecode+duration") -> FLFact {
    FLFact(id: f?.id ?? id, groupID: group, filename: f?.filename ?? name, digest: f?.digest ?? digest, disposition: d,
           confidence: .medium, bestMatch: "", likeness: f, groupReasons: reasons)
}

// MARK: - LOGIC: the pairs

@Suite("Footage likeness — the pairs a split keeps")
struct FootageLikenessPairsTests {

    @Test("a weak-only trio (default timecode): .pairs SPLITS it — two weak pairs to the keeper's content, reasons verbatim; nothing held")
    func weakTrioSplitsWithPairs() throws {
        let g = UUID()
        let fs = trio(timecode: "00:00:00:00")
        let plan = DuplicateGroupDigestSplit.plan([fact(fs[0], group: g, .keep), fact(fs[1], group: g), fact(fs[2], group: g)],
                                                  keeping: .pairs)
        #expect(plan.heldGroups.isEmpty)
        #expect(plan.recordsLeaving == 3)
        #expect(plan.pairs.count == 2)
        #expect(plan.pairs.allSatisfy { $0.hubDigest == flHex(1) && $0.strength == .weak && $0.source == .duplicateCheck })
        #expect(Set(plan.pairs.map(\.digest)) == [flHex(2), flHex(3)])
        #expect(plan.pairs.first?.reasons == "timecode+duration+resolution+audio")
        let words = try #require(plan.groups.first?.words)
        #expect(words.contains("likeness kept: test_family_export.mov ~ test_synthetic_master.mkv (possible — timecode+duration+resolution+audio)"), "\(words)")
    }

    @Test("the same trio on catalog.json (.footageGroups, no link) is still HELD — no table to keep it in")
    func jsonStillHolds() {
        let g = UUID()
        let fs = trio(timecode: "00:00:00:00")
        let plan = DuplicateGroupDigestSplit.plan([fact(fs[0], group: g, .keep), fact(fs[1], group: g), fact(fs[2], group: g)],
                                                  keeping: .footageGroups([:]))
        #expect(plan.heldGroups.count == 1 && plan.isEmpty)
    }

    @Test("a specific timecode anchors the pairs ('anchored'); a row the rule no longer pairs keeps the OLD group's reasons ('oldGroup', weak)")
    func anchoredAndOldGroup() {
        let g = UUID()
        let fs = trio(timecode: "01:02:03:04")
        let stranger = fact(nil, name: "test_unrelated_render.mxf", digest: flHex(9), group: g, reasons: "tape+created")
        let plan = DuplicateGroupDigestSplit.plan([fact(fs[0], group: g, .keep), fact(fs[1], group: g), stranger], keeping: .pairs)
        let byDigest = Dictionary(uniqueKeysWithValues: plan.pairs.map { ($0.digest, $0) })
        #expect(byDigest[flHex(2)]?.strength == .anchored)
        #expect(byDigest[flHex(2)]?.source == .duplicateCheck)
        #expect(byDigest[flHex(9)]?.source == .oldGroup)
        #expect(byDigest[flHex(9)]?.strength == .weak)
        #expect(byDigest[flHex(9)]?.reasons == "tape+created")
    }

    @Test("a different length (only the sampled hash matched) makes NO pair — evidence says not the same")
    func differentLengthNoPair() {
        let g = UUID()
        let a = DuplicateLikeness.Facts(filename: "test_a.mxf", partialMD5: "same", sizeBytes: 42, durationSeconds: 100, digest: flHex(1))
        let b = DuplicateLikeness.Facts(filename: "test_b.mxf", partialMD5: "same", sizeBytes: 42, durationSeconds: 200, digest: flHex(2))
        let plan = DuplicateGroupDigestSplit.plan([fact(a, group: g, .keep), fact(b, group: g)], keeping: .pairs)
        #expect(plan.pairs.isEmpty)
        #expect(plan.recordsLeaving == 2 && plan.differentLengthFiles == 2)
    }

    @Test("byte copies make no pair among themselves; an unknown digest is not known to differ and makes none")
    func copiesAndUnknown() {
        let g = UUID()
        let fs = trio(timecode: "01:02:03:04", digests: [flHex(1), flHex(1), nil])
        let plan = DuplicateGroupDigestSplit.plan([fact(fs[0], group: g, .keep), fact(fs[1], group: g), fact(fs[2], group: g)],
                                                  keeping: .pairs)
        #expect(plan.isEmpty, "one known digest: nothing to split")
        #expect(plan.pairs.isEmpty)
    }

    @Test("Plan.holding drops the held group's changes and says why; other groups go on")
    func holding() {
        let g = UUID(), h = UUID()
        let fs = trio(timecode: "00:00:00:00")
        let other = trio(timecode: "00:00:00:00", digests: [flHex(7), flHex(8), flHex(9)])
        let plan = DuplicateGroupDigestSplit.plan([fact(fs[0], group: g, .keep), fact(fs[1], group: g), fact(fs[2], group: g),
                                                   fact(other[0], group: h, .keep), fact(other[1], group: h), fact(other[2], group: h)],
                                                  keeping: .pairs)
        let held = plan.holding([g], why: "test: not stored")
        #expect(held.changes.allSatisfy { $0.oldGroupID == h })
        #expect(held.heldGroups.map(\.oldGroupID) == [g])
        #expect(held.heldGroups.first?.words.hasSuffix("kept as it is — test: not stored") == true)
        #expect(held.pairs.count == 2, "only the split group's pairs")
        #expect(plan.holding([], why: "x") == plan)
    }

    @Test("IDEMPOTENT: applying the plan and planning again plans nothing and keeps no pair")
    func idempotent() {
        let g = UUID()
        let fs = trio(timecode: "00:00:00:00")
        var facts = [fact(fs[0], group: g, .keep), fact(fs[1], group: g), fact(fs[2], group: g)]
        let first = DuplicateGroupDigestSplit.plan(facts, keeping: .pairs)
        let changes = Dictionary(uniqueKeysWithValues: first.changes.map { ($0.id, $0) })
        facts = facts.compactMap { f in
            guard let c = changes[f.id], let group = c.groupID else { return changes[f.id] == nil ? f : nil }
            var n = f; n.groupID = group; n.disposition = c.disposition
            return n
        }
        let second = DuplicateGroupDigestSplit.plan(facts, keeping: .pairs)
        #expect(second.isEmpty && second.pairs.isEmpty)
    }
}

// MARK: - LOGIC: the inspector

@Suite("Footage likeness — the inspector's 'Same footage as (possible)'")
@MainActor
struct FootageLikenessInspectorTests {

    private func rec(_ name: String, digest: String, codec: String = "h264") -> VideoRecord {
        let r = makeDuplicateRecord(filename: name, streamType: .videoAndAudio, sizeBytes: 100, durationSeconds: 60,
                                    partialMD5: "p", videoCodec: codec)
        r.fullPath = "/Volumes/Synthetic/" + name
        r.contentFixity = ContentFixity(digest: digest, byteCount: 100, stamp: flStamp, computedAt: flNow)
        return r
    }

    private func pair(_ other: String, strength: String = "weak") -> FootageLikenessStore.Pair {
        FootageLikenessStore.Pair(otherDigest: other, reasons: "timecode+duration", strength: strength, source: "duplicateCheck")
    }

    @Test("a weak pair shows the other content's first live file; an anchored one does not (Find Similar Footage links it)")
    func weakShowsAnchoredDoesNot() {
        let me = rec("test_master.mkv", digest: flHex(1), codec: "ffv1")
        let b = rec("test_export.mov", digest: flHex(2))
        let c = rec("test_dv.mov", digest: flHex(3), codec: "dvvideo")
        let byDigest = [flHex(1): [me], flHex(2): [b], flHex(3): [c]]
        let shown = InspectorPanelRules.possibleSameFootage(of: me, pairs: [pair(flHex(2)), pair(flHex(3), strength: "anchored")],
                                                            recordsByDigest: byDigest, shown: [])
        #expect(shown.map(\.id) == [b.id])
        let panel = InspectorPanel(record: me, duplicateGroupMembers: [], possibleSameFootage: shown,
                                   previewImage: nil, previewOfflineVolumeName: nil)
        #expect(panel.formatAllMetadata(me).contains("Same footage as (possible): test_export.mov (H.264, MOV)"))
    }

    @Test("an answered pair is not shown — 'not the same' suppresses it, 'same' too (it becomes a footage link), from either side or a copy")
    func answeredPairsHidden() {
        let me = rec("test_master.mkv", digest: flHex(1))
        let myCopy = rec("test_master_copy.mkv", digest: flHex(1))
        let b = rec("test_export.mov", digest: flHex(2))
        let byDigest = [flHex(1): [me, myCopy], flHex(2): [b]]
        let pairs = [pair(flHex(2))]
        #expect(InspectorPanelRules.possibleSameFootage(of: me, pairs: pairs, recordsByDigest: byDigest, shown: []).count == 1)
        myCopy.setFootageDecision(FootageDecision(otherID: b.id, verdict: .notSame, decidedAt: flNow))
        #expect(InspectorPanelRules.possibleSameFootage(of: me, pairs: pairs, recordsByDigest: byDigest, shown: []).isEmpty)
        myCopy.forgetFootageDecision(about: b.id)
        b.setFootageDecision(FootageDecision(otherID: me.id, verdict: .same, decidedAt: flNow))
        #expect(InspectorPanelRules.possibleSameFootage(of: me, pairs: pairs, recordsByDigest: byDigest, shown: []).isEmpty)
    }

    @Test("a file already listed as 'Same footage' is not listed twice; a content with no live file is not listed")
    func shownAndGone() {
        let me = rec("test_master.mkv", digest: flHex(1))
        let b = rec("test_export.mov", digest: flHex(2))
        let gone = rec("test_gone.mov", digest: flHex(3))
        gone.removal = RemovalMarker.missing(noticedAt: flNow, lastSeen: nil, reason: .missingOnDisk)
        let byDigest = [flHex(1): [me], flHex(2): [b], flHex(3): [gone]]
        #expect(InspectorPanelRules.possibleSameFootage(of: me, pairs: [pair(flHex(2)), pair(flHex(3))],
                                                        recordsByDigest: byDigest, shown: [b]).isEmpty)
    }
}

// MARK: - LOGIC: Verify's yellow rule

@Suite("Footage likeness — Verify Catalog's informational rule")
struct FootageLikenessVerifyRuleTests {

    private func row(_ name: String, digest: String, live: Bool = true) -> IntegrityRow {
        IntegrityRow(fullPath: "/Volumes/Synthetic/\(name)", fullDigest: digest,
                     removal: live ? nil : RemovalMarker.missing(noticedAt: flNow, lastSeen: nil, reason: .missingOnDisk))
    }

    @Test("an undecided weak pair on live rows is ONE finding, needsDecision false (yellow); decided, anchored or gone pairs are not")
    func onlyUndecidedWeakLivePairs() {
        let rows = [row("test_a.mov", digest: flHex(1)), row("test_b.mov", digest: flHex(2)), row("test_c.mov", digest: flHex(3)),
                    row("test_gone.mov", digest: flHex(4), live: false)]
        let likeness = [
            IntegrityLikenessFact(digestA: flHex(1), digestB: flHex(2), reasons: "timecode+duration", strength: "weak"),
            IntegrityLikenessFact(digestA: flHex(1), digestB: flHex(3), reasons: "timecode+duration", strength: "weak", verdict: "notSame"),
            IntegrityLikenessFact(digestA: flHex(2), digestB: flHex(3), reasons: "hash+duration", strength: "anchored"),
            IntegrityLikenessFact(digestA: flHex(1), digestB: flHex(4), reasons: "", strength: "weak"),
        ]
        let found = CatalogConstraints.check(rows: rows, events: [], likeness: likeness).filter { $0.rule == .possibleSameFootage }
        #expect(found.count == 1)
        #expect(found.allSatisfy { !$0.needsDecision })
        #expect(found.first?.words == "may be the same footage as test_b.mov (the duplicate check matched timecode+duration, weakly) — Same footage / Not the same in the inspector")
        #expect(CatalogConstraints.Rule.possibleSameFootage.tier == 5)
    }

    @Test("tier 5 counts them as could-not-check — the band's yellow — and never as a decision")
    func tierFiveIsYellow() {
        let rows = [row("test_a.mov", digest: flHex(1)), row("test_b.mov", digest: flHex(2))]
        var snapshot = VerifyCatalogSnapshot(rows: rows, events: [], catalogFile: "/tmp/none/catalog.sqlite", store: .sqlite)
        snapshot.likeness = [IntegrityLikenessFact(digestA: flHex(1), digestB: flHex(2), reasons: "timecode+duration", strength: "weak")]
        let input = VerifyCatalogTiers.TierInput(snapshot: snapshot, previous: nil, constraintFindings: nil, runID: UUID(), now: flNow,
                                                 databaseGeneration: .read(0))
        let outcome = VerifyCatalogTiers.databaseConstraints(input)
        #expect(outcome.tier.needsDecision == 0)
        #expect(outcome.tier.result == .couldNotCheck(1))
        #expect(outcome.tier.summary.contains("pairs of files may be the same footage"), "\(outcome.tier.summary)")
    }
}

// MARK: - TRUTH + ISOLATION: the door on catalog.sqlite

@MainActor
private func flVerify(_ scene: CutoverScene) async -> VerifyCatalogJob {
    let job = VerifyCatalogJob(model: scene.model)
    job.eventsForTesting = []
    job.start()
    await job.task?.value
    return job
}

@MainActor
private func storedPairs(_ model: VideoScanModel) async throws -> [CatalogRow.FootageLikenessReview] {
    let repository = try #require(model.catalogCutover.committer?.repository)
    return try await repository.read { reader in
        var out: [CatalogRow.FootageLikenessReview] = []
        try reader.footageLikenessReviews { out.append($0) }
        return out
    }
}

/// A weak-only group of three codecs on bulk rows 0…2 (default timecode,
/// one length, one resolution): the class the split used to HOLD.
@MainActor
private func weakGroup(_ scene: CutoverScene) throws -> (group: UUID, members: [VideoRecord]) {
    let g = UUID()
    let codecs = ["ffv1", "h264", "dvvideo"]
    let members = try (0..<3).map { try scene.bulk($0) }
    for (i, r) in members.enumerated() {
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.durationSeconds = 600
        r.timecode = "00:00:00:00"
        r.resolution = "720x480"
        r.videoCodec = codecs[i]
        r.duplicateGroupID = g
        r.duplicateConfidence = .high
        r.duplicateDisposition = i == 0 ? .keep : .extraCopy
        r.duplicateReasons = "timecode+duration+resolution"
        r.duplicateGroupCount = 3
        r.dupAnalyzedAt = flNow
    }
    return (g, members)
}

@Suite("Footage likeness — the split door on catalog.sqlite", .serialized)
@MainActor
struct FootageLikenessDoorTests {

    @Test("TRUTH: a weak-only group (the 403 class) → split, not held → two pairs in footage_likeness, nobody lost → Verify: no red, two yellow → 'not the same' → one → a second split records nothing")
    func weakGroupSplitsAndStaysKnown() async throws {
        let scene = try CutoverScene.make("fl_truth", healthyRows: 5); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let (g, members) = try weakGroup(scene)
        #expect(model.saveCatalogNow())
        let red = try #require(await flVerify(scene).report)
        #expect(red.findings.filter { $0.rule == "duplicateGroupDigestsAgree" }.count == 1)

        guard case .split(1, 0, 3, true, _) = model.splitDuplicateGroupsByFullDigest() else {
            Issue.record("expected one group split, three leaving"); return
        }
        let pairs = try await storedPairs(model)
        #expect(pairs.count == 2)
        #expect(pairs.allSatisfy { $0.likeness.strength == "weak" && $0.likeness.source == "duplicateCheck" && $0.verdict == nil })
        // Nothing lost: each leaver's content has a pair with the keeper's.
        let keeperDigest = try #require(VideoScanModel.storedFullDigest(members[0]))
        for r in members.dropFirst() {
            let d = try #require(VideoScanModel.storedFullDigest(r))
            #expect(pairs.contains { $0.likeness.key == CatalogRow.PairKey(d, keeperDigest) }, "\(r.filename) lost its likeness")
        }
        let reloaded = try await scene.sqliteLoad()
        #expect(!reloaded.records.contains { $0.duplicateGroupID == g })
        #expect(model.footageLikeness.count == 2, "the inspector's store absorbed the pairs")
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("likeness kept in catalog.sqlite: 2 new pair(s), 0 already there"), "\(log.suffix(600))")
        #expect(log.contains("via footage likeness — split duplicate groups: 2 likeness pair(s)"))

        let after = try #require(await flVerify(scene).report)
        #expect(after.findings.filter { $0.rule == "duplicateGroupDigestsAgree" }.isEmpty)
        let yellow = after.findings.filter { $0.rule == "possibleSameFootage" }
        #expect(yellow.count == 2)
        #expect(yellow.allSatisfy { !$0.needsDecision })
        #expect(after.tier(5)?.needsDecision == 0)

        model.setFootageDecision(.notSame, between: members[0].id, and: members[1].id)
        #expect(model.saveCatalogNow())
        let answered = try #require(await flVerify(scene).report)
        #expect(answered.findings.filter { $0.rule == "possibleSameFootage" }.count == 1)

        #expect(model.splitDuplicateGroupsByFullDigest() == .nothingToSplit)
        #expect(try await storedPairs(model).count == 2, "a second split records nothing")
    }

    @Test("ISOLATION: a blocked committer refuses the split — no pair recorded, no record changed")
    func blockedCommitterRefuses() async throws {
        let scene = try CutoverScene.make("fl_blocked", healthyRows: 5); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let (g, members) = try weakGroup(scene)
        #expect(model.saveCatalogNow())
        let committer = try #require(model.catalogCutover.committer)
        #expect(committer.sideTableWriteRefusal == nil)
        // Blocked: the door's first write (the safety copy's commit) is
        // refused, so the likeness write is never reached.
        committer.block("test: blocked")
        #expect(committer.sideTableWriteRefusal != nil)
        guard case .refused = model.splitDuplicateGroupsByFullDigest() else { Issue.record("expected refused"); return }
        #expect(members.allSatisfy { $0.duplicateGroupID == g }, "nothing changed")
        // The likeness step itself refuses with the store's words.
        let plan = DuplicateGroupDigestSplit.plan(model.duplicateDigestSplitFacts(), keeping: .pairs)
        #expect(plan.pairs.count == 2)
        guard case .failure(let refusal) = model.recordSplitLikeness(plan, committer: committer) else {
            Issue.record("expected the likeness write to be refused"); return
        }
        #expect(refusal.words.contains("the likeness could not be kept in catalog.sqlite"))
        #expect(try await storedPairs(model).isEmpty)
        #expect(model.footageLikeness.isEmpty)
    }

    @Test("ISOLATION: a read-only session refuses and records nothing")
    func readOnlyRefuses() async throws {
        let scene = try CutoverScene.make("fl_ro", healthyRows: 5); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let (g, members) = try weakGroup(scene)
        #expect(model.saveCatalogNow())
        model.isReadOnly = true
        guard case .refused = model.splitDuplicateGroupsByFullDigest() else { Issue.record("expected refused"); return }
        #expect(members.allSatisfy { $0.duplicateGroupID == g })
        #expect(try await storedPairs(model).isEmpty)
        #expect(model.footageLikeness.isEmpty)
    }
}

// MARK: - SCALE

@Suite("Footage likeness — SCALE (100k)", .serialized)
@MainActor
struct FootageLikenessScaleTests {

    /// 25k old groups × four files, four digests each, weak likeness (a
    /// default timecode): 100k facts → 75k pairs. Budget (Debug, M4 Max):
    /// 15 s — the per-group scoring is star-shaped (k−1 pairs, each a few
    /// member pairs); a quadratic slip across groups would be hours.
    @Test(.timeLimit(.minutes(3)))
    func planWithPairsAt100k() {
        var facts: [FLFact] = []
        facts.reserveCapacity(100_000)
        for n in 0..<25_000 {
            let g = UUID()
            for i in 0..<4 {
                let f = DuplicateLikeness.Facts(filename: "test_clip_\(n)_\(i).mov", partialMD5: "p\(n)_\(i)", sizeBytes: Int64(100 + i),
                                                timecode: "00:00:00:00", durationSeconds: Double(60 + n % 500), resolution: "720x480",
                                                videoCodec: ["ffv1", "h264", "dvvideo", "hevc"][i], digest: flHex(n * 4 + i + 1))
                facts.append(fact(f, group: g, i == 0 ? .keep : .extraCopy))
            }
        }
        let clock = ContinuousClock()
        var plan = DuplicateGroupDigestSplit.Plan()
        let measured = clock.measure { plan = DuplicateGroupDigestSplit.plan(facts, keeping: .pairs) }
        print("[footage-likeness] plan 100k facts with pairs: \(measured)")
        #expect(plan.pairs.count == 75_000)
        #expect(plan.heldGroups.isEmpty)
        #expect(measured < .seconds(15))
    }

    /// 100k pairs into the inspector's store and 50k pairs over 100k rows
    /// through Verify's rule. Budgets (Debug): 5 s each.
    @Test(.timeLimit(.minutes(2)))
    func storeAndVerifyRuleAt100k() {
        let rows = (0..<100_000).map { IntegrityRow(fullPath: "/Volumes/Synthetic/test_\($0).mov", fullDigest: flHex($0 + 1)) }
        let pairs = (0..<100_000).map { CatalogRow.FootageLikeness(flHex($0 + 1), flHex($0 + 2), reasons: "timecode+duration",
                                                                   strength: "weak", source: "duplicateCheck", recordedAt: 0) }
        let store = FootageLikenessStore()
        let clock = ContinuousClock()
        let absorbing = clock.measure { store.replace(with: pairs) }
        #expect(store.count == 100_000)
        let facts = pairs.prefix(50_000).map { IntegrityLikenessFact(digestA: $0.digestA, digestB: $0.digestB, reasons: $0.reasons,
                                                                     strength: $0.strength) }
        var found: [CatalogConstraints.Finding] = []
        var idx = CatalogConstraints.index(rows)
        idx.likeness = Array(facts)
        let checking = clock.measure { found = CatalogConstraints.possibleSameFootage(rows, idx, []) }
        print("[footage-likeness] store 100k pairs: \(absorbing); Verify rule 100k rows + 50k pairs: \(checking)")
        #expect(found.count == 50_000)
        #expect(absorbing < .seconds(5))
        #expect(checking < .seconds(5))
    }
}

// MARK: - SENSOR

@Suite("Footage likeness — sensors")
struct FootageLikenessSensorTests {

    @Test("no delete path reads footage likeness — eligibility never comes from footage_likeness")
    func deletePathsNeverReadLikeness() throws {
        let files = ["VideoScanModel+Duplicates.swift", "DeleteDuplicatesJob.swift", "DeleteDuplicatesPlan.swift",
                     "DeleteDuplicatesFlow.swift", "DeleteDuplicatesTargetGates.swift", "DeleteDuplicatesSiblingProof.swift",
                     "DeleteDuplicatesReviewedPlan.swift", "DeleteDuplicatesBatchRun.swift", "CopiesAdviceTrash.swift",
                     "VideoScanModel+JunkDelete.swift"]
        for name in files {
            let code = try SourceTree.appCode(named: name)
            #expect(code.range(of: #"footageLikeness|footage_likeness|FootageLikeness|possibleSameFootage|LikenessPair"#,
                               options: .regularExpression) == nil, "\(name) reads footage likeness")
        }
    }

    @Test("ONE writer: only the split door records footage likeness, through the committer's side-table door")
    func oneWriter() throws {
        let door = try SourceTree.appCode(named: "VideoScanModel+DuplicateDigestSplit.swift")
        #expect(door.contains("committer.commitSideTables(") && door.contains("via: .footageLikeness"))
        #expect(door.contains("try tx.recordFootageLikeness(row)"))
        #expect(door.contains("plan = plan.holding(likeness?.heldGroups ?? [], why: Self.contentMissingWords)"))
        #expect(door.contains("catalogCutover.isSQLiteAuthority ? .pairs : .footageGroups(duplicateDigestSplitFootageGroups())"),
                "under catalog.sqlite nothing is held by the plan")
    }
}
