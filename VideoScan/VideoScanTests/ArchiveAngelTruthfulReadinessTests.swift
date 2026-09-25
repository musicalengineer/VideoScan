// ArchiveAngelTruthfulReadinessTests.swift
// Rules v12 — "truthful readiness" (docs/archive_angel_wise_design.md §3,
// 2026-09-25). Measured on the live catalog that morning: the Angel's own
// buffer companions listed as Worth a look, VHS tapes digitized in 2026
// listed as Ready under 2026, Person Finder compilations as Ready, and a
// 43 GB / 37 s broken encode graded like a tape. Each rule below has a
// positive and a negative, the safety floor a refusal test, the footage
// pre-pass a 100k budget.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let now = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-25 (UTC)

private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: DateComponents(year: y, month: m, day: d))!
}

// MARK: - 1. The working-copy safety floor

@Suite("rules v12 — the Angel's buffer is never material (angelWorkingCopy safety floor)", .serialized)
struct ArchiveAngelWorkingCopyFloorTests {

    @Test("a flagged working copy is excluded with its own reason, star or not; an unflagged twin passes")
    func floor() {
        let copy = ArchiveAngelCandidate(filename: "Tape.vs.preserve.mkv", durationSeconds: 3600, starRating: 3,
                                         isAngelWorkingCopy: true)
        #expect(ArchiveAngelScorer.hardFloor(copy, now: now) == .angelWorkingCopy)
        #expect(ArchiveAngelScorer.safetyHit(copy, now: now) == .angelWorkingCopy, "a SAFETY floor — its own pass")
        #expect(ArchiveAngelRejection.safetyReasons.contains(.angelWorkingCopy))
        let plain = ArchiveAngelCandidate(filename: "Tape.vs.preserve.mkv", durationSeconds: 3600, starRating: 3)
        #expect(ArchiveAngelScorer.hardFloor(plain, now: now) == nil)
    }

    @Test("the floor sits right after onMasterArchive and is a safety floor a policy.json cannot switch off, narrow or loosen")
    func refusedWhole() {
        let ids = AngelPolicyDefaults.floors.map(\.id)
        #expect(ids.firstIndex(of: "angelWorkingCopy") == (ids.firstIndex(of: "onMasterArchive") ?? -2) + 1)
        #expect(AngelPolicyDefaults.safetyFloorIDs.contains("angelWorkingCopy"))
        for json in [#"{"schemaVersion":2,"floors":[{"id":"angelWorkingCopy","enabled":false}]}"#,
                     #"{"schemaVersion":2,"floors":[{"id":"angelWorkingCopy","starExempt":true}]}"#,
                     #"{"schemaVersion":2,"floors":[{"id":"angelWorkingCopy","when":[{"field":"starRating","op":"==","value":0}]}]}"#] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("policy.json")
            try? Data(json.utf8).write(to: url)
            let loaded = AngelRecommendationPolicy.load(overrideURL: url, bundledURL: nil)
            #expect(loaded.source == .builtIn, "refused whole: \(json)")
            #expect(loaded.notices.first?.contains("safety floor") == true, "\(loaded.notices)")
        }
    }

    @Test("isUnder(bufferRoot:) — the root and its descendants only; a sibling with the same prefix is outside")
    func prefix() {
        let root = URL(fileURLWithPath: "/Users/r/Movies/VideoScan Buffer/ArchiveAngel/")
        #expect(ArchiveAngelCandidate.isUnder(bufferRoot: root, path: "/Users/r/Movies/VideoScan Buffer/ArchiveAngel/batch-1/x.mov"))
        #expect(ArchiveAngelCandidate.isUnder(bufferRoot: root, path: "/Users/r/Movies/VideoScan Buffer/ArchiveAngel"))
        #expect(!ArchiveAngelCandidate.isUnder(bufferRoot: root, path: "/Users/r/Movies/VideoScan Buffer/ArchiveAngelOld/x.mov"))
        #expect(!ArchiveAngelCandidate.isUnder(bufferRoot: root, path: "/Volumes/LaCie/x.mov"))
        #expect(!ArchiveAngelCandidate.isUnder(bufferRoot: URL(fileURLWithPath: "/"), path: "/Volumes/LaCie/x.mov"), "a root of / never claims the world")
    }

    @Test("the projection flags a record under the façade's buffer root and the sweep builder excludes it")
    @MainActor
    func projected() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("angel_workingcopy")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        let root = model.archiveAngel.environment.bufferRoot
        let inside = root.appendingPathComponent("batch-2026-09-24T20-01-51/Tape.vs.archive.mov").path
        let outside = sb.sources.appendingPathComponent("Tape.mov").path
        for (path, star) in [(inside, 3), (outside, 3)] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try MasterArchiveTestSupport.writeBlob(at: URL(fileURLWithPath: path), bytes: 4096, seed: 9)
            let rec = MasterArchiveTestSupport.makeRecord(path: path, starRating: star)
            rec.durationSeconds = 3600; rec.sizeBytes = 9_000_000_000; rec.isPlayable = "Yes"; rec.videoCodec = "dvvideo"
            rec.userDate = "1994"
            model.records.append(rec)
        }
        let out = model.archiveAngelSweepCandidates()
        let buffer = try #require(out.first { $0.fullPath == inside })
        let tape = try #require(out.first { $0.fullPath == outside })
        #expect(buffer.isAngelWorkingCopy && !tape.isAngelWorkingCopy)
        #expect(ArchiveAngelScorer.hardFloor(buffer) == .angelWorkingCopy)
        #expect(ArchiveAngelScorer.hardFloor(tape) == nil)
    }
}

// MARK: - 3/4. The yearsAgo field and the two class rules

@Suite("rules v12 — yearsAgo, recentDigitization and absurdBitrate class rules", .serialized)
struct ArchiveAngelV12ClassRuleTests {

    private func evidence(_ c: ArchiveAngelCandidate, score: Int) -> [UUID: ArchiveAngelEvidenceRecord] {
        [c.id: .init(score: score, lines: [], rejection: nil, useCount: 0, lastUsed: nil, computedAt: now)]
    }

    private func classify(_ c: ArchiveAngelCandidate, score: Int = 120) -> ArchiveAngelRecommendations.Verdict {
        ArchiveAngelRecommendations.classify([c], evidence: evidence(c, score: score), rules: .standard, now: now).verdicts[0]
    }

    /// A tape converted this year: FFV1, no device, a capture-tool filename.
    private func digitized(codec: String = "ffv1", device: String = "", name: String = "2026-07-05_13-15-36.mkv",
                           embedded: Date? = nil, user: String? = nil, important: Bool = true) -> ArchiveAngelCandidate {
        ArchiveAngelCandidate(filename: name, fullPath: "/Volumes/Projects/Converted_VHS_Tapes_2026/\(name)",
                              sizeBytes: 20_000_000_000, durationSeconds: 3000,
                              mediaDisposition: important ? .important : .unreviewed,
                              userDate: user, videoCodec: codec, deviceModel: device, captureDate: embedded,
                              originEncoder: embedded == nil ? nil : "Lavf61")
    }

    @Test("yearsAgo reads the ONE date rule's year: 0 for a 2026 filename stamp, 34 for a 1992 camera stamp, nil when undated")
    func yearsAgo() {
        // One context per record (it caches the date resolution) — as the
        // scorer and the classifier make them.
        func yearsAgo(_ c: ArchiveAngelCandidate) -> Double? {
            var ctx = AngelEvalContext(now: now)
            return ctx.number(.yearsAgo, c)
        }
        #expect(yearsAgo(digitized()) == 0)
        let camera = ArchiveAngelCandidate(filename: "MVI_0012.MOV", deviceModel: "Sony DCR", captureDate: utc(1992, 6, 1))
        #expect(yearsAgo(camera) == 34)
        #expect(yearsAgo(ArchiveAngelCandidate(filename: "tape7.dv")) == nil)
        #expect(AngelField.yearsAgo.kind == .number)
        // A condition on an undated file never matches — even "!=".
        var ctx = AngelEvalContext(now: now)
        let cond = AngelCondition(field: .yearsAgo, op: .ne, value: .number(99))
        #expect(!cond.matches(ArchiveAngelCandidate(filename: "tape7.dv"), &ctx))
    }

    @Test("a vouched FFV1/ProRes/DV/MPEG-2/MJPEG file dated within the last year with no camera → Needs a date, with the reason and the year")
    func recentDigitizationFires() {
        for codec in AngelPolicyDefaults.recentDigitizationCodecs {
            let v = classify(digitized(codec: codec))
            #expect(v.kind == .needsDate, "\(codec): \(v.kind)")
            #expect(v.reasons.first == "Dated 2026, but it looks like a digitization of older footage — confirm when it was filmed", "\(codec): \(v.reasons)")
        }
        // A conversion stamp with no camera behind it and no year in the name: the same.
        let stamped = classify(digitized(name: "Montana tape.mov", embedded: utc(2026, 5, 19)))
        #expect(stamped.kind == .needsDate)
    }

    @Test("it does not fire on an iPhone clip, on H.264, on a file dated two years ago, on an unvouched grade C, or once the person typed a year")
    func recentDigitizationSpares() {
        #expect(classify(digitized(codec: "prores", device: "iPhone 12")).kind == .ready, "a camera named it")
        #expect(classify(digitized(codec: "h264")).kind == .ready, "a delivery codec is not a digitizer's")
        // QA v12 #5: a make-only stamp names a camera too (the resolver trusts it at 0.95).
        let sony = ArchiveAngelCandidate(filename: "Tape.mov", fullPath: "/Volumes/Projects/Tape.mov",
                                         sizeBytes: 20_000_000_000, durationSeconds: 3000,
                                         mediaDisposition: .important, videoCodec: "prores",
                                         captureDate: utc(2026, 5, 19), originMake: "Sony")
        #expect(classify(sony).kind == .ready, "a make-only camera stamp is a camera")
        var ctx = AngelEvalContext(now: now)
        #expect(ctx.flag(.hasCameraOrigin, sony) == true)
        #expect(ctx.flag(.hasCameraOrigin, digitized()) == false)
        #expect(classify(digitized(name: "2024-07-05_13-15-36.mkv")).kind == .ready, "two years ago")
        #expect(classify(digitized(important: false), score: 30).kind == .notNow, "nothing vouched, grade C — not promoted into Needs a date")
        #expect(classify(digitized(user: "1994")).kind == .ready, "Rick's year outranks everything")
        #expect(classify(digitized(user: "2026")).kind == .ready, "…even when it IS this year")
    }

    @Test("a recommendable file over 1 Gbit/s is Worth a look with the reason; 999,999 kbit/s and an unvouched grade C are not")
    func absurdBitrate() {
        // 37 s at 43.4 GB (the live CapeCod_June_1997.mp4) → ~9.4 Gbit/s.
        func file(bytes: Int64, seconds: Double, stars: Int = 3) -> ArchiveAngelCandidate {
            ArchiveAngelCandidate(filename: "CapeCod_June_1997.mp4", sizeBytes: bytes, durationSeconds: seconds,
                                  starRating: stars, userDate: "1997", videoCodec: "h264")
        }
        let broken = classify(file(bytes: 43_400_000_000, seconds: 37))
        #expect(broken.kind == .worthALook)
        #expect(broken.reasons.first == AngelPolicyDefaults.absurdBitrateLine)
        // Exactly at the line: 1,000,000 kbit/s over 120 s = 15,000,000,000 bytes.
        #expect(classify(file(bytes: 15_000_000_000, seconds: 120)).kind == .worthALook)
        #expect(classify(file(bytes: 14_999_999_000, seconds: 120)).kind == .ready, "just under")
        // Grade B, nobody vouched: still Worth a look (recommendedAtAll), with the reason first.
        let b = classify(file(bytes: 43_400_000_000, seconds: 37, stars: 0), score: 70)
        #expect(b.kind == .worthALook && b.reasons.first == AngelPolicyDefaults.absurdBitrateLine)
        // Grade C, nobody vouched: Not now — the rule never lifts a file.
        #expect(classify(file(bytes: 43_400_000_000, seconds: 37, stars: 0), score: 30).kind == .notNow)
    }

    @Test("both rules are data: a policy.json class rule with a line is decoded, encoded and validated (a 301-character line is refused)")
    func classRuleLineRoundTrip() throws {
        let rule = AngelClassRule(.worthALook, when: [.init(field: .yearsAgo, op: .le, value: .number(1))], line: "Dated {year} — check")
        let data = try JSONEncoder().encode(rule)
        let back = try JSONDecoder().decode(AngelClassRule.self, from: data)
        #expect(back == rule)
        #expect(back.reasonLine(year: 2026) == "Dated 2026 — check")
        // QA v12 #8: no year is "undated", never a claim of this year.
        #expect(back.reasonLine(year: nil) == "Dated undated — check")
        #expect(AngelClassRule(.ready).reasonLine(year: 2026) == nil)
        var rules = AngelRecommendRules.standard
        rules.classes.insert(AngelClassRule(.ready, line: String(repeating: "x", count: 301)), at: 0)
        #expect(rules.problems.contains { $0.contains("line/note longer") })
        #expect(AngelRecommendRules.standard.problems.isEmpty)
        #expect(AngelRecommendationPolicy.builtIn.validationProblems().isEmpty)
    }

    @Test("the Archive Readiness sheet translates both reasons into plain sentences without the internal numbers")
    func explained() {
        let a = ArchiveAngelReadinessExplanation.sentence(forReason: AngelPolicyDefaults.absurdBitrateLine)
        #expect(a?.contains("broken encode") == true, "\(a ?? "nil")")
        let d = ArchiveAngelReadinessExplanation.sentence(forReason:
            "Dated 2026, but it looks like a digitization of older footage — confirm when it was filmed")
        #expect(d?.contains("2026") == true && d?.contains("confirm the year") == true, "\(d ?? "nil")")
    }
}

// MARK: - 5. Person Finder compilations are app output

@Suite("rules v12 — Person Finder compilations are an app's output, not originals")
struct ArchiveAngelCompilationTableTests {

    @Test("the stem glob matches a compilation wherever it was copied; a bare 'compilation' or a family name does not")
    func glob() {
        let m = AngelPolicyTables.standard.appCacheStemMatcher
        #expect(AngelPolicyTables.standard.appCacheStemGlobs == ["*_compilation_*"])
        #expect(AngelStemMatcher.problems(names: [], globs: ["*_compilation_*"]).isEmpty)
        #expect(m.matches("Donna_compilation_39_h264_720p2398_aac44k_1ch"))
        #expect(m.matches("TIM_COMPILATION_2_HEVC"))
        #expect(!m.matches("compilation"))
        #expect(!m.matches("Donna_compilation"), "needs the trailing `_…` the exporter writes")
        #expect(!m.matches("Christmas 1990 compilation tape"))
    }

    @Test("the folder and the stem each fire the appCache floor; a star does not override an app's output folder")
    func floor() {
        let t = AngelPolicyTables.standard
        #expect(t.appCacheFolders.contains("personsearchresults"))
        let inFolder = ArchiveAngelCandidate(filename: "Donna.mov", fullPath: "/Volumes/CrucialX9/PersonSearchResults/Donna.mov",
                                             durationSeconds: 600)
        #expect(ArchiveAngelScorer.hardFloor(inFolder, now: now) == .appCache)
        let byStem = ArchiveAngelCandidate(filename: "Donna_compilation_65_h264_720p2997_aac48k_2ch.mp4",
                                           fullPath: "/Volumes/Projects/Movies/Donna_compilation_65_h264_720p2997_aac48k_2ch.mp4",
                                           durationSeconds: 600)
        #expect(ArchiveAngelScorer.hardFloor(byStem, now: now) == .appCache)
        // The appCache floor is star-exempt by design (a person's star wins) — pinned so a change is deliberate.
        var starred = byStem; starred.starRating = 2
        #expect(ArchiveAngelScorer.hardFloor(starred, now: now) == nil)
    }
}

// MARK: - 6. A footage group whose original is archived is done

@Suite("rules v12 — a footage group's archived original excludes its other members", .serialized)
struct ArchiveAngelArchivedFootageTests {

    private func member(group: UUID, rank: Int, confidence: FootageConfidence = .likely) -> ArchiveAngelCandidate {
        ArchiveAngelCandidate(filename: "m\(rank).mov", durationSeconds: 3600, starRating: 2, userDate: "1994",
                              footageGroupID: group, footageRank: rank, footageConfidence: confidence)
    }

    @Test("the pure pass flags rank > 0 members of a Likely-or-stronger group in the archived set — never rank 0, never Possible, never another group")
    func pass() {
        let g = UUID(), other = UUID()
        var cs = [member(group: g, rank: 0), member(group: g, rank: 1), member(group: g, rank: 2, confidence: .identical),
                  member(group: g, rank: 3, confidence: .possible), member(group: other, rank: 1),
                  ArchiveAngelCandidate(filename: "lone.mov")]
        ArchiveAngelScorer.markArchivedFootage(&cs, archivedGroups: [g])
        #expect(cs.map(\.archivedFootageOriginal) == [false, true, true, false, false, false])
        // QA v12 #6: its OWN reason — no byte copy of it is in the archive.
        #expect(ArchiveAngelScorer.hardFloor(cs[1], now: now) == .footageOriginalArchived)
        #expect(ArchiveAngelScorer.safetyHit(cs[1], now: now) == .footageOriginalArchived, "…and it is a safety floor")
        #expect(ArchiveAngelRejection.safetyReasons.contains(.footageOriginalArchived))
        // A real byte copy in the archive keeps the byte-copy reason, even in an archived group.
        var both = cs[1]; both.hasArchivedDuplicate = true
        #expect(ArchiveAngelScorer.hardFloor(both, now: now) == .duplicateArchived)
        // The Readiness sheet says it in words.
        #expect(ArchiveAngelReadinessExplanation.sentence(forReason: ArchiveAngelRejection.footageOriginalArchived.rawValue)?
                    .contains("Find Similar Footage") == true)
        #expect(ArchiveAngelScorer.hardFloor(cs[0], now: now) == nil, "the original answers for itself")
        var none = [member(group: g, rank: 1), member(group: other, rank: 2)]
        ArchiveAngelScorer.markArchivedFootage(&none, archivedGroups: [])
        #expect(!none.contains { $0.archivedFootageOriginal })
    }

    @Test("the model's pre-pass: a group whose likely original has an archive copy is in the set; a Possible group and a group with an unarchived original are not")
    @MainActor
    func modelPrePass() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("angel_footage_archived")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        func add(_ name: String) throws -> VideoRecord {
            let path = sb.sources.appendingPathComponent(name).path
            try MasterArchiveTestSupport.writeBlob(at: URL(fileURLWithPath: path), bytes: 4096, seed: 5)
            let rec = MasterArchiveTestSupport.makeRecord(path: path, starRating: 2)
            rec.durationSeconds = 3600; rec.sizeBytes = 9_000_000_000; rec.isPlayable = "Yes"; rec.videoCodec = "dvvideo"
            rec.userDate = "1994"
            model.records.append(rec)
            return rec
        }
        func join(_ r: VideoRecord, _ g: UUID, original: UUID, rank: Int, conf: FootageConfidence = .likely) {
            r.footage = FootageMembership(groupID: g, groupSize: 2, confidence: conf, role: rank == 0 ? .original : .reEncode,
                                          rank: rank, likelyOriginalID: original, originalInCatalog: true, evidence: [],
                                          scannedAt: now, algorithmVersion: 1)
        }
        // Group A: the original is an archive copy (promoted) → the re-encode is done.
        let a0 = try add("A_original.dv"); a0.derivationKind = ArchivePromotion.derivationKind
        let a1 = try add("A_reencode.mp4")
        let ga = UUID(); join(a0, ga, original: a0.id, rank: 0); join(a1, ga, original: a0.id, rank: 1)
        // Group B: nothing archived → both stay.
        let b0 = try add("B_original.dv"), b1 = try add("B_reencode.mp4")
        let gb = UUID(); join(b0, gb, original: b0.id, rank: 0); join(b1, gb, original: b0.id, rank: 1)
        // Group C: archived original but only a Possible link → shown, not decided.
        let c0 = try add("C_original.dv"); c0.derivationKind = ArchivePromotion.derivationKind
        let c1 = try add("C_maybe.mp4")
        let gc = UUID(); join(c0, gc, original: c0.id, rank: 0, conf: .possible); join(c1, gc, original: c0.id, rank: 1, conf: .possible)

        let active = pfActiveRecords(model.records)
        #expect(model.archivedFootageGroupIDs(active) == [ga])
        let out = model.archiveAngelSweepCandidates()
        func by(_ r: VideoRecord) -> ArchiveAngelCandidate? { out.first { $0.id == r.id } }
        #expect(by(a1)?.archivedFootageOriginal == true)
        #expect(by(a1).map { ArchiveAngelScorer.hardFloor($0) } == .footageOriginalArchived)
        #expect(by(b1)?.archivedFootageOriginal == false && by(b0)?.archivedFootageOriginal == false)
        #expect(by(b1).map { ArchiveAngelScorer.hardFloor($0) } == .some(nil))
        #expect(by(c1)?.archivedFootageOriginal == false)
    }

    @Test("SCALE: the pass over 100k candidates (every fourth in an archived group) is O(n) — under the Debug budget")
    func budget() {
        let groups = (0..<1_000).map { _ in UUID() }
        var cs: [ArchiveAngelCandidate] = []
        cs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            cs.append(member(group: groups[i % groups.count], rank: i % 4, confidence: i % 7 == 0 ? .possible : .likely))
        }
        let archived = Set(groups.prefix(250))
        let clock = ContinuousClock()
        let elapsed = clock.measure { ArchiveAngelScorer.markArchivedFootage(&cs, archivedGroups: archived) }
        let flagged = cs.filter(\.archivedFootageOriginal).count
        print("[angel-v12] archived-footage pass over 100k: \(elapsed), flagged \(flagged)")
        #expect(flagged > 10_000 && flagged < 25_000)
        #expect(elapsed < PerformanceLane.debugCeiling(.milliseconds(200)), "pass took \(elapsed)")
    }
}
