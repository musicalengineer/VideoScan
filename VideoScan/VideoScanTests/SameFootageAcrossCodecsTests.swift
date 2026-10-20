// SameFootageAcrossCodecsTests.swift
// "Same footage, different file" (Rick 2026-10-19: "I have a 2 hour video
// FFV1 then re-encode to H264 … I don't want to lose the 'same event
// different codec' feature"). Three relationships, none lost:
//   copies        same whole-file SHA-256 → the duplicate group (delete-eligible extras)
//   same footage  the duplicate check's likeness, different bytes, lengths agree
//                 → a Find Similar Footage link with the reasons verbatim; NEVER
//                 delete-eligible
//   not the same  only on evidence: lengths disagree (sampled-hash collision) or
//                 the person said so
//
// Dimensions (CLAUDE.md feature-test checklist):
//   LOGIC      the shared likeness rule (relationships, words); the detector
//              stamps copies only and counts the rest; FootageGrouping links the
//              FFV1-MKV + H.264-MOV + DV-MOV trio with reasons; Possible on a
//              default timecode; the person's "not the same" wins; the split
//              plan says "same footage" / "a different length" and is idempotent;
//              the inspector's "Same footage as" line; a group whose files
//              would be cut apart (weak likeness only) is HELD, with words.
//   SCALE      100k footage inputs, 100k detector records, 100k plan facts —
//              each inside a budget.
//   MEDIA      real ffmpeg fixtures (mp4/h264, mov/prores, mkv/ffv1+pcm,
//              mxf/mpeg2, avi/dv) probed by the scan parser → copy-check links
//              with the probed codec words.
//   ISOLATION  delete eligibility never comes from footage: a model whose files
//              are linked only as the same footage offers nothing to delete.
//   SENSOR     no delete-path source reads footage membership; the detector and
//              Find Similar Footage share ONE likeness rule; the split door and
//              menu keep the same footage; Verify has no footage rule.
//   TRUTH      end to end on catalog.sqlite: a false group of three codecs →
//              split → Find Similar Footage → reload: no copies group, one
//              footage group of three with reasons; Verify green; re-runs change
//              nothing.
// Plus an OPT-IN evidence run against a COPY of a real catalog
// (`SameFootageRealCopyEvidence`, no-op unless its request file exists).
//
// Suites (filter by SUITE): SameFootageLikenessRuleTests ·
// SameFootageDetectorTests · SameFootageGroupingTests · SameFootageSplitPlanTests ·
// SameFootageHeldDoorTests · SameFootageInspectorTests · SameFootageDeleteIsolationTests ·
// SameFootageSensorTests · SameFootageScaleTests · SameFootageMediaMatrixTests ·
// SameFootageTruthTests · SameFootageRealCopyEvidence
// Synthetic names only.

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let sfNow = Date(timeIntervalSince1970: 1_760_850_000)   // 2026-10-19
private func sfHex(_ n: Int) -> String { String(format: "%064x", n) }
private let sfStamp = FileIdentityStamp(device: 1, inode: 2, size: 100, mtimeNs: 3)

/// The trio of one synthetic two-hour recording: FFV1 MKV (the master),
/// its H.264 MOV re-encode and a DV MOV transfer — same length, same
/// timecode, different names, different bytes.
private enum Trio {
    static let seconds = 7200.0
    static let timecode = "01:02:03:04"

    static func facts(digests: [String?] = [sfHex(1), sfHex(2), sfHex(3)], timecode: String = Trio.timecode,
                      durations: [Double] = [seconds, seconds, seconds]) -> [DuplicateLikeness.Facts] {
        [
            DuplicateLikeness.Facts(filename: "test_synthetic_xmas_master.mkv", fullPath: "/Volumes/Synthetic/A/test_synthetic_xmas_master.mkv",
                                    partialMD5: "m1", sizeBytes: 900_000_000_000, timecode: timecode, durationSeconds: durations[0],
                                    resolution: "720x480", videoCodec: "ffv1", audioCodec: "pcm_s16le", audioChannels: "2",
                                    audioSampleRate: "48000", isPlayable: "Yes", digest: digests[0]),
            DuplicateLikeness.Facts(filename: "test_family_evening_export.mov", fullPath: "/Volumes/Synthetic/B/test_family_evening_export.mov",
                                    partialMD5: "m2", sizeBytes: 4_000_000_000, timecode: timecode, durationSeconds: durations[1],
                                    resolution: "720x480", videoCodec: "h264", audioCodec: "aac", audioChannels: "2",
                                    audioSampleRate: "48000", isPlayable: "Yes", digest: digests[1]),
            DuplicateLikeness.Facts(filename: "test_tape_transfer_dv.mov", fullPath: "/Volumes/Synthetic/C/test_tape_transfer_dv.mov",
                                    partialMD5: "m3", sizeBytes: 26_000_000_000, timecode: timecode, durationSeconds: durations[2],
                                    resolution: "720x480", videoCodec: "dvvideo", audioCodec: "pcm_s16le", audioChannels: "2",
                                    audioSampleRate: "48000", isPlayable: "Yes", digest: digests[2]),
        ]
    }

    /// The same three as FootageInputs carrying their likeness facts.
    static func inputs(_ fs: [DuplicateLikeness.Facts] = Trio.facts()) -> [FootageInput] {
        fs.map { f in
            FootageInput(id: f.id, filename: f.filename, fullPath: f.fullPath, durationSeconds: f.durationSeconds,
                         sizeBytes: f.sizeBytes, partialMD5: f.partialMD5, fixityDigest: f.digest, videoCodec: f.videoCodec,
                         likeness: f)
        }
    }

    /// The same three as VideoRecords.
    static func records(digests: [String?] = [sfHex(1), sfHex(2), sfHex(3)]) -> [VideoRecord] {
        facts(digests: digests).map { f in
            let r = makeDuplicateRecord(filename: f.filename, streamType: .videoAndAudio, sizeBytes: f.sizeBytes,
                                        durationSeconds: f.durationSeconds, partialMD5: f.partialMD5, resolution: f.resolution,
                                        videoCodec: f.videoCodec, audioCodec: f.audioCodec, timecode: f.timecode)
            r.fullPath = f.fullPath
            if let d = f.digest {
                r.contentFixity = ContentFixity(digest: d, byteCount: f.sizeBytes, stamp: sfStamp, computedAt: sfNow)
            }
            return r
        }
    }
}

@MainActor
private func sfVerify(_ scene: CutoverScene) async -> VerifyCatalogJob {
    let job = VerifyCatalogJob(model: scene.model)
    job.eventsForTesting = []
    job.start()
    await job.task?.value
    return job
}

private func runFootage(_ xs: [FootageInput]) -> FootageGrouping.Result {
    FootageGrouping.run(xs, options: .init(), now: sfNow)
}

// MARK: - LOGIC: the shared rule

@Suite("Same footage — the duplicate check's likeness rule (DuplicateLikeness)")
struct SameFootageLikenessRuleTests {

    @Test("the trio: different digests, same length → a same-footage link for every scored pair (two of them the detector's star edges), reasons verbatim; nothing is 'copies'")
    func trioLinks() throws {
        let fs = Trio.facts()
        let run = DuplicateLikeness.sameFootageLinks(fs)
        #expect(run.links.count == 3, "every pair of the three scores")
        #expect(run.differentLength == 0)
        let star = run.links.filter(\.inStar)
        #expect(star.count == 2 && Set(star.map(\.b)) == [0], "the FFV1 master is the star's hub (best-connected, technically best)")
        for link in run.links {
            #expect(link.score.reasons.starts(with: ["timecode", "duration"]), "\(link.score.reasons)")
            #expect(DuplicateLikeness.relationship(fs[link.a], fs[link.b], reasons: link.score.reasons) == .sameFootage)
        }
    }

    @Test("same digest = copies (no link); one digest unknown = not known to differ (no link)")
    func copiesAndUnknown() {
        let copies = Trio.facts(digests: [sfHex(7), sfHex(7), sfHex(7)])
        #expect(DuplicateLikeness.sameFootageLinks(copies).links.isEmpty)
        #expect(DuplicateLikeness.relationship(copies[0], copies[1], reasons: ["timecode", "duration"]) == .copies)
        let unknown = Trio.facts(digests: [sfHex(1), nil, nil])
        #expect(DuplicateLikeness.sameFootageLinks(unknown).links.isEmpty)
        #expect(DuplicateLikeness.relationship(unknown[0], unknown[1], reasons: ["duration"]) == .unknown)
    }

    @Test("NOT THE SAME on evidence: one sampled hash + size, different digests, 100 s vs 200 s → a different length; no link")
    func collision() {
        let a = DuplicateLikeness.Facts(filename: "test_a.mxf", partialMD5: "same", sizeBytes: 42, durationSeconds: 100,
                                        videoCodec: "dnxhd", digest: sfHex(1))
        let b = DuplicateLikeness.Facts(filename: "test_b.mxf", partialMD5: "same", sizeBytes: 42, durationSeconds: 200,
                                        videoCodec: "dnxhd", digest: sfHex(2))
        let run = DuplicateLikeness.sameFootageLinks([a, b])
        #expect(run.links.isEmpty)
        #expect(run.differentLength == 1)
    }

    @Test("words: the codec as families know it, then the container")
    func words() {
        #expect(DuplicateLikeness.formatWords(videoCodec: "ffv1", audioCodec: "pcm_s16le", filename: "x.mkv") == "FFV1 MKV")
        #expect(DuplicateLikeness.formatWords(videoCodec: "h264", audioCodec: "aac", filename: "x.mov") == "H.264 MOV")
        #expect(DuplicateLikeness.formatWords(videoCodec: "dvvideo", audioCodec: "", filename: "x.mov") == "DV MOV")
        #expect(DuplicateLikeness.formatWords(videoCodec: "", audioCodec: "aac", filename: "x.m4a") == "AAC M4A")
        #expect(DuplicateLikeness.differenceWords("FFV1 MKV", "H.264 MOV") == "different codec: FFV1 MKV · H.264 MOV")
        #expect(DuplicateLikeness.differenceWords("DV MOV", "DV MOV") == "different bytes, same format: DV MOV")
        #expect(DuplicateLikeness.isDefaultTimecode("00:00:00:00") && DuplicateLikeness.isDefaultTimecode("01:00:00;00"))
        #expect(!DuplicateLikeness.isDefaultTimecode(Trio.timecode))
    }
}

// MARK: - LOGIC: the detector

@Suite("Same footage — the detector stamps copies only and counts the rest")
struct SameFootageDetectorTests {

    @Test("FFV1 MKV + H.264 MOV + DV MOV of one recording: ZERO copies-group membership; two same-footage pairs counted")
    func trioIsNotCopies() {
        let rs = Trio.records()
        let summary = DuplicateDetector.analyze(records: rs)
        #expect(summary.groups == 0)
        #expect(rs.allSatisfy { $0.duplicateGroupID == nil && $0.duplicateDisposition == .none })
        #expect(summary.sameFootageLinks == 2)
        #expect(summary.differentLength == 0)
    }

    @Test("byte-identical copies still form a group (one keeper, one extra); a re-encode beside them is counted, not grouped")
    func copiesStillGroup() {
        let rs = Trio.records(digests: [sfHex(1), sfHex(1), sfHex(3)])
        let summary = DuplicateDetector.analyze(records: rs)
        #expect(summary.groups == 1)
        let group: UUID? = rs[0].duplicateGroupID
        #expect(group != nil)
        #expect(group == rs[1].duplicateGroupID)
        let keepers = [rs[0], rs[1]].filter { $0.duplicateDisposition == .keep }
        #expect(keepers.count == 1)
        #expect(rs[2].duplicateGroupID == nil, "the DV transfer is not a copy")
        #expect(summary.sameFootageLinks >= 1)
    }
}

// MARK: - LOGIC: Find Similar Footage keeps the likeness

@Suite("Same footage — Find Similar Footage records the duplicate check's likeness")
struct SameFootageGroupingTests {

    @Test("the trio → ONE footage group of three, Likely, each with 'same footage as … different codec … (the duplicate check matched …)'; none is a 'copy'")
    func trioOneGroup() throws {
        let xs = Trio.inputs()
        let r = runFootage(xs)
        let ids = Set(xs.compactMap { r.memberships[$0.id]?.groupID })
        #expect(ids.count == 1 && xs.allSatisfy { r.memberships[$0.id] != nil }, "all three in one group")
        #expect(r.memberships[xs[0].id]?.groupSize == 3)
        #expect(r.memberships[xs[0].id]?.confidence == .likely)
        #expect(r.stats.edgesByReason[.copyCheckLikeness] == 3)
        #expect(xs.allSatisfy { r.memberships[$0.id]?.role != .copy }, "different bytes are never a copy")
        let h264 = try #require(r.memberships[xs[1].id]).evidence.joined(separator: " | ")
        #expect(h264.contains("same footage as test_synthetic_xmas_master.mkv — different codec: H.264 MOV · FFV1 MKV"), "\(h264)")
        #expect(h264.contains("(the duplicate check matched timecode+duration+resolution)"), "\(h264)")
        let ffv1 = try #require(r.memberships[xs[0].id]).evidence.joined(separator: " | ")
        #expect(ffv1.contains("different codec: FFV1 MKV · DV MOV") && ffv1.contains("different codec: FFV1 MKV · H.264 MOV"), "\(ffv1)")
        #expect(r.memberships.values.flatMap(\.evidence).allSatisfy { !$0.contains("same bytes") })
    }

    @Test("a default timecode (00:00:00:00) is no anchor: the link is only Possible")
    func defaultTimecodeIsPossible() {
        let xs = Trio.inputs(Array(Trio.facts(timecode: "00:00:00:00").prefix(2)))
        let r = runFootage(xs)
        #expect(r.stats.edgesByReason[.copyCheckLikenessWeak] == 1)
        #expect(r.memberships[xs[0].id]?.confidence == .possible)
    }

    @Test("the person's 'not the same' wins over the duplicate check's likeness")
    func personSplits() {
        var xs = Trio.inputs(Array(Trio.facts().prefix(2)))
        xs[0].decisions = [FootageDecision(otherID: xs[1].id, verdict: .notSame, decidedAt: sfNow)]
        let r = runFootage(xs)
        #expect(r.memberships[xs[0].id] == nil && r.memberships[xs[1].id] == nil)
        #expect(r.stats.refusedByPerson == 1)
    }

    @Test("a sampled-hash collision of a different length is NOT linked, and is counted")
    func collisionNotLinked() {
        let a = DuplicateLikeness.Facts(filename: "test_a.mxf", partialMD5: "same", sizeBytes: 42, durationSeconds: 100,
                                        videoCodec: "dnxhd", digest: sfHex(1))
        let b = DuplicateLikeness.Facts(filename: "test_b.mxf", partialMD5: "same", sizeBytes: 42, durationSeconds: 200,
                                        videoCodec: "dnxhd", digest: sfHex(2))
        let xs = Trio.inputs([a, b])
        let r = runFootage(xs)
        #expect(r.memberships.isEmpty)
        #expect(r.stats.copyCheckDifferentLength == 1)
    }

    @Test("RE-RUN: the same inputs give the same answer (sameAnswer) — the incremental apply writes nothing the second time")
    func idempotent() {
        let xs = Trio.inputs()
        let first = runFootage(xs)
        let second = runFootage(xs.map { x in var y = x; y.existing = first.memberships[x.id]; return y })
        for x in xs {
            guard let a = first.memberships[x.id], let b = second.memberships[x.id] else {
                Issue.record("\(x.filename) lost its footage group on the re-run"); continue
            }
            #expect(a.sameAnswer(as: b))
        }
    }
}

// MARK: - LOGIC: the split plan keeps the same footage

private typealias SFact = DuplicateGroupDigestSplit.MemberFact

private func sfact(_ f: DuplicateLikeness.Facts, group: UUID, _ d: DuplicateDisposition = .extraCopy) -> SFact {
    SFact(id: f.id, groupID: group, filename: f.filename, digest: f.digest, disposition: d, confidence: .medium,
          bestMatch: "", likeness: f)
}

@Suite("Same footage — Split Duplicate Groups by Full Hash keeps it")
struct SameFootageSplitPlanTests {

    @Test("an old 'copies' group of the trio: all three leave the copies, each 'kept as same footage', with formats and reasons")
    func trioLeavesAsSameFootage() throws {
        let g = UUID()
        let fs = Trio.facts()
        let plan = DuplicateGroupDigestSplit.plan([sfact(fs[0], group: g, .keep), sfact(fs[1], group: g), sfact(fs[2], group: g)])
        #expect(plan.recordsLeaving == 3)
        #expect(plan.sameFootageFiles == 3)
        #expect(plan.differentLengthFiles == 0)
        let words = try #require(plan.groups.first?.words)
        #expect(words.contains("test_family_evening_export.mov left the copies — same footage as test_synthetic_xmas_master.mkv, different codec: H.264 MOV · FFV1 MKV (the duplicate check matched timecode+duration+resolution) — kept as same footage, not copies"), "\(words)")
    }

    @Test("copies stay copies; the different-length member is said to be not the same footage")
    func mixed() throws {
        let g = UUID()
        var fs = Trio.facts(digests: [sfHex(1), sfHex(1), sfHex(3)])
        // A fourth file: same sampled hash + size as the master, other bytes, half the length.
        let odd = DuplicateLikeness.Facts(filename: "test_padded_other.mkv", partialMD5: fs[0].partialMD5, sizeBytes: fs[0].sizeBytes,
                                          durationSeconds: 3600, resolution: "640x480", videoCodec: "mpeg4", digest: sfHex(9))
        fs.append(odd)
        let plan = DuplicateGroupDigestSplit.plan([sfact(fs[0], group: g, .keep), sfact(fs[1], group: g), sfact(fs[2], group: g),
                                                   sfact(fs[3], group: g)])
        let byID = Dictionary(uniqueKeysWithValues: plan.changes.map { ($0.id, $0) })
        #expect(byID[fs[0].id]?.groupID == g && byID[fs[1].id]?.groupID == g, "the byte copies stay one group")
        #expect(plan.sameFootageFiles == 1 && plan.differentLengthFiles == 1)
        let words = try #require(plan.groups.first?.words)
        #expect(words.contains("test_padded_other.mkv left the copies — a different length from test_synthetic_xmas_master.mkv (only the sampled hash matched) — not the same footage"), "\(words)")
    }

    @Test("HELD: when a simulated Find Similar Footage pass would leave the files apart (weak likeness only), the group is kept exactly as it is, with words")
    func heldWhenWeak() throws {
        let g = UUID()
        let fs = Trio.facts(timecode: "00:00:00:00")   // a default timecode anchors nothing
        let facts = [sfact(fs[0], group: g, .keep), sfact(fs[1], group: g), sfact(fs[2], group: g)]
        let plan = DuplicateGroupDigestSplit.plan(facts, footageGroupOf: [:])
        #expect(plan.isEmpty, "no change is planned for a held group")
        #expect(plan.heldGroups.count == 1 && plan.splitGroups.isEmpty)
        #expect(plan.recordsLeaving == 0 && plan.sameFootageFiles == 0)
        let words = try #require(plan.groups.first?.words)
        #expect(words.contains("kept as it is — splitting would lose what the duplicate check knew:"), "\(words)")
        #expect(words.contains("only weakly (the duplicate check matched timecode+duration+resolution"), "\(words)")
        #expect(words.hasSuffix("It waits for a place to keep weak likeness."))
    }

    @Test("NOT HELD: the same group splits when the files stay linked as the same footage, or when the part cut off is a different length")
    func splitWhenLinkedOrDifferent() {
        let g = UUID(), footage = UUID()
        let fs = Trio.facts()
        let facts = [sfact(fs[0], group: g, .keep), sfact(fs[1], group: g), sfact(fs[2], group: g)]
        let linked = DuplicateGroupDigestSplit.plan(facts, footageGroupOf: Dictionary(uniqueKeysWithValues: fs.map { ($0.id, footage) }))
        #expect(linked.heldGroups.isEmpty && linked.recordsLeaving == 3)
        let a = DuplicateLikeness.Facts(filename: "test_a.mxf", partialMD5: "same", sizeBytes: 42, durationSeconds: 100, digest: sfHex(1))
        let b = DuplicateLikeness.Facts(filename: "test_b.mxf", partialMD5: "same", sizeBytes: 42, durationSeconds: 200, digest: sfHex(2))
        let h = UUID()
        let collision = DuplicateGroupDigestSplit.plan([sfact(a, group: h, .keep), sfact(b, group: h)], footageGroupOf: [:])
        #expect(collision.heldGroups.isEmpty && collision.recordsLeaving == 2 && collision.differentLengthFiles == 2)
    }

    @Test("IDEMPOTENT with likeness facts: applying the plan and planning again plans nothing")
    func idempotent() {
        let g = UUID()
        let fs = Trio.facts(digests: [sfHex(1), sfHex(1), sfHex(3)])
        var facts = [sfact(fs[0], group: g, .keep), sfact(fs[1], group: g), sfact(fs[2], group: g)]
        let first = DuplicateGroupDigestSplit.plan(facts)
        #expect(!first.isEmpty)
        let changes = Dictionary(uniqueKeysWithValues: first.changes.map { ($0.id, $0) })
        facts = facts.compactMap { f in
            guard let c = changes[f.id] else { return f }
            guard let group = c.groupID else { return nil }
            var n = f; n.groupID = group; n.disposition = c.disposition; n.bestMatch = c.bestMatch
            return n
        }
        #expect(DuplicateGroupDigestSplit.plan(facts).isEmpty)
    }
}

// MARK: - The door holds what it cannot keep

@Suite("Same footage — the split door holds a weak-only group", .serialized)
@MainActor
struct SameFootageHeldDoorTests {

    @Test("a group of three codecs alike only by a default timecode: nothing changes, no safety copy, the log says held and why; Verify keeps it listed")
    func heldAtTheDoor() throws {
        let sb = try ShowAgainSandbox.make("samefoot_held"); defer { sb.cleanup() }
        let g = UUID()
        let codecs = ["ffv1", "h264", "dvvideo"]
        let rs = try (0..<3).map { i -> VideoRecord in
            let r = try sb.record("test_held_\(i).mov", bytes: 100, stage: .none)
            r.contentFixity = ContentFixity(digest: sfHex(10 + i), byteCount: 100, stamp: sfStamp, computedAt: sfNow)
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.timecode = "00:00:00:00"
            r.durationSeconds = 600
            r.resolution = "720x480"
            r.videoCodec = codecs[i]
            r.duplicateGroupID = g
            r.duplicateConfidence = .high
            r.duplicateDisposition = i == 0 ? .keep : .extraCopy
            return r
        }
        #expect(sb.model.splitDuplicateGroupsByFullDigest() == .nothingToSplit)
        #expect(rs.allSatisfy { $0.duplicateGroupID == g }, "held exactly as it is")
        let log = sb.catalogLogText()
        #expect(log.contains("Split duplicate groups: held 1 of 1 — group "), "\(log.suffix(800))")
        #expect(log.contains("OUTCOME — nothing to split: 1 group(s) held as they are"))
        let folder = URL(fileURLWithPath: sb.model.catalogStore.fileLocation).deletingLastPathComponent()
        let copies = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.contains("pre-dup-split") } ?? []
        #expect(copies.isEmpty, "no safety copy when nothing changes")
    }
}

// MARK: - LOGIC: the inspector line

@Suite("Same footage — the inspector's line")
@MainActor
struct SameFootageInspectorTests {

    private func rec(_ name: String, codec: String, digest: String, group: UUID?) -> VideoRecord {
        let r = makeDuplicateRecord(filename: name, streamType: .videoAndAudio, sizeBytes: 100, durationSeconds: 60,
                                    partialMD5: "p", videoCodec: codec)
        r.fullPath = "/Volumes/Synthetic/" + name
        r.contentFixity = ContentFixity(digest: digest, byteCount: 100, stamp: sfStamp, computedAt: sfNow)
        if let group {
            r.footage = FootageMembership(groupID: group, groupSize: 3, confidence: .likely, role: .reEncode, rank: 1,
                                          likelyOriginalID: r.id, originalInCatalog: true, evidence: [], scannedAt: sfNow,
                                          algorithmVersion: FootageGrouping.algorithmVersion)
        }
        return r
    }

    @Test("'Same footage as' lists the group's OTHER files with different bytes — never itself, never a byte copy; codec and container shown")
    func line() {
        let g = UUID()
        let me = rec("test_master.mkv", codec: "ffv1", digest: sfHex(1), group: g)
        let reencode = rec("test_export.mov", codec: "h264", digest: sfHex(2), group: g)
        let copy = rec("test_master_copy.mkv", codec: "ffv1", digest: sfHex(1), group: g)
        let stranger = rec("test_other.mov", codec: "h264", digest: sfHex(5), group: UUID())
        let others = InspectorPanelRules.sameFootageOthers(of: me, groupMembers: [me, reencode, copy, stranger])
        #expect(others.map(\.id) == [reencode.id])
        #expect(InspectorPanelRules.sameFootageLine(reencode) == "test_export.mov (H.264, MOV)")
        #expect(InspectorPanelRules.showsDuplicatesOrSameFootage(me, sameFootage: others))
        let panel = InspectorPanel(record: me, duplicateGroupMembers: [], sameFootageMembers: others,
                                   previewImage: nil, previewOfflineVolumeName: nil)
        #expect(panel.formatAllMetadata(me).contains("Same footage as: test_export.mov (H.264, MOV)"))
    }
}

// MARK: - ISOLATION: delete eligibility never comes from footage

@Suite("Same footage — never delete-eligible", .serialized)
@MainActor
struct SameFootageDeleteIsolationTests {

    @Test("files linked ONLY as the same footage (no duplicate group) offer nothing to Delete Duplicates; a copy pair beside them does")
    func footageIsNotDeletable() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("samefoot_delete")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        let vol = "/Volumes/SyntheticDrive"
        let g = UUID()
        let trio = Trio.records()
        for (i, r) in trio.enumerated() {
            r.fullPath = "\(vol)/footage/\(r.filename)"
            r.footage = FootageMembership(groupID: g, groupSize: 3, confidence: .likely, role: i == 0 ? .original : .reEncode,
                                          rank: i, likelyOriginalID: trio[0].id, originalInCatalog: true,
                                          evidence: ["same footage as x — different codec: A · B (the duplicate check matched timecode+duration)"],
                                          scannedAt: sfNow, algorithmVersion: FootageGrouping.algorithmVersion)
        }
        model.records = trio
        #expect(model.duplicateDeletionSelection(onVolume: vol).targets.isEmpty, "same footage is never a target")

        // Control: a real copy pair on the same drive IS offered.
        let dg = UUID()
        let k = makeDuplicateRecord(filename: "test_k.mov", streamType: .videoAndAudio, sizeBytes: 10, durationSeconds: 5, partialMD5: "q")
        let x = makeDuplicateRecord(filename: "test_x.mov", streamType: .videoAndAudio, sizeBytes: 10, durationSeconds: 5, partialMD5: "q")
        k.fullPath = "\(vol)/copies/test_k.mov"; x.fullPath = "\(vol)/copies/test_x.mov"
        k.duplicateGroupID = dg; x.duplicateGroupID = dg
        k.duplicateDisposition = .keep; x.duplicateDisposition = .extraCopy
        model.records = trio + [k, x]
        #expect(model.duplicateDeletionSelection(onVolume: vol).targets.map(\.id) == [x.id])
    }
}

// MARK: - SENSOR

@Suite("Same footage — sensors")
struct SameFootageSensorTests {

    @Test("no delete path reads footage membership — Delete Duplicates, its plan/flow/gates and the Copies card's Trash button")
    func deletePathsNeverReadFootage() throws {
        let files = ["VideoScanModel+Duplicates.swift", "DeleteDuplicatesJob.swift", "DeleteDuplicatesPlan.swift",
                     "DeleteDuplicatesFlow.swift", "DeleteDuplicatesTargetGates.swift", "DeleteDuplicatesSiblingProof.swift",
                     "DeleteDuplicatesReviewedPlan.swift", "DeleteDuplicatesBatchRun.swift", "CopiesAdviceTrash.swift",
                     "VideoScanModel+JunkDelete.swift"]
        for name in files {
            let code = try SourceTree.appCode(named: name)
            #expect(code.range(of: #"\.footage\b|footageGroupID|FootageMembership|footageDecisions"#, options: .regularExpression) == nil,
                    "\(name) reads footage membership")
        }
    }

    @Test("ONE likeness rule: the detector and Find Similar Footage both call DuplicateLikeness; the detector still partitions by digest")
    func oneRule() throws {
        let detector = try SourceTree.appCode(named: "DuplicateDetector.swift")
        #expect(detector.contains("DuplicateLikeness.pairs(facts)") && detector.contains("DuplicateLikeness.stars(facts, pairs: scored)"))
        #expect(detector.contains("DuplicateGroupDigestSplit.partition("))
        #expect(!detector.contains("ScoringRule("), "the rule table lives in DuplicateLikeness only")
        let grouping = try SourceTree.appCode(named: "FootageGrouping.swift")
        #expect(grouping.contains("DuplicateLikeness.sameFootageLinks(facts)"))
        #expect(grouping.contains("b.copyCheckLikeness()"))
        let snapshot = try SourceTree.appCode(named: "VideoScanModel+FindSimilarFootage.swift")
        #expect(snapshot.contains("likeness: DuplicateLikeness.Facts(record: r, deferStem: true)"), "no regex on the main actor")
    }

    @Test("the split keeps the same footage: likeness facts go into the plan; the menu item starts Find Similar Footage after a split")
    func splitKeepsIt() throws {
        let door = try SourceTree.appCode(named: "VideoScanModel+DuplicateDigestSplit.swift")
        #expect(door.contains("likeness: DuplicateLikeness.Facts(record: r)"))
        #expect(door.contains("plan.sameFootageFiles"))
        let app = try SourceTree.appCode(named: "App/VideoScanApp.swift")
        #expect(app.contains("fileOpsCenter.splitDuplicateGroupsKeepingSameFootage(model: catalogModel)"))
        #expect(door.contains("if case .split = outcome { startFindSimilarFootage(scope: .catalog, model: model) }"))
    }

    @Test("Verify Catalog has no footage rule — a same-footage link is never a finding")
    func verifyIgnoresFootage() throws {
        for name in ["Integrity/CatalogConstraints.swift", "Integrity/VerifyCatalogTiers.swift", "Integrity/VerifyCatalogJob.swift"] {
            let code = try SourceTree.appCode(named: name)
            #expect(code.range(of: #"\.footage\b|footageGroupID|FootageMembership"#, options: .regularExpression) == nil, "\(name)")
        }
    }
}

// MARK: - SCALE

@Suite("Same footage — SCALE (100k)", .serialized)
struct SameFootageScaleTests {

    /// 25k recordings × four files each (FFV1 MKV, H.264 MOV, DV MOV, HEVC
    /// MP4), each with its own digest; one timecode + length per recording;
    /// no shared names. Budget (Debug, M4 Max): 8 s for the whole grouping
    /// (measured 5.4–5.6 s at load 12–13 on 16 cores, 2026-10-19: the
    /// likeness pairs ≈1.4 s, stars ≈0.3 s, the rest of the grouping ≈1.5 s,
    /// evidence words for 75k links the remainder). A quadratic slip would
    /// be minutes, not seconds.
    @Test(.timeLimit(.minutes(2)))
    func footageAt100k() {
        let codecs = [("ffv1", "mkv"), ("h264", "mov"), ("dvvideo", "mov"), ("hevc", "mp4")]
        var xs: [FootageInput] = []
        xs.reserveCapacity(100_000)
        for q in 0..<25_000 {
            let tc = String(format: "%02d:%02d:%02d:%02d", 1 + q / 3600 % 23, q / 60 % 60, q % 60, 1 + q % 23)
            let seconds = 60 + Double(q % 5000) * 1.5
            for (m, (codec, ext)) in codecs.enumerated() {
                let f = DuplicateLikeness.Facts(filename: "test_rec\(q)_v\(m).\(ext)", fullPath: "/Volumes/S/\(q % 97)/test_rec\(q)_v\(m).\(ext)",
                                                partialMD5: "p\(q)-\(m)", sizeBytes: Int64(1_000 + q * 4 + m), timecode: tc,
                                                durationSeconds: seconds, resolution: "720x480", videoCodec: codec,
                                                audioCodec: "pcm_s16le", isPlayable: "Yes", digest: sfHex(q * 4 + m + 1))
                xs.append(FootageInput(id: f.id, filename: f.filename, fullPath: f.fullPath, durationSeconds: seconds,
                                       sizeBytes: f.sizeBytes, partialMD5: f.partialMD5, fixityDigest: f.digest,
                                       videoCodec: codec, likeness: f))
            }
        }
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        var r: FootageGrouping.Result?
        let measured = clock.measure { r = runFootage(xs) }
        #expect(r?.stats.groups == 25_000, "each recording is one group of four")
        #expect(r?.stats.largestGroup == 4)
        #expect(r?.stats.edgesByReason[.copyCheckLikeness] == 150_000, "every pair of each four is anchored by its timecode")
        expectWithinTimingBudget("footage grouping with copy-check likeness over 100k", measured: measured,
                                 budget: PerformanceLane.debugCeiling(.seconds(8)), loadBefore: load)
    }

    /// The detector over the same shape as records: no copies group is
    /// formed, 75k same-footage pairs are counted. Budget (Debug): 10 s.
    @Test(.timeLimit(.minutes(2)))
    func detectorAt100k() {
        let codecs = [("ffv1", "mkv"), ("h264", "mov"), ("dvvideo", "mov"), ("hevc", "mp4")]
        var rs: [VideoRecord] = []
        rs.reserveCapacity(100_000)
        for q in 0..<25_000 {
            let tc = String(format: "%02d:%02d:%02d:%02d", 1 + q / 3600 % 23, q / 60 % 60, q % 60, 1 + q % 23)
            for (m, (codec, ext)) in codecs.enumerated() {
                let size = Int64(1_000 + q * 4 + m)
                let r = makeDuplicateRecord(filename: "test_rec\(q)_v\(m).\(ext)", streamType: .videoAndAudio, sizeBytes: size,
                                            durationSeconds: 60 + Double(q % 5000) * 1.5, partialMD5: "p\(q)-\(m)",
                                            resolution: "720x480", videoCodec: codec, audioCodec: "pcm_s16le", timecode: tc)
                r.fullPath = "/Volumes/S/\(q % 97)/" + r.filename
                r.contentFixity = ContentFixity(digest: sfHex(q * 4 + m + 1), byteCount: size, stamp: sfStamp, computedAt: sfNow)
                rs.append(r)
            }
        }
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        var summary: DuplicateAnalysisSummary?
        let measured = clock.measure { summary = DuplicateDetector.analyze(records: rs) }
        #expect(summary?.groups == 0)
        #expect(summary?.sameFootageLinks == 75_000)
        expectWithinTimingBudget("duplicate detector over 100k records", measured: measured,
                                 budget: PerformanceLane.debugCeiling(.seconds(10)), loadBefore: load)
    }

    /// 100k grouped facts with likeness (25k old groups of four digests):
    /// every file leaves as the same footage. Budget (Debug): 4 s.
    @Test(.timeLimit(.minutes(1)))
    func planAt100k() {
        var facts: [SFact] = []
        facts.reserveCapacity(100_000)
        for q in 0..<25_000 {
            let g = UUID()
            for m in 0..<4 {
                let f = DuplicateLikeness.Facts(filename: "test_rec\(q)_v\(m).mov", sizeBytes: Int64(1_000 + m),
                                                timecode: "01:02:03:04", durationSeconds: 60, resolution: "720x480",
                                                videoCodec: ["ffv1", "h264", "dvvideo", "hevc"][m], digest: sfHex(q * 4 + m + 1))
                facts.append(sfact(f, group: g, m == 0 ? .keep : .extraCopy))
            }
        }
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        var plan = DuplicateGroupDigestSplit.Plan()
        let measured = clock.measure { plan = DuplicateGroupDigestSplit.plan(facts) }
        #expect(plan.groups.count == 25_000)
        #expect(plan.sameFootageFiles == 100_000)
        expectWithinTimingBudget("split plan with likeness over 100k", measured: measured,
                                 budget: PerformanceLane.debugCeiling(.seconds(4)), loadBefore: load)
    }
}

// MARK: - MEDIA MATRIX

@Suite("Same footage — media matrix (real ffmpeg fixtures)", .serialized)
struct SameFootageMediaMatrixTests {

    struct Case: Sendable {
        let filename: String, videoCodec: String, extraVideoArgs: [String], audioCodec: String, words: String
    }
    /// One synthetic recording in five formats, all 720x576 at 25 fps.
    static let cases = [
        Case(filename: "test_samefoot_clip.mp4", videoCodec: "libx264", extraVideoArgs: ["-preset", "ultrafast", "-pix_fmt", "yuv420p"],
             audioCodec: "aac", words: "H.264 MP4"),
        Case(filename: "test_samefoot_clip.mov", videoCodec: "prores", extraVideoArgs: [], audioCodec: "pcm_s16le", words: "ProRes MOV"),
        Case(filename: "test_samefoot_clip.mkv", videoCodec: "ffv1", extraVideoArgs: [], audioCodec: "pcm_s16le", words: "FFV1 MKV"),
        Case(filename: "test_samefoot_clip.mxf", videoCodec: "mpeg2video", extraVideoArgs: ["-g", "15"], audioCodec: "pcm_s16le",
             words: "MPEG-2 MXF"),
        Case(filename: "test_samefoot_clip.avi", videoCodec: "dvvideo", extraVideoArgs: ["-pix_fmt", "yuv420p"], audioCodec: "pcm_s16le",
             words: "DV AVI"),
    ]

    @Test("five formats of one recording, probed by the scan parser → copy-check links naming each probed format", .timeLimit(.minutes(3)))
    func matrix() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable, "ffmpeg is a required project dependency")
        let dir = try VerifyAudioTestMedia.makeScratchDir("samefoot-matrix")
        defer { try? FileManager.default.removeItem(at: dir) }
        var records: [VideoRecord] = []
        for c in Self.cases {
            let path = try VerifyAudioTestMedia.generate(into: dir, name: c.filename, videoCodec: c.videoCodec,
                                                         extraVideoArgs: c.extraVideoArgs, audioCodec: c.audioCodec,
                                                         size: "720x576", rate: "25")
            let (probe, stderr) = await ScanEngine.runFFProbe(url: URL(fileURLWithPath: path))
            let r = VideoRecord()
            ScanEngine.extractMetadata(probe: try #require(probe, "ffprobe failed for \(c.filename): \(stderr)"), into: r)
            r.filename = c.filename
            r.fullPath = path
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            r.sizeBytes = Int64(data.count)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            r.contentFixity = ContentFixity(digest: digest, byteCount: r.sizeBytes, stamp: sfStamp, computedAt: sfNow)
            #expect(DuplicateLikeness.formatWords(videoCodec: r.videoCodec, audioCodec: r.audioCodec, filename: r.filename) == c.words,
                    "probed codec \(r.videoCodec) for \(c.filename)")
            records.append(r)
        }
        let facts = records.map { DuplicateLikeness.Facts(record: $0) }
        let run = DuplicateLikeness.sameFootageLinks(facts)
        #expect(run.links.count == 10, "every pair of the five formats")
        #expect(run.links.filter(\.inStar).count == 4, "a star of five")
        var stats = FootageGrouping.Stats()
        let inputs = records.map { r in FootageInput(id: r.id, filename: r.filename, fullPath: r.fullPath, durationSeconds: r.durationSeconds,
                                                     sizeBytes: r.sizeBytes, videoCodec: r.videoCodec,
                                                     likeness: DuplicateLikeness.Facts(record: r)) }
        let p = FootageGrouping.prepare(inputs, options: .init(), stats: &stats)
        let edges = FootageGrouping.edges(p, stats: &stats).filter { $0.reason == .copyCheckLikeness }
        #expect(edges.count == 10, "a specific name + length anchors every pair")
        let named = Set(edges.flatMap(\.formats))
        #expect(named == Set(Self.cases.map(\.words)), "\(named)")
        #expect(edges.allSatisfy { $0.detail.split(separator: "+").contains("duration") })
    }
}

// MARK: - TRUTH: end to end on catalog.sqlite

@Suite("Same footage — TRUTH end to end on catalog.sqlite", .serialized)
@MainActor
struct SameFootageTruthTests {

    @Test("a false copies group of three codecs → split → Find Similar Footage → reload: no copies group, one footage group of three with reasons; Verify green; re-runs change nothing")
    func endToEnd() async throws {
        let scene = try CutoverScene.make("samefoot_truth", healthyRows: 5)
        defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let g = UUID()
        let members = try (0..<3).map { try scene.bulk($0) }
        let codecs = ["ffv1", "h264", "dvvideo"]
        for (i, r) in members.enumerated() {
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.durationSeconds = Trio.seconds
            r.timecode = Trio.timecode
            r.resolution = "720x480"
            r.videoCodec = codecs[i]
            r.isPlayable = "Yes"
            r.duplicateGroupID = g
            r.duplicateConfidence = .high
            r.duplicateDisposition = i == 0 ? .keep : .extraCopy
            r.duplicateReasons = "timecode+duration+resolution"
            r.duplicateGroupCount = 3
            r.dupAnalyzedAt = sfNow
        }
        #expect(model.saveCatalogNow())
        #expect(Set(members.compactMap { VideoScanModel.storedFullDigest($0) }).count == 3, "three different digests")

        guard case .split(1, 0, 3, true, _) = model.splitDuplicateGroupsByFullDigest() else {
            Issue.record("expected one group split, three leaving"); return
        }
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("3 file(s) are the same footage in a different file — kept as same footage"), "the OUTCOME says so")
        #expect(log.contains("left the copies — same footage as"))

        let job = FindSimilarFootageJob(scope: .catalog, model: model)
        job.start()
        await job.task?.value
        #expect(model.saveCatalogNow())

        let reloaded = try await scene.sqliteLoad()
        let back = reloaded.records.filter { r in members.contains { $0.id == r.id } }
        #expect(back.count == 3)
        #expect(back.allSatisfy { $0.duplicateGroupID == nil }, "no copies group")
        let footageIDs = Set(back.compactMap { $0.footage?.groupID })
        #expect(footageIDs.count == 1 && back.allSatisfy { $0.footage != nil }, "one footage group of three, persisted")
        #expect(back.allSatisfy { r in (r.footage?.evidence ?? []).contains { $0.contains("(the duplicate check matched timecode+duration") } })

        let report = try #require(await sfVerify(scene).report)
        #expect(report.findings.filter { $0.rule == "duplicateGroupDigestsAgree" }.isEmpty)
        #expect(!report.findings.contains { $0.needsDecision && $0.words.lowercased().contains("footage") })

        #expect(model.splitDuplicateGroupsByFullDigest() == .nothingToSplit)
        let again = FindSimilarFootageJob(scope: .catalog, model: model)
        again.start()
        await again.task?.value
        #expect(again.summary?.recordsChanged == 0 && again.summary?.recordsCleared == 0, "a second run writes nothing")
    }
}

// MARK: - OPT-IN evidence against a COPY of a real catalog

/// The evidence run's arithmetic, in small pure pieces (each well under the
/// CCN-15 ratchet). Groups are `[record]` keyed by their old group id.
private enum SFEvidence {
    typealias Groups = [UUID: [VideoRecord]]

    static func format(_ r: VideoRecord) -> String {
        DuplicateLikeness.formatWords(videoCodec: r.videoCodec, audioCodec: r.audioCodec, filename: r.filename)
    }

    static func groups(_ rows: [VideoRecord]) -> Groups {
        var out: Groups = [:]
        for r in rows { if let g = r.duplicateGroupID { out[g, default: []].append(r) } }
        return out.filter { $0.value.count > 1 }
    }

    static func digests(_ members: [VideoRecord]) -> Int {
        Set(members.compactMap { VideoScanModel.storedFullDigest($0) }).count
    }

    /// (has a cross-digest pair with one sampled hash + size, …and that
    /// pair's lengths disagree — the collision class).
    static func sampledHashPairs(_ members: [VideoRecord]) -> (pair: Bool, differentLength: Bool) {
        var pair = false, differentLength = false
        for (i, a) in members.enumerated() {
            for b in members[(i + 1)...] where sampledTwins(a, b) {
                pair = true
                if abs(a.durationSeconds - b.durationSeconds) > DuplicateLikeness.durationToleranceLoose { differentLength = true }
            }
        }
        return (pair, differentLength)
    }

    static func sampledTwins(_ a: VideoRecord, _ b: VideoRecord) -> Bool {
        guard let da = VideoScanModel.storedFullDigest(a), let db = VideoScanModel.storedFullDigest(b), da != db else { return false }
        return !a.partialMD5.isEmpty && a.partialMD5 == b.partialMD5 && a.sizeBytes == b.sizeBytes
    }

    /// Size × 1.5 or lengths more than 2 s apart.
    static func veryDifferent(_ members: [VideoRecord]) -> Bool {
        let sizes = members.map(\.sizeBytes), lengths = members.map(\.durationSeconds)
        let ratio = Double(sizes.max() ?? 0) / Double(max(1, sizes.min() ?? 1))
        return ratio > 1.5 || (lengths.max() ?? 0) - (lengths.min() ?? 0) > 2
    }

    /// How many parts the members fall into, joined by "same duplicate
    /// group" or "same footage group" in `byID` (1 = still connected).
    static func components(_ ids: [UUID], byID: [UUID: VideoRecord]) -> Int {
        var parent = Array(ids.indices)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        var firstByKey: [String: Int] = [:]
        for (i, id) in ids.enumerated() {
            let r = byID[id]
            let keys = [r?.duplicateGroupID.map { "c:" + $0.uuidString }, r?.footage.map { "f:" + $0.groupID.uuidString }]
            for key in keys.compactMap({ $0 }) {
                if let j = firstByKey[key] { parent[find(i)] = find(j) } else { firstByKey[key] = i }
            }
        }
        return Set(ids.indices.map(find)).count
    }

    static func line(_ r: VideoRecord) -> String {
        "\(r.filename) [\(format(r)), \(Int(r.durationSeconds)) s, \(r.sizeBytes) B]"
    }

    /// The old groups the split works on.
    struct Before {
        var multiDigest: Groups
        var crossCodec: Set<UUID>
        var counts: [String: Any]
    }
}

/// Runs ONLY when `~/Library/Logs/VideoScan/same-footage-evidence/request.json`
/// exists: `{"database": "<a .backup COPY of catalog.sqlite>", "output":
/// "<result .json>"}`. Everything happens in a sandbox COPY of that copy.
/// Reports before/after counts, the cross-codec groups, the held groups, the
/// collision question and what became of every multi-digest group.
@Suite("Same footage — real-catalog COPY evidence (opt-in)", .serialized)
@MainActor
struct SameFootageRealCopyEvidence {

    struct Request: Decodable { var database: String; var output: String }

    @Test(.timeLimit(.minutes(15)))
    func evidence() async throws {
        let requestURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VideoScan/same-footage-evidence/request.json")
        guard let data = try? Data(contentsOf: requestURL) else { return }   // opt-in
        let request = try JSONDecoder().decode(Request.self, from: data)
        let scene = try CutoverScene.make("samefoot_evidence"); defer { scene.cleanup() }
        try load(request, into: scene)
        let model = scene.model
        let start = before(model)
        var result = start.counts
        let split = model.splitDuplicateGroupsByFullDigest()
        let job = FindSimilarFootageJob(scope: .catalog, model: model)
        job.start()
        await job.task?.value
        _ = model.saveCatalogNow()
        result["split"] = String(describing: split)
        result["jobSummary"] = job.summary?.line ?? ""
        let reloaded = try await scene.sqliteLoad().records.filter { $0.removal == nil }
        after(model, start, reloaded: reloaded, into: &result)
        let out = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: URL(fileURLWithPath: request.output))
    }

    /// The sandbox gets ONLY the copy; the model launches on it.
    private func load(_ request: Request, into scene: CutoverScene) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: scene.folder.path) { try fm.removeItem(at: scene.folder.appendingPathComponent(name)) }
        try fm.copyItem(at: URL(fileURLWithPath: request.database), to: scene.databaseURL)
        try scene.writeLatch()
        scene.model.records = scene.model.loadCatalogAtLaunch()
        scene.model.masterArchive = scene.model.catalogStore.masterArchive
        #expect(scene.model.catalogCutover.isSQLiteAuthority)
    }

    /// Counts before the split, and the plan the split will run.
    private func before(_ model: VideoScanModel) -> SFEvidence.Before {
        let live = model.records.filter { $0.removal == nil }
        let old = SFEvidence.groups(live)
        let multi = old.filter { SFEvidence.digests($0.value) > 1 }
        let cross = Set(multi.filter { Set($0.value.map(SFEvidence.format)).count > 1 }.keys)
        let plan = DuplicateGroupDigestSplit.plan(model.duplicateDigestSplitFacts(),
                                                  footageGroupOf: model.duplicateDigestSplitFootageGroups())
        let held = Set(plan.heldGroups.map(\.oldGroupID))
        let pairs = multi.values.map(SFEvidence.sampledHashPairs)
        let very = Set(multi.filter { SFEvidence.veryDifferent($0.value) }.keys)
        let counts: [String: Any] = [
            "liveRows": live.count, "dupGroupsBefore": old.count, "multiDigestGroupsBefore": multi.count,
            "crossCodecGroupsBefore": cross.count, "footageMembersBefore": live.filter { $0.footage != nil }.count,
            "planGroups": plan.groups.count, "planSplitGroups": plan.splitGroups.count, "planHeldGroups": held.count,
            "planLeaving": plan.recordsLeaving, "planNewGroups": plan.newGroupCount,
            "planSameFootageFiles": plan.sameFootageFiles, "planDifferentLengthFiles": plan.differentLengthFiles,
            "heldWeak": plan.heldGroups.filter { $0.heldWhy.contains("only weakly") }.count,
            "heldNoLikeness": plan.heldGroups.filter { $0.heldWhy.contains("no likeness") }.count,
            "heldCrossCodec": held.intersection(cross).count, "heldSamples": plan.heldGroups.prefix(12).map(\.words),
            "groupsWithSampledHashPairDifferentDigest": pairs.filter(\.pair).count,
            "groupsWithSampledHashPairDifferentLength_collisions": pairs.filter(\.differentLength).count,
            "groupsVeryDifferentSizeOrLength": very.count, "groupsVeryDifferentHeld": very.intersection(held).count,
        ]
        return SFEvidence.Before(multiDigest: multi, crossCodec: cross, counts: counts)
    }

    /// Counts after the split and the Find Similar Footage run, read back
    /// from catalog.sqlite; and what became of every old multi-digest group.
    private func after(_ model: VideoScanModel, _ start: SFEvidence.Before, reloaded: [VideoRecord],
                       into result: inout [String: Any]) {
        var stats = FootageGrouping.Stats()
        let p = FootageGrouping.prepare(model.footageInputs(), options: .init(), stats: &stats)
        _ = FootageGrouping.edges(p, stats: &stats)
        let byID = Dictionary(reloaded.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let now = SFEvidence.groups(reloaded)
        var fully = 0, partly = 0, notLinked = 0, crossFully = 0
        var lost: [[String: String]] = []
        for (g, members) in start.multiDigest {
            let parts = SFEvidence.components(members.map(\.id), byID: byID)
            if parts == 1 { fully += 1 } else if parts < members.count { partly += 1 } else { notLinked += 1 }
            if parts == 1, start.crossCodec.contains(g) { crossFully += 1 }
            if parts > 1, lost.count < 25 {
                lost.append(["files": members.map(SFEvidence.line).joined(separator: " · "),
                             "reasons": members.map(\.duplicateReasons).joined(separator: " | ")])
            }
        }
        result["dupGroupsAfter"] = now.count
        result["impureGroupsAfter"] = now.values.filter { SFEvidence.digests($0) > 1 }.count
        result["footageMembersAfter"] = reloaded.filter { $0.footage != nil }.count
        result["footageGroupsAfter"] = Set(reloaded.compactMap { $0.footage?.groupID }).count
        result["copyCheckLinks"] = stats.edgesByReason[.copyCheckLikeness] ?? 0
        result["copyCheckLinksWeak"] = stats.edgesByReason[.copyCheckLikenessWeak] ?? 0
        result["copyCheckDifferentLength"] = stats.copyCheckDifferentLength
        result["multiDigestFullyLinked"] = fully
        result["multiDigestPartlyLinked"] = partly
        result["multiDigestNotLinked"] = notLinked
        result["crossCodecFullyLinked"] = crossFully
        result["crossCodecSamples"] = crossCodecSamples(start, byID: byID)
        result["notFullyLinkedSamples"] = lost
    }

    private func crossCodecSamples(_ start: SFEvidence.Before, byID: [UUID: VideoRecord]) -> [[String: String]] {
        start.multiDigest.filter { start.crossCodec.contains($0.key) }.prefix(15).map { _, members in
            let back = members.compactMap { byID[$0.id] }
            return ["files": back.map(SFEvidence.line).joined(separator: " · "),
                    "footage": back.compactMap { $0.footage.map { "\($0.confidence.label) \($0.role.label)" } }.joined(separator: ", "),
                    "stillAGroup": back.contains { $0.duplicateGroupID != nil } ? "yes (held, or copies)" : "no"]
        }
    }
}
