// ProvenanceResolverTests.swift
// Machine-estimated provenance (ProvenanceResolver.swift; DECISIONS 2026-11-10).
//   LOGIC      — every clause of the evidence rule (remove one → no proposal);
//                tapes told apart by NAME first, then duration within 1 %
//                (the real folder shapes of 2026-11-10); the master
//                tie-breaks (pixels, bits, the shorter stem, path); a
//                name-related shorter file is left unclassified; byte copies
//                are one content; the three drafts and their signer.
//   ISOLATION  — poisoned / missing probe values, an empty path, a zero or
//                non-finite duration, a path that lost bytes in decoding, a
//                bad digest: no proposal and no crash.
//   MEDIA      — the five standard combinations: only mkv/ffv1 from the VHS
//                folder qualifies.
//   SCALE      — 100,000 facts resolved inside a budget.
//   TRUTH      — what stands is read from the rows: inferred alone is never
//                "confirmed"; a rejected role shows nothing; a confidence
//                never appears in any sentence; year and month are omitted
//                when unknown, never invented; the year is the archive's
//                filing folder, never the capture's own year; an alternate
//                names its master only when given the archive's name for it.
//   REVIEW     — the independent review of 2026-11-10 (its red tests, kept):
//                Not Right never resurrects an older proposal; a name is
//                related by whole tokens, never a raw prefix; and the fixes'
//                own rules — the capture setup needs the file's own 2026
//                date, a withdrawal row takes an estimate back, Rick's Set
//                Role wins on every surface, the counts add up.
//   DOOR       — the three drafts land through `appendProvenanceAssertion`
//                (none is a name or a date, so the archived refusal never
//                applies); Rick's reject vetoes the role's re-proposal;
//                `standingAt` makes a second run a `.duplicate`.
// Synthetic names and digests only.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

private func hex(_ n: Int) -> String { String(format: "%064x", n) }

private let vhsFolder = "/Volumes/Fixture/_staging/Converted_VHS_Tapes_2026/1984"

private func fact(_ n: Int, path: String? = nil, container: String = "matroska,webm", codec: String = "ffv1",
                  seconds: Double = 3_660, resolution: String = "1280x720", bits: String = "8",
                  encoder: String? = "Lavf61.7.100", created: Date? = Date(timeIntervalSince1970: 1_783_000_000)) -> ProvenanceFact {
    let p = path ?? "\(vhsFolder)/test_tape_\(n).mkv"
    return ProvenanceFact(digest: hex(n), originalPath: p, filename: (p as NSString).lastPathComponent, container: container,
                          videoCodec: codec, durationSeconds: seconds, embeddedCreatedAt: created, resolution: resolution, bitDepth: bits,
                          frameRate: "30", originEncoder: encoder)
}

private func row(_ seq: Int64, _ field: String, _ value: String, state: String = "inferred",
                 by: String = ProvenanceEstimateRule.signer, evidence: String = "{}") -> CatalogRow.ProvenanceAssertionReading {
    CatalogRow.ProvenanceAssertionReading(seq: seq, subjectKind: "content", subjectID: hex(1), field: field, value: value, state: state,
                                          by: by, at: 1_794_300_000 + seq, confidence: state == "inferred" ? 0.9 : nil, evidenceJSON: evidence)
}

private func inferred(role: String = "master", from: Int64 = 1) -> [CatalogRow.ProvenanceAssertionReading] {
    [row(from, "role", role), row(from + 1, "carrier", "VHS"), row(from + 2, "captureSetup", CaptureSetup.july2026.id)]
}

private let utc = TimeZone(identifier: "UTC") ?? .current
private let july2026 = Date(timeIntervalSince1970: 1_783_944_000)       // 2026-07-13T12:00:00Z

// MARK: - Logic

@Suite("ProvenanceResolver — the evidence rule, grouping and the master")
struct ProvenanceResolverLogicTests {

    @Test func theExampleFileIsProposedAsAVHSMasterWithThreeDrafts() throws {
        let example = fact(1, path: "/Volumes/Projects/_staging_from_Fixture/Converted_VHS_Tapes_2026/1984/test_Bday_1984.mkv")
        let resolved = ProvenanceResolver.resolve([example])
        #expect(resolved.examined == 1)
        #expect(resolved.qualified == 1)
        let proposal = try #require(resolved.proposals.first)
        #expect(proposal.role == .master)
        #expect(proposal.carrier == "VHS")
        #expect(proposal.captureSetupID == CaptureSetup.july2026.id)
        let drafts = proposal.drafts(at: 1_794_300_000)
        #expect(drafts.map(\.field) == ["role", "carrier", "captureSetup"])
        #expect(drafts.map(\.value) == ["master", "VHS", CaptureSetup.july2026.id])
        #expect(drafts.allSatisfy { $0.state == "inferred" && $0.subjectKind == "content" && $0.subjectID == hex(1) })
        #expect(drafts.allSatisfy { $0.by == "machine:catalog-rule/provenance-v1/vhs-capture-2026@r1" })
        #expect(drafts.allSatisfy { $0.confidence == ProvenanceEstimateRule.confidence })
    }

    @Test func noAssertedFieldIsANameOrADate() {
        for field in ProvenanceEstimateRule.fields {
            #expect(!ProvenanceAssertionFieldPolicy.isNameOrDate(field), "\(field) would be refused on archived content")
        }
        // The ruling: the tape year and the capture date are NOT asserted.
        #expect(ProvenanceAssertionFieldPolicy.isNameOrDate("tapeYear"))
        #expect(ProvenanceAssertionFieldPolicy.isNameOrDate("digitizedOn"))
        #expect(!ProvenanceEstimateRule.fields.contains { $0.lowercased().contains("date") || $0.lowercased().contains("year") })
    }

    @Test func theEvidenceNamesTheRuleAndTheFactsItUsed() throws {
        let proposal = try #require(ProvenanceResolver.resolve([fact(1)]).proposals.first)
        let evidence = try #require(try JSONSerialization.jsonObject(with: Data(proposal.evidenceJSON.utf8)) as? [String: Any])
        #expect(evidence["rule"] as? String == "vhsCapture2026")
        #expect(evidence["pathComponent"] as? String == "Converted_VHS_Tapes_2026")
        #expect(evidence["videoCodec"] as? String == "ffv1")
        #expect(evidence["container"] as? String == "matroska,webm")
        #expect(evidence["durationMs"] as? Int == 3_660_000)
        #expect(evidence["resolution"] as? String == "1280x720")
        #expect(evidence["bitDepth"] as? Int == 8)
        #expect(evidence["originEncoder"] as? String == "Lavf61.7.100")
        #expect(evidence["groupSize"] as? Int == 1)
        #expect((evidence["confidenceIs"] as? String)?.contains("fixed value") == true)
        #expect(evidence["confidence"] == nil, "the number rides the column, never the evidence")
    }

    @Test func theSameFactsGiveTheSameEvidenceBytes() {
        let a = ProvenanceResolver.resolve([fact(1), fact(2, seconds: 3_661)])
        let b = ProvenanceResolver.resolve([fact(2, seconds: 3_661), fact(1)])
        #expect(a == b)
    }

    @Test func aPathWithoutTheFolderComponentProposesNothing() {
        #expect(ProvenanceResolver.resolve([fact(1, path: "/Volumes/Fixture/Other/1984/test_tape.mkv")]).proposals.isEmpty)
    }

    @Test func theComponentMustBeADirectoryNotPartOfAName() {
        #expect(ProvenanceResolver.resolve([fact(1, path: "/Volumes/Fixture/x/Converted_VHS_Tapes_2026_old/test_tape.mkv")]).proposals.isEmpty)
        #expect(ProvenanceResolver.resolve([fact(1, path: "/Volumes/Fixture/x/Converted_VHS_Tapes_2026")]).proposals.isEmpty)
    }

    @Test func aCodecOtherThanFFV1ProposesNothing() {
        #expect(ProvenanceResolver.resolve([fact(1, codec: "h264")]).proposals.isEmpty)
    }

    @Test func aContainerOtherThanMatroskaProposesNothing() {
        #expect(ProvenanceResolver.resolve([fact(1, container: "mov,mp4,m4a,3gp,3g2,mj2")]).proposals.isEmpty)
    }

    @Test func aCaptureShorterThanTwentyMinutesProposesNothing() {
        #expect(ProvenanceResolver.resolve([fact(1, seconds: 1_199.9)]).proposals.isEmpty)
        #expect(ProvenanceResolver.resolve([fact(1, seconds: 1_200)]).proposals.count == 1)
    }

    @Test func capturesWithinOnePercentAreOneTapeWithExactlyOneMaster() {
        let resolved = ProvenanceResolver.resolve([fact(1, path: "\(vhsFolder)/test_x.mkv", seconds: 3_660),
                                                   fact(2, path: "\(vhsFolder)/test_x_2.mkv", seconds: 3_640),
                                                   fact(3, path: "\(vhsFolder)/test_x_3.mkv", seconds: 3_625)])
        #expect(resolved.proposals.count == 3)
        #expect(resolved.masters == 1)
        #expect(resolved.alternates == 2)
        #expect(resolved.shorterUnclassified == 0)
    }

    @Test func theMasterIsTheLargerPicture() {
        let resolved = ProvenanceResolver.resolve([fact(1, path: "\(vhsFolder)/test_x.mkv", resolution: "720x480"),
                                                   fact(2, path: "\(vhsFolder)/test_x_2.mkv", resolution: "1280x720")])
        #expect(resolved.proposals.first { $0.role == .master }?.digest == hex(2))
        #expect(resolved.proposals.first { $0.role == .alternateCapture }?.digest == hex(1))
    }

    @Test func atEqualPictureTheMasterIsTheDeeperOne() {
        let resolved = ProvenanceResolver.resolve([fact(1, path: "\(vhsFolder)/test_x.mkv", bits: "8"),
                                                   fact(2, path: "\(vhsFolder)/test_x_2.mkv", bits: "10")])
        #expect(resolved.proposals.first { $0.role == .master }?.digest == hex(2))
    }

    @Test func atEqualPictureDepthAndStemLengthTheMasterIsTheSmallestOriginalPath() {
        // Equal stems (the names differ only in case): the smaller path wins.
        let resolved = ProvenanceResolver.resolve([fact(1, path: "\(vhsFolder)/test_x.mkv"), fact(2, path: "\(vhsFolder)/Test_X.mkv")])
        #expect(resolved.proposals.first { $0.role == .master }?.digest == hex(2))
        #expect(resolved.proposals.first { $0.role == .alternateCapture }?.digest == hex(1))
    }

    @Test func anAlternateNamesItsMasterInItsEvidence() throws {
        let resolved = ProvenanceResolver.resolve([fact(1, path: "\(vhsFolder)/test_a_2.mkv"), fact(2, path: "\(vhsFolder)/test_a.mkv")])
        let alternate = try #require(resolved.proposals.first { $0.role == .alternateCapture })
        let evidence = try #require(try JSONSerialization.jsonObject(with: Data(alternate.evidenceJSON.utf8)) as? [String: Any])
        #expect(evidence["masterDigest"] as? String == hex(2))
        #expect(evidence["masterFilename"] as? String == "test_a.mkv")
        #expect(evidence["groupSize"] as? Int == 2)
    }

    @Test func filesInDifferentFoldersAreDifferentTapes() {
        let resolved = ProvenanceResolver.resolve([fact(1), fact(2, path: "/Volumes/Fixture/Converted_VHS_Tapes_2026/1991/test_other.mkv")])
        #expect(resolved.masters == 2)
        #expect(resolved.alternates == 0)
    }

    @Test func byteCopiesAreOneContent() {
        var copy = fact(1, path: "\(vhsFolder)/test_zz_copy.mkv")
        copy.digest = "sha256:" + hex(1).uppercased()
        let resolved = ProvenanceResolver.resolve([copy, fact(1, path: "\(vhsFolder)/test_aa.mkv")])
        #expect(resolved.proposals.count == 1)
        #expect(resolved.proposals.first?.role == .master)
        #expect(resolved.qualified == 1)
    }

    @Test func aFileThatDoesNotQualifyNeverJoinsAGroup() {
        let resolved = ProvenanceResolver.resolve([fact(1), fact(2, codec: "h264", seconds: 3_660)])
        #expect(resolved.proposals.map(\.digest) == [hex(1)])
        #expect(resolved.shorterUnclassified == 0)
    }
}

// MARK: - Grouping by name, then duration (the real folder shapes, 2026-11-10)

@Suite("ProvenanceResolver — tapes are told apart by NAME first, then duration")
struct ProvenanceResolverGroupingTests {

    private static let root = "/Volumes/Fixture/_staging/Converted_VHS_Tapes_2026"

    private func capture(_ n: Int, _ relative: String, minutes: Double, bits: String = "8", codec: String = "ffv1",
                         container: String = "matroska,webm", resolution: String = "1280x720") -> ProvenanceFact {
        fact(n, path: "\(Self.root)/\(relative)", container: container, codec: codec, seconds: minutes * 60, resolution: resolution, bits: bits)
    }

    private func roles(_ resolved: ProvenanceResolver.Resolution) -> [String: ProvenanceRole] {
        Dictionary(uniqueKeysWithValues: resolved.proposals.map { ($0.digest, $0.role) })
    }

    /// The shapes found in the real catalog: names and durations as they are.
    @Test func theRealFolderShapes() {
        let resolved = ProvenanceResolver.resolve([
            capture(1, "Misc1990/Franklin_1988.mkv", minutes: 56.0),
            capture(2, "Misc1990/Franklin_1990_p216.mkv", minutes: 91.5, bits: "16"),
            capture(3, "Misc1990/Franklin_1990_P216_2.mkv", minutes: 91.5, bits: "16"),
            capture(4, "Misc1990/Franklin_Dan_Kindergarten_NV12_2.mkv", minutes: 67.0),
            capture(5, "Montana/Montana_Tape_1.mkv", minutes: 83.9),
            capture(6, "Montana/Montana_1995_part_x.mkv", minutes: 54.4),
            capture(7, "Montana/Montana_Camping_1995.mov", minutes: 40, codec: "prores", container: "mov,mp4,m4a,3gp,3g2,mj2"),
        ])
        #expect(roles(resolved) == [hex(1): .master, hex(2): .master, hex(3): .alternateCapture, hex(4): .master,
                                    hex(5): .master, hex(6): .master])
        #expect(resolved.shorterUnclassified == 0)
        #expect(resolved.qualified == 6, "the ProRes .mov is not a candidate at all")
    }

    @Test func twoUnrelatedNamesOfEqualLengthAreTwoTapes() {
        let resolved = ProvenanceResolver.resolve([capture(1, "1984/test_birthday.mkv", minutes: 120), capture(2, "1984/test_christmas.mkv", minutes: 120)])
        #expect(roles(resolved) == [hex(1): .master, hex(2): .master])
    }

    @Test func aNameRelatedShorterFileIsUnclassifiedAndTheLongerIsStillAMaster() {
        let resolved = ProvenanceResolver.resolve([capture(1, "1984/test_x.mkv", minutes: 60), capture(2, "1984/test_x_trimmed.mkv", minutes: 25)])
        #expect(roles(resolved) == [hex(1): .master])
        #expect(resolved.shorterUnclassified == 1)
    }

    @Test func anUnrelatedShorterFileIsItsOwnTape() {
        let resolved = ProvenanceResolver.resolve([capture(1, "1984/test_x.mkv", minutes: 60), capture(2, "1984/test_y.mkv", minutes: 25)])
        #expect(roles(resolved) == [hex(1): .master, hex(2): .master])
        #expect(resolved.shorterUnclassified == 0)
    }

    @Test func atEqualPictureAndDepthTheMasterIsTheShorterStem() {
        let resolved = ProvenanceResolver.resolve([capture(1, "1984/test_x_2.mkv", minutes: 60), capture(2, "1984/test_x.mkv", minutes: 60)])
        #expect(roles(resolved) == [hex(1): .alternateCapture, hex(2): .master])
    }

    @Test func nameRelationIgnoresCaseAndTheExtension() {
        let resolved = ProvenanceResolver.resolve([capture(1, "1984/Test_X.MKV", minutes: 60), capture(2, "1984/test_x_B.mkv", minutes: 60.2)])
        #expect(roles(resolved) == [hex(1): .master, hex(2): .alternateCapture])
    }

    @Test func theSameNameInAnotherFolderIsAnotherTape() {
        let resolved = ProvenanceResolver.resolve([capture(1, "1984/test_x.mkv", minutes: 60), capture(2, "1985/test_x_2.mkv", minutes: 60)])
        #expect(roles(resolved) == [hex(1): .master, hex(2): .master])
    }

    @Test func theEvidenceCarriesTheNameRelationAndTheDurations() throws {
        let resolved = ProvenanceResolver.resolve([capture(1, "1984/test_x.mkv", minutes: 60), capture(2, "1984/test_x_2.mkv", minutes: 60.1),
                                                   capture(3, "1984/test_other.mkv", minutes: 60)])
        let master = try #require(resolved.proposals.first { $0.digest == hex(1) })
        let evidence = try #require(try JSONSerialization.jsonObject(with: Data(master.evidenceJSON.utf8)) as? [String: Any])
        #expect(evidence["nameRelation"] as? String == "prefix")
        #expect(evidence["relatedNames"] as? [String] == ["test_x_2.mkv"])
        #expect(evidence["groupDurationsMs"] as? [Int] == [3_600_000, 3_606_000])
        #expect(evidence["groupSize"] as? Int == 2)
        let alone = try #require(resolved.proposals.first { $0.digest == hex(3) })
        let single = try #require(try JSONSerialization.jsonObject(with: Data(alone.evidenceJSON.utf8)) as? [String: Any])
        #expect(single["nameRelation"] as? String == "none")
        #expect(single["groupSize"] as? Int == 1)
    }
}

// MARK: - Isolation

@Suite("ProvenanceResolver — poisoned facts propose nothing and never crash")
struct ProvenanceResolverIsolationTests {

    @Test func missingProbeValuesProposeNothing() {
        #expect(ProvenanceResolver.resolve([fact(1, resolution: "")]).proposals.isEmpty)
        #expect(ProvenanceResolver.resolve([fact(1, bits: "")]).proposals.isEmpty)
    }

    @Test(arguments: ["x", "1280x", "x720", "0x720", "1280x-720", "1280×720", "NaNxNaN", "99999999999999999999x2", "1280x720x3"])
    func aPoisonedResolutionProposesNothing(_ resolution: String) {
        #expect(ProvenanceResolver.resolve([fact(1, resolution: resolution)]).proposals.isEmpty)
    }

    @Test(arguments: ["0", "-8", "eight", "8.5", "9999999999999999999999"])
    func aPoisonedBitDepthProposesNothing(_ bits: String) {
        #expect(ProvenanceResolver.resolve([fact(1, bits: bits)]).proposals.isEmpty)
    }

    @Test(arguments: ["", "relative/Converted_VHS_Tapes_2026/1984/test.mkv", "/", "//", "/Converted_VHS_Tapes_2026",
                      "/Volumes/Fixture/Converted_VHS_Tapes_2026/19\u{FFFD}84/test.mkv",
                      "/Volumes/Fixture/Converted_VHS_Tapes_2026/1984/te\u{0}st.mkv"])
    func aPathThatIsNotEvidenceProposesNothing(_ path: String) {
        #expect(ProvenanceResolver.resolve([fact(1, path: path)]).proposals.isEmpty)
    }

    @Test(arguments: [0.0, -5.0, Double.nan, Double.infinity, -Double.infinity])
    func aDurationThatIsNotALengthProposesNothing(_ seconds: Double) {
        #expect(ProvenanceResolver.resolve([fact(1, seconds: seconds)]).proposals.isEmpty)
    }

    @Test func aDigestThatIsNotAWholeFileSHA256ProposesNothing() {
        var bad = fact(1)
        bad.digest = "v1:sampled"
        #expect(ProvenanceResolver.resolve([bad]).proposals.isEmpty)
        bad.digest = ""
        #expect(ProvenanceResolver.resolve([bad]).proposals.isEmpty)
    }

    @Test func onePoisonedFactDoesNotStopTheOthers() {
        let resolved = ProvenanceResolver.resolve([fact(1, resolution: "junk"), fact(2), fact(3, seconds: .nan)])
        #expect(resolved.proposals.map(\.digest) == [hex(2)])
        #expect(resolved.examined == 3)
    }

    @Test func noFactsIsNoProposals() {
        #expect(ProvenanceResolver.resolve([]) == ProvenanceResolver.Resolution())
    }
}

// MARK: - Media matrix

@Suite("ProvenanceResolver — media matrix")
struct ProvenanceResolverMediaMatrixTests {

    /// (container as ffprobe names it, video codec, extension) for the five standard combinations.
    static let matrix: [(container: String, codec: String, ext: String, qualifies: Bool)] = [
        ("mov,mp4,m4a,3gp,3g2,mj2", "h264", "mp4", false),
        ("mov,mp4,m4a,3gp,3g2,mj2", "prores", "mov", false),
        ("matroska,webm", "ffv1", "mkv", true),
        ("mxf", "dnxhd", "mxf", false),
        ("avi", "dvvideo", "avi", false),
    ]

    @Test func onlyMkvFFV1FromTheVHSFolderQualifies() {
        for (i, m) in Self.matrix.enumerated() {
            let inFolder = fact(i + 1, path: "\(vhsFolder)/test_\(m.ext)_\(i).\(m.ext)", container: m.container, codec: m.codec)
            #expect(ProvenanceResolver.resolve([inFolder]).proposals.count == (m.qualifies ? 1 : 0), "\(m.ext)/\(m.codec) in the VHS folder")
            let elsewhere = fact(i + 1, path: "/Volumes/Fixture/Elsewhere/test_\(i).\(m.ext)", container: m.container, codec: m.codec)
            #expect(ProvenanceResolver.resolve([elsewhere]).proposals.isEmpty, "\(m.ext)/\(m.codec) outside the VHS folder")
        }
    }

    @Test func theWholeMatrixInOneFolderYieldsOneMasterAndNothingElse() {
        let facts = Self.matrix.enumerated().map { i, m in
            fact(i + 1, path: "\(vhsFolder)/test_\(m.ext)_\(i).\(m.ext)", container: m.container, codec: m.codec)
        }
        let resolved = ProvenanceResolver.resolve(facts)
        #expect(resolved.proposals.map(\.digest) == [hex(3)])
        #expect(resolved.proposals.first?.role == .master)
        #expect(resolved.shorterUnclassified == 0, "a file the rule does not hold for is not a 'shorter capture'")
    }
}

// MARK: - Scale

@Suite("ProvenanceResolver — SCALE (100k)")
struct ProvenanceResolverScaleTests {

    /// 100,000 archived facts: 20,000 qualifying captures in 10,000 folders
    /// (a master and a name-related alternate each) among 80,000 that do not
    /// qualify — and, below, 5,000 unrelated names in ONE folder (each its
    /// own tape; the sorted-stem walk never compares unrelated files).
    /// Budget 2 s (Debug, M4 Max; measured ≈ 0.5 s) — O(n²) would be minutes.
    @Test(.timeLimit(.minutes(2)))
    func hundredThousandFacts() {
        var facts: [ProvenanceFact] = []
        facts.reserveCapacity(100_000)
        for n in 1...100_000 {
            if n <= 20_000 {
                let folder = "/Volumes/Fixture/Converted_VHS_Tapes_2026/tape_\((n - 1) / 2)"
                facts.append(fact(n, path: "\(folder)/test_capture\(n % 2 == 0 ? "" : "_2").mkv", seconds: 3_600 + Double(n % 2),
                                  resolution: n % 2 == 0 ? "1280x720" : "720x480"))
            } else {
                facts.append(fact(n, path: "/Volumes/Fixture/Clips/test_clip_\(n).mov", container: "mov,mp4,m4a,3gp,3g2,mj2", codec: "h264"))
            }
        }
        let load = TimingBudget.sampleLoad()
        var resolved = ProvenanceResolver.Resolution()
        let took = ContinuousClock().measure { resolved = ProvenanceResolver.resolve(facts) }
        #expect(resolved.examined == 100_000)
        #expect(resolved.proposals.count == 20_000)
        #expect(resolved.masters == 10_000)
        #expect(resolved.alternates == 10_000)
        print("ProvenanceResolver scale: 100k facts → \(resolved.proposals.count) proposals in \(took)")
        expectWithinTimingBudget("100k archived facts resolved to provenance proposals", measured: took,
                                 budget: .seconds(2), loadBefore: load)
    }

    @Test(.timeLimit(.minutes(2)))
    func fiveThousandUnrelatedNamesInOneFolder() {
        let facts = (1...5_000).map { fact($0, path: "\(vhsFolder)/test_\(String(format: "%05d", $0))_tape.mkv") }
        let load = TimingBudget.sampleLoad()
        var resolved = ProvenanceResolver.Resolution()
        let took = ContinuousClock().measure { resolved = ProvenanceResolver.resolve(facts) }
        #expect(resolved.masters == 5_000)
        #expect(resolved.alternates == 0)
        expectWithinTimingBudget("5,000 unrelated names in one folder", measured: took, budget: .seconds(1), loadBefore: load)
    }

    /// 100,000 assertion rows (one content's worth at a time) reduced to what stands.
    @Test(.timeLimit(.minutes(2)))
    func hundredThousandRowsReduceToEstimates() {
        let rows = inferred()
        let load = TimingBudget.sampleLoad()
        var shown = 0
        let took = ContinuousClock().measure {
            for _ in 0..<33_334 where ProvenanceResolver.estimate(fromRowsOfOneSubject: rows) != nil { shown += 1 }
        }
        #expect(shown == 33_334)
        expectWithinTimingBudget("100k assertion rows reduced to 33k estimates", measured: took, budget: .seconds(1), loadBefore: load)
    }
}

// MARK: - Truth

@Suite("ProvenanceResolver — what stands, and the words (truth)")
struct ProvenanceResolverTruthTests {

    private let tech = ProvenanceResolver.Technical(videoCodec: "ffv1", resolution: "1280x720", bitDepth: "8")

    @Test func noRowsIsNoEstimate() {
        #expect(ProvenanceResolver.estimate(fromRowsOfOneSubject: []) == nil)
        #expect(ProvenanceResolver.estimate(fromRowsOfOneSubject: [row(1, "era.fused", "1984-1986")]) == nil)
    }

    @Test func inferredRowsAloneAreNeverConfirmed() throws {
        let estimate = try #require(ProvenanceResolver.estimate(fromRowsOfOneSubject: inferred()))
        #expect(estimate.role == .master)
        #expect(estimate.carrier == "VHS")
        #expect(!estimate.isConfirmed)
        #expect(estimate.isVHSMaster)
        let sentence = try #require(ProvenanceResolver.sentence(estimate, year: 1984, captured: july2026, technical: tech, timeZone: utc))
        let line = ProvenanceResolver.labelledLine(estimate, sentence: sentence)
        #expect(line.hasPrefix("Provenance (estimated): "))
        #expect(!line.lowercased().contains("confirmed"))
        let short = try #require(ProvenanceResolver.shortLine(estimate, captured: july2026, timeZone: utc))
        #expect(short == "Estimated: original capture of a VHS tape, captured July 2026 — not confirmed")
    }

    @Test func theFullSentenceIsTheRulingsExample() throws {
        let estimate = try #require(ProvenanceResolver.estimate(fromRowsOfOneSubject: inferred()))
        #expect(ProvenanceResolver.sentence(estimate, year: 1984, captured: july2026, technical: tech, timeZone: utc)
                == "Original capture of a VHS tape from 1984, captured July 2026 using ClearClick into OBS — FFV1, 1280×720, 8-bit")
    }

    @Test func anUnknownYearOrMonthIsOmittedNeverInvented() throws {
        let estimate = try #require(ProvenanceResolver.estimate(fromRowsOfOneSubject: inferred()))
        #expect(ProvenanceResolver.sentence(estimate, year: nil, captured: july2026, technical: nil, timeZone: utc)
                == "Original capture of a VHS tape, captured July 2026 using ClearClick into OBS")
        #expect(ProvenanceResolver.sentence(estimate, year: 1984, captured: nil, technical: nil, timeZone: utc)
                == "Original capture of a VHS tape from 1984, captured using ClearClick into OBS")
        #expect(ProvenanceResolver.shortLine(estimate, captured: nil, timeZone: utc)
                == "Estimated: original capture of a VHS tape — not confirmed")
    }

    @Test func onlyRicksConfirmedRowsOnEveryFieldMakeItConfirmed() throws {
        var rows = inferred()
        rows.append(row(4, "role", "master", state: "confirmed", by: "rick"))
        let partly = try #require(ProvenanceResolver.estimate(fromRowsOfOneSubject: rows))
        #expect(!partly.isConfirmed, "the carrier and the setup are still only inferred")
        rows.append(row(5, "carrier", "VHS", state: "confirmed", by: "rick"))
        rows.append(row(6, "captureSetup", CaptureSetup.july2026.id, state: "confirmed", by: "rick"))
        let whole = try #require(ProvenanceResolver.estimate(fromRowsOfOneSubject: rows))
        #expect(whole.isConfirmed)
        let sentence = try #require(ProvenanceResolver.sentence(whole, year: 1984, captured: july2026, technical: tech, timeZone: utc))
        #expect(ProvenanceResolver.labelledLine(whole, sentence: sentence).hasPrefix("Provenance (confirmed by Rick): Original capture of a VHS tape from 1984"))
        #expect(ProvenanceResolver.shortLine(whole, captured: july2026, timeZone: utc)
                == "Original capture of a VHS tape, captured July 2026. Provenance confirmed by Rick.")
    }

    @Test func aRejectedRoleShowsNothing() {
        var rows = inferred()
        rows.append(row(4, "role", "master", state: "rejected", by: "rick"))
        #expect(ProvenanceResolver.estimate(fromRowsOfOneSubject: rows) == nil)
    }

    @Test func aRejectAfterAConfirmShowsNothing() {
        var rows = inferred()
        rows.append(row(4, "role", "master", state: "confirmed", by: "rick"))
        rows.append(row(5, "role", "master", state: "rejected", by: "rick"))
        #expect(ProvenanceResolver.estimate(fromRowsOfOneSubject: rows) == nil)
    }

    @Test func aRoleKeyThisBuildCannotReadShowsNothing() {
        #expect(ProvenanceResolver.estimate(fromRowsOfOneSubject: inferred(role: "zzz")) == nil)
        #expect(ProvenanceResolver.estimate(fromRowsOfOneSubject: inferred(role: "unknown")) == nil)
    }

    @Test func aHumanInferredRowIsNotAnEstimate() {
        // The CHECK refuses this row; a poisoned table must still not show it.
        #expect(ProvenanceResolver.estimate(fromRowsOfOneSubject: [row(1, "role", "master", by: "rick")]) == nil)
    }

    @Test func anAlternateCaptureNamesItsMaster() throws {
        let evidence = #"{"masterDigest":"\#(hex(2))","masterFilename":"test_a.mkv"}"#
        let rows = [row(1, "role", "alternateCapture", evidence: evidence), row(2, "carrier", "VHS"),
                    row(3, "captureSetup", CaptureSetup.july2026.id)]
        let estimate = try #require(ProvenanceResolver.estimate(fromRowsOfOneSubject: rows))
        #expect(estimate.role == .alternateCapture)
        #expect(!estimate.isVHSMaster)
        #expect(estimate.masterDigest == hex(2))
        // Named by what the caller says the archive calls the master — never by the original name in the evidence.
        #expect(ProvenanceResolver.sentence(estimate, year: 1984, captured: july2026, technical: tech, masterName: "1984_test-a.mkv", timeZone: utc)
                == "Alternate capture of the same tape as 1984_test-a.mkv")
        #expect(ProvenanceResolver.shortLine(estimate, captured: july2026, masterName: "1984_test-a.mkv", timeZone: utc)
                == "Estimated: alternate capture of the same tape as 1984_test-a.mkv — not confirmed")
    }

    @Test func anAlternateWhoseMasterNoLongerStandsDropsThePointer() throws {
        let evidence = #"{"masterDigest":"\#(hex(2))","masterFilename":"test_a.mkv"}"#
        let rows = [row(1, "role", "alternateCapture", evidence: evidence), row(2, "carrier", "VHS"),
                    row(3, "captureSetup", CaptureSetup.july2026.id)]
        let estimate = try #require(ProvenanceResolver.estimate(fromRowsOfOneSubject: rows))
        let sentence = try #require(ProvenanceResolver.sentence(estimate, year: 1984, captured: july2026, technical: tech, masterName: nil, timeZone: utc))
        #expect(sentence == "Alternate capture of a VHS tape")
        #expect(!sentence.contains("test_a"), "the original name in the evidence is never the pointer")
        #expect(ProvenanceResolver.labelledLine(estimate, sentence: sentence) == "Provenance (estimated): Alternate capture of a VHS tape")
        #expect(ProvenanceResolver.sentence(estimate, year: nil, captured: nil, technical: nil, masterName: "", timeZone: utc)
                == "Alternate capture of a VHS tape")
    }

    @Test func theTapeYearIsTheArchivesFilingFolderAndNeverTheCapturesOwnYear() {
        let filed = "/Volumes/Fixture/Archive/30_Video/1980-1989/1984/1984_test-tape.mkv"
        #expect(ProvenanceResolver.filingYear(archivePath: filed) == 1984)
        #expect(ProvenanceResolver.filingYear(archivePath: "30_Video/1990-1999/1995/1995-07_test.mkv") == 1995)
        #expect(ProvenanceResolver.tapeYear(archivePath: filed, captured: july2026, timeZone: utc) == 1984)
        #expect(ProvenanceResolver.tapeYear(archivePath: filed, captured: nil, timeZone: utc) == 1984)
        // Filed by its capture stamp: that year says nothing about the tape.
        let byCapture = "/Volumes/Fixture/Archive/30_Video/2020-2029/2026/2026-07-13_test-tape.mkv"
        #expect(ProvenanceResolver.filingYear(archivePath: byCapture) == 2026)
        #expect(ProvenanceResolver.tapeYear(archivePath: byCapture, captured: july2026, timeZone: utc) == nil)
        #expect(ProvenanceResolver.tapeYear(archivePath: nil, captured: july2026, timeZone: utc) == nil)
    }

    @Test(arguments: ["", "/", "/Volumes/Fixture/_staging/Converted_VHS_Tapes_2026/1984/test.mkv",
                      "/Volumes/Fixture/Archive/30_Video/Undated/test.mkv", "/Volumes/Fixture/Archive/30_Video/1980-1989/test.mkv",
                      "/Volumes/Fixture/Archive/30_Video/1980-1989/1994/test.mkv", "/Volumes/Fixture/Archive/30_Video/1980-1990/1984/test.mkv",
                      "/Volumes/Fixture/Archive/30_Video/abcd-efgh/1984/test.mkv", "/Volumes/Fixture/Archive/30_Video/1980-1989/1984"])
    func aPathWithNoYearFolderHasNoFilingYear(_ path: String) {
        #expect(ProvenanceResolver.filingYear(archivePath: path) == nil)
    }

    @Test func noSentenceEverCarriesAConfidence() throws {
        let estimate = try #require(ProvenanceResolver.estimate(fromRowsOfOneSubject: inferred()))
        let proposal = try #require(ProvenanceResolver.resolve([fact(1)]).proposals.first)
        let stored = proposal.drafts(at: 1).enumerated().map { i, d in
            CatalogRow.ProvenanceAssertionReading(seq: Int64(i + 1), subjectKind: d.subjectKind, subjectID: d.subjectID, field: d.field,
                                                  value: d.value, state: d.state, by: d.by, at: d.at, confidence: d.confidence,
                                                  evidenceJSON: d.evidenceJSON)
        }
        let texts = [
            ProvenanceResolver.sentence(estimate, year: 1984, captured: july2026, technical: tech, timeZone: utc),
            ProvenanceResolver.shortLine(estimate, captured: july2026, timeZone: utc),
            ProvenanceResolver.evidenceWords(fromRowsOfOneSubject: stored),
        ].compactMap { $0 }
        #expect(texts.count == 3)
        for text in texts {
            #expect(!text.contains("0.9"), "\(text)")
            #expect(!text.contains("90"), "\(text)")
            #expect(!text.lowercased().contains("confidence"), "\(text)")
            #expect(!text.contains("%"), "\(text)")
        }
    }

    @Test func technicalWordsComeFromTheFilesOwnProbeValues() {
        #expect(ProvenanceResolver.Technical(videoCodec: "ffv1", resolution: "720x480", bitDepth: "10").words == "FFV1, 720×480, 10-bit")
        #expect(ProvenanceResolver.Technical(videoCodec: "", resolution: "", bitDepth: "").words == nil)
        #expect(!CaptureSetup.july2026.using.contains("1280"), "the owner's statement carries no per-file numbers")
        #expect(CaptureSetup.july2026.statement == "ClearClick into OBS; FFV1 in Matroska (Rick, 2026-11-10)")
    }

    @Test func theDossierLineIsAnObservationUntilConfirmedAndAbsentWithoutAnEstimate() throws {
        let r = VideoRecord()
        r.filename = "test_tape.mkv"
        r.streamTypeRaw = "Video+Audio"
        r.videoCodec = "ffv1"
        r.resolution = "1280x720"
        r.bitDepth = "8"
        r.userDate = "1977"         // not the source of the sentence's year
        r.fullPath = "/Volumes/Fixture/Archive/30_Video/1980-1989/1984/1984_test-tape.mkv"
        r.embeddedCreationDate = july2026
        #expect(FileDossier.provenanceLine(r, assertions: []) == nil)
        let provisional = try #require(FileDossier.provenanceLine(r, assertions: inferred()))
        #expect(provisional.label == "Provenance")
        #expect(provisional.standing == .observation)
        #expect(provisional.reading == "estimated, unconfirmed")
        #expect(provisional.source.hasSuffix("unconfirmed"))
        #expect(provisional.value.hasPrefix("Original capture of a VHS tape from 1984, captured "))
        var rows = inferred()
        for (i, field) in ProvenanceEstimateRule.fields.enumerated() {
            rows.append(row(Int64(10 + i), field, rows[i].value, state: "confirmed", by: "rick"))
        }
        // A real Confirm also sets Rick's role (one transaction); the line is his fact while that role stands.
        let confirmed = try #require(FileDossier.provenanceLine(r, assertions: rows, rickRole: .master))
        #expect(confirmed.standing == .fact)
        #expect(confirmed.source == "Rick")
        rows.append(row(20, "role", "master", state: "rejected", by: "rick"))
        #expect(FileDossier.provenanceLine(r, assertions: rows) == nil)
        let built = FileDossier.build(record: r, digest: hex(1), assertions: inferred(), now: july2026)
        #expect(built.patterns.line("Provenance")?.standing == .observation)
        // A row outside the archive has no filing year: the year is omitted, never taken from another field.
        r.fullPath = "/Volumes/Fixture/_staging/Converted_VHS_Tapes_2026/1984/test_tape.mkv"
        #expect(FileDossier.provenanceLine(r, assertions: inferred())?.value.hasPrefix("Original capture of a VHS tape, captured ") == true)
    }

    @Test func aSecondRunReusesTheStandingRowsTimeButNeverARejectedOnes() throws {
        let draft = try #require(ProvenanceResolver.resolve([fact(1)]).proposals.first?.drafts(at: 500).first)
        let stored = CatalogRow.ProvenanceAssertionReading(seq: 1, subjectKind: "content", subjectID: hex(1), field: draft.field,
                                                           value: draft.value, state: "inferred", by: draft.by, at: 100,
                                                           confidence: draft.confidence, evidenceJSON: draft.evidenceJSON)
        #expect(ProvenanceResolver.standingAt(of: draft, among: []) == nil)
        #expect(ProvenanceResolver.standingAt(of: draft, among: [stored]) == 100)
        let rejected = row(2, "role", "master", state: "rejected", by: "rick")
        #expect(ProvenanceResolver.standingAt(of: draft, among: [stored, rejected]) == nil, "a rejected value goes to the door afresh, to be vetoed")
        var other = stored
        other.evidenceJSON = "{}"
        #expect(ProvenanceResolver.standingAt(of: draft, among: [other]) == nil, "other evidence is another observation")
    }
}

// MARK: - The door (catalog.sqlite)

@Suite("ProvenanceResolver — its drafts through the assertions door")
struct ProvenanceResolverDoorTests {

    private func open(_ fixture: StoreFixture) async throws -> GRDBCatalogRepository {
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        return repository
    }

    /// One stored content. (That the three fields are allowed on ARCHIVED content is the field
    /// policy's answer — `noAssertedFieldIsANameOrADate`; the door's archived refusal itself is
    /// CatalogProvenanceAssertionsTests'.)
    private func seedContent(_ fixture: StoreFixture) throws {
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.execute(sql: "INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, 100, 1700000000, 'rescan')",
                           arguments: [hex(1)])
        }
    }

    private func append(_ repository: GRDBCatalogRepository, _ drafts: [CatalogRow.ProvenanceAssertionDraft]) async -> [CatalogRow.ProvenanceAssertionLanding] {
        let box = Landings()
        _ = await repository.write(as: .ui) { tx in for d in drafts { box.append(try tx.appendProvenanceAssertion(d)) } }
        return box.items
    }

    @Test func estimateThenRejectThenReEstimateIsVetoedAndASecondRunIsADuplicate() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture)
        let repository = try await open(fixture)
        let proposal = try #require(ProvenanceResolver.resolve([fact(1)]).proposals.first)
        let first = await append(repository, proposal.drafts(at: 1_794_300_000))
        #expect(first.count == 3)
        #expect(first.allSatisfy { if case .recorded = $0 { return true } else { return false } }, "\(first)")

        // A second run: the standing rows' own `at` → the door says duplicate, nothing is written.
        var rows = try await repository.read { try $0.provenanceAssertions(subjectKind: "content", subjectID: hex(1)) }
        let again = proposal.drafts(at: 1_794_400_000).map { draft -> CatalogRow.ProvenanceAssertionDraft in
            var d = draft
            if let at = ProvenanceResolver.standingAt(of: draft, among: rows) { d.at = at }
            return d
        }
        #expect(await append(repository, again) == [.duplicate, .duplicate, .duplicate])
        #expect(try await repository.read { try $0.provenanceAssertionCount() } == 3)
        #expect(ProvenanceResolver.estimate(fromRowsOfOneSubject: rows)?.isConfirmed == false)

        // Rick rejects the role; the machine's re-proposal is vetoed by the trigger.
        let reject = CatalogRow.ProvenanceAssertionDraft(subjectKind: "content", subjectID: hex(1), field: "role", value: "master",
                                                         state: "rejected", by: "rick", at: 1_794_500_000, confidence: nil, evidenceJSON: "{}")
        #expect(await append(repository, [reject]).count == 1)
        rows = try await repository.read { try $0.provenanceAssertions(subjectKind: "content", subjectID: hex(1)) }
        #expect(ProvenanceResolver.estimate(fromRowsOfOneSubject: rows) == nil, "after a reject nothing is shown")
        let third = proposal.drafts(at: 1_794_600_000).map { draft -> CatalogRow.ProvenanceAssertionDraft in
            var d = draft
            if let at = ProvenanceResolver.standingAt(of: draft, among: rows) { d.at = at }
            return d
        }
        #expect(await append(repository, third) == [.vetoed, .duplicate, .duplicate])
        #expect(try await repository.read { try $0.provenanceAssertionCount() } == 4)
        await repository.close()
    }

    @Test func ricksConfirmedRowsLandAndReadBackAsConfirmed() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture)
        let repository = try await open(fixture)
        let proposal = try #require(ProvenanceResolver.resolve([fact(1)]).proposals.first)
        _ = await append(repository, proposal.drafts(at: 1_794_300_000))
        let confirms = proposal.drafts(at: 1_794_300_100).map { d in
            CatalogRow.ProvenanceAssertionDraft(subjectKind: d.subjectKind, subjectID: d.subjectID, field: d.field, value: d.value,
                                                state: "confirmed", by: "rick", at: d.at, confidence: nil, evidenceJSON: "{}")
        }
        let landed = await append(repository, confirms)
        #expect(landed.allSatisfy { if case .recorded = $0 { return true } else { return false } }, "\(landed)")
        let rows = try await repository.read { try $0.provenanceAssertions(subjectKind: "content", subjectID: hex(1)) }
        #expect(ProvenanceResolver.estimate(fromRowsOfOneSubject: rows)?.isConfirmed == true)
        await repository.close()
    }
}

private final class Landings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CatalogRow.ProvenanceAssertionLanding] = []
    func append(_ l: CatalogRow.ProvenanceAssertionLanding) { lock.lock(); storage.append(l); lock.unlock() }
    var items: [CatalogRow.ProvenanceAssertionLanding] { lock.lock(); defer { lock.unlock() }; return storage }
}

// MARK: - Review 2026-11-10 (independent reviewer): written RED on 5cebfd5e6, green since the review fixes

@Suite("ProvenanceResolver — review 2026-11-10")
struct ProvenanceResolverReviewTests {

    private func capture(_ n: Int, _ relative: String, minutes: Double) -> ProvenanceFact {
        fact(n, path: "/Volumes/Fixture/_staging/Converted_VHS_Tapes_2026/\(relative)", seconds: minutes * 60)
    }

    /// Pins ProvenanceResolver.swift:401-404 (`standing`): after Rick rejects the
    /// rule's NEWEST role, an OLDER role value the rule itself had replaced comes
    /// back as the estimate. "Not Right — it disappears" must leave nothing.
    @Test func rejectingTheNewestProposalDoesNotResurrectAnOlderOne() {
        var rows = inferred(role: "alternateCapture")                  // run 1: seq 1-3
        rows.append(row(4, "role", "master"))                          // run 2: the rule changed its mind
        rows.append(row(5, "role", "master", state: "rejected", by: "rick"))
        #expect(ProvenanceResolver.estimate(fromRowsOfOneSubject: rows) == nil,
                "a superseded machine value is not what the rule says now, and Rick said the current one is wrong")
    }

    /// Pins ProvenanceResolver.swift:308 (`hasPrefix`): numbered tapes of equal
    /// length are DIFFERENT tapes; "montana_tape_1" is a string prefix of
    /// "montana_tape_10", so tapes 10-12 are claimed as alternate captures of tape 1.
    @Test func numberedTapesOfEqualLengthAreNotCapturesOfOneTape() {
        let resolved = ProvenanceResolver.resolve([
            capture(1, "Montana/Montana_Tape_1.mkv", minutes: 120.0),
            capture(2, "Montana/Montana_Tape_10.mkv", minutes: 120.3),
            capture(3, "Montana/Montana_Tape_11.mkv", minutes: 119.8),
            capture(4, "Montana/Montana_Tape_12.mkv", minutes: 62.0),
        ])
        let roles = Dictionary(uniqueKeysWithValues: resolved.proposals.map { ($0.digest, $0.role) })
        #expect(roles == [hex(1): .master, hex(2): .master, hex(3): .master, hex(4): .master])
        #expect(resolved.shorterUnclassified == 0, "tape 12 is not a trim of tape 1")
    }

    /// Same line: a word that merely starts another word (`Cape` / `Cape_1993`, `Dan` / `Dance_recital`).
    @Test func aNameThatOnlyStartsAnotherIsNotTheSameTape() {
        let resolved = ProvenanceResolver.resolve([capture(1, "1993/Dan.mkv", minutes: 120), capture(2, "1993/Dance_recital.mkv", minutes: 120)])
        #expect(resolved.proposals.map(\.role) == [.master, .master])
    }

    /// PROBE (determinism): every order of the same facts gives the same proposals.
    @Test func everyOrderOfTheSameFactsGivesTheSameProposals() {
        let facts = [capture(1, "a/x.mkv", minutes: 100), capture(2, "a/x_2.mkv", minutes: 100.9), capture(3, "a/x_2_b.mkv", minutes: 101.8),
                     capture(4, "a/x_3.mkv", minutes: 50), capture(5, "a/y.mkv", minutes: 100), capture(6, "b/x.mkv", minutes: 100),
                     fact(1, path: "/Volumes/Fixture/_staging/Converted_VHS_Tapes_2026/a/w.mkv", seconds: 6000)]
        let reference = ProvenanceResolver.resolve(facts)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 { #expect(ProvenanceResolver.resolve(facts.shuffled(using: &rng)) == reference) }
    }
}

// MARK: - The review's fixes: their own rules (each seen red by breaking the rule)

@Suite("ProvenanceResolver — review fixes 2026-11-10")
struct ProvenanceResolverReviewFixTests {

    private let other2019 = Date(timeIntervalSince1970: 1_560_000_000)      // 2019-06-08

    @Test func aNameIsRelatedByWholeTokensOnly() {
        #expect(ProvenanceResolver.nameRelated("franklin_1990_p216", "franklin_1990_p216_2"))
        #expect(ProvenanceResolver.nameRelated("franklin_1990_p216_2", "franklin_1990_p216"))
        #expect(ProvenanceResolver.nameRelated("test_x", "test_x"))
        #expect(ProvenanceResolver.nameRelated("test_x", "test_x-b"))
        #expect(ProvenanceResolver.nameRelated("test_x", "test_x copy"))
        #expect(ProvenanceResolver.nameRelated("test_x", "test_x.v2"))
        #expect(!ProvenanceResolver.nameRelated("montana_tape_1", "montana_tape_10"))
        #expect(!ProvenanceResolver.nameRelated("dan", "dance_recital"))
        #expect(!ProvenanceResolver.nameRelated("test_x", "test_y"))
        #expect(!ProvenanceResolver.nameRelated("test_x2", "test_x"))
    }

    @Test func theCaptureSetupIsClaimedOnlyWithTheFilesOwn2026Date() throws {
        let dated = try #require(ProvenanceResolver.resolve([fact(1)]).proposals.first)
        #expect(dated.captureSetupID == CaptureSetup.july2026.id)
        #expect(dated.drafts(at: 1).map(\.field) == ["role", "carrier", "captureSetup"])
        let evidence = try #require(try JSONSerialization.jsonObject(with: Data(dated.evidenceJSON.utf8)) as? [String: Any])
        #expect(evidence["embeddedCreatedMonth"] as? String == "2026-07")
        #expect(evidence["setupStatement"] as? String == CaptureSetup.july2026.statement)
    }

    @Test func aFileDatedInAnotherYearGetsRoleAndCarrierButNoSetup() throws {
        let proposal = try #require(ProvenanceResolver.resolve([fact(1, created: other2019)]).proposals.first)
        #expect(proposal.role == .master)
        #expect(proposal.carrier == "VHS")
        #expect(proposal.captureSetupID == nil)
        #expect(proposal.drafts(at: 1).map(\.field) == ["role", "carrier"])
        let evidence = try #require(try JSONSerialization.jsonObject(with: Data(proposal.evidenceJSON.utf8)) as? [String: Any])
        #expect(evidence["captureSetup"] as? String == "not claimed: the file's embedded creation date is not in 2026")
        #expect(evidence["setupStatement"] == nil)
        #expect(evidence["embeddedCreatedMonth"] == nil)
    }

    @Test func aFileWithNoEmbeddedDateGetsRoleAndCarrierButNoSetup() throws {
        let proposal = try #require(ProvenanceResolver.resolve([fact(1, created: nil)]).proposals.first)
        #expect(proposal.captureSetupID == nil)
        #expect(proposal.drafts(at: 1).map(\.field) == ["role", "carrier"])
        let evidence = try #require(try JSONSerialization.jsonObject(with: Data(proposal.evidenceJSON.utf8)) as? [String: Any])
        #expect(evidence["captureSetup"] as? String == "not claimed: the file carries no embedded creation date")
        // And the sentence then names no rig.
        let rows = [row(1, "role", "master"), row(2, "carrier", "VHS")]
        let estimate = try #require(ProvenanceResolver.estimate(fromRowsOfOneSubject: rows))
        #expect(ProvenanceResolver.sentence(estimate, year: 1984, captured: nil, technical: nil, timeZone: utc) == "Original capture of a VHS tape from 1984")
    }

    @Test func theCountsAddUpToExamined() {
        var copy = fact(1, path: "\(vhsFolder)/test_zz_copy.mkv")
        copy.digest = hex(1)
        let resolved = ProvenanceResolver.resolve([
            fact(1, path: "\(vhsFolder)/test_x.mkv"), copy,                                   // one content, a byte copy
            fact(2, path: "\(vhsFolder)/test_x_trim.mkv", seconds: 1_500),                    // shorter, name-related
            fact(3, codec: "h264"), fact(4, path: "/Volumes/Fixture/Elsewhere/test.mkv"),     // do not qualify
            fact(5, path: "\(vhsFolder)/test_y.mkv"),
        ])
        #expect(resolved.examined == 6)
        #expect(resolved.notQualifying == 2)
        #expect(resolved.byteCopies == 1)
        #expect(resolved.qualified == 3)
        #expect(resolved.shorterDigests == [hex(2)])
        #expect(resolved.examined == resolved.notQualifying + resolved.byteCopies + resolved.qualified)
        #expect(resolved.qualified == resolved.proposals.count + resolved.shorterUnclassified)
    }

    @Test func ricksOwnRoleWinsOnEverySurface() throws {
        let confirmed = ProvenanceEstimate(role: .master, carrier: "VHS", captureSetupID: nil, isConfirmed: true)
        #expect(ProvenanceResolver.visible(confirmed, rickRole: .master) == confirmed)
        #expect(ProvenanceResolver.visible(confirmed, rickRole: .editCopy) == nil)
        // Unknown after a Confirm takes his word back: shown, but provisional again.
        let withdrawn = try #require(ProvenanceResolver.visible(confirmed, rickRole: .unknown))
        #expect(!withdrawn.isConfirmed)
        #expect(withdrawn.role == .master)
        let provisional = ProvenanceEstimate(role: .master, carrier: "VHS", captureSetupID: nil, isConfirmed: false)
        #expect(ProvenanceResolver.visible(provisional, rickRole: .unknown) == provisional)
        #expect(ProvenanceResolver.visible(provisional, rickRole: .alternateCapture) == nil)
    }

    @Test func theDossierLineYieldsToRicksRole() throws {
        let r = VideoRecord()
        r.streamTypeRaw = "Video+Audio"
        var rows = inferred()
        for (i, field) in ProvenanceEstimateRule.fields.enumerated() {
            rows.append(row(Int64(10 + i), field, rows[i].value, state: "confirmed", by: "rick"))
        }
        #expect(FileDossier.provenanceLine(r, assertions: rows, rickRole: .master)?.standing == .fact)
        #expect(FileDossier.provenanceLine(r, assertions: rows, rickRole: .editCopy) == nil)
        let again = try #require(FileDossier.provenanceLine(r, assertions: rows, rickRole: .unknown))
        #expect(again.standing == .observation, "Set Role ▸ Unknown after a Confirm: provisional again")
        #expect(again.reading == "estimated, unconfirmed")
        #expect(FileDossier.build(record: r, digest: hex(1), assertions: rows, rickRole: .editCopy, now: july2026).patterns.line("Provenance") == nil)
    }

    @Test func aWithdrawalRowLeavesNothingStandingAndASecondOneIsNotNeeded() throws {
        var rows = inferred()
        #expect(ProvenanceResolver.withdrawable(rows) == .master)
        let draft = ProvenanceProposal.withdrawal(digest: hex(1), why: "test: it may be a trim", at: 9)
        #expect(draft.field == "role")
        #expect(draft.value == "unknown")
        #expect(draft.state == "inferred")
        #expect(draft.by == ProvenanceEstimateRule.signer)
        let evidence = try #require(try JSONSerialization.jsonObject(with: Data(draft.evidenceJSON.utf8)) as? [String: Any])
        #expect(evidence["rule"] as? String == "withdrawn")
        #expect(evidence["why"] as? String == "test: it may be a trim")
        rows.append(row(4, "role", "unknown", evidence: draft.evidenceJSON))
        #expect(ProvenanceResolver.estimate(fromRowsOfOneSubject: rows) == nil)
        #expect(ProvenanceResolver.withdrawable(rows) == nil, "already withdrawn: a second run writes nothing")
        #expect(ProvenanceResolver.evidenceWords(fromRowsOfOneSubject: rows)?.contains("withdrawn") == false)
        // The rule proposing it again is written as a NEW newest row, never called a duplicate of the old one.
        let again = CatalogRow.ProvenanceAssertionDraft(subjectKind: "content", subjectID: hex(1), field: "role", value: "master",
                                                        state: "inferred", by: ProvenanceEstimateRule.signer, at: 50, confidence: 0.9,
                                                        evidenceJSON: "{}")
        #expect(ProvenanceResolver.standingAt(of: again, among: rows) == nil)
        rows.append(row(5, "role", "master"))
        #expect(ProvenanceResolver.estimate(fromRowsOfOneSubject: rows)?.role == .master)
        #expect(ProvenanceResolver.standingAt(of: again, among: rows) == rows[4].at)
    }

    @Test func whatMayBeWithdrawn() {
        #expect(ProvenanceResolver.withdrawable([]) == nil)
        #expect(ProvenanceResolver.withdrawable([row(1, "role", "master", by: "machine:test/other/rule@r1")]) == nil, "another signer's role is not ours to take back")
        #expect(ProvenanceResolver.withdrawable([row(1, "role", "master"), row(2, "role", "master", state: "rejected", by: "rick")]) == nil,
                "Rick rejected it: nothing stands already")
        #expect(ProvenanceResolver.withdrawable([row(1, "role", "zzz")]) == nil)
        #expect(ProvenanceResolver.withdrawable([row(1, "role", "alternateCapture")]) == .alternateCapture)
    }

    @Test func ricksConfirmationOutlivesAWithdrawal() throws {
        var rows = inferred()
        for (i, field) in ProvenanceEstimateRule.fields.enumerated() {
            rows.append(row(Int64(10 + i), field, rows[i].value, state: "confirmed", by: "rick"))
        }
        rows.append(row(20, "role", "unknown", evidence: ProvenanceProposal.withdrawal(digest: hex(1), why: "test", at: 1).evidenceJSON))
        let estimate = try #require(ProvenanceResolver.estimate(fromRowsOfOneSubject: rows))
        #expect(estimate.isConfirmed, "his word stands; the machine took back only its own")
        #expect(estimate.role == .master)
    }

    @Test func theWithdrawalRowPassesTheDoorAndIsNotVetoed() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.execute(sql: "INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, 100, 1700000000, 'rescan')",
                           arguments: [hex(1)])
        }
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let proposal = try #require(ProvenanceResolver.resolve([fact(1)]).proposals.first)
        let box = Landings()
        _ = await repository.write(as: .ui) { tx in
            for d in proposal.drafts(at: 100) { box.append(try tx.appendProvenanceAssertion(d)) }
            box.append(try tx.appendProvenanceAssertion(ProvenanceProposal.withdrawal(digest: hex(1), why: "test", at: 200)))
        }
        #expect(box.items.count == 4)
        #expect(box.items.allSatisfy { if case .recorded = $0 { return true } else { return false } }, "\(box.items)")
        let rows = try await repository.read { try $0.provenanceAssertions(subjectKind: "content", subjectID: hex(1)) }
        #expect(ProvenanceResolver.estimate(fromRowsOfOneSubject: rows) == nil)
        await repository.close()
    }
}
