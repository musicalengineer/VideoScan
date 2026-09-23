// FootageGroupingTests.swift
// Find Similar Footage, Phase 1 — the pure core (FootageStem,
// FootageGrouping, FootageOriginality). Five-dimension checklist:
//   LOGIC     one table per evidence rule, originality, component rules
//   SCALE     100k synthetic records inside a time budget
//   MEDIA     n/a — the walk opens no media (the mediaIdentifier capture
//             has its own ffmpeg fixture, FootageMediaIdentifierFixtureTests)
//   ISOLATION pure values only: no catalog, no App Support, no disk
//   SENSOR    the three known real-catalog cases as metadata replicas, and
//             "duration alone never groups" at production scale
// No real catalog is ever read here.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Helpers

private enum F {
    static func run(_ xs: [FootageInput], cap: Int = FootageGrouping.defaultCap,
                    includeHidden: Bool = false) -> FootageGrouping.Result {
        FootageGrouping.run(xs, options: .init(cap: cap, includeHidden: includeHidden),
                            now: Date(timeIntervalSince1970: 1_800_000_000))
    }
    static func grouped(_ r: FootageGrouping.Result, _ a: FootageInput, _ b: FootageInput) -> Bool {
        guard let x = r.memberships[a.id], let y = r.memberships[b.id] else { return false }
        return x.groupID == y.groupID
    }
    static func v(_ name: String, _ dur: Double, path: String? = nil, hash: String = "", pmd5: String = "",
                  size: Int64 = 1_000_000, fps: String = "29.97", codec: String = "h264",
                  encoder: String? = nil, model: String? = nil, make: String? = nil,
                  derivedFrom: UUID? = nil, kind: String? = nil, embedded: Date? = nil,
                  stream: String = StreamType.videoAndAudio.rawValue, hidden: Bool = false,
                  mediaID: String? = nil) -> FootageInput {
        FootageInput(filename: name, fullPath: path ?? "/Volumes/T/\(UUID().uuidString.prefix(6))/\(name)",
                     durationSeconds: dur, frameRate: fps, sizeBytes: size, contentHash: hash, partialMD5: pmd5,
                     derivedFrom: derivedFrom, derivationKind: kind, streamTypeRaw: stream,
                     mediaIdentifier: mediaID, originMake: make, originModel: model, originEncoder: encoder,
                     videoCodec: codec, embeddedCreationDate: embedded, isHidden: hidden)
    }
}

// MARK: - Name normalizer

@Suite("Find Similar Footage — name normalizer (FootageStem)")
struct FootageStemTests {

    static let keyCases: [(String, String)] = [
            ("1990-xx-xx_Christmas1990-Part3-47mins.mov", "christmas1990part347mins"),
            ("1990-xx-xx_1990-xx-xx_Christmas1990-Part3-47mins_balanced.mov", "christmas1990part347mins"),
            ("Christmas1990-Part3-47mins.vs.archive.mov", "christmas1990part347mins"),
            ("Christmas1990-Part3-47mins.vs.preserve.mkv", "christmas1990part347mins"),
            ("Clip 08_converted.vs.edit.mov", "clip08"),
            ("Rick's Guitars 2024 copy 2.mov", "ricksguitars2024"),
            ("RicksGuitars2024.mp4", "ricksguitars2024"),
            ("Birthday-vs-edit_02.mov", "birthday"),
            ("Beach cleaned.mov", "beach"),
    ]

    @Test("keys: date prefixes, version tokens, copy N, case and punctuation are stripped", arguments: Self.keyCases)
    func keys(name: String, key: String) {
        #expect(FootageStem.analyze(name).key == key, "\(name)")
    }

    @Test("a trailing _02 is NOT stripped by the normalizer; it is offered as a same-folder collision")
    func collisionIsFolderScoped() {
        let a = FootageStem.analyze("Birthday_02.mov")
        #expect(a.key == "birthday02")
        #expect(a.collisionBaseFilename == "birthday.mov")
        #expect(FootageStem.analyze("Birthday_01.mov").collisionBaseFilename == nil, "_01 is never a collision")
    }

    @Test("a trailing counter offers a base key only when the rest is specific")
    func counterBase() {
        #expect(FootageStem.analyze("DickyTheBoysDadBreen-1985-3.mp4").counterBaseKey == "dickytheboysdadbreen1985")
        #expect(FootageStem.analyze("DickyTheBoysDadBreen-1985.mp4").counterBaseKey == nil, "-1985 is a year, not a counter")
        #expect(FootageStem.analyze("Clip 3.mov").counterBaseKey == nil, "'clip' is too short to be specific")
    }

    @Test("name roles from version tokens")
    func nameRoles() {
        #expect(FootageStem.analyze("x.vs.archive.mov").nameRole == .reEncode)
        #expect(FootageStem.analyze("x_balanced.mov").nameRole == .restored)
        #expect(FootageStem.analyze("x_trimmed.mov").nameRole == .trim)
        #expect(FootageStem.analyze("x_proxy.mov").nameRole == .transcode)
        #expect(FootageStem.analyze("x.mov").nameRole == nil)
    }

    static let toleranceCases: [(String, Double)] = [
        ("29.97", 2.0 / 29.97), ("59.94", 2.0 / 59.94), ("24", 2.0 / 24.0), ("30000/1001", 2.0 / 29.97),
        ("90000", 0.1), ("600", 0.1), ("1.999", 0.1), ("", 0.1),
    ]

    @Test("±2 frames at the record's own rate; untrusted rates fall back to 0.1 s", arguments: Self.toleranceCases)
    func tolerance(rate: String, want: Double) {
        #expect(abs(FootageStem.durationTolerance(frameRate: rate) - want) < 0.0005, "\(rate)")
    }
}

// MARK: - Evidence rules (one row per rule)

@Suite("Find Similar Footage — evidence rules")
struct FootageEvidenceRuleTests {

    @Test("same segmented content hash (sampled windows) → Likely, 'not yet verified', never 'same bytes' (codex #1674)")
    func sampledContentHashIsLikely() {
        let a = F.v("A.mov", 100, hash: "v1:aa"), b = F.v("Totally Different.mov", 50, hash: "v1:aa")
        let r = F.run([a, b])
        #expect(F.grouped(r, a, b))
        #expect(r.memberships[a.id]?.confidence == .likely)
        #expect(r.memberships[a.id]?.evidence.contains { $0.contains("not yet verified") } == true)
        #expect(r.memberships.values.flatMap(\.evidence).allSatisfy { !$0.contains("same bytes") })
    }

    @Test("same whole-file digest, CURRENT on both → Identical; recorded but not current → Likely")
    func currentDigestIsIdentical() {
        var a = F.v("A.mov", 100), b = F.v("Totally Different.mov", 50)
        a.fixityDigest = "sha-1"; b.fixityDigest = "sha-1"
        a.fixityFresh = true; b.fixityFresh = true
        let r = F.run([a, b])
        #expect(F.grouped(r, a, b))
        #expect(r.memberships[a.id]?.confidence == .identical)
        #expect(a.sameBytes(as: b))
        b.fixityFresh = false
        let r2 = F.run([a, b])
        #expect(F.grouped(r2, a, b))
        #expect(r2.memberships[a.id]?.confidence == .likely, "one side changed or offline since it was hashed")
        #expect(!a.sameBytes(as: b))
        #expect(r2.memberships.values.flatMap(\.evidence).allSatisfy { !$0.contains("same bytes") })
    }

    @Test("same sampled signature + size NOMINATES (Likely), never Identical")
    func sampledIsLikely() {
        let a = F.v("A.mp4", 100, hash: "v1:aa", pmd5: "m1", size: 42)
        let b = F.v("B.mp4", 7, pmd5: "m1", size: 42)            // no full hash yet
        let r = F.run([a, b])
        #expect(F.grouped(r, a, b))
        #expect(r.memberships[b.id]?.confidence == .likely)
        #expect(r.memberships[b.id]?.evidence.contains { $0.contains("not yet verified") } == true)
    }

    @Test("sampled signature REFUSED when both full hashes are known and differ")
    func sampledConflict() {
        let a = F.v("A.mxf", 100, hash: "v1:aa", pmd5: "m1", size: 42)
        let b = F.v("B.mxf", 200, hash: "v1:bb", pmd5: "m1", size: 42)
        let r = F.run([a, b])
        #expect(!F.grouped(r, a, b))
        #expect(r.stats.sampledConflicts == 1)
    }

    @Test("recorded lineage (derivedFrom) → Likely, role from derivationKind")
    func lineage() {
        let src = F.v("Tape.mov", 3000, codec: "dvvideo")
        let bal = F.v("Tape_balanced.mov", 3000, codec: "dvvideo", encoder: "Lavf63.1.101",
                      derivedFrom: src.id, kind: "balanceAudio")
        let trim = F.v("Tape piece.mov", 60, derivedFrom: src.id, kind: "trim")
        let r = F.run([src, bal, trim])
        #expect(F.grouped(r, src, bal) && F.grouped(r, src, trim))
        #expect(r.memberships[src.id]?.role == .original)
        #expect(r.memberships[bal.id]?.role == .restored)
        #expect(r.memberships[trim.id]?.role == .trim)
    }

    @Test("same name + length within ±2 frames → Likely; 3 frames apart → nothing")
    func nameAndDuration() {
        let a = F.v("RicksGuitars2024.mov", 951.7508, codec: "prores", encoder: "Apple ProRes 422")
        let b = F.v("RicksGuitars2024.mp4", 951.7508 + 1 / 29.97)
        let c = F.v("RicksGuitars2024.m4v", 951.7508 + 3.2 / 29.97)
        let r = F.run([a, b, c])
        #expect(F.grouped(r, a, b))
        #expect(r.memberships[a.id]?.confidence == .likely)
        #expect(r.memberships[c.id] == nil, "3 frames apart is not the same length")
    }

    @Test("a camera-counter name + length is only Possible")
    func genericIsPossible() {
        let a = F.v("MVI_1234.MOV", 12.0), b = F.v("MVI_1234.mp4", 12.0)
        let r = F.run([a, b])
        #expect(F.grouped(r, a, b))
        #expect(r.memberships[a.id]?.confidence == .possible)
    }

    @Test("same name but a trailing counter + same length → Possible (the Dicky case)")
    func counterIsPossible() {
        let a = F.v("DickyTheBoysDadBreen-1985.mp4", 71.188, fps: "90000")
        let b = F.v("DickyTheBoysDadBreen-1985-3.mp4", 71.188)
        let r = F.run([a, b])
        #expect(F.grouped(r, a, b))
        #expect(r.memberships[a.id]?.confidence == .possible)
    }

    @Test("promote collision _02 beside the base in the SAME folder + same length → Likely; other folder → no")
    func promoteCollision() {
        let a = F.v("Birthday.mov", 300, path: "/Volumes/A/1990/Birthday.mov")
        let b = F.v("Birthday_02.mov", 300, path: "/Volumes/A/1990/Birthday_02.mov")
        let c = F.v("Birthday_02.mov", 300, path: "/Volumes/A/1991/Birthday_02.mov")
        let r = F.run([a, b, c])
        #expect(F.grouped(r, a, b))
        #expect(r.memberships[b.id]?.evidence.contains { $0.contains("second copy") } == true)
        #expect(!(r.memberships[c.id]?.evidence.contains { $0.contains("second copy") } ?? false))
    }

    @Test("FCP Transcoded Media ↔ Original Media, same event, same stem → Likely")
    func fcpStructure() {
        let o = F.v("MA5A3201.MOV", 20, path: "/Volumes/L/Lib.fcpbundle/12-27-23/Original Media/MA5A3201.MOV",
                    model: "Canon EOS R6m2")
        let t = F.v("MA5A3201.mov", 45, path: "/Volumes/L/Lib.fcpbundle/12-27-23/Transcoded Media/High Quality Media/MA5A3201.mov",
                    codec: "prores", encoder: "Apple ProRes 422")
        let other = F.v("MA5A3201.mov", 45, path: "/Volumes/L/Lib.fcpbundle/OtherEvent/Transcoded Media/High Quality Media/MA5A3201.mov",
                        codec: "prores")
        let r = F.run([o, t, other])
        #expect(F.grouped(r, o, t))
        #expect(r.memberships[t.id]?.role == .transcode)
        #expect(r.memberships[o.id]?.role == .original)
        #expect(!(r.memberships[other.id]?.evidence.contains { $0.contains("Final Cut transcode") } ?? false),
                "a different event never links by structure")
    }

    @Test("same FCP media identifier → Likely")
    func mediaIdentifier() {
        let a = F.v("X.mov", 10, mediaID: "E2D2E261"), b = F.v("Y.mov", 99, mediaID: "E2D2E261")
        #expect(F.grouped(F.run([a, b]), a, b))
    }

    @Test("A/V pair: High → Likely, Medium / Low → nothing; combined output joins the pair")
    func avPairs() {
        let pid = UUID()
        var v = F.v("V.mxf", 30, stream: StreamType.videoOnly.rawValue)
        var a = F.v("A.mxf", 30, stream: StreamType.audioOnly.rawValue)
        v.pairGroupID = pid; a.pairGroupID = pid; v.pairConfidence = .high; a.pairConfidence = .high
        var combined = F.v("V_combined.mov", 30)
        combined.combinedFromPairID = pid
        let r = F.run([v, a, combined])
        #expect(F.grouped(r, v, a) && F.grouped(r, v, combined))
        #expect(r.memberships[a.id]?.role == .avHalf)
        v.pairConfidence = .medium
        #expect(F.run([v, a]).memberships[a.id] == nil, "a Medium correlation is a guess, not evidence")
        v.pairConfidence = .low
        #expect(F.run([v, a]).memberships[a.id] == nil, "a Low correlation is a guess, not evidence")
    }

    @Test("hidden (purged / set aside / superseded) records are not grouped unless asked")
    func hidden() {
        let a = F.v("A.mov", 10, hash: "v1:x"), b = F.v("B.mov", 10, hash: "v1:x", hidden: true)
        #expect(!F.grouped(F.run([a, b]), a, b))
        #expect(F.grouped(F.run([a, b], includeHidden: true), a, b))
    }
}

// MARK: - Component rules

@Suite("Find Similar Footage — component rules (cap, one-hop Possible, the person's word)")
struct FootageComponentRuleTests {

    @Test("group confidence is the weakest link on the strongest path")
    func weakestLink() {
        // (A key under 6 characters — "movie" — would be generic → Possible.)
        let a = F.v("Thanksgiving.mov", 100, hash: "v1:a")
        let b = F.v("Thanksgiving copy.mov", 100, hash: "v1:a")
        let c = F.v("Thanksgiving.mp4", 100 + 1 / 29.97)
        let r = F.run([a, b, c])
        #expect(F.grouped(r, a, c))
        #expect(r.memberships[a.id]?.confidence == .likely)
        var a2 = a, b2 = b
        a2.fixityDigest = "sha-t"; b2.fixityDigest = "sha-t"
        a2.fixityFresh = true; b2.fixityFresh = true
        let r2 = F.run([a2, b2])
        #expect(r2.memberships[a.id]?.confidence == .identical)
    }

    @Test("Possible never chains: a leaf attached by a Possible link never hosts another")
    func possibleNeverChains() {
        let xs = ["a.mov", "b.mov", "c.mov", "d.mov"].map { F.v($0, 10) }
        var stats = FootageGrouping.Stats()
        let p = FootageGrouping.prepare(xs, options: .init(), stats: &stats)
        // a–b attaches b as a leaf of a; b–c would chain through the leaf.
        let edges = [FootageGrouping.Edge(a: 0, b: 1, reason: .counterNameAndDuration),
                     FootageGrouping.Edge(a: 1, b: 2, reason: .counterNameAndDuration),
                     FootageGrouping.Edge(a: 3, b: 0, reason: .counterNameAndDuration)]
        let c = FootageGrouping.components(p, edges: edges, options: .init(), stats: &stats)
        #expect(c.root[0] == c.root[1], "the first Possible link is taken")
        #expect(c.root[2] != c.root[0], "b is a leaf: c may not chain through it")
        #expect(c.root[3] == c.root[0], "a is a hub: a second leaf (star, depth one) is fine")
        #expect(stats.refusedPossibleChain == 1)
    }

    @Test("a Possible edge never merges two multi-member groups")
    func possibleNeverMergesGroups() {
        let a1 = F.v("MVI_0002.MOV", 12.0, hash: "v1:g1"), a2 = F.v("Other1.MOV", 12.0, hash: "v1:g1")
        let b1 = F.v("MVI_0002.mp4", 12.0, hash: "v1:g2"), b2 = F.v("Other2.mp4", 12.0, hash: "v1:g2")
        let r = F.run([a1, a2, b1, b2])
        #expect(F.grouped(r, a1, a2) && F.grouped(r, b1, b2))
        #expect(!F.grouped(r, a1, b1))
    }

    @Test("the cap refuses a non-Identical merge past it; Identical is exempt")
    func cap() {
        var xs: [FootageInput] = []
        for i in 0..<10 { xs.append(F.v("Same Name.mov", 100, hash: "v1:\(i)", pmd5: "p\(i)", size: Int64(i + 1))) }
        let r = F.run(xs, cap: 4)
        #expect(r.stats.largestGroup <= 4)
        #expect(r.stats.refusedByCap > 0)
        let ident = (0..<10).map { _ in
            var x = F.v("X.mov", 5, hash: "v1:same")
            x.fixityDigest = "sha-same"; x.fixityFresh = true
            return x
        }
        #expect(F.run(ident, cap: 4).stats.largestGroup == 10)
        // Sampled-only copies are a nomination (Likely): the cap applies.
        let sampled = (0..<10).map { _ in F.v("X.mov", 5, hash: "v1:same") }
        #expect(F.run(sampled, cap: 4).stats.largestGroup <= 4)
    }

    @Test("'Not the same' splits even byte-identical files; 'Same footage' joins what no rule would")
    func personWins() {
        var a = F.v("A.mov", 10, hash: "v1:x"), b = F.v("B.mov", 10, hash: "v1:x")
        a.decisions = [FootageDecision(otherID: b.id, verdict: .notSame)]
        let r = F.run([a, b])
        #expect(!F.grouped(r, a, b))
        #expect(r.stats.refusedByPerson == 1)

        var c = F.v("Lake.mov", 10), d = F.v("Picnic.mov", 900)
        d.decisions = [FootageDecision(otherID: c.id, verdict: .same)]
        c.decisions = []
        let r2 = F.run([c, d])
        #expect(F.grouped(r2, c, d))
        #expect(r2.memberships[c.id]?.confidence == .confirmed)
    }

    @Test("a cannot-link also blocks the transitive path through a third file")
    func cannotLinkTransitive() {
        var a = F.v("Movie.mov", 100, hash: "v1:a")
        let b = F.v("Movie.mp4", 100)                  // name+length to both
        let c = F.v("Movie.m4v", 100, hash: "v1:c")
        a.decisions = [FootageDecision(otherID: c.id, verdict: .notSame)]
        let r = F.run([a, b, c])
        #expect(!F.grouped(r, a, c))
    }

    @Test("group id = smallest member id; stable when a larger id joins")
    func groupIDStable() {
        let lo = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let hi = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
        let a = FootageInput(id: lo, filename: "A.mov", durationSeconds: 5, contentHash: "v1:z")
        let b = FootageInput(id: hi, filename: "B.mov", durationSeconds: 5, contentHash: "v1:z")
        let r = F.run([b, a])
        #expect(r.memberships[a.id]?.groupID == lo && r.memberships[b.id]?.groupID == lo)
    }
}

// MARK: - Originality

@Suite("Find Similar Footage — originality scorer")
struct FootageOriginalityTests {

    @Test("camera tags beat a transcode; the export beats the FCP transcode when no camera file exists")
    func ranking() {
        let cam = F.v("MVI_0042.MOV", 60, codec: "h264", model: "Canon EOS R6m2", embedded: Date())
        let t = F.v("MVI_0042.mov", 60, path: "/Volumes/L/Lib.fcpbundle/E/Transcoded Media/High Quality Media/MVI_0042.mov",
                    codec: "prores", encoder: "Apple ProRes 422")
        let r = F.run([t, cam])
        #expect(r.memberships[cam.id]?.rank == 0)
        #expect(r.memberships[cam.id]?.originalInCatalog == true)
    }

    @Test("'original not in catalog' is claimed only for an export-looking best member")
    func exportClaim() {
        let mp4 = F.v("X.mp4", 10, codec: "h264")
        #expect(FootageOriginality.looksLikeExport(mp4, verdict: FootageOriginality.assess(mp4, analysis: FootageStem.analyze("X.mp4"))))
        let wav = F.v("GuitarLead-2", 10, codec: "")
        #expect(!FootageOriginality.looksLikeExport(wav, verdict: FootageOriginality.assess(wav, analysis: FootageStem.analyze("GuitarLead-2"))),
                "untagged byte copies make no claim")
        let cam = F.v("MVI_0001.mp4", 10, codec: "h264", model: "Canon")
        #expect(!FootageOriginality.looksLikeExport(cam, verdict: FootageOriginality.assess(cam, analysis: FootageStem.analyze("MVI_0001.mp4"))))
    }

    @Test("QuickTime's 'Apple' make alone is not camera evidence; a device model is")
    func appleMakeAlone() {
        let x = F.v("A.mov", 10, make: "Apple")
        let v = FootageOriginality.assess(x, analysis: FootageStem.analyze(x.filename))
        #expect(!v.cameraEvidence)
        let y = F.v("A.mov", 10, model: "iPhone 12", make: "Apple")
        #expect(FootageOriginality.assess(y, analysis: FootageStem.analyze(y.filename)).cameraEvidence)
    }

    static let encoderCases: [(String, Bool)] = [
        ("Lavf63.1.101", true), ("HandBrake 1.9.2 2025022300", true), ("Apple ProRes 422", true),
        ("H.264", true), ("CoreMediaAuthoring 700, …", true), ("vlc 3.0.20", true),
        ("Avid DV25 4:1:1 NTSC 601", false), ("DV/DVCPRO - NTSC", false), ("ScreenFlow", false),
    ]

    @Test("transcoder encoders", arguments: Self.encoderCases)
    func transcoders(encoder: String, want: Bool) {
        #expect(FootageOriginality.isTranscoderEncoder(encoder) == want, "\(encoder)")
    }

    static let cameraNameCases: [(String, Bool)] = [
        ("MVI_1234", true), ("IMG_0001", true), ("GX010123", true), ("MA5A3201", true), ("00012", true),
        ("20190704_123456", true), ("P1000123", true), ("Christmas1990", false), ("Clip 08", false),
    ]

    @Test("camera filenames", arguments: Self.cameraNameCases)
    func cameraNames(stem: String, want: Bool) {
        #expect(FootageOriginality.isCameraFilename(stem) == want, "\(stem)")
    }
}

// MARK: - Sensors: the three real cases (metadata replicas, 2026-09-23 catalog)

@Suite("Find Similar Footage — SENSOR: the known cases from Rick's catalog")
struct FootageKnownCaseSensorTests {

    /// (a) The guitar case. Values copied from the live catalog 2026-09-23.
    static func guitar() -> (lacie: FootageInput, projects: FootageInput, cheese: FootageInput, x9: FootageInput) {
        let lacie = FootageInput(
            filename: "RickGuitarGravity_etc_2024.mov",
            fullPath: "/Volumes/LaCieWorkspace/Movies/RickGuitarVideos.fcpbundle/GuitarJams/Transcoded Media/High Quality Media/RickGuitarGravity_etc_2024.mov",
            durationSeconds: 951.7508, frameRate: "29.97", sizeBytes: 16_760_485_162,
            contentHash: "v1:d4f1d9de", partialMD5: "e33f6c22",
            originEncoder: "Apple ProRes 422", videoCodec: "prores",
            embeddedCreationDate: Date(timeIntervalSince1970: 1_773_259_839))
        var projects = lacie
        projects.id = UUID()
        projects.filename = "RicksGuitars2024.mov"
        projects.fullPath = "/Volumes/Projects/MiscMovies/RickGuitarVideos.fcpbundle/GuitarJams/Transcoded Media/High Quality Media/RicksGuitars2024.mov"
        let cheese = FootageInput(
            filename: "RicksGuitars2024.mp4",
            fullPath: "/Volumes/LaCieWorkspace/CheesegraterArchive/highsierra_rickb/rickb/Desktop/RicksGuitars2024.mp4",
            durationSeconds: 951.784167, frameRate: "29.97", sizeBytes: 2_307_340_481,
            contentHash: "v1:dc32aca4", partialMD5: "37b07d1f", videoCodec: "h264",
            embeddedCreationDate: Date(timeIntervalSince1970: 1_738_539_018))
        var x9 = cheese
        x9.id = UUID()
        x9.fullPath = "/Volumes/CrucialX9/Matt/2025/RicksGuitars2024.mp4"
        x9.contentHash = ""   // not hashed yet in the live catalog
        return (lacie, projects, cheese, x9)
    }

    @Test("(a) guitar: 4 files, one group, likely original = the .mp4 export, original NOT in catalog")
    func guitarCase() {
        let g = Self.guitar()
        let r = F.run([g.lacie, g.projects, g.cheese, g.x9])
        let ids = [g.lacie, g.projects, g.cheese, g.x9].map(\.id)
        let groupIDs = Set(ids.compactMap { r.memberships[$0]?.groupID })
        #expect(groupIDs.count == 1 && ids.allSatisfy { r.memberships[$0] != nil }, "one group of four")
        let original = r.memberships[g.lacie.id]?.likelyOriginalID
        #expect(original == g.cheese.id || original == g.x9.id, "the .mp4 export is the likely original")
        #expect(r.memberships[g.lacie.id]?.originalInCatalog == false, "camera clips were never cataloged")
        #expect(r.memberships[g.lacie.id]?.role == .transcode)
        #expect(r.memberships[g.projects.id]?.role == .transcode)
        #expect(r.memberships[g.x9.id]?.role == .copy || r.memberships[g.cheese.id]?.role == .copy)
        #expect(r.memberships[g.lacie.id]?.confidence == .likely)
    }

    @Test("(b) Dicky: the 46 GB broken file and the 39 MB -3 file are one group")
    func dickyCase() {
        let big = FootageInput(filename: "DickyTheBoysDadBreen-1985.mp4",
                               fullPath: "/Volumes/LaCieWorkspace/from-Seagate/DickyTheBoysDadBreen-1985.mp4",
                               durationSeconds: 71.188, frameRate: "90000", sizeBytes: 45_976_101_977,
                               contentHash: "v1:781b93f9",
                               originEncoder: "HandBrake 1.9.2 2025022300", videoCodec: "h264")
        let small = FootageInput(filename: "DickyTheBoysDadBreen-1985-3.mp4",
                                 fullPath: "/Volumes/Projects/MoviesExpansion/DickyTheBoysDadBreen-1985-3.mp4",
                                 durationSeconds: 71.188, frameRate: "29.97", sizeBytes: 39_043_440,
                                 contentHash: "v1:3e427667",
                                 originEncoder: "HandBrake 1.9.2 2025022300", videoCodec: "h264")
        var archived = small
        archived.id = UUID()
        archived.filename = "1984-xx-xx_DickyTheBoysDadBreen-1985-3.mp4"
        archived.fullPath = "/Volumes/FamilyArchive/Breen_Family_Archive/30_Video/1980-1989/1984/1984-xx-xx_DickyTheBoysDadBreen-1985-3.mp4"
        archived.derivedFrom = small.id
        archived.derivationKind = "archivePromotion"
        let r = F.run([big, small, archived])
        #expect(F.grouped(r, big, small) && F.grouped(r, small, archived))
        #expect(r.memberships[big.id]?.confidence == FootageConfidence.possible)
    }

    @Test("(c) Christmas 1990 Part 3: original, copies, _balanced and the Angel's .vs.* outputs are one group; the original ranks first")
    func christmasCase() {
        let src = UUID()  // the source record the lineage points at (not in catalog any more)
        func m(_ name: String, _ path: String, _ dur: Double, _ hash: String, _ codec: String, _ enc: String,
               kind: String? = nil, from: UUID? = nil) -> FootageInput {
            FootageInput(filename: name, fullPath: path, durationSeconds: dur, frameRate: "29.97", sizeBytes: 10,
                         contentHash: hash, derivedFrom: from, derivationKind: kind, originMake: "Apple",
                         originEncoder: enc, videoCodec: codec,
                         embeddedCreationDate: Date(timeIntervalSince1970: 1_222_634_638))
        }
        let base = "/Volumes/FamilyArchive/Breen_Family_Archive/30_Video/1990-1999"
        let orig1 = m("Christmas1990-Part3-47mins.mov", "/Volumes/LaCieWorkspace/CheesegraterArchive/InternalRaid/Family Movies/Christmas_1990_Quicktimes/Christmas1990-Part3-47mins.mov",
                      2828.994995, "v1:c614", "dvvideo", "Avid DV25 4:1:1 NTSC 601")
        let orig2 = m("Christmas1990-Part3-47mins.mov", "/Volumes/SanDiskWorkspace/FromCheesegrater/Family Movies/Christmas_1990_Quicktimes/Christmas1990-Part3-47mins.mov",
                      2828.994995, "v1:c614", "dvvideo", "Avid DV25 4:1:1 NTSC 601")
        let promoted = m("1990-xx-xx_Christmas1990-Part3-47mins.mov", "\(base)/1990/1990-xx-xx_Christmas1990-Part3-47mins.mov",
                         2828.994995, "v1:c614", "dvvideo", "Avid DV25 4:1:1 NTSC 601", kind: "archivePromotion", from: src)
        let balanced = m("Christmas1990-Part3-47mins_balanced.mov", "/Volumes/SanDiskWorkspace/FromCheesegrater/Family Movies/Christmas_1990_Quicktimes/Christmas1990-Part3-47mins_balanced.mov",
                         2828.995662, "v1:3063", "dvvideo", "Lavf63.1.101", kind: "balanceAudio", from: src)
        let balancedArch = m("1990-xx-xx_Christmas1990-Part3-47mins_balanced.mov", "\(base)/1990/1990-xx-xx_Christmas1990-Part3-47mins_balanced.mov",
                             2828.995662, "v1:3063", "dvvideo", "Lavf63.1.101", kind: "archivePromotion", from: UUID())
        let preserve = m("Christmas1990-Part3-47mins.vs.preserve.mkv", "\(base)/1994/Christmas1990-Part3-47mins.vs.preserve.mkv",
                         2828.995, "v1:7db7", "ffv1", "Lavf63.1.101", from: src)
        let access = m("Christmas1990-Part3-47mins.vs.archive.mov", "\(base)/1994/Christmas1990-Part3-47mins.vs.archive.mov",
                       2828.995662, "v1:8aa3", "hevc", "Lavf63.1.101", from: src)
        let all = [orig1, orig2, promoted, balanced, balancedArch, preserve, access]
        let r = F.run(all)
        let groups = Set(all.compactMap { r.memberships[$0.id]?.groupID })
        #expect(groups.count == 1 && all.allSatisfy { r.memberships[$0.id] != nil }, "one group of seven")
        let top = r.memberships[orig1.id]?.likelyOriginalID
        #expect(top == orig1.id || top == orig2.id, "a non-archive copy of the DV original ranks first")
        #expect(r.memberships[orig1.id]?.originalInCatalog == true)
        #expect(r.memberships[balanced.id]?.role == .restored)
        #expect(r.memberships[balancedArch.id]?.role == .restored, "byte copies share the specific role")
        #expect(r.memberships[access.id]?.role == .reEncode)
        #expect(r.memberships[preserve.id]?.role == .reEncode)
        #expect(r.memberships[promoted.id]?.role == .copy)
    }
}

// MARK: - Sensor: duration alone never groups (production scale)

@Suite("Find Similar Footage — SENSOR: duration alone never groups")
struct FootageDurationAloneSensorTests {

    @Test("20k records sharing ONE length, all different names and bytes → zero groups", .timeLimit(.minutes(1)))
    func sameLengthDifferentNames() {
        let xs = (0..<20_000).map { i in
            FootageInput(filename: "Event \(i) at the lake house.mov", durationSeconds: 120.0,
                         sizeBytes: Int64(i + 1), contentHash: "v1:\(i)", partialMD5: "m\(i)")
        }
        let r = F.run(xs)
        #expect(r.stats.groups == 0, "duration alone grouped \(r.stats.members) records")
    }

    @Test("100k random-length records with unique names → zero groups, zero Likely edges")
    func randomLengths() {
        var rng = FootageTestRNG(seed: 7)
        let xs = (0..<100_000).map { i in
            FootageInput(filename: "Recording \(i).mov",
                         durationSeconds: Double(rng.next() % 7_200_000) / 1000,
                         sizeBytes: Int64(i + 1))
        }
        let r = F.run(xs)
        #expect(r.stats.groups == 0)
        #expect((r.stats.edgesByReason[.nameAndDuration] ?? 0) == 0)
    }
}

// MARK: - Scale

@Suite("Find Similar Footage — SCALE: 100k synthetic records")
struct FootageScaleTests {

    /// 100k records shaped like the catalog: ~20% byte copies, ~10% name+length
    /// versions, ~5% lineage, the rest unique. Budget: < 3 s in Debug on the
    /// M4 Max (the spec's ~2 s target is for the grouping phases; the budget
    /// leaves headroom for a loaded machine), and it must not go quadratic.
    @Test("group 100k records inside the budget", .timeLimit(.minutes(1)))
    func hundredThousand() {
        var rng = FootageTestRNG(seed: 42)
        var xs: [FootageInput] = []
        xs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let family = i / 5
            let dur = 30 + Double(family % 5000) + Double(family % 7) * 0.001
            switch i % 20 {
            case 0...3:   // byte copies of the family's master
                xs.append(FootageInput(filename: "Family\(family)_master.mov", durationSeconds: dur,
                                       sizeBytes: Int64(family + 1), contentHash: "v1:f\(family)"))
            case 4, 5:    // re-encodes by name + length
                xs.append(FootageInput(filename: "Family\(family)_master.mp4", durationSeconds: dur + 0.01,
                                       sizeBytes: Int64(rng.next() % 1_000_000 + 1)))
            case 6:       // lineage to the previous record
                xs.append(FootageInput(filename: "Family\(family)_balanced.mov", durationSeconds: dur,
                                       derivedFrom: xs[i - 1].id, derivationKind: "balanceAudio"))
            default:      // unique recordings
                xs.append(FootageInput(filename: "Clip\(i)_\(rng.next() % 1000).mov",
                                       durationSeconds: Double(rng.next() % 3_600_000) / 1000,
                                       sizeBytes: Int64(i + 1)))
            }
        }
        let t0 = Date()
        var stats = FootageGrouping.Stats()
        let p = FootageGrouping.prepare(xs, options: .init(), stats: &stats)
        let t1 = Date()
        let e = FootageGrouping.edges(p, stats: &stats)
        let t2 = Date()
        let c = FootageGrouping.components(p, edges: e, options: .init(), stats: &stats)
        let t3 = Date()
        let r = FootageGrouping.assemble(p, edges: e, components: c, now: Date(), stats: stats)
        let elapsed = Date().timeIntervalSince(t0)
        print(String(format: "FootageScaleTests phases: prepare %.2f s, edges %.2f s, components %.2f s, assemble %.2f s",
                     t1.timeIntervalSince(t0), t2.timeIntervalSince(t1), t3.timeIntervalSince(t2), Date().timeIntervalSince(t3)))
        #expect(elapsed < 3.0, "100k grouping took \(elapsed) s")
        #expect(r.stats.groups > 1000, "expected thousands of groups, got \(r.stats.groups)")
        #expect(r.stats.largestGroup <= FootageGrouping.defaultCap)
        print("FootageScaleTests: 100k records → \(r.stats.groups) groups, \(r.stats.members) members in \(String(format: "%.2f", elapsed)) s")
    }
}

/// Deterministic xorshift (tests must not depend on the system RNG).
private struct FootageTestRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}
