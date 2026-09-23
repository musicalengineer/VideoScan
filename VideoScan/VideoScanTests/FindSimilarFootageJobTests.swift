// FindSimilarFootageJobTests.swift
// Find Similar Footage, Phase 1 — everything around the pure core:
//   • the additive catalog fields (legacy decode, byte-identical re-encode)
//   • the MFO job end to end on an ISOLATED model (sandboxed catalog store,
//     sandboxed ledger — never App Support): write, incremental re-run,
//     scope, read-only refusal, stale (poisoned) answers cleared
//   • the person's decisions: stored on both records, Media Ledger lines,
//     obeyed by every later run
//   • the catalog "One per footage" filter
//   • the Archive Angel integration (one recommendation per footage group,
//     switchable by policy)
//   • the FCP mediaIdentifier capture on a synthetic `test_*` ffmpeg fixture
//     (scan parser, tag-only refresh probe, probe-cache column)
//   • menu-title conventions

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
private enum FJ {
    static func model(_ label: String) throws -> (VideoScanModel, MasterArchiveTestSupport.Sandbox) {
        let sb = try MasterArchiveTestSupport.makeSandbox("footage_\(label)")
        let m = MasterArchiveTestSupport.makeModel(sb)
        m.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        return (m, sb)
    }

    static func rec(_ name: String, dir: String = "/Volumes/T/a", dur: Double, hash: String = "",
                    codec: String = "h264", encoder: String? = nil) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = dir + "/" + name
        r.directory = dir
        r.durationSeconds = dur
        r.frameRate = "29.97"
        r.sizeBytes = 1000
        r.contentHash = hash
        r.videoCodec = codec
        r.originEncoder = encoder
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return r
    }

    static func run(_ m: VideoScanModel, _ scope: FootageScope = .catalog) async -> FindSimilarFootageJob {
        let job = FindSimilarFootageJob(scope: scope, model: m)
        job.start()
        await job.task?.value
        return job
    }
}

// MARK: - Additive fields

@Suite("Find Similar Footage — additive catalog fields")
@MainActor
struct FootageFieldCodableTests {

    @Test("a legacy record (no keys) decodes nil / [] and re-encodes WITHOUT the new keys")
    func legacyRoundTrip() throws {
        let legacy = #"{"id":"11111111-2222-3333-4444-555555555555","filename":"a.mov","fullPath":"/V/a.mov"}"#
        let r = try JSONDecoder().decode(VideoRecord.self, from: Data(legacy.utf8))
        #expect(r.footage == nil && r.footageDecisions.isEmpty && r.proAppsMediaIdentifier == nil)
        let out = String(decoding: try JSONEncoder().encode(VideoRecordDTO(r)), as: UTF8.self)
        #expect(!out.contains("footage") && !out.contains("proAppsMediaIdentifier"), "\(out)")
    }

    @Test("membership, decisions and the media identifier round-trip; the clone carries them")
    func fullRoundTrip() throws {
        let r = VideoRecord()
        r.filename = "a.mov"
        r.proAppsMediaIdentifier = "E2D2E261"
        r.footage = FootageMembership(groupID: UUID(), groupSize: 3, confidence: .likely, role: .transcode, rank: 2,
                                      likelyOriginalID: UUID(), originalInCatalog: false,
                                      evidence: ["same bytes as b.mov"], scannedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                      algorithmVersion: FootageGrouping.algorithmVersion)
        r.footageDecisions = [FootageDecision(otherID: UUID(), verdict: .notSame, decidedAt: Date(timeIntervalSince1970: 1_800_000_001))]
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(VideoRecord.self, from: enc.encode(VideoRecordDTO(r)))
        #expect(back.footage == r.footage)
        #expect(back.footageDecisions == r.footageDecisions)
        #expect(back.proAppsMediaIdentifier == "E2D2E261")
        let c = r.snapshotClone()
        #expect(c.footage == r.footage && c.footageDecisions == r.footageDecisions
                && c.proAppsMediaIdentifier == r.proAppsMediaIdentifier)
    }
}

// MARK: - The job, isolated

@Suite("Find Similar Footage — MFO job on an isolated model", .serialized)
@MainActor
struct FindSimilarFootageJobModelTests {

    @Test("whole-catalog run records groups; an unchanged re-run writes nothing (incremental)",
          .timeLimit(.minutes(1)))
    func runAndRerun() async throws {
        let (m, sb) = try FJ.model("run")
        defer { sb.cleanup() }
        let a = FJ.rec("Thanksgiving1992.mov", dur: 600, hash: "v1:x", codec: "dvvideo")
        let b = FJ.rec("Thanksgiving1992.mov", dir: "/Volumes/U/b", dur: 600, hash: "v1:x", codec: "dvvideo")
        let c = FJ.rec("Thanksgiving1992.mp4", dur: 600.03, encoder: "HandBrake 1.9.2")
        let lone = FJ.rec("Lake.mov", dur: 600)
        m.records = [a, b, c, lone]
        let job = await FJ.run(m)
        #expect(job.state == .finished(summary: job.summary?.line ?? ""), "\(job.state)")
        #expect(a.footage?.groupID != nil && a.footage?.groupID == c.footage?.groupID)
        #expect(lone.footage == nil)
        #expect(job.summary?.groups == 1 && job.summary?.members == 3)
        #expect(job.summary?.recordsChanged == 3)
        #expect(c.footage?.role == .reEncode)

        let again = await FJ.run(m)
        #expect(again.summary?.recordsChanged == 0 && again.summary?.recordsCleared == 0,
                "an unchanged catalog re-run writes nothing")
    }

    @Test("POISONED state: a stale answer on a file no longer in any group is cleared by a catalog run")
    func staleAnswersCleared() async throws {
        let (m, sb) = try FJ.model("stale")
        defer { sb.cleanup() }
        let x = FJ.rec("Lonely.mov", dur: 42)
        x.footage = FootageMembership(groupID: UUID(), groupSize: 9, confidence: .identical, role: .copy, rank: 3,
                                      likelyOriginalID: UUID(), originalInCatalog: true, evidence: ["junk"],
                                      scannedAt: .distantPast, algorithmVersion: 99)
        m.records = [x]
        let job = await FJ.run(m)
        #expect(x.footage == nil)
        #expect(job.summary?.recordsCleared == 1)
    }

    @Test("a scoped run writes only groups touching the scope")
    func scoped() async throws {
        let (m, sb) = try FJ.model("scope")
        defer { sb.cleanup() }
        let a1 = FJ.rec("Wedding1988.mov", dur: 100, hash: "v1:a"), a2 = FJ.rec("Wedding1988 copy.mov", dur: 100, hash: "v1:a")
        let b1 = FJ.rec("Picnic1990.mov", dur: 200, hash: "v1:b"), b2 = FJ.rec("Picnic1990-2.mov", dur: 7, hash: "v1:b")
        m.records = [a1, a2, b1, b2]
        _ = await FJ.run(m, .records([a1.id]))
        #expect(a1.footage != nil && a2.footage != nil, "the in-scope group is written, both members")
        #expect(b1.footage == nil && b2.footage == nil, "out-of-scope groups are untouched")
        _ = await FJ.run(m, .volume(prefix: "/Volumes/T", label: "T"))
        #expect(b1.footage != nil)
    }

    @Test("read-only catalog → refused, nothing written")
    func readOnly() async throws {
        let (m, sb) = try FJ.model("ro")
        defer { sb.cleanup() }
        let a = FJ.rec("A1.mov", dur: 10, hash: "v1:q"), b = FJ.rec("B1.mov", dur: 10, hash: "v1:q")
        m.records = [a, b]
        m.isReadOnly = true
        let job = await FJ.run(m)
        #expect(job.wasRefused)
        #expect(a.footage == nil)
    }

    @Test("Stop before the apply leaves the catalog untouched and ends Stopped")
    func stop() async throws {
        let (m, sb) = try FJ.model("stop")
        defer { sb.cleanup() }
        let a = FJ.rec("A2.mov", dur: 10, hash: "v1:s"), b = FJ.rec("B2.mov", dur: 10, hash: "v1:s")
        m.records = [a, b]
        let job = FindSimilarFootageJob(scope: .catalog, model: m)
        job.pause()          // parks at the first checkpoint
        job.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(job.isPaused)
        job.cancel()
        await job.task?.value
        #expect(job.state == .cancelled)
        #expect(a.footage == nil)
    }

    @Test("the person's answers: stored on both, in the Media Ledger, obeyed by every later run")
    func decisions() async throws {
        let (m, sb) = try FJ.model("decide")
        defer { sb.cleanup() }
        let a = FJ.rec("Birthday1979.mov", dur: 300, hash: "v1:d"), b = FJ.rec("Other name.mov", dur: 300, hash: "v1:d")
        m.records = [a, b]
        _ = await FJ.run(m)
        #expect(a.footage?.groupID == b.footage?.groupID)

        let flush = m.setFootageDecision(.notSame, between: a.id, and: b.id)
        await flush?.value
        #expect(a.footageDecision(about: b.id)?.verdict == .notSame)
        #expect(b.footageDecision(about: a.id)?.verdict == .notSame)
        _ = await FJ.run(m)
        #expect(a.footage == nil && b.footage == nil, "identical bytes, but the person said no")
        #expect(a.footageDecisions.count == 1, "a run never rewrites a decision")

        let ledgerDir = sb.root.appendingPathComponent("ledger", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: ledgerDir, includingPropertiesForKeys: nil)) ?? []
        let text = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(text.components(separatedBy: "\"footageDecided\"").count - 1 == 2, "one ledger line per record")
        #expect(text.contains("\"answer\":\"notSame\""))

        await m.setFootageDecision(nil, between: a.id, and: b.id)?.value
        #expect(a.footageDecisions.isEmpty && b.footageDecisions.isEmpty)
        _ = await FJ.run(m)
        #expect(a.footage?.groupID == b.footage?.groupID, "answer taken back → the machine groups them again")
    }
}

// MARK: - Rescan (QA MAJOR 1)

@Suite("Find Similar Footage — the person's answers survive a real rescan cycle", .serialized)
@MainActor
struct FootageRescanSurvivalTests {

    @Test("decisions follow BOTH records to their fresh ids; the machine answer is carried")
    func rescanCycle() async throws {
        let model = VideoScanModel()
        let a = FJ.rec("Birthday1979.mov", dir: "/Volumes/T", dur: 300, hash: "v1:r")
        let b = FJ.rec("Other1979.mov", dir: "/Volumes/T", dur: 300, hash: "v1:r")
        model.records = [a, b]
        a.setFootageDecision(FootageDecision(otherID: b.id, verdict: .notSame))
        b.setFootageDecision(FootageDecision(otherID: a.id, verdict: .notSame))
        a.footage = FootageMembership(groupID: a.id, groupSize: 2, confidence: .likely, role: .original, rank: 0,
                                      likelyOriginalID: a.id, originalInCatalog: true, evidence: [],
                                      scannedAt: Date(), algorithmVersion: 1)
        let target = CatalogScanTarget(searchPath: "/Volumes/T")
        model.snapshotPreservedFieldsForRescan(of: target)
        let fresh: [VideoRecord] = [a.fullPath, b.fullPath].map { path in
            let r = VideoRecord()
            r.fullPath = path
            r.filename = (path as NSString).lastPathComponent
            r.directory = "/Volumes/T"
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            return r
        }
        model.applyPreservedFieldsAfterRescan(of: target, onto: fresh)
        _ = await model.commitScanResults(root: "/Volumes/T", volName: "T", targetRecords: fresh, scanWasComplete: true)
        let na = fresh[0], nb = fresh[1]
        #expect(na.id != a.id, "the scan minted fresh ids")
        #expect(na.footageDecision(about: nb.id)?.verdict == .notSame, "a's answer now names b's NEW id")
        #expect(nb.footageDecision(about: na.id)?.verdict == .notSame, "and b's names a's")
        #expect(na.footage?.likelyOriginalID == na.id, "the machine answer's pointer is re-linked too")
    }
}

// MARK: - QA 2026-09-23 fixes (red first)

@Suite("Find Similar Footage — QA fixes (MAJOR 2/3 + minors)")
@MainActor
struct FootageQAFixTests {

    @Test("MAJOR 2: a footage key never splits a duplicate group — one recommendation")
    func footageKeyDoesNotSplitDuplicateGroup() {
        let dup = UUID()
        let a = ArchiveAngelCandidate(filename: "Tape.mov", starRating: 3, userDate: "1990", videoCodec: "dvvideo",
                                      duplicateGroupID: dup, footageGroupID: UUID(), footageRank: 0,
                                      footageConfidence: .likely)
        let b = ArchiveAngelCandidate(filename: "Tape copy.mov", starRating: 3, userDate: "1990", videoCodec: "dvvideo",
                                      duplicateGroupID: dup)
        var rules = AngelRecommendationPolicy.builtIn.recommend
        rules.useAngelFloors = false
        let r = ArchiveAngelRecommendations.classify([a, b], rules: rules)
        #expect(r.verdicts.filter { $0.kind == .anotherCopy }.count == 1)
    }

    @Test("MAJOR 2: the batch filter also merges footage + duplicate keys; the person's Keep wins")
    func batchMergesKeys() {
        let dup = UUID(), g = UUID()
        var keep = ArchiveAngelCandidate(filename: "Keep.mov", duplicateGroupID: dup)
        keep.duplicateDisposition = .keep
        let orig = ArchiveAngelCandidate(filename: "Orig.mov", duplicateGroupID: dup, footageGroupID: g,
                                         footageRank: 0, footageConfidence: .likely)
        let exp = ArchiveAngelCandidate(filename: "Export.mp4", footageGroupID: g, footageRank: 1, footageConfidence: .likely)
        let picks = [exp, orig, keep].map { ArchiveAngelPick(candidate: $0, score: 1, evidence: []) }
        var rejected: [ArchiveAngelRejection: Int] = [:]
        let kept = ArchiveAngelScorer.onePerDuplicateGroup(picks, rejected: &rejected,
                                                           collapseBy: ["footageGroup", "duplicateGroup"])
        #expect(kept.map(\.candidate.filename) == ["Keep.mov"])
    }

    @Test("minor: a Possible footage group is shown, not collapsed")
    func possibleNotCollapsed() {
        let g = UUID()
        let a = ArchiveAngelCandidate(filename: "A.mov", starRating: 3, userDate: "1990", videoCodec: "dvvideo",
                                      footageGroupID: g, footageRank: 0, footageConfidence: .possible)
        let b = ArchiveAngelCandidate(filename: "B.mov", starRating: 3, userDate: "1990", videoCodec: "dvvideo",
                                      footageGroupID: g, footageRank: 1, footageConfidence: .possible)
        var rules = AngelRecommendationPolicy.builtIn.recommend
        rules.useAngelFloors = false
        #expect(!ArchiveAngelRecommendations.classify([a, b], rules: rules).verdicts.contains { $0.kind == .anotherCopy })
    }

    @Test("MAJOR 3: a sampled signature is refused on a whole-file SHA-256 conflict")
    func sampledSignatureRefusedOnFixityConflict() {
        let a = FootageInput(filename: "Tape.mov", durationSeconds: 600, sizeBytes: 1000, partialMD5: "abc", fixityDigest: "sha-A")
        let b = FootageInput(filename: "Other.mov", durationSeconds: 900, sizeBytes: 1000, partialMD5: "abc", fixityDigest: "sha-B")
        #expect(FootageGrouping.run([a, b]).memberships.isEmpty)
        #expect(!a.sameBytes(as: b))
    }

    @Test("MAJOR 3: a segmented content hash is not Identical when the whole-file digests differ")
    func contentHashRefusedOnFixityConflict() {
        let a = FootageInput(filename: "A.mxf", durationSeconds: 60, sizeBytes: 9, contentHash: "v1:h", fixityDigest: "sha-A")
        let b = FootageInput(filename: "B.mxf", durationSeconds: 70, sizeBytes: 9, contentHash: "v1:h", fixityDigest: "sha-B")
        #expect(FootageGrouping.run([a, b]).memberships.isEmpty)
        #expect(!a.sameBytes(as: b))
    }

    @Test("minor: different date prefixes block a name + length link; unknown (xx) parts don't")
    func datePrefixesBlock() {
        let a = FootageInput(filename: "1990-12-25 Christmas.mov", durationSeconds: 600)
        let b = FootageInput(filename: "1994-12-25 Christmas.mov", durationSeconds: 600)
        #expect(FootageGrouping.run([a, b]).memberships.isEmpty)
        let c = FootageInput(filename: "1990-xx-xx_Christmas.mov", durationSeconds: 600)
        let r = FootageGrouping.run([a, c])
        #expect(r.memberships[a.id] != nil && r.memberships[a.id]?.groupID == r.memberships[c.id]?.groupID)
    }

    @Test("minor: Stop between apply slices never leaves a group half-written")
    func applyByGroup() async throws {
        let (m, sb) = try FJ.model("slices")
        defer { sb.cleanup() }
        var recs: [VideoRecord] = []
        for i in 0..<6 {  // three groups of two
            recs.append(FJ.rec("G\(i / 2)a.mov", dur: 10, hash: "v1:g\(i / 2)"))
        }
        m.records = recs
        let result = FootageGrouping.run(m.footageInputs())
        var calls = 0
        let out = await m.applyFootage(result, touched: Set(recs.map(\.id)), sliceSize: 1,
                                       checkpoint: { calls += 1; return calls <= 1 })
        #expect(out.stopped)
        for i in stride(from: 0, to: 6, by: 2) {
            #expect((recs[i].footage == nil) == (recs[i + 1].footage == nil), "group \(i / 2) half-written")
        }
        #expect(out.changed > 0)
    }

    @Test("minor: the chip says 'Same footage ×N', never 'copies'")
    func chipWording() {
        let f = FootageMembership(groupID: UUID(), groupSize: 3, confidence: .likely, role: .avHalf, rank: 2,
                                  likelyOriginalID: UUID(), originalInCatalog: true, evidence: [],
                                  scannedAt: Date(), algorithmVersion: 1)
        #expect(FootageGroupBadge.text(f) == "Same footage ×3")
        #expect(!FootageGroupBadge.help(f).lowercased().contains("copies"))
    }
}

// MARK: - One per footage

@Suite("Find Similar Footage — catalog 'One per footage' filter")
@MainActor
struct FootageOnePerGroupTests {

    private func member(_ name: String, group: UUID, rank: Int) -> VideoRecord {
        let r = FJ.rec(name, dur: 1)
        r.footage = FootageMembership(groupID: group, groupSize: 3, confidence: .likely, role: rank == 0 ? .original : .copy,
                                      rank: rank, likelyOriginalID: UUID(), originalInCatalog: true, evidence: [],
                                      scannedAt: Date(), algorithmVersion: 1)
        return r
    }

    @Test("keeps the best-ranked VISIBLE member per group plus every ungrouped row, in order")
    func filter() {
        let g = UUID()
        let copy2 = member("c2.mov", group: g, rank: 2), copy1 = member("c1.mov", group: g, rank: 1)
        let loner = FJ.rec("solo.mov", dur: 1)
        // The rank-0 original is offline (not among the visible rows).
        let out = FootageOnePerGroup.filter([copy2, loner, copy1])
        #expect(out.map(\.filename) == ["solo.mov", "c1.mov"])
    }

    @Test("SCALE: 100k rows in well under a second", .timeLimit(.minutes(1)))
    func scale() {
        var rows: [VideoRecord] = []
        rows.reserveCapacity(100_000)
        for i in 0..<100_000 {
            if i % 3 == 0 { rows.append(FJ.rec("x\(i).mov", dur: 1)) } else {
                rows.append(member("m\(i).mov", group: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i / 3))!, rank: i % 3))
            }
        }
        let t0 = Date()
        let out = FootageOnePerGroup.filter(rows)
        #expect(Date().timeIntervalSince(t0) < 1.0)
        #expect(out.count < rows.count)
    }
}

// MARK: - Archive Angel

@Suite("Find Similar Footage — Archive Angel: one recommendation per footage group")
@MainActor
struct FootageArchiveAngelTests {

    private func candidate(_ name: String, group: UUID?, rank: Int?, score: Int) -> ArchiveAngelCandidate {
        ArchiveAngelCandidate(filename: name, starRating: 3, userDate: "1990", videoCodec: "dvvideo",
                              footageGroupID: group, footageRank: rank, footageConfidence: group == nil ? nil : .likely)
    }

    @Test("the likely original is recommended; the others become Another copy with a footage reason")
    func collapse() {
        let g = UUID()
        let original = candidate("Christmas1990.mov", group: g, rank: 0, score: 10)
        let export = candidate("Christmas1990.mp4", group: g, rank: 1, score: 99)
        let other = candidate("Picnic.mov", group: nil, rank: nil, score: 50)
        var rules = AngelRecommendationPolicy.builtIn.recommend
        rules.useAngelFloors = false
        let r = ArchiveAngelRecommendations.classify([export, original, other], rules: rules)
        #expect(r.verdicts[1].kind != .anotherCopy, "the likely original stays")
        #expect(r.verdicts[0].kind == .anotherCopy)
        #expect(r.verdicts[0].reasons.first?.contains("Same footage as Christmas1990.mov") == true)
        #expect(r.verdicts[2].kind != .anotherCopy)
    }

    @Test("switchable: a policy without footageGroup does not collapse by it")
    func switchedOff() {
        let g = UUID()
        let a = candidate("A.mov", group: g, rank: 0, score: 1), b = candidate("B.mov", group: g, rank: 1, score: 1)
        var rules = AngelRecommendationPolicy.builtIn.recommend
        rules.useAngelFloors = false
        rules.copies = AngelCopyRules(collapseBy: ["duplicateGroup", "nameAndDuration"], prefer: ["userKeeper", "best"])
        let r = ArchiveAngelRecommendations.classify([a, b], rules: rules)
        #expect(!r.verdicts.contains { $0.kind == .anotherCopy })
    }

    @Test("the defaults collapse by footage group first and prefer the footage original; unknown kinds are refused")
    func defaults() {
        let c = AngelRecommendationPolicy.builtIn.recommend.copies
        #expect(c.collapseBy.first == "footageGroup")
        #expect(c.prefer == ["userKeeper", "footageOriginal", "best"])
        #expect(c.batchCollapseBy == ["footageGroup", "duplicateGroup"])
        #expect(AngelCopyRules(collapseBy: ["footageGroupz"]).problems.count == 1)
    }

    @Test("the batch takes one member per footage group — its likely original")
    func batch() {
        let g = UUID()
        let picks = [
            ArchiveAngelPick(candidate: candidate("Export.mp4", group: g, rank: 1, score: 90), score: 90, evidence: []),
            ArchiveAngelPick(candidate: candidate("Camera.mov", group: g, rank: 0, score: 10), score: 10, evidence: []),
        ]
        var rejected: [ArchiveAngelRejection: Int] = [:]
        let kept = ArchiveAngelScorer.onePerDuplicateGroup(picks, rejected: &rejected,
                                                           collapseBy: ["footageGroup", "duplicateGroup"])
        #expect(kept.map(\.candidate.filename) == ["Camera.mov"])
        #expect(rejected[.duplicateOfPick] == 1)
    }
}

// MARK: - FCP media identifier capture (synthetic ffmpeg fixture)

@Suite("Find Similar Footage — FCP mediaIdentifier capture (test_* fixture)", .serialized)
@MainActor
struct FootageMediaIdentifierFixtureTests {

    @Test("scan parser, tag-only refresh probe and the probe-cache column all carry com.apple.proapps.mediaIdentifier",
          .timeLimit(.minutes(2)))
    func capture() async throws {
        try #require(CleanupTestMedia.toolsAvailable, "ffmpeg/ffprobe are required project dependencies")
        let dir = try CleanupTestMedia.makeScratchDir("footage_mid")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tagged = EmbeddedFixtureCase(
            label: "mov/prores FCP media identifier", filename: "test_footage_mid.mov", videoCodec: "prores_ks",
            extraArgs: ["-movflags", "use_metadata_tags",
                        "-metadata", "com.apple.proapps.mediaIdentifier=E2D2E261-TEST-4F00-9A00-000000000001"],
            expectDate: nil, expectSource: nil, expectMake: nil, expectModel: nil, expectEncoderFamily: nil)
        let plain = EmbeddedFixtureCase(
            label: "mp4/h264 no identifier", filename: "test_footage_nomid.mp4", videoCodec: "libx264",
            extraArgs: [], expectDate: nil, expectSource: nil, expectMake: nil, expectModel: nil, expectEncoderFamily: nil)
        let path = try EmbeddedFixtures.generate(tagged, into: dir)
        let plainPath = try EmbeddedFixtures.generate(plain, into: dir)

        let (probe, stderr) = await ScanEngine.runFFProbe(url: URL(fileURLWithPath: path))
        let r = ScanEngine.extractMetadata(probe: try #require(probe, "ffprobe failed: \(stderr)"))
        #expect(r.proAppsMediaIdentifier == "E2D2E261-TEST-4F00-9A00-000000000001")
        let (probe2, _) = await ScanEngine.runFFProbe(url: URL(fileURLWithPath: plainPath))
        #expect(ScanEngine.extractMetadata(probe: try #require(probe2)).proAppsMediaIdentifier == nil)

        let set = try #require(await VideoScanModel.probeEmbeddedTagSet(path: path))
        #expect(set.mediaIdentifier == "E2D2E261-TEST-4F00-9A00-000000000001")

        // Probe cache: stored with the outcome, returned on a hit, and the
        // refresh's write-through lands on an existing row.
        let cache = MetadataCache(path: dir.appendingPathComponent("test_footage_cache.sqlite").path)
        var o = ProbeOutcome()
        o.fullPath = plainPath; o.filename = "test_footage_nomid.mp4"; o.probe = r
        let mod = Date(timeIntervalSince1970: 1_800_000_000)
        cache.store(outcome: o, fileSize: 10, modDate: mod)
        #expect(cache.lookup(path: plainPath, fileSize: 10, modDate: mod)?.probe.proAppsMediaIdentifier
                == "E2D2E261-TEST-4F00-9A00-000000000001")
        cache.updateMediaIdentifier(path: plainPath, identifier: "OTHER")
        #expect(cache.lookup(path: plainPath, fileSize: 10, modDate: mod)?.probe.proAppsMediaIdentifier == "OTHER")
    }

    @Test("Refresh Embedded Dates asks for the identifier only on .fcpbundle files lacking it")
    func candidates() {
        let inBundle = FJ.rec("x.mov", dir: "/Volumes/L/Lib.fcpbundle/E/Transcoded Media/High Quality Media", dur: 1)
        let outside = FJ.rec("y.mov", dur: 1)
        let known = FJ.rec("z.mov", dir: "/Volumes/L/Lib.fcpbundle/E/Original Media", dur: 1)
        known.proAppsMediaIdentifier = "K"
        #expect(VideoScanModel.needsMediaIdentifier(inBundle))
        #expect(!VideoScanModel.needsMediaIdentifier(outside))
        #expect(!VideoScanModel.needsMediaIdentifier(known))
    }

    @Test("tag extraction is case-insensitive and ignores blanks")
    func extraction() {
        #expect(EmbeddedOriginTags.proAppsMediaIdentifier(formatTags: ["COM.APPLE.PROAPPS.MEDIAIDENTIFIER": " A1 "],
                                                          streamTags: []) == "A1")
        #expect(EmbeddedOriginTags.proAppsMediaIdentifier(formatTags: ["com.apple.proapps.mediaIdentifier": "  "],
                                                          streamTags: [["com.apple.proapps.mediaIdentifier": "S1"]]) == "S1")
        #expect(EmbeddedOriginTags.proAppsMediaIdentifier(formatTags: [:], streamTags: []) == nil)
    }
}

// MARK: - Menu conventions

@Suite("Find Similar Footage — menu titles")
struct FootageMenuTitleTests {
    @Test("toolbar verbs start a job at once: no ellipsis (Rick's convention)")
    func titles() {
        #expect(CatalogDuplicatesMenu.findSimilarFootageTitle == "Find Similar Footage")
        #expect(!CatalogDuplicatesMenu.findSimilarFootageOfSelectedTitle.hasSuffix("…"))
        #expect(MediaFileOperationKind.findSimilarFootage.badgeText == "Footage")
        #expect(!MediaFileOperationKind.findSimilarFootage.hasDetailView)
    }
}
